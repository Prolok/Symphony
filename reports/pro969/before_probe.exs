defmodule SymphonyElixir.OrchestratorIOTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.ProjectContext

  setup do
    SymphonyElixir.TestSupport.isolate_application_orchestrator()
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", poll_interval_ms: 60_000, codex_stall_timeout_ms: 1_000)
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

          {:error, :controlled_scan_failure}

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
    %{pid: pid, worker: worker}
  end

  test "project answers snapshots and processes completion while a PO comment scan waits", %{pid: pid, worker: worker} do
    send(pid, :run_poll_cycle)
    assert_receive {:scan_entered, scanner, entered}, 2_000
    send(pid, :run_poll_cycle)
    for _ <- 1..20, do: send(pid, :tick)
    send(pid, {:codex_worker_update, "worker", %{event: :turn_completed, session_id: "thread-turn", timestamp: DateTime.utc_now()}})
    started = System.monotonic_time(:millisecond)
    snapshot = Orchestrator.snapshot(pid, 2_000)
    elapsed = System.monotonic_time(:millisecond) - started

    if snapshot == :timeout do
      IO.inspect(%{caller: scanner, orchestrator: pid, duration_ms: elapsed, process: Process.info(pid, [:current_stacktrace, :message_queue_len, :messages])},
        label: "PRO-969 before",
        limit: :infinity,
        printable_limit: :infinity
      )

      send(scanner, :release_scan)
      Process.sleep(100)
      state = :sys.get_state(pid)
      IO.inspect(%{worker_alive: Process.alive?(worker), retry: state.retry_attempts}, label: "PRO-969 after release")
    end

    assert is_map(snapshot)
    assert elapsed < 2_000
    assert hd(snapshot.running).last_codex_event == :turn_completed
    Process.sleep(350)
    assert is_map(Orchestrator.snapshot(pid, 2_000))
    assert Process.alive?(worker)
    send(scanner, :release_scan)
    assert System.monotonic_time(:millisecond) - entered > 300
  end
end
