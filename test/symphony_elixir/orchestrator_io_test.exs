defmodule SymphonyElixir.OrchestratorIOTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.ProjectContext

  setup tags do
    SymphonyElixir.TestSupport.isolate_application_orchestrator()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 60_000,
      codex_stall_timeout_ms: 1_000
    )

    root = Path.dirname(Workflow.workflow_file_path())
    {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    context = %{context | assignee_ids: ["human"], human_handoff_id: "human", yolo_agent_id: "pai"}
    context = put_in(context.settings.tracker.yolo_agent, "Pai")
    context = put_in(context.settings.tracker.app["state_root"], Path.join(root, "state"))

    issues =
      for n <- 1..5 do
        %Issue{
          id: "po-#{n}",
          identifier: "PRO-#{n}",
          title: "PO member",
          state: "Yolo Review",
          delegate_id: "pai",
          assignee_id: "human",
          assigned_to_worker: true,
          in_project_scope: true,
          project_context_id: context.id,
          workspace_id: context.settings.tracker.app["workspace_id"],
          relations_complete: true,
          labels: [~s(skip "freigabe implementierung"), ~s(skip "freigabe review")]
        }
      end

    worker_issue = %Issue{id: "worker", identifier: "PRO-999", title: "Worker", state: "In Arbeit (AI)"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [worker_issue | issues])
    parent = self()
    scans = :atomics.new(1, [])

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      query = payload[:query] || payload["query"]

      cond do
        query =~ "YoloBlockers" ->
          {:ok, %{status: 200, body: %{"data" => %{"issue" => %{"inverseRelations" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}}}}}}

        query =~ "SymphonyCommentScanSignal" ->
          if :atomics.add_get(scans, 1, 1) == 1 do
            send(parent, {:scan_entered, self(), System.monotonic_time(:millisecond)})

            receive do
              :release_scan -> :ok
            end
          end

          if tags[:successful_scan] do
            empty_comments()
          else
            {:error, :controlled_scan_failure}
          end

        query =~ "SymphonyLinearIssueComments" and tags[:successful_scan] ->
          empty_comments()

        true ->
          flunk("unexpected query #{query}")
      end
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)
    pid = start_supervised!({Orchestrator, name: __MODULE__, context: context, initial_poll?: false})

    {:ok, worker} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

    entry = %{
      pid: worker,
      ref: nil,
      identifier: worker_issue.identifier,
      issue: worker_issue,
      session_id: nil,
      turn_count: 0,
      started_at: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0
    }

    :sys.replace_state(pid, fn state -> %{state | running: %{"worker" => %{entry | ref: Process.monitor(worker)}}, claimed: MapSet.new(["worker"])} end)
    %{pid: pid, worker: worker, context: context, scans: scans, issues: issues}
  end

  test "project answers snapshots and processes completion while a PO comment scan waits", %{pid: pid, worker: worker} do
    send(pid, :run_poll_cycle)
    assert_receive {:scan_entered, scanner, entered}, 2_000
    task = poll_task(:sys.get_state(pid))
    send(pid, :run_poll_cycle)
    for _ <- 1..20, do: send(pid, :tick)
    send(pid, {:codex_worker_update, "worker", %{event: :turn_completed, session_id: "thread-turn", timestamp: DateTime.utc_now()}})
    started = System.monotonic_time(:millisecond)
    snapshot = Orchestrator.snapshot(pid, 2_000)
    elapsed = System.monotonic_time(:millisecond) - started

    assert is_map(snapshot)
    assert elapsed < 2_000
    assert hd(snapshot.running).last_codex_event == :turn_completed
    assert scanner != pid
    assert poll_task(:sys.get_state(pid)).ref == task.ref
    Process.sleep(2_100)
    send(pid, :tick)
    assert is_map(Orchestrator.snapshot(pid, 2_000))
    assert Process.alive?(worker)
    assert :sys.get_state(pid).retry_attempts == %{}
    send(scanner, :release_scan)
    state = await_state(pid, &is_nil(poll_task(&1)))
    assert state.running["worker"].last_codex_event == :turn_completed
    assert state.retry_attempts == %{}
    assert Process.alive?(worker)
    IO.puts("PRO-969 after: snapshot_elapsed_ms=#{elapsed} blocked_scan_ms=#{System.monotonic_time(:millisecond) - entered} no_stall_retry=true")
  end

  test "a failed poll task preserves worker events and permits another poll", %{pid: pid, worker: worker} do
    send(pid, :run_poll_cycle)
    assert_receive {:scan_entered, scanner, _}, 2_000
    update_worker(pid, :turn_completed)
    assert is_map(Orchestrator.snapshot(pid, 2_000))
    Process.exit(scanner, :kill)
    state = await_state(pid, &is_nil(poll_task(&1)))
    assert state.running["worker"].last_codex_event == :turn_completed
    assert state.retry_attempts == %{}
    assert Process.alive?(worker)
    send(pid, :tick)
    await_state(pid, &(&1.poll_check_in_progress in [nil, false]))
  end

  test "changed project context cancels a pending poll and ignores its old result", %{pid: pid, context: context} do
    send(pid, :run_poll_cycle)
    assert_receive {:scan_entered, scanner, _}, 2_000
    task = poll_task(:sys.get_state(pid))
    old_result = %{task.baseline | codex_totals: %{task.baseline.codex_totals | input_tokens: 999}}
    updated = put_in(context.settings.agent.max_concurrent_agents, 1)
    send(pid, {:project_poll, updated})
    update_worker(pid, :turn_completed)
    send(pid, {task.ref, old_result})
    snapshot = Orchestrator.snapshot(pid, 2_000)
    assert snapshot.codex_totals.input_tokens == 0
    assert hd(snapshot.running).last_codex_event == :turn_completed
    refute Process.alive?(scanner)
    state = await_state(pid, &(&1.poll_check_in_progress in [nil, false]))
    assert state.max_concurrent_agents == 1
  end

  test "an exited worker finishes normally while the PO scan still waits", %{pid: pid, worker: worker} do
    send(pid, :run_poll_cycle)
    assert_receive {:scan_entered, scanner, _}, 2_000
    update_worker(pid, :turn_completed)
    send(worker, :stop)
    state = await_state(pid, &(not Map.has_key?(&1.running, "worker")))
    assert Process.alive?(scanner)
    refute ((state.retry_attempts["worker"] || %{})[:error] || "") =~ "stalled"
    send(scanner, :release_scan)
  end

  test "real inactivity is recovered even while the PO scan waits", %{pid: pid, worker: worker} do
    send(pid, :run_poll_cycle)
    assert_receive {:scan_entered, scanner, _}, 2_000
    stale = DateTime.add(DateTime.utc_now(), -5, :second)
    :sys.replace_state(pid, fn state -> put_in(state.running["worker"].started_at, stale) end)
    send(pid, :tick)
    state = await_state(pid, &Map.has_key?(&1.retry_attempts, "worker"))
    assert state.retry_attempts["worker"].error =~ "stalled"
    refute Process.alive?(worker)
    assert Process.alive?(scanner)
    send(scanner, :release_scan)
    state = await_state(pid, &is_nil(poll_task(&1)))
    refute Map.has_key?(state.running, "worker")
    assert state.retry_attempts["worker"].error =~ "stalled"
  end

  test "a new session resumes stall detection after a completed turn", %{pid: pid, worker: worker} do
    send(pid, :run_poll_cycle)
    assert_receive {:scan_entered, scanner, _}, 2_000
    update_worker(pid, :turn_completed)
    assert is_map(Orchestrator.snapshot(pid, 2_000))
    send(pid, {:codex_worker_update, "worker", %{event: :session_started, session_id: "next-turn", timestamp: DateTime.add(DateTime.utc_now(), -5, :second)}})
    send(pid, :tick)
    state = await_state(pid, &Map.has_key?(&1.retry_attempts, "worker"))
    assert state.retry_attempts["worker"].error =~ "stalled"
    refute Process.alive?(worker)
    send(scanner, :release_scan)
  end

  test "stopping a project terminates its pending poll task", %{pid: pid} do
    send(pid, :run_poll_cycle)
    assert_receive {:scan_entered, scanner, _}, 2_000
    GenServer.stop(pid)
    refute Process.alive?(scanner)
  end

  test "poll integration preserves intervening PO events and regular worker updates", %{pid: pid, issues: issues} do
    finished = %{hd(issues) | id: "finished-po", state: "Review"}
    current = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [finished | current])

    {:ok, po_worker} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        receive do
          :stop -> :ok
        end
      end)

    :sys.replace_state(pid, fn state ->
      run = %{pid: po_worker, ids: [finished.id], issues: [finished], started_at: DateTime.utc_now(), event: %{session_id: "old"}}
      %{state | yolo_runs: %{"incoming" => run}, claimed: MapSet.put(state.claimed, finished.id)}
    end)

    send(pid, :run_poll_cycle)
    assert_receive {:scan_entered, scanner, _}, 2_000
    send(pid, {:yolo_event, "incoming", %{session_id: "new", workspace_path: "synthetic"}})
    update_worker(pid, :turn_completed)
    assert is_map(Orchestrator.snapshot(pid, 2_000))
    send(scanner, :release_scan)
    state = await_state(pid, &is_nil(poll_task(&1)))
    assert state.yolo_runs["incoming"].event.session_id == "new"
    assert state.yolo_runs["incoming"].event.workspace_path == "synthetic"
    assert state.running["worker"].last_codex_event == :turn_completed
    assert MapSet.member?(state.claimed, finished.id)
  end

  test "starts during observation respect current claims, capacity and poll binding", %{pid: pid, issues: issues} do
    send(pid, :run_poll_cycle)
    assert_receive {:scan_entered, scanner, _}, 2_000
    task = poll_task(:sys.get_state(pid))
    callback = fn -> flunk("rejected start must not execute") end
    call = fn token, members -> GenServer.call(pid, {:start_yolo_group, token, "review", members, callback, %{}, false}) end
    assert call.(make_ref(), issues) == {:error, :capacity}
    :sys.replace_state(pid, fn state -> %{state | claimed: MapSet.put(state.claimed, hd(issues).id)} end)
    assert call.(task.token, issues) == {:error, :capacity}
    :sys.replace_state(pid, fn state -> %{state | max_concurrent_agents: 0} end)
    assert call.(task.token, [List.last(issues)]) == {:error, :capacity}
    assert :sys.get_state(pid).yolo_runs == %{}
    update_worker(pid, :turn_completed)
    send(scanner, :release_scan)
    await_state(pid, &is_nil(poll_task(&1)))
    assert call.(task.token, issues) == {:error, :capacity}
  end

  test "the next coalesced poll reconciles a worker status change", %{pid: pid, worker: worker} do
    send(pid, :run_poll_cycle)
    assert_receive {:scan_entered, scanner, _}, 2_000
    issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, Enum.map(issues, fn issue -> if issue.id == "worker", do: %{issue | state: "Review"}, else: issue end))
    update_worker(pid, :turn_completed)
    send(pid, :tick)
    assert is_map(Orchestrator.snapshot(pid, 2_000))
    send(scanner, :release_scan)
    state = await_state(pid, &(not Map.has_key?(&1.running, "worker")))
    refute Process.alive?(worker)
    refute Map.has_key?(state.retry_attempts, "worker")
  end

  @tag successful_scan: true
  test "a prepared group starts once through the orchestrator and retains its claims", %{pid: pid, issues: issues} do
    send(pid, :run_poll_cycle)
    assert_receive {:scan_entered, scanner, _}, 2_000
    update_worker(pid, :turn_completed)
    assert is_map(Orchestrator.snapshot(pid, 2_000))
    send(scanner, :release_scan)
    state = await_state(pid, &(is_nil(poll_task(&1)) and Map.has_key?(&1.yolo_runs, "review")))
    assert map_size(state.yolo_runs) == 1
    assert state.yolo_runs["review"].ids == Enum.map(issues, & &1.id)
    assert Enum.all?(issues, &MapSet.member?(state.claimed, &1.id))
    assert state.running["worker"].last_codex_event == :turn_completed
    assert state.retry_attempts == %{}
  end

  defp empty_comments do
    page = %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}
    {:ok, %{status: 200, body: %{"data" => %{"issue" => %{"comments" => page, "foreignComments" => page}}}}}
  end

  defp poll_task(%{poll_check_in_progress: %{ref: _} = task}), do: task
  defp poll_task(_), do: nil

  defp update_worker(pid, event) do
    send(pid, {:codex_worker_update, "worker", %{event: event, session_id: "thread-turn", timestamp: DateTime.utc_now()}})
  end

  defp await_state(pid, predicate, attempts \\ 300)
  defp await_state(_pid, _predicate, 0), do: flunk("orchestrator state did not converge")

  defp await_state(pid, predicate, attempts) do
    state = :sys.get_state(pid)

    if predicate.(state) do
      state
    else
      Process.sleep(10)
      await_state(pid, predicate, attempts - 1)
    end
  end
end
