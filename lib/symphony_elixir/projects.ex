defmodule SymphonyElixir.Projects do
  @moduledoc "Discovery and aggregate observability for one service serving all projects."
  use GenServer

  alias SymphonyElixir.{EnvFile, Orchestrator, ProjectContext}
  alias SymphonyElixir.Linear.Client

  @snapshot_interval_ms 1_000
  @fresh_ms 2_000
  @expired_ms 300_000
  @idle_timeout_ms 1_000

  @spec configured() :: [ProjectContext.t()]
  def configured, do: Application.get_env(:symphony_elixir, :project_contexts, [])

  @spec prepare(Path.t(), Path.t()) :: :ok | {:error, term()}
  def prepare(code_root, workflow) do
    with {:ok, values} <- EnvFile.read_root(code_root),
         root_env <- Map.merge(Map.take(values, EnvFile.root_config_names()), Map.take(System.get_env(), EnvFile.root_config_names())),
         {:ok, roots} <- ProjectContext.discover(Map.get(root_env, "SYM_PROJECT_ROOT", "~/QuantHub"), code_root),
         false <- roots == [],
         {:ok, contexts} <- load_contexts(roots, workflow, root_env, code_root),
         :ok <- validate_workspace_roots(contexts),
         :ok <- Client.validate_workspace_bindings(contexts),
         :ok <- SymphonyElixir.TestInstance.validate_contexts(contexts),
         :ok <- SymphonyElixir.TestExecutor.validate_contexts(contexts),
         {:ok, contexts} <- SymphonyElixir.TestRun.bind_contexts(contexts) do
      Application.put_env(:symphony_elixir, :project_contexts, contexts)
      Application.put_env(:symphony_elixir, :service_settings, hd(contexts).settings)
      :ok
    else
      true -> {:error, :no_symphony_projects_found}
      error -> error
    end
  end

  @spec validate_workspace_roots([ProjectContext.t()]) :: :ok | {:error, term()}
  def validate_workspace_roots(contexts) do
    Enum.reduce_while(contexts, {:ok, []}, &check_workspace_root/2)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp check_workspace_root(context, {:ok, seen}) do
    case SymphonyElixir.PathSafety.canonicalize(context.settings.workspace.root) do
      {:ok, root} -> record_workspace_root(context, root, seen)
      error -> {:halt, error}
    end
  end

  defp record_workspace_root(context, root, seen) do
    case Enum.find(seen, fn {_, previous} -> roots_overlap?(root, previous) end) do
      nil -> {:cont, {:ok, [{context.root, root} | seen]}}
      {project, previous} -> {:halt, {:error, {:overlapping_project_worktree_roots, project, context.root, previous, root}}}
    end
  end

  defp roots_overlap?(a, b) do
    a == b or String.starts_with?(a, String.trim_trailing(b, "/") <> "/") or
      String.starts_with?(b, String.trim_trailing(a, "/") <> "/")
  end

  @spec server(ProjectContext.t()) :: GenServer.server()
  def server(context), do: {:via, Registry, {SymphonyElixir.ProjectRegistry, context.id}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, Orchestrator))

  @impl true
  def init(opts) do
    state = %{
      contexts: Keyword.fetch!(opts, :contexts),
      projects: %{},
      idle_check: nil,
      clock: Keyword.get(opts, :clock_fun, fn -> System.monotonic_time(:millisecond) end),
      shutdown: Keyword.get(opts, :shutdown_fun, fn -> Task.start(fn -> Application.stop(:symphony_elixir) end) end)
    }

    Process.send_after(self(), :check_idle, @snapshot_interval_ms)
    {:ok, reconcile_projects(state)}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.projects, fn {_, entry} -> release_project(entry) end)
    if state.idle_check, do: Process.cancel_timer(state.idle_check.timer)
  end

  @impl true
  def handle_info(:check_idle, state) do
    state = reconcile_projects(state)

    if state.idle_check == nil and map_size(state.projects) > 0 and
         Enum.all?(state.projects, fn {_, entry} -> entry.pid != nil and entry.request == nil end) do
      token = make_ref()
      now_ms = state.clock.()
      delay = state.projects |> Map.values() |> Enum.map(&snapshot_delay(&1, now_ms)) |> Enum.max()
      timer = Process.send_after(self(), {:start_idle_check, token}, delay)
      check = %{token: token, timer: timer, started_at: nil, pending: MapSet.new(Map.keys(state.projects)), snapshots: []}

      projects =
        Map.new(state.projects, fn {id, entry} ->
          cancel_snapshot_timer(entry)
          {id, %{entry | timer: nil}}
        end)

      {:noreply, %{state | idle_check: check, projects: projects}}
    else
      if state.idle_check == nil, do: schedule_idle_check()
      {:noreply, state}
    end
  end

  def handle_info({:start_idle_check, token}, %{idle_check: %{token: token, started_at: nil}} = state) do
    state = reconcile_projects(state)

    if state.idle_check && Enum.all?(state.projects, fn {_, entry} -> entry.pid != nil and entry.request == nil end) do
      Process.cancel_timer(state.idle_check.timer)
      timer = Process.send_after(self(), {:idle_deadline, token}, @idle_timeout_ms)
      check = %{state.idle_check | timer: timer, started_at: state.clock.()}
      projects = Map.new(state.projects, fn {id, entry} -> {id, request_snapshot(entry)} end)
      {:noreply, %{state | idle_check: check, projects: projects}}
    else
      {:noreply, if(state.idle_check, do: finish_idle_check(state, false), else: state)}
    end
  end

  def handle_info({:start_idle_check, _token}, state), do: {:noreply, state}

  def handle_info({:idle_deadline, token}, %{idle_check: %{token: token}} = state) do
    {:noreply, finish_idle_check(state, false)}
  end

  def handle_info({:idle_deadline, _token}, state), do: {:noreply, state}

  def handle_info({:refresh_snapshot, id, token}, state) do
    state = reconcile_projects(state)

    projects =
      case state.projects[id] do
        %{timer: {_, ^token}, request: nil, pid: pid} = entry when is_pid(pid) ->
          Map.put(state.projects, id, request_snapshot(entry))

        %{timer: {_, ^token}} = entry ->
          Map.put(state.projects, id, schedule_snapshot(%{entry | timer: nil}, id))

        _ ->
          state.projects
      end

    {:noreply, %{state | projects: projects}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason} = message, state) do
    case Enum.find(state.projects, fn {_, entry} -> entry.monitor == ref end) do
      {id, entry} ->
        release_project(entry)
        entry = new_project(nil) |> Map.put(:error, "process_unavailable") |> schedule_snapshot(id)
        {:noreply, %{state | projects: Map.put(state.projects, id, entry)}}

      nil ->
        {:noreply, receive_snapshot(message, state)}
    end
  end

  def handle_info(message, state), do: {:noreply, receive_snapshot(message, state)}

  defp globally_idle?(snapshots, now_ms) do
    snapshots != [] and
      Enum.all?(snapshots, fn snapshot ->
        is_map(snapshot) and snapshot.running == [] and snapshot.retrying == [] and
          Map.get(snapshot, :waiting, []) == [] and snapshot.idle_shutdown_ms > 0 and
          get_in(snapshot, [:polling, :checking?]) == false
      end) and
      now_ms - Enum.max(Enum.map(snapshots, & &1.last_activity_at_ms)) >=
        Enum.max(Enum.map(snapshots, & &1.idle_shutdown_ms))
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = reconcile_projects(state)
    now_ms = state.clock.()
    statuses = Enum.map(state.contexts, &project_status(&1, state.projects[&1.id], now_ms))

    snapshots =
      state.contexts
      |> Enum.zip(statuses)
      |> Enum.reject(fn {_, status} -> status.status == :unavailable end)
      |> Enum.map(fn {context, _} -> {context, aged_snapshot(state.projects[context.id], now_ms)} end)

    result = %{
      projects: Enum.map(state.contexts, & &1.name),
      project_statuses: statuses,
      partial: Enum.any?(statuses, &(&1.status == :unavailable)),
      running: entries(snapshots, :running, state.contexts),
      retrying: entries(snapshots, :retrying, state.contexts),
      waiting: entries(snapshots, :waiting, state.contexts),
      codex_totals: totals(snapshots),
      rate_limits: snapshots |> Enum.map(fn {_, s} -> s.rate_limits end) |> Enum.find(&(not is_nil(&1))),
      polling: SymphonyElixir.ProjectPoller.polling()
    }

    {:reply, result, state}
  end

  def handle_call(:request_refresh, _from, state) do
    SymphonyElixir.ProjectPoller.refresh()
    Enum.each(state.contexts, &GenServer.cast(server(&1), :request_refresh))
    result = %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: ["poll", "reconcile"]}
    {:reply, result, state}
  end

  defp reconcile_projects(state) do
    projects =
      Map.new(state.contexts, fn context ->
        pid = GenServer.whereis(server(context))
        pid = if is_pid(pid) and Process.alive?(pid), do: pid
        {context.id, reconcile_project(state.projects[context.id], pid, context.id)}
      end)

    changed? = Enum.any?(projects, fn {id, entry} -> state.projects[id] && state.projects[id].pid != entry.pid end)
    state = %{state | projects: projects}
    if changed? and state.idle_check, do: finish_idle_check(state, false), else: state
  end

  defp reconcile_project(%{pid: pid} = previous, pid, _id), do: previous

  defp reconcile_project(previous, pid, id) do
    if previous, do: release_project(previous)
    entry = new_project(pid)
    if pid, do: request_snapshot(entry), else: schedule_snapshot(entry, id)
  end

  defp new_project(pid) do
    %{
      pid: pid,
      monitor: if(pid, do: Process.monitor(pid)),
      request: nil,
      timer: nil,
      snapshot: nil,
      observed_at: nil,
      observed_at_ms: nil,
      error: if(pid, do: "snapshot_pending", else: "process_unavailable")
    }
  end

  defp request_snapshot(entry) do
    cancel_snapshot_timer(entry)
    %{entry | request: :gen_server.send_request(entry.pid, :snapshot), timer: nil}
  end

  defp schedule_snapshot(entry, id) do
    token = make_ref()
    timer = Process.send_after(self(), {:refresh_snapshot, id, token}, @snapshot_interval_ms)
    %{entry | timer: {timer, token}}
  end

  defp snapshot_delay(%{observed_at_ms: nil}, _now_ms), do: @snapshot_interval_ms
  defp snapshot_delay(entry, now_ms), do: max(@snapshot_interval_ms - (now_ms - entry.observed_at_ms), 0)

  defp cancel_snapshot_timer(%{timer: {ref, _}}), do: Process.cancel_timer(ref)
  defp cancel_snapshot_timer(_entry), do: :ok

  defp release_project(entry) do
    cancel_snapshot_timer(entry)
    if entry.monitor, do: Process.demonitor(entry.monitor, [:flush])
    # receive_response/2 abandons a pending request and deactivates its reply alias.
    if entry.request, do: :gen_server.receive_response(entry.request, 0)
  end

  defp receive_snapshot(message, state) do
    Enum.reduce_while(state.projects, state, fn
      {_id, %{request: nil}}, acc ->
        {:cont, acc}

      {id, entry}, acc ->
        case :gen_server.check_response(message, entry.request) do
          :no_reply -> {:cont, acc}
          {:reply, snapshot} when is_map(snapshot) -> {:halt, record_snapshot(acc, id, entry, snapshot)}
          _error -> {:halt, record_snapshot(acc, id, entry, nil)}
        end
    end)
  end

  defp record_snapshot(state, id, entry, snapshot) do
    now_ms = state.clock.()
    observed_at = DateTime.utc_now()

    entry =
      %{
        entry
        | request: nil,
          snapshot: observe_retry_deadlines(snapshot, observed_at),
          error: if(snapshot, do: nil, else: "snapshot_error"),
          observed_at: if(snapshot, do: DateTime.to_iso8601(observed_at)),
          observed_at_ms: if(snapshot, do: now_ms)
      }
      |> schedule_snapshot(id)

    state = %{state | projects: Map.put(state.projects, id, entry)}
    SymphonyElixirWeb.ObservabilityPubSub.broadcast_update()
    record_idle_response(state, id, snapshot, now_ms)
  end

  defp observe_retry_deadlines(nil, _observed_at), do: nil

  defp observe_retry_deadlines(snapshot, observed_at) do
    Map.update(snapshot, :retrying, [], fn retries ->
      Enum.map(retries, fn
        %{due_in_ms: due_in_ms} = retry when is_integer(due_in_ms) -> Map.put(retry, :due_at, DateTime.add(observed_at, due_in_ms, :millisecond))
        retry -> retry
      end)
    end)
  end

  defp aged_snapshot(entry, now_ms) do
    age_ms = max(now_ms - entry.observed_at_ms, 0)

    Map.update(entry.snapshot, :retrying, [], fn retries ->
      Enum.map(retries, fn
        %{due_in_ms: due_in_ms} = retry when is_integer(due_in_ms) -> %{retry | due_in_ms: max(due_in_ms - age_ms, 0)}
        retry -> retry
      end)
    end)
  end

  defp record_idle_response(%{idle_check: nil} = state, _id, _snapshot, _now_ms), do: state

  defp record_idle_response(state, id, snapshot, now_ms) do
    check = state.idle_check
    check = %{check | pending: MapSet.delete(check.pending, id), snapshots: [snapshot | check.snapshots]}
    state = %{state | idle_check: check}

    if MapSet.size(check.pending) == 0 do
      same_processes? =
        Enum.all?(state.contexts, fn context ->
          pid = state.projects[context.id].pid
          is_pid(pid) and Process.alive?(pid) and GenServer.whereis(server(context)) == pid
        end)

      within_deadline? = now_ms - check.started_at < @idle_timeout_ms
      idle? = same_processes? and within_deadline? and globally_idle?(check.snapshots, now_ms)
      finish_idle_check(state, idle?)
    else
      state
    end
  end

  defp finish_idle_check(state, idle?) do
    Process.cancel_timer(state.idle_check.timer)
    if idle?, do: state.shutdown.(), else: schedule_idle_check()

    projects =
      Map.new(state.projects, fn
        {id, %{request: nil, timer: nil} = entry} -> {id, schedule_snapshot(entry, id)}
        project -> project
      end)

    %{state | idle_check: nil, projects: projects}
  end

  defp schedule_idle_check, do: Process.send_after(self(), :check_idle, @snapshot_interval_ms)

  defp project_status(context, entry, now_ms) do
    age_ms = if entry.observed_at_ms, do: max(now_ms - entry.observed_at_ms, 0)

    {status, error} =
      cond do
        entry.error -> {:unavailable, entry.error}
        age_ms >= @expired_ms -> {:unavailable, "snapshot_expired"}
        age_ms > @fresh_ms -> {:stale, nil}
        true -> {:fresh, nil}
      end

    %{id: context.id, name: context.name, root: context.root, status: status, observed_at: entry.observed_at, age_ms: age_ms, error: error}
  end

  defp load_contexts(roots, workflow, env, code_root) do
    Enum.reduce_while(roots, {:ok, []}, fn root, {:ok, contexts} ->
      case ProjectContext.load(root, workflow, env, code_root) do
        {:ok, context} -> {:cont, {:ok, contexts ++ [context]}}
        {:error, reason} -> {:halt, {:error, {:invalid_project, root, reason}}}
      end
    end)
  end

  defp entries(snapshots, key, contexts) do
    Enum.flat_map(snapshots, fn {context, snapshot} ->
      Enum.map(
        Map.get(snapshot, key, []),
        fn entry ->
          Map.merge(entry, %{
            project: context.name,
            project_qualifier: qualifier(context, contexts),
            project_root: context.root,
            workspace_id: context.settings.tracker.app["workspace_id"],
            workspace_path: entry[:workspace_path] || Path.join(context.settings.workspace.root, entry.identifier)
          })
        end
      )
    end)
  end

  defp qualifier(context, contexts) do
    if Enum.count(contexts, &(&1.name == context.name)) > 1, do: context.root, else: context.name
  end

  defp totals(snapshots) do
    empty = %{input_tokens: 0, cached_input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    Enum.reduce(snapshots, empty, fn {_, snapshot}, acc -> Map.merge(acc, snapshot.codex_totals, fn _, a, b -> a + b end) end)
  end
end
