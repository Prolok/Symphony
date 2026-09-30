defmodule SymphonyElixir.OrchestratorIOTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Maintenance, ProjectContext, WorkerCapacity}
  alias SymphonyElixir.Yolo.{Coordinator, Delivery, Store}

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
          state: tags[:maintenance_phase] || "Yolo Review",
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

  for {phase, group} <- [{"Backlog", "incoming"}, {"Yolo Review", "review"}, {"BLOCKER", "blocker"}] do
    @tag successful_scan: true, maintenance_phase: phase, maintenance_group: group, maintenance_start_race: true
    test "maintenance after the tick check defers #{group} without consuming its impulse", %{
      pid: pid,
      context: context,
      issues: issues,
      maintenance_group: group
    } do
      comments = [%{id: "workpad", body: "## Symphony Workpad\n\n### Validierung\n\n- [ ] Betreiber prüft den Hostzugang.\n"}]
      Application.put_env(:symphony_elixir, :memory_tracker_comments, Map.new(issues, &{&1.id, comments}))

      ProjectContext.with_context(context, fn ->
        assert {:ok, initial} = Store.read(group)
        impulses = Map.new(issues, &{&1.id, %{"generation" => 1, "reason" => "delegated_again"}})
        assert :ok = Store.write(group, Map.put(initial, "impulses", impulses))
      end)

      send(pid, :run_poll_cycle)
      assert_receive {:scan_entered, scanner, _}, 2_000
      assert poll_task(:sys.get_state(pid))
      update_worker(pid, :turn_completed)
      assert {:ok, _} = Maintenance.update(%{"enabled" => true, "reason" => "Prepared PO race"})
      send(scanner, :release_scan)
      deferred = await_state(pid, &is_nil(poll_task(&1)))
      assert deferred.yolo_runs == %{}
      assert deferred.retry_attempts == %{}
      refute Enum.any?(issues, &MapSet.member?(deferred.claimed, &1.id))
      assert WorkerCapacity.count(nil) == 0
      GenServer.stop(pid)

      ProjectContext.with_context(context, fn ->
        assert {:ok, record} = Store.read(group)
        assert record["impulses"] == impulses_for(issues)
        assert Enum.sort(Map.keys(record["observations"])) == Enum.sort(Enum.map(issues, & &1.id))
        assert Delivery.pending(issues, record["observations"], record) == issues
        assert record["attempt"] == nil
        assert record["processed"] == nil
        assert record["deliveries"] in [nil, %{}]
        assert record["retry_at"] == nil
        assert record["failure_count"] == nil

        # Keep the real PO arbiter and delivery journal while substituting only
        # the Codex session. The prepared source must start once after disable.
        assert {:ok, _} = Maintenance.update(%{"enabled" => false})
        parent = self()

        runner = fn name, members, _ ->
          {:ok, current} = Store.read(name)
          :ok = Delivery.reserve(name, "maintenance-resumed", current["observations"])
          send(parent, {:resumed_po, self(), Enum.map(members, & &1.id)})

          receive do
            :stop -> :ok
          end
        end

        opts = [
          dependencies: &{:ok, &1},
          scan: fn _ ->
            {:ok, %{"current" => %{}, "versions" => %{}, "last_successful_scan" => "now", "scan_error" => nil}}
          end,
          runner: runner
        ]

        resumed = Coordinator.tick(deferred, issues, opts)
        assert %{pid: worker} = resumed.yolo_runs[group]
        on_exit(fn -> Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker) end)
        assert_receive {:resumed_po, ^worker, ids}, 2_000
        assert ids == Enum.map(issues, & &1.id)
        repeated = Coordinator.tick(resumed, issues, opts)
        assert repeated.yolo_runs[group].pid == worker
        refute_receive {:resumed_po, _, _}
        assert {:ok, delivered} = Store.read(group)
        assert Delivery.pending(issues, delivered["observations"], delivered) == []
      end)
    end
  end

  defp impulses_for(issues), do: Map.new(issues, &{&1.id, %{"generation" => 1, "reason" => "delegated_again"}})

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

  test "completed PO ticks update the regular capacity queue despite repeated follow-up polls", %{pid: pid, context: context} do
    candidate = %Issue{id: "queued", identifier: "PRO-1000", title: "Queued worker", state: "In Arbeit (AI)"}
    baseline = %{:sys.get_state(pid) | max_concurrent_agents: 0}

    ProjectContext.with_context(context, fn ->
      Enum.reduce(1..3, baseline, fn _, state ->
        task = %{ref: make_ref(), context: context, pending?: true, issues: [candidate], baseline: state}
        polling = %{state | poll_check_in_progress: task, waiting: []}
        assert {:noreply, completed} = Orchestrator.handle_info({task.ref, state}, polling)
        assert completed.waiting == [%{issue_id: candidate.id, identifier: candidate.identifier}]
        assert_receive :tick
        completed
      end)
    end)
  end

  test "a pending follow-up poll still starts a regular worker exactly once", %{pid: pid, context: context} do
    candidate = %Issue{id: "regular", identifier: "PRO-1001", title: "Regular worker", state: "In Arbeit (AI)"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [candidate])
    context = put_in(context.settings.codex.command, "sleep 20")
    baseline = :sys.get_state(pid)

    ProjectContext.with_context(context, fn ->
      task = %{ref: make_ref(), context: context, pending?: true, issues: [candidate], baseline: baseline}
      assert {:noreply, started} = Orchestrator.handle_info({task.ref, baseline}, %{baseline | poll_check_in_progress: task})
      assert_receive :tick
      assert %{pid: worker} = started.running[candidate.id]

      try do
        next = %{task | ref: make_ref(), baseline: started}
        assert {:noreply, repeated} = Orchestrator.handle_info({next.ref, started}, %{started | poll_check_in_progress: next})
        assert_receive :tick
        assert repeated.running[candidate.id].pid == worker
      after
        Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker)
        Enum.each(started.comment_scans, fn {_, scan} -> Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, scan) end)
      end
    end)
  end

  test "recovery retries its own reserved claims but rejects live workers and duplicate groups", %{pid: pid, issues: issues} do
    send(pid, :run_poll_cycle)
    assert_receive {:scan_entered, scanner, _}, 2_000
    task = poll_task(:sys.get_state(pid))
    member = List.last(issues)
    parent = self()

    callback = fn ->
      send(parent, {:recovery_started, self()})

      receive do
        :stop -> :ok
      end
    end

    :sys.replace_state(pid, fn state -> %{state | claimed: MapSet.put(state.claimed, member.id), max_concurrent_agents: 0} end)

    call = fn group, members, recovering? ->
      GenServer.call(pid, {:start_yolo_group, task.token, group, members, callback, %{}, recovering?})
    end

    assert call.("recovery", [member], false) == {:error, :capacity}
    assert {:ok, recovered} = call.("recovery", [member], true)
    assert_receive {:recovery_started, ^recovered}
    assert call.("recovery", [member], true) == {:error, :capacity}
    assert call.("other", [member], true) == {:error, :capacity}
    assert call.("regular", [%{member | id: "worker"}], true) == {:error, :capacity}
    ref = Process.monitor(recovered)
    send(recovered, :stop)
    assert_receive {:DOWN, ^ref, :process, ^recovered, :normal}
    assert {:ok, restarted} = call.("recovery", [member], true)
    assert_receive {:recovery_started, ^restarted}
    Process.exit(scanner, :kill)
    await_state(pid, &is_nil(poll_task(&1)))
  end

  test "a recovery that exits before tick reconciliation releases its newly recorded claim", %{pid: pid, context: context, issues: issues} do
    baseline = :sys.get_state(pid)
    task = %{ref: make_ref(), token: make_ref(), context: context, pending?: true, issues: [], baseline: baseline}
    member = hd(issues)

    ProjectContext.with_context(context, fn ->
      polling = %{baseline | poll_check_in_progress: task}
      message = {:start_yolo_group, task.token, "recovery", [member], fn -> :ok end, %{}, true}
      assert {:reply, {:ok, recovered}, started} = Orchestrator.handle_call(message, {self(), make_ref()}, polling)
      ref = Process.monitor(recovered)
      assert_receive {:DOWN, ^ref, :process, ^recovered, _}
      assert MapSet.member?(started.claimed, member.id)

      current = %{started | retry_attempts: %{"retry" => %{capacity_wait: true}}, claimed: MapSet.put(started.claimed, "retry")}
      assert {:noreply, completed} = Orchestrator.handle_info({task.ref, baseline}, current)
      assert completed.yolo_runs == %{}
      refute MapSet.member?(completed.claimed, member.id)
      assert MapSet.member?(completed.claimed, "worker")
      assert MapSet.member?(completed.claimed, "retry")
      assert_receive :tick
    end)
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
