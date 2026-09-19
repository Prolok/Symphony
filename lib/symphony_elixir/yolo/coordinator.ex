defmodule SymphonyElixir.Yolo.Coordinator do
  @moduledoc "PO scheduling inside the existing project orchestrator and shared capacity."
  require Logger
  alias SymphonyElixir.{Config, ProjectContext}
  alias SymphonyElixir.Linear.YoloAgent
  alias SymphonyElixir.Yolo.{Admission, Completion, Group, Observation, Operations, ReviewReadiness, Runner, Store}

  @spec tick(map(), [map()], keyword()) :: map()
  def tick(state, issues, opts \\ []) do
    if is_binary(Config.yolo_agent_id()) do
      runs = reconcile(state.yolo_runs, issues)
      previous_ids = Enum.flat_map(state.yolo_runs, fn {_, run} -> run.ids end) |> MapSet.new()
      current_ids = Enum.flat_map(runs, fn {_, run} -> run.ids end) |> MapSet.new()
      claimed = state.claimed |> MapSet.difference(previous_ids) |> MapSet.union(current_ids)
      state = %{state | yolo_runs: runs, claimed: claimed}
      {issues, state} = admit(issues, state, opts)

      schedule_groups(state, issues, opts)
    else
      state
    end
  end

  defp schedule_groups(state, issues, opts) do
    case ReviewReadiness.observe(issues) do
      {:ok, epoch} ->
        Enum.reduce(Enum.sort(Group.groups(issues)), state, fn {group, members}, acc ->
          dispatch(acc, group, members, issues, Keyword.put(opts, :review_epoch, epoch))
        end)

      {:error, reason} ->
        Logger.warning("YOLO review readiness unavailable reason=#{inspect(reason)}")
        state
    end
  end

  defp reconcile(runs, issues) do
    by_id = Map.new(issues, &{&1.id, &1})

    Map.filter(runs, fn {group, run} ->
      alive? = Process.alive?(run.pid)

      withdrawn? =
        Enum.all?(run.ids, &withdrawn?(by_id[&1]))

      own_finish? = Completion.ready?(group, run.issues)
      withdrawn? = withdrawn? and not own_finish?
      if alive? and withdrawn?, do: Process.exit(run.pid, :shutdown)
      alive? and not withdrawn?
    end)
  end

  defp withdrawn?(nil), do: true
  defp withdrawn?(issue), do: not YoloAgent.delegated?(issue) or not Admission.eligible?(issue)

  defp admit(issues, state, opts) do
    reserved = Enum.flat_map(state.yolo_runs, fn {_, run} -> run.ids end)
    prepare = Keyword.get(opts, :prepare, &Admission.prepare/1)

    issues =
      Enum.flat_map(issues, fn issue ->
        if Admission.eligible?(issue) and Admission.needed?(issue) and
             not Group.terminal?(issue) and issue.id not in reserved and not Map.has_key?(state.running, issue.id) do
          [prepare_issue(issue, prepare)]
        else
          [issue]
        end
      end)

    {issues, state}
  end

  defp prepare_issue(issue, prepare) do
    case prepare.(issue) do
      {:ok, updated} ->
        updated

      {:error, reason} ->
        Logger.warning("YOLO admission failed issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")
        issue
    end
  end

  defp dispatch(state, group, members, issues, opts) do
    used = map_size(state.running) + map_size(state.yolo_runs)
    limit = state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents
    busy? = Enum.any?(members, &(Map.has_key?(state.running, &1.id) or MapSet.member?(state.claimed, &1.id)))
    allowed? = Enum.all?(members, &SymphonyElixir.TestRun.start_allowed?/1)

    if used < limit and not busy? and allowed? and not Map.has_key?(state.yolo_runs, group) do
      case prepare_group(group, members, opts) do
        :run -> start(state, group, members, issues, opts)
        _ -> state
      end
    else
      state
    end
  end

  defp prepare_group(group, members, opts) do
    Store.lock(group, fn -> observe_group(group, members, opts) end)
  end

  defp observe_group(group, members, opts) do
    with {:ok, record} <- Store.read(group),
         true <- is_nil(record["retry_at"]) or record["retry_at"] <= System.system_time(:millisecond),
         {:ok, observations, fingerprint} <- Observation.capture(members, record["observations"], opts),
         {:ok, pending} <- Operations.pending(Enum.map(members, & &1.id)),
         :ok <- Store.write(group, Map.put(record, "observations", observations)) do
      same_epoch? = group != "review" or Map.get(record, "processed_epoch", 0) == opts[:review_epoch]
      if pending == [] and record["processed"] == fingerprint and same_epoch?, do: :unchanged, else: :run
    else
      {:error, reason} ->
        Logger.warning("YOLO observation failed group=#{group} reason=#{inspect(reason)}")
        :unavailable

      _ ->
        :waiting
    end
  end

  defp start(state, group, members, issues, opts) do
    context = ProjectContext.current()
    recipient = self()
    runner = Keyword.get(opts, :runner, fn name, members, all -> Runner.run(name, members, all, recipient: recipient) end)
    callback = fn -> ProjectContext.with_context(context, fn -> runner.(group, members, issues) end) end

    start =
      Keyword.get(opts, :start, fn name, fun ->
        if state.external_poll,
          do: SymphonyElixir.WorkerCapacity.start_child(nil, "YOLO #{name}", fun),
          else: Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fun)
      end)

    case start.(group, callback) do
      {:ok, pid} ->
        %{
          state
          | yolo_runs: Map.put(state.yolo_runs, group, %{pid: pid, ids: Enum.map(members, & &1.id), issues: members, started_at: DateTime.utc_now(), event: %{}}),
            claimed: MapSet.union(state.claimed, MapSet.new(members, & &1.id)),
            last_activity_at_ms: System.monotonic_time(:millisecond)
        }

      _ ->
        state
    end
  end

  @spec event(map(), String.t(), map()) :: map()
  def event(runs, group, message) do
    case runs[group] do
      nil -> runs
      run -> Map.put(runs, group, %{run | event: Map.merge(run.event, message)})
    end
  end

  @spec entries(map()) :: [map()]
  def entries(runs) do
    Enum.flat_map(runs, fn {group, run} ->
      Enum.map(run.issues, fn issue ->
        %{
          issue_id: issue.id,
          identifier: issue.identifier,
          state: "YOLO " <> group,
          worker_host: nil,
          workspace_path: run.event[:workspace_path],
          session_id: run.event[:session_id],
          codex_app_server_pid: run.event[:codex_app_server_pid],
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          turn_count: 1,
          started_at: run.started_at,
          last_codex_timestamp: nil,
          last_codex_message: nil,
          last_codex_event: run.event[:event],
          recent_codex_events: [],
          runtime_seconds: DateTime.diff(DateTime.utc_now(), run.started_at)
        }
      end)
    end)
  end

  @spec stop(map()) :: :ok
  def stop(runs) do
    Enum.each(runs, fn {_, run} -> Process.exit(run.pid, :shutdown) end)
    :ok
  end
end
