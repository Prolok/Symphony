defmodule SymphonyElixir.ProjectPoller do
  @moduledoc "One durable relay consumer per workspace, shared by project loops and retries."
  use GenServer
  require Logger

  alias SymphonyElixir.Linear.{Client, RateLimit}
  alias SymphonyElixir.{ProjectContext, Projects, Relay}
  alias SymphonyElixir.Relay.Session

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec candidates(ProjectContext.t()) :: {:ok, list()} | {:error, term()}
  def candidates(context), do: GenServer.call(__MODULE__, {:candidates, context.id}, 120_000)

  @spec context(ProjectContext.t()) :: ProjectContext.t()
  def context(context), do: GenServer.call(__MODULE__, {:context, context.id}, 120_000)

  @spec refresh() :: :ok
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @spec relay_issues(ProjectContext.t() | nil, [String.t()]) :: {:ok, list()} | {:error, term()}
  def relay_issues(context, ids), do: relay_call({:relay_issues, context, ids})

  @spec comment_epoch(ProjectContext.t() | nil, String.t()) :: {:ok, term()} | {:error, term()}
  def comment_epoch(context, id), do: relay_call({:comment_epoch, context, id})

  defp relay_call(message) do
    GenServer.call(__MODULE__, message, 120_000)
  catch
    :exit, _ -> {:error, :relay_unavailable}
  end

  @spec service_settings() :: SymphonyElixir.Config.Schema.t() | nil
  def service_settings do
    :ets.lookup_element(__MODULE__, :settings, 2)
  rescue
    ArgumentError -> nil
  end

  @spec polling() :: map()
  def polling do
    GenServer.call(__MODULE__, :polling, 50)
  catch
    :exit, _ -> %{checking?: true, next_poll_in_ms: nil, poll_interval_ms: nil}
  end

  @impl true
  def init(opts) do
    contexts = Keyword.fetch!(opts, :contexts)
    interval = contexts |> Enum.map(& &1.settings.polling.interval_ms) |> Enum.min()

    case verify_initial_workspace_assignees(contexts) do
      {:ok, verified_workspaces} ->
        state = %{
          contexts: contexts,
          interval: interval,
          result: Map.new(contexts, &{&1.id, {:error, :initial_poll_pending}}),
          timer: nil,
          timer_token: nil,
          relays: %{},
          verified_workspaces: verified_workspaces
        }

        :ets.new(__MODULE__, [:named_table, :protected, read_concurrency: true])
        publish_settings(contexts)
        {:ok, state, {:continue, :poll}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:poll, state), do: {:noreply, poll(state)}

  @impl true
  def handle_call(:polling, _from, state) do
    remaining = if state.timer, do: Process.read_timer(state.timer), else: false

    relays =
      Map.new(state.relays, fn {workspace, entry} ->
        status = entry |> Map.take([:status, :error, :retry_at]) |> Map.update!(:error, &if(&1, do: inspect(&1), else: nil))

        execution = execution_summary(entry)

        consumer = if match?(%Session{}, entry), do: entry.record["consumer"]
        {workspace, status |> Map.put(:execution, execution) |> Map.put(:consumer_id, consumer)}
      end)

    polling = %{checking?: false, next_poll_in_ms: remaining || 0, poll_interval_ms: state.interval, relay: relays}
    {:reply, polling, state}
  end

  def handle_call({:candidates, id}, _from, state) do
    {:reply, Map.fetch!(state.result, id), state}
  end

  def handle_call({:context, id}, _from, state) do
    {:reply, Enum.find(state.contexts, &(&1.id == id)), state}
  end

  def handle_call({:relay_issues, %ProjectContext{} = context, ids}, _from, state) do
    workspace = context.settings.tracker.app["workspace_id"]

    case state.relays[workspace] do
      %Session{} = session ->
        session = Session.watch(session, ids)

        result =
          if session.status == :ready do
            nodes = session.record["issues"] |> Map.take(ids) |> Map.values()
            {:ok, ProjectContext.with_context(context, fn -> Enum.map(nodes, &Client.relay_issue/1) end)}
          else
            {:error, {:relay_not_ready, session.status}}
          end

        {:reply, result, put_in(state.relays[workspace], session)}

      _ ->
        {:reply, {:error, :relay_unavailable}, state}
    end
  end

  def handle_call({:comment_epoch, %ProjectContext{} = context, id}, _from, state) do
    workspace = context.settings.tracker.app["workspace_id"]

    result =
      case state.relays[workspace] do
        %Session{status: :ready, record: record} ->
          if id in record["known"], do: {:ok, {record["generation"], record["epochs"][id]}}, else: {:error, :relay_issue_unknown}

        _ ->
          {:error, :relay_unavailable}
      end

    {:reply, result, state}
  end

  def handle_call({operation, _, _}, _from, state) when operation in [:relay_issues, :comment_epoch],
    do: {:reply, {:error, :relay_context_required}, state}

  @impl true
  def handle_cast(:refresh, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, poll(state)}
  end

  @impl true
  def handle_info({:poll, token}, %{timer_token: token} = state), do: {:noreply, poll(state)}
  def handle_info({:poll, _stale_token}, state), do: {:noreply, state}

  defp poll(state) do
    contexts = Enum.map(state.contexts, &ProjectContext.refresh/1)
    interval = contexts |> Enum.map(& &1.settings.polling.interval_ms) |> Enum.min()
    state = %{state | contexts: contexts, interval: interval}
    :ok = SymphonyElixir.WorkerCapacity.configure(contexts)
    publish_settings(contexts)
    groups = Enum.group_by(contexts, & &1.settings.tracker.app["workspace_id"])

    {results, relays} =
      Enum.map_reduce(groups, state.relays, fn group, relays ->
        {candidates, delay, relays} = poll_workspace(group, relays)
        {{candidates, delay}, relays}
      end)

    result = results |> Enum.map(&elem(&1, 0)) |> Enum.reduce(%{}, &Map.merge/2)
    token = make_ref()
    delay = results |> Enum.map(&elem(&1, 1)) |> Enum.min()
    timer = Process.send_after(self(), {:poll, token}, delay)

    for context <- state.contexts do
      if pid = GenServer.whereis(Projects.server(context)), do: send(pid, {:project_poll, context})
    end

    %{state | result: result, timer: timer, timer_token: token, relays: relays}
  end

  defp execution_status(config, record, assignee) do
    case Relay.owner(config["owners"], assignee, record["consumer"]) do
      :ok -> "zuständig"
      {:error, :relay_other_executor} -> "empfängt; anderer Rechner zuständig"
      _ -> "Starts gesperrt: Zuordnung fehlt oder ist mehrdeutig"
    end
  end

  defp execution_summary(%Session{record: record, config: config}) do
    assignees = Enum.uniq(record["subscription"]["assigneeIds"] ++ Map.keys(config["owners"]))
    assignees = if assignees == [], do: ["Zuständigkeit nicht konfiguriert"], else: assignees
    Map.new(assignees, &{&1, execution_status(config, record, &1)})
  end

  defp execution_summary(_), do: %{}

  defp poll_workspace({workspace, contexts}, relays) do
    entry = relay_tick(relays[workspace], contexts)

    result =
      case entry do
        %Session{} -> Relay.candidates(entry, contexts)
        %{error: reason} -> {:error, reason}
      end

    if entry.status != get_in(relays, [workspace, Access.key(:status)]),
      do: Logger.info("Relay state workspace_id=#{workspace} status=#{entry.status} reason=#{inspect(entry.error)}")

    candidates =
      Map.new(contexts, fn context ->
        scoped =
          case result do
            {:ok, found} -> {:ok, Map.fetch!(found, context.id)}
            error -> error
          end

        {context.id, scoped}
      end)

    interval = contexts |> Enum.map(& &1.settings.polling.interval_ms) |> Enum.min()
    cooldown = contexts |> Enum.map(&ProjectContext.with_context(&1, fn -> RateLimit.remaining_ms() end)) |> Enum.max()

    candidates =
      if cooldown > 0 do
        Map.new(candidates, fn
          {id, {:ok, _}} -> {id, {:error, {:linear_app_rate_limited, %{retry_after_ms: cooldown}}}}
          entry -> entry
        end)
      else
        candidates
      end

    delay = max(interval, max(cooldown, entry.retry_at - System.system_time(:millisecond)))
    {candidates, delay, Map.put(relays, workspace, entry)}
  end

  defp relay_tick(%Session{} = session, contexts) do
    # Accepted workflow reloads affect future snapshots and local routing.
    snapshot = &Client.fetch_relay_snapshot(contexts, &1)
    fetch = &Client.fetch_relay_issues(contexts, &1)
    %{session | snapshot: snapshot, fetch: fetch} |> Session.reconfigure(Relay.binding_key(contexts)) |> Session.tick()
  end

  defp relay_tick(previous, contexts) do
    now = System.system_time(:millisecond)

    if previous && previous.retry_at > now do
      previous
    else
      result = if hd(contexts).settings.tracker.relay, do: Relay.open(contexts), else: {:error, :missing_relay_configuration}

      case result do
        {:ok, session} -> Session.tick(session)
        {:error, reason} -> %{status: :degraded, error: reason, retry_at: now + 300_000}
      end
    end
  end

  defp verify_initial_workspace_assignees(contexts) do
    contexts
    |> Enum.group_by(& &1.settings.tracker.app["workspace_id"])
    |> Enum.reduce_while({MapSet.new(), []}, fn {workspace, grouped}, {verified, deferred} ->
      case Client.verify_project_assignees(grouped) do
        :ok -> {:cont, {MapSet.put(verified, workspace), deferred}}
        {:error, reason} -> initial_verification_error(reason, verified, deferred)
      end
    end)
    |> finish_initial_verification()
  end

  defp initial_verification_error(reason, verified, deferred) do
    if rate_limited?(reason) or temporary_startup_failure?(reason),
      do: {:cont, {verified, [reason | deferred]}},
      else: {:halt, {:error, reason}}
  end

  defp finish_initial_verification({:error, _reason} = error), do: error
  defp finish_initial_verification({verified, []}), do: {:ok, verified}

  defp finish_initial_verification({verified, deferred}) do
    if MapSet.size(verified) > 0 or Enum.all?(deferred, &rate_limited?/1),
      do: {:ok, verified},
      else: {:error, List.last(deferred)}
  end

  defp rate_limited?({:linear_api_status, _status, %{classification: "rate_limited"}}), do: true
  defp rate_limited?({:linear_app_rate_limited, _details}), do: true
  defp rate_limited?({:linear_api_request, reason}), do: rate_limited?(reason)
  defp rate_limited?(_reason), do: false

  defp temporary_startup_failure?({:linear_api_request, :linear_app_request_unavailable}),
    do: true

  defp temporary_startup_failure?({:linear_api_request, reason})
       when reason in [:linear_app_identity_unavailable, :linear_app_token_unavailable],
       do: true

  defp temporary_startup_failure?({:linear_api_status, status, _diagnostics})
       when status in 500..599,
       do: true

  defp temporary_startup_failure?(_reason), do: false

  defp publish_settings(contexts) do
    settings = hd(contexts).settings
    limit = contexts |> Enum.map(& &1.settings.agent.max_concurrent_agents) |> Enum.min()
    settings = %{settings | agent: %{settings.agent | max_concurrent_agents: limit}}
    :ets.insert(__MODULE__, {:settings, settings})
  end
end
