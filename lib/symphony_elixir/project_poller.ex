defmodule SymphonyElixir.ProjectPoller do
  @moduledoc "One periodic candidate fetch per workspace, shared by project loops and retries."
  use GenServer
  require Logger

  alias SymphonyElixir.Linear.{Client, RateLimit}
  alias SymphonyElixir.{ProjectContext, Projects}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec candidates(ProjectContext.t()) :: {:ok, list()} | {:error, term()}
  def candidates(context), do: GenServer.call(__MODULE__, {:candidates, context.id}, 120_000)

  @spec context(ProjectContext.t()) :: ProjectContext.t()
  def context(context), do: GenServer.call(__MODULE__, {:context, context.id}, 120_000)

  @spec refresh() :: :ok
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

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
    {:reply, %{checking?: false, next_poll_in_ms: remaining || 0, poll_interval_ms: state.interval}, state}
  end

  def handle_call({:candidates, id}, _from, state) do
    {:reply, Map.fetch!(state.result, id), state}
  end

  def handle_call({:context, id}, _from, state) do
    {:reply, Enum.find(state.contexts, &(&1.id == id)), state}
  end

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

    {results, verified_workspaces} =
      Enum.map_reduce(groups, state.verified_workspaces, fn group, verified ->
        {candidates, delay, verified} = poll_workspace(group, verified)
        {{candidates, delay}, verified}
      end)

    result = results |> Enum.map(&elem(&1, 0)) |> Enum.reduce(%{}, &Map.merge/2)
    token = make_ref()
    delay = results |> Enum.map(&elem(&1, 1)) |> Enum.min()
    timer = Process.send_after(self(), {:poll, token}, delay)

    for context <- state.contexts do
      if pid = GenServer.whereis(Projects.server(context)), do: send(pid, {:project_poll, context})
    end

    %{state | result: result, timer: timer, timer_token: token, verified_workspaces: verified_workspaces}
  end

  defp poll_workspace({workspace, contexts}, verified_workspaces) do
    {result, verified_workspaces} =
      case verify_workspace_assignees(workspace, contexts, verified_workspaces) do
        {:ok, verified} -> {Client.fetch_project_candidates(contexts), verified}
        {:error, reason, verified} -> {{:error, reason}, verified}
      end

    if match?({:error, _}, result),
      do: Logger.error("Gemeinsames Linear-Polling fehlgeschlagen workspace_id=#{workspace}: #{inspect(result)}")

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
    {candidates, max(interval, cooldown), verified_workspaces}
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

  defp verify_workspace_assignees(workspace, contexts, verified) do
    if MapSet.member?(verified, workspace) do
      {:ok, verified}
    else
      case Client.verify_project_assignees(contexts) do
        :ok -> {:ok, MapSet.put(verified, workspace)}
        {:error, reason} -> {:error, reason, verified}
      end
    end
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
