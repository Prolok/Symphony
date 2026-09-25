defmodule SymphonyElixir.CommentPollingTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{CommentCheckpoint, ProjectContext, WaitMarker}
  alias SymphonyElixir.Linear.{Budget, RateLimit}

  test "low app budget slows relay background scans and defers cross-workspace wait lookups, not writes" do
    unique = System.unique_integer([:positive])
    settings = Config.settings!()
    source_app = Map.merge(settings.tracker.app, %{"workspace_id" => "source-#{unique}", "client_id" => "source-app"})
    target_app = Map.merge(settings.tracker.app, %{"workspace_id" => "target-#{unique}", "client_id" => "target-app"})
    source_settings = settings |> put_in([Access.key(:tracker), Access.key(:app)], source_app) |> put_in([Access.key(:tracker), Access.key(:relay)], %{})
    target_settings = put_in(settings, [Access.key(:tracker), Access.key(:app)], target_app)
    source = %ProjectContext{settings: source_settings}
    target = %ProjectContext{settings: target_settings}
    headers = %{"x-ratelimit-requests-limit" => "5000", "x-ratelimit-requests-remaining" => "999"}
    Budget.record(source_app, :read, headers)
    Budget.record(target_app, :read, headers)
    assert Budget.low?(source_app)
    assert Budget.low?(target_app)

    ProjectContext.with_context(source, fn ->
      assert CommentCheckpoint.background_interval_ms() == 180_000
      issue = %{id: "waiting", description: "Wartet auf: PRI-1"}
      query = fn _, _ -> flunk("deferred wait lookup reached Linear") end

      assert {:error, :linear_budget_reserved} =
               WaitMarker.targets(issue, contexts: [target], wait_comments: fn _ -> {:ok, []} end, query: query)
    end)

    write = fn -> {:ok, %{status: 200, headers: %{}, body: %{}}} end
    assert {:ok, _} = RateLimit.request(target_app, write, budget_kind: :write)
  end

  test "real orchestrator tasks respect due time, interval reloads and scan cleanup" do
    orchestrator = Process.whereis(Orchestrator)
    :sys.suspend(orchestrator)
    on_exit(fn -> :sys.resume(orchestrator) end)
    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 600_000)
    context = %SymphonyElixir.ProjectContext{settings: Config.settings!()}
    start_supervised!({SymphonyElixir.WorkerCapacity, contexts: [context]})
    assert CommentCheckpoint.background_interval_ms() == 600_000
    parent = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    source = %{"id" => "latest", "body" => "unchanged", "issue" => %{"id" => "issue"}, "user" => %{"id" => "human", "app" => false}}

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      query = payload["query"]

      data =
        cond do
          query =~ "SymphonyCommentScanSignal" ->
            count = Agent.get_and_update(counter, &{&1, &1 + 1})
            send(parent, {:signal, self()})

            if count == 0,
              do:
                (receive do
                   :continue -> :ok
                 end)

            %{"issue" => %{"comments" => %{"nodes" => [source]}}}

          query =~ "SymphonyLinearIssueComments" ->
            %{"issue" => %{"comments" => %{"nodes" => [source], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}

          query =~ "SymphonyLinearIssuesById" ->
            node = %{
              "id" => "issue",
              "identifier" => "PRO-1",
              "state" => %{"name" => "In Arbeit (AI)"},
              "project" => %{"slugId" => Config.settings!().tracker.project_slug},
              "assignee" => %{"id" => "human", "email" => "dev@example.com", "app" => false}
            }

            %{"issues" => %{"nodes" => [node]}}

          true ->
            %{"issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}
        end

      {:ok, %{status: 200, body: %{"data" => data}}}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)

    {:ok, worker} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker) end)
    issue = %Issue{id: "issue", identifier: "PRO-1", state: "In Arbeit (AI)", assigned_to_worker: true}

    entry = %{
      pid: worker,
      ref: make_ref(),
      issue: issue,
      identifier: issue.identifier,
      started_at: DateTime.utc_now(),
      session_id: "session",
      last_codex_timestamp: nil,
      last_codex_event: nil,
      turn_count: 0
    }

    state = %Orchestrator.State{external_poll: true, running: %{issue.id => entry}, claimed: MapSet.new([issue.id]), max_concurrent_agents: 1, last_activity_at_ms: System.monotonic_time(:millisecond)}
    assert {:noreply, state} = Orchestrator.handle_info(:run_poll_cycle, state)
    assert_receive {:signal, scan}, 2_000
    assert state.comment_scans[issue.id] == scan
    assert {:noreply, repeated} = Orchestrator.handle_info(:run_poll_cycle, state)
    assert repeated.comment_scans == state.comment_scans
    refute_received {:signal, _}
    ref = Process.monitor(scan)
    send(scan, :continue)
    assert_receive {:signal, ^scan}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^scan, :normal}, 2_000
    assert {:noreply, repeated} = Orchestrator.handle_info(:run_poll_cycle, repeated)
    refute_received {:signal, _}
    assert repeated.comment_scan_due[issue.id].at > System.monotonic_time(:millisecond)

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 5_000)
    assert {:noreply, reloaded} = Orchestrator.handle_info(:run_poll_cycle, repeated)
    assert reloaded.poll_interval_ms == 5_000
    assert CommentCheckpoint.background_interval_ms() == 30_000
    assert reloaded.comment_scan_due[issue.id].at <= System.monotonic_time(:millisecond) + 30_000
    assert reloaded.comment_scans[issue.id] != scan

    assert {:noreply, cleaned} = Orchestrator.handle_info(:run_poll_cycle, %{reloaded | running: %{}})
    assert cleaned.comment_scans == %{}
    assert cleaned.comment_scan_due == %{}
    assert Process.alive?(worker)
  end
end
