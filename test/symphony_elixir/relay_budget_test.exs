defmodule SymphonyElixir.RelayBudgetTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.{CommentTool, DynamicTool, MCPServer}
  alias SymphonyElixir.{CommentCheckpoint, ProjectContext, ProjectPoller, Relay, Tracker, WorkerCapacity}
  alias SymphonyElixir.Linear.{Budget, CommentVersion, IssueLease, IssueReadCache, WriteContext}
  alias SymphonyElixir.RelayFixture, as: Server
  alias SymphonyElixir.Yolo.{ActionScope, BlockerBrake, Coordinator, Dependencies, Escalation, Operations}
  alias SymphonyElixir.Yolo.{Runner, Scope}

  test "the actual five-second timer fetches an available event then stays Linear-free on warm ticks" do
    root = Path.dirname(Workflow.workflow_file_path())
    server = start_supervised!(Server)
    counts = start_supervised!({Agent, fn -> %{} end})
    interval = Config.settings!().polling.interval_ms
    assert interval == 5_000
    [context] = Enum.map(contexts(root, ["one"]), &put_in(&1.settings.polling.interval_ms, interval))
    bump = fn key -> Agent.update(counts, &Map.update(&1, key, 1, fn n -> n + 1 end)) end
    configure_http(server, [context], [issue_node(context)], bump)
    start_supervised!({WorkerCapacity, contexts: [context]})
    start_supervised!({Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry})
    start_supervised!({ProjectPoller, contexts: [context]})
    assert {:ok, [_]} = ProjectPoller.candidates(context)
    context = ProjectPoller.context(context)
    Agent.update(counts, fn _ -> %{} end)
    polling = ProjectPoller.polling()
    assert polling.poll_interval_ms == 5_000
    assert polling.next_poll_in_ms in 4_001..5_000
    state = :sys.get_state(ProjectPoller)
    assert Process.read_timer(state.timer) <= polling.next_poll_in_ms
    before = Server.calls(server)

    for _ <- 1..20 do
      snapshot = %{running: [], retrying: [], codex_totals: %{}, rate_limits: nil, polling: ProjectPoller.polling()}
      rendered = StatusDashboard.format_snapshot_content_for_test({:ok, snapshot}, 0.0, 115)
      assert Regex.replace(~r/\e\[[0-9;]*m/, rendered, "") =~ "Next refresh: 5s"
    end

    assert Server.calls(server) == before
    assert Agent.get(counts, & &1) == %{}
    Server.publish(server, "one", %{"issueId" => "issue-0"})
    Process.sleep(100)
    assert Server.consumer(server, "one", "one").cursor == 0
    assert Server.calls(server) == before
    assert wait_for_poll(server, length(before))
    assert Server.consumer(server, "one", "one").cursor == 1
    assert Agent.get_and_update(counts, &{&1, %{}}) == %{read: 1}

    for _ <- 1..2 do
      ProjectPoller.refresh()
      assert {:ok, [issue]} = ProjectPoller.candidates(context)

      ProjectContext.with_context(context, fn ->
        assert :ok = Relay.execution_allowed(issue)
        assert {:ok, [_]} = Relay.background_issues([issue.id])
      end)

      assert Agent.get(counts, & &1) == %{}
    end
  end

  test "complete relay issue is reused after one full Linear comparison" do
    root = Path.dirname(Workflow.workflow_file_path())
    server = start_supervised!(Server)
    counts = start_supervised!({Agent, fn -> %{} end})
    [context] = contexts(root, ["one"])
    assert Client.complete_relay_issue?(issue_node(context), context)
    refute Client.complete_relay_issue?(Map.delete(issue_node(context), "labels"), context)
    refute Client.complete_relay_issue?(put_in(issue_node(context)["labels"]["nodes"], List.duplicate(%{"name" => "label"}, 50)), context)
    bump = fn key -> Agent.update(counts, &Map.update(&1, key, 1, fn n -> n + 1 end)) end
    configure_http(server, [context], [issue_node(context)], bump)
    start_supervised!({WorkerCapacity, contexts: [context]})
    start_supervised!({Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry})
    start_supervised!({ProjectPoller, contexts: [context]})
    context = ProjectPoller.context(context)
    assert {:ok, [{_, _}]} = ProjectPoller.read_issues(context, ["issue-0"])
    Agent.update(counts, fn _ -> %{} end)

    ProjectContext.with_context(context, fn ->
      assert {:ok, [_]} = IssueReadCache.fetch(["issue-0"])
      assert Agent.get_and_update(counts, &{&1, %{}}) == %{read: 1}
      assert {:ok, [_]} = IssueReadCache.fetch(["issue-0"])
      assert Agent.get(counts, & &1) == %{}
    end)

    Server.publish(server, "one", %{"issueId" => "issue-0"})
    ProjectPoller.refresh()
    assert {:ok, [_]} = ProjectPoller.candidates(context)

    ProjectContext.with_context(context, fn ->
      assert {:ok, [_]} = IssueReadCache.fetch(["issue-0"])
      assert Agent.get(counts, & &1) == %{read: 2}
    end)
  end

  test "relay blocker types preserve custom terminal states and reject old incomplete cache nodes" do
    root = Path.dirname(Workflow.workflow_file_path())
    [context] = contexts(root, ["one"])
    blocker = %{"type" => "blocks", "issue" => %{"id" => "blocker", "identifier" => "PRO-2", "state" => %{"name" => "Abgeschlossen", "type" => "completed"}}}
    node = put_in(issue_node(context)["inverseRelations"]["nodes"], [blocker])

    assert Client.complete_relay_issue?(node, context)
    issue = ProjectContext.with_context(context, fn -> Client.relay_issue(node) end)
    assert [%{state_type: "completed"} = dependency] = issue.blocked_by
    assert Dependencies.terminal?(dependency)

    old_node = put_in(node["inverseRelations"]["nodes"], [put_in(blocker["issue"]["state"], %{"name" => "Abgeschlossen"})])
    refute Client.complete_relay_issue?(old_node, context)

    truncated = put_in(node["inverseRelations"]["nodes"], List.duplicate(blocker, 50))
    refute Client.complete_relay_issue?(truncated, context)
    incomplete = ProjectContext.with_context(context, fn -> Client.relay_issue(truncated) end)
    refute incomplete.relations_complete
  end

  test "a predecessor epoch invalidates a warm dependent issue read" do
    root = Path.dirname(Workflow.workflow_file_path())
    server = start_supervised!(Server)
    counts = start_supervised!({Agent, fn -> %{} end})
    [context] = contexts(root, ["one"])
    state = %{"name" => "Review", "type" => "completed"}
    blocker = %{"type" => "blocks", "issue" => %{"id" => "predecessor", "identifier" => "PRO-2", "state" => state}}
    node = put_in(issue_node(context)["inverseRelations"]["nodes"], [blocker])
    assert Client.complete_relay_issue?(node, context)

    # This probe measures issue verification, independently of comment tasks.
    bump = fn
      :read -> Agent.update(counts, &Map.update(&1, :read, 1, fn n -> n + 1 end))
      _ -> :ok
    end

    configure_http(server, [context], [node], bump)
    start_supervised!({WorkerCapacity, contexts: [context]})
    start_supervised!({Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry})
    start_supervised!({ProjectPoller, contexts: [context]})
    context = ProjectPoller.context(context)

    ProjectContext.with_context(context, fn ->
      assert {:ok, [_]} = Tracker.fetch_issue_states_by_ids([node["id"]])
      Agent.update(counts, fn _ -> %{} end)
      assert {:ok, [_]} = Tracker.fetch_issue_states_by_ids([node["id"]])
      assert Agent.get(counts, & &1) == %{}
    end)

    Server.publish(server, "one", %{"issueId" => "predecessor"})
    ProjectPoller.refresh()
    assert {:ok, [_]} = ProjectPoller.candidates(context)
    Agent.update(counts, fn _ -> %{} end)

    ProjectContext.with_context(context, fn ->
      assert {:ok, [_]} = Tracker.fetch_issue_states_by_ids([node["id"]])
      assert Agent.get(counts, & &1) == %{read: 1}
    end)
  end

  test "forced dependency marker reads bypass the shared warm comment stand" do
    root = Path.dirname(Workflow.workflow_file_path())
    server = start_supervised!(Server)
    [context] = contexts(root, ["one"])
    node = issue_node(context)
    configure_http(server, [context], [node], fn _ -> :ok end)
    start_supervised!({WorkerCapacity, contexts: [context]})
    start_supervised!({Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry})
    start_supervised!({ProjectPoller, contexts: [context]})
    context = ProjectPoller.context(context)
    request = Application.fetch_env!(:symphony_elixir, :linear_client_request_fun)
    {:ok, comments} = Agent.start_link(fn -> [] end)

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, headers ->
      if (payload[:query] || payload["query"]) =~ "SymphonyLinearIssueComments" do
        connection = %{"nodes" => Agent.get(comments, & &1), "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}
        {:ok, %{status: 200, body: %{"data" => %{"issue" => %{"comments" => connection}}}}}
      else
        request.(payload, headers)
      end
    end)

    ProjectContext.with_context(context, fn ->
      issue = Client.relay_issue(node)
      assert {:ok, []} = SymphonyElixir.WaitMarker.workpad_markers(issue, [])
      source = %{"id" => "workpad", "body" => "## Symphony Workpad\nWartet auf: PRI-1", "issue" => %{"id" => issue.id}, "user" => %{"id" => "human", "app" => false}}
      Agent.update(comments, fn _ -> [source] end)
      assert {:ok, []} = SymphonyElixir.WaitMarker.workpad_markers(issue, [])
      assert {:ok, ["PRI-1"]} = SymphonyElixir.WaitMarker.workpad_markers(issue, force_full: true)
    end)
  end

  @tag :review_regression
  test "delegated lease admission rejects Linear ownership changes before the relay echo" do
    {context, node, linear, _comments, _counts} = mutable_read_fixture()

    ProjectContext.with_context(context, fn ->
      assert {:ok, [issue]} = Tracker.fetch_issue_states_by_ids([node["id"]])
      Agent.update(linear, &Map.put(&1, "delegate", nil))
      assert {:ok, [cached]} = Tracker.fetch_issue_states_by_ids([issue.id])
      assert cached.delegate_id == issue.delegate_id
      assert {:error, :yolo_delegation_changed} = IssueLease.ready_for_delivery(issue)
    end)
  end

  @tag :review_regression
  test "final PO start rejects a Linear description change during checkout creation" do
    {context, node, linear, _comments, _counts} = mutable_read_fixture()

    ProjectContext.with_context(context, fn ->
      assert {:ok, [issue]} = Tracker.fetch_issue_states_by_ids([node["id"]])

      opts = [
        lease: fn _, callback -> callback.() end,
        scan: fn _ -> {:ok, %{"versions" => %{}, "last_successful_scan" => "now", "scan_error" => nil}} end,
        workspace: fn _, _ ->
          Agent.update(linear, &Map.put(&1, "description", "Anforderungen zwischenzeitlich geändert"))
          {:ok, %{path: context.root, sha: "sha"}}
        end,
        unchanged: fn _ -> true end,
        checkpoint: fn _ -> {:ok, %{}} end,
        session: fn _, _, _, _ -> {:error, :unexpected_cached_start} end
      ]

      assert {:error, :yolo_launch_changed} = Runner.run("incoming", [issue], [issue], opts)
    end)
  end

  @tag :review_regression
  test "wait notes preserve the latest remote workpad before its relay echo" do
    {context, node, _linear, comments, _counts} = mutable_read_fixture()

    ProjectContext.with_context(context, fn ->
      assert {:ok, [issue]} = Tracker.fetch_issue_states_by_ids([node["id"]])
      assert {:ok, [old]} = IssueReadCache.comments(issue.id)
      current = old.body <> "\nAktuelle Ergänzung aus Linear.\n"
      Agent.update(comments, &put_in(&1, [issue.id, "body"], current))
      assert {:ok, [^old]} = Tracker.fetch_issue_comments(issue.id)

      assert :ok = SymphonyElixir.WaitMarker.record_wait(issue, [%{identifier: "PRI-1", state: "Todo"}])
      written = Agent.get(comments, &get_in(&1, [issue.id, "body"]))
      assert String.contains?(written, "Aktuelle Ergänzung aus Linear.")
      assert String.contains?(written, "Wartemarker offen: PRI-1")
    end)
  end

  @tag :review_regression
  test "warm marker reads survive an expired issue verification under critical budget" do
    {context, node, _linear, _comments, counts} = mutable_read_fixture()
    clock = start_supervised!({Agent, fn -> 0 end}, id: :read_clock)
    Application.put_env(:symphony_elixir, :linear_read_now_fun, fn -> Agent.get(clock, & &1) end)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_read_now_fun) end)

    ProjectContext.with_context(context, fn ->
      assert {:ok, [issue]} = Tracker.fetch_issue_states_by_ids([node["id"]])
      assert {:ok, []} = SymphonyElixir.WaitMarker.workpad_markers(issue, [])
      Agent.update(counts, fn _ -> %{} end)
      Agent.update(clock, fn _ -> 3_600_001 end)
      app = context.settings.tracker.app
      Budget.record(app, :read, %{"x-ratelimit-requests-limit" => "5000", "x-ratelimit-requests-remaining" => "999"})

      assert {:ok, []} = SymphonyElixir.WaitMarker.workpad_markers(issue, [])
      assert Agent.get(counts, & &1) == %{}
    end)
  end

  test "trusted BLOCKER brake confirms a lost update response before the relay echo" do
    {context, node, linear, _comments, _counts} = mutable_read_fixture()
    trusted = "b57e9f80-53ce-4d96-9180-370f03d60d16"
    tracker = %{context.settings.tracker | trusted_agent_ids: [trusted], escalation_trusted_agent_id: trusted}

    context = %{
      context
      | yolo_agent_id: trusted,
        settings: %{context.settings | tracker: tracker},
        trusted_binding: CommentVersion.digest([tracker.app, tracker.trusted_agent_ids])
    }

    ProjectContext.with_context(context, fn ->
      assert {:ok, [cached]} = Tracker.fetch_issue_states_by_ids([node["id"]])
      Agent.update(linear, &Map.merge(&1, %{"state" => %{"name" => "BLOCKER"}, "delegate" => %{"id" => trusted}}))
      assert {:ok, [issue]} = Tracker.fetch_issue_states_by_ids([node["id"]], force_full: true)
      assert issue.state == "BLOCKER"
      assert {:ok, [stale]} = Tracker.fetch_issue_states_by_ids([issue.id])
      assert stale.state == cached.state and stale.delegate_id == cached.delegate_id
      Process.put(:brake_note, [])
      body = "## Symphony Workpad\n\n### Validierung\n\n- [ ] Betreiber prüft Hostzugang; fällig: Yolo Review\n"

      opts = [
        now: fn -> 1_000 end,
        workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: body}]} end,
        workpad_write: fn _, _ -> :ok end,
        comments: fn _ -> {:ok, Process.get(:brake_note)} end,
        escalation_comment: fn _, note ->
          Process.put(:brake_note, [%{body: note}])
          :ok
        end,
        query: fn query, variables ->
          if query =~ "YoloEscalationRecipient" do
            user = %{"id" => trusted, "app" => true, "active" => true, "isMentionable" => false, "organization" => %{"id" => tracker.app["workspace_id"]}}
            {:ok, %{"data" => %{"users" => %{"nodes" => [user], "pageInfo" => %{"hasNextPage" => false}}}}}
          else
            assert query =~ "YoloUpdate"
            assert variables.input == %{delegateId: nil}
            Agent.update(linear, &Map.put(&1, "delegate", nil))
            {:error, :response_lost}
          end
        end
      ]

      assert :ok = BlockerBrake.reserve([issue], "first-run", opts)
      assert {:ok, []} = BlockerBrake.check([issue], opts)
      assert {:ok, [fresh]} = Tracker.fetch_issue_states_by_ids([issue.id], force_full: true)
      assert fresh.delegate_id == nil
      assert fresh.assignee_id == issue.assignee_id
      assert fresh.state == "BLOCKER"
    end)
  end

  defp mutable_read_fixture do
    root = Path.dirname(Workflow.workflow_file_path())
    server = start_supervised!(Server)
    [context] = contexts(root, ["one"])
    app = context.settings.tracker.app
    normal = %{"x-ratelimit-requests-limit" => "5000", "x-ratelimit-requests-remaining" => "5000"}
    Budget.record(app, :read, normal)
    on_exit(fn -> Budget.record(app, :read, normal) end)
    node = issue_node(context)

    node = %{
      node
      | "state" => %{"name" => "Backlog"},
        "delegate" => %{"id" => "agent"},
        "labels" => %{"nodes" => [%{"name" => ~s(Skip "Freigabe Implementierung")}, %{"name" => ~s(Skip "Freigabe Review")}]}
    }

    counts = start_supervised!({Agent, fn -> %{} end})
    bump = fn kind -> Agent.update(counts, &Map.update(&1, kind, 1, fn n -> n + 1 end)) end
    configure_http(server, [context], [node], bump)
    start_supervised!({WorkerCapacity, contexts: [context]})
    start_supervised!({Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry})
    start_supervised!({ProjectPoller, contexts: [context]})
    context = %{ProjectPoller.context(context) | yolo_agent_id: "agent"}
    linear = start_supervised!({Agent, fn -> node end}, id: :linear_source)
    comment = initial_workpad(node, [context])
    comments = start_supervised!({Agent, fn -> %{node["id"] => comment} end}, id: :comment_source)
    request = Application.fetch_env!(:symphony_elixir, :linear_client_request_fun)

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, headers ->
      query = payload[:query] || payload["query"]

      if query =~ "SymphonyLinearIssuesById" or query =~ "comments(" or query =~ "commentUpdate(" or query =~ "SymphonyReceipt(" do
        {kind, data} = budget_response(query, payload, context.settings.tracker.app, [context.settings.tracker.project_slug], [Agent.get(linear, & &1)], false, comments)
        bump.(kind)
        {:ok, %{status: 200, body: %{"data" => data}}}
      else
        request.(payload, headers)
      end
    end)

    {context, node, linear, comments, counts}
  end

  for {active, unresolved} <- [{0, false}, {5, false}, {0, true}] do
    if active > 0, do: @tag(:running_load)
    @tag timeout: 180_000
    test "thirty-minute virtual relay load with #{active} running tickets and unresolved marker #{unresolved} stays within instance budget" do
      active = unquote(active)
      unresolved = unquote(unresolved)
      root = Path.dirname(Workflow.workflow_file_path())
      server = start_supervised!(Server)
      counts = start_supervised!({Agent, fn -> %{} end})
      {:ok, operations} = Agent.start_link(fn -> %{} end)
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      {:ok, recovery_attempts} = Agent.start_link(fn -> 0 end)
      [context | target_contexts] = contexts(root, ["one", "two", "two", "two"])
      context = put_in(context.settings.polling.interval_ms, 5_000)
      contexts = [context | target_contexts]
      target_context = hd(target_contexts)

      target_node =
        issue_node(target_context)
        |> Map.put("identifier", "PRI-892")
        |> Map.put("team", %{"key" => "PRI"})
        |> Map.put("state", %{"name" => "Yolo Review"})

      active_nodes =
        for index <- 0..(active - 1)//1, active > 0 do
          issue_node(context)
          |> Map.put("id", "issue-#{index}")
          |> Map.put("identifier", "PRO-#{index}")
        end

      delegated_nodes =
        for index <- 1..4 do
          issue_node(context)
          |> Map.put("id", "yolo-#{index}")
          |> Map.put("identifier", "PRO-#{100 + index}")
          |> Map.put("state", %{"name" => "Yolo Review"})
          |> Map.put("description", if(index == 1, do: "Wartet auf: #{if(unresolved, do: "PRI-999", else: "PRI-892")}", else: ""))
          |> Map.put("delegate", %{"id" => "pai"})
          |> Map.put("labels", %{"nodes" => Enum.map([~s(Skip "Freigabe Implementierung"), ~s(Skip "Freigabe Review")], &%{"name" => &1})})
        end

      nodes = active_nodes ++ delegated_nodes ++ [target_node]
      Application.put_env(:symphony_elixir, :linear_read_now_fun, fn -> Agent.get(clock, & &1) end)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_read_now_fun) end)

      bump = fn key -> Agent.update(counts, &Map.update(&1, key, 1, fn n -> n + 1 end)) end
      configure_http(server, contexts, nodes, bump, unresolved)
      start_supervised!({WorkerCapacity, contexts: contexts})
      start_supervised!({Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry})
      start_supervised!({ProjectPoller, contexts: contexts})
      context = ProjectPoller.context(context)
      context = if active > 0, do: put_in(context.settings.tracker.advisory_agent_ids, ["advisor"]), else: context
      context = %{context | yolo_agent_id: "pai", assignee_ids: ["human"], human_handoff_id: "human"}
      assert {:ok, _} = ProjectPoller.candidates(context)
      assert length(target_contexts) == 3

      :sys.replace_state(ProjectPoller, fn state ->
        session = state.relays["one"]
        session = %{session | record: Map.put(session.record, "reconcile_at", 1_800_001), clock: fn -> Agent.get(clock, & &1) end}
        put_in(state.relays["one"], session)
      end)

      ProjectContext.with_context(context, fn ->
        for node <- active_nodes do
          assert {:ok, [_]} = IssueReadCache.fetch([node["id"]], now: 0)
          assert {:ok, _} = CommentCheckpoint.background_scan(Client.relay_issue(node), background_now: fn -> 0 end)
          adopt_inputs(node["id"], 0)
        end

        if active > 0 do
          members = Enum.map(Enum.take(delegated_nodes, -3), &Client.relay_issue/1)

          Scope.with_scope("review", members, "load-review", fn ->
            for issue <- members, do: adopt_inputs(issue.id, 0)
          end)
        end
      end)

      IO.puts("thirty-minute relay cold active=#{active} requests=#{inspect(Agent.get(counts, & &1))}")
      Agent.update(counts, fn _ -> %{} end)
      handler = "thirty-minute-budget-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:symphony, :linear, :request],
        fn _, _, metadata, pid ->
          key = {metadata.workspace_id, WriteContext.current()["phase"] || "background", metadata.operation}
          Agent.update(pid, &Map.update(&1, key, 1, fn n -> n + 1 end))
        end,
        operations
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      yolo_state = %SymphonyElixir.Orchestrator.State{max_concurrent_agents: 0, codex_totals: %{}}
      Process.put(:completion_refresh_now_fun, fn -> Agent.get(clock, & &1) end)
      on_exit(fn -> Process.delete(:completion_refresh_now_fun) end)

      marker_state = %SymphonyElixir.Orchestrator.State{
        max_concurrent_agents: 0,
        completed: MapSet.new(["invisible-merge"]),
        completed_states: %{"invisible-merge" => "merge (ai)"}
      }

      ProjectContext.with_context(context, fn ->
        for id <- if(unresolved, do: ["yolo-1", "yolo-2"], else: ["yolo-1"]) do
          assert :ok =
                   Operations.save(%{
                     "key" => "followup:budget:#{id}",
                     "request" => %{"kind" => "followup", "origin_ids" => [id]},
                     "issue_id" => Ecto.UUID.generate(),
                     "done" => false
                   })
        end
      end)

      {{yolo_state, marker_state}, log} =
        ExUnit.CaptureLog.with_log(fn ->
          Enum.reduce(5..1_800//5, {yolo_state, marker_state}, fn seconds, {yolo_state, marker_state} ->
            Agent.update(clock, fn _ -> seconds * 1_000 end)
            before_event = if seconds in [600, 1_200], do: Agent.get(counts, & &1), else: %{}

            if active > 0 and seconds == 600,
              do: Server.publish(server, "one", %{"type" => "Comment", "issueId" => "issue-0", "commentId" => "human-comment"})

            if active > 0 and seconds == 1_200,
              do: Server.publish(server, "one", %{"issueId" => "issue-1"})

            ProjectPoller.refresh()
            assert {:ok, _} = ProjectPoller.candidates(context)

            ProjectContext.with_context(context, fn ->
              for node <- active_nodes do
                issue = Client.relay_issue(node)
                assert {:ok, _} = CommentCheckpoint.background_scan(issue, background_now: fn -> seconds * 1_000 end)
                assert {:ok, [_]} = IssueReadCache.fetch([issue.id], now: seconds * 1_000)
              end
            end)

            if active > 0 and rem(seconds, 30) == 0 do
              ProjectContext.with_context(context, fn -> running_reads(active_nodes, delegated_nodes, seconds) end)
            end

            marker_state =
              ProjectContext.with_context(context, fn ->
                {next, []} = SymphonyElixir.Orchestrator.reconcile_completed_states_for_test(marker_state, [])
                assert next.completed_states["invisible-merge"] == "merge (ai)"
                next
              end)

            yolo_state =
              ProjectContext.with_context(context, fn ->
                delegated =
                  Enum.map(delegated_nodes, fn node ->
                    %{Client.relay_issue(node) | last_comment_signal: %{relay_epoch: "budget-stable"}}
                  end)

                Coordinator.tick(yolo_state, delegated,
                  background_now: fn -> seconds * 1_000 end,
                  contexts: contexts,
                  relay_ready: fn _ -> true end,
                  recovery_now: fn -> seconds * 1_000 end,
                  lease: fn _, callback -> callback.() end,
                  invoke: fn request, _ ->
                    assert request["origin_ids"] == [if(unresolved, do: "yolo-2", else: "yolo-1")]
                    Agent.update(recovery_attempts, &(&1 + 1))
                    assert {:ok, _} = Tracker.fetch_issue_comment_bodies(if(unresolved, do: "yolo-2", else: "yolo-1"))
                    {:error, :yolo_created_issue_changed}
                  end,
                  scan: fn _ -> {:ok, %{"versions" => %{}, "last_successful_scan" => "now", "scan_error" => nil}} end,
                  start: fn _, _ -> {:error, :capacity} end
                )
              end)

            if active > 0 and seconds == 600,
              do: assert(Map.get(Agent.get(counts, & &1), :comments, 0) > Map.get(before_event, :comments, 0))

            if active > 0 and seconds == 1_200,
              do: assert(Map.get(Agent.get(counts, & &1), :read, 0) > Map.get(before_event, :read, 0))

            {yolo_state, marker_state}
          end)
        end)

      if unresolved do
        assert %{reason: :wait_target_unresolved, error: {:wait_marker_unresolved, "PRI-999", :wait_target_unresolved}} =
                 yolo_state.yolo_marker_cache[{:wait_report, "yolo-1", "PRI-999"}]
      end

      assert marker_state.completed_states["invisible-merge"] == "merge (ai)"
      assert Agent.get(recovery_attempts, & &1) == 4

      if unresolved do
        assert length(Regex.scan(~r/Wartemarker nicht auflösbar issue_id=yolo-1 /, log)) <= 6
        refute log =~ "YOLO dependencies unavailable"
      end

      requests = Agent.get(counts, & &1)
      attributed = Agent.get(operations, & &1)
      by_operation = Enum.reduce(attributed, %{}, fn {{_, _, operation}, n}, acc -> Map.update(acc, operation, n, &(&1 + n)) end)
      total = Enum.sum(Map.values(by_operation))

      for {workspace, entries} <- Enum.group_by(attributed, fn {{workspace, _, _}, _} -> workspace end) do
        operation_counts = Enum.reduce(entries, %{}, fn {{_, _, operation}, n}, acc -> Map.update(acc, operation, n, &(&1 + n)) end)
        IO.puts("Linear budget summary workspace_id=#{workspace} active=#{active} requests=#{Enum.sum(Map.values(operation_counts))} operations=#{inspect(operation_counts)}")
        assert Enum.sum(Map.values(operation_counts)) <= if(active == 0, do: 50, else: 375)
      end

      IO.puts("thirty-minute relay budget active=#{active} requests=#{total} attributed=#{inspect(attributed, limit: :infinity)}")
      assert total == Enum.sum(Map.values(requests))
      assert total <= if(active == 0, do: 50, else: 375)
      assert Map.get(by_operation, "WaitTarget", 0) <= 6
      if unresolved, do: assert(Map.get(by_operation, "SymphonyLinearIssueComments", 0) <= 20)
      if unresolved, do: refute(Map.has_key?(by_operation, "SymphonyLinearCommentUpdate"))
      if active == 0, do: refute(Map.has_key?(by_operation, "SymphonyCommentScanSignal"))
    end
  end

  defp running_reads(active_nodes, delegated_nodes, seconds) do
    for {node, index} <- Enum.with_index(active_nodes) do
      phases = ["Planung (AI)", "In Arbeit (AI)", "PreReview (AI)", "Review (AI)", "Test (AI)", "Merge (AI)"]
      phase = Enum.at(phases, rem(index + div(seconds, 30), length(phases)))
      context = %{issue_id: node["id"], phase: phase, run_id: "worker-#{index}", tool_call_id: "load-#{seconds}"}

      WriteContext.with_context(context, fn -> worker_reads(node, index, seconds) end)
    end

    for {phase, node} <- Enum.zip(["po_incoming", "po_review", "BLOCKER"], Enum.take(delegated_nodes, -3)) do
      WriteContext.with_context(%{issue_id: node["id"], phase: phase, run_id: phase}, fn -> po_reads(node, seconds) end)
    end

    members = Enum.map(Enum.take(delegated_nodes, -3), &Client.relay_issue/1)
    Scope.with_scope("review", members, "load-review", fn -> review_group_reads(members, seconds) end)
  end

  defp worker_reads(node, index, seconds) do
    worker_read(node, index, seconds)
    if rem(seconds, 300) == 0, do: worker_write(node, seconds)
  end

  defp po_reads(node, seconds) do
    issue = Client.relay_issue(node)
    assert {:ok, [_]} = Tracker.fetch_issue_states_by_ids([issue.id])
    opts = [now: seconds * 1_000, background_now: fn -> seconds * 1_000 end]
    assert {:ok, [_]} = Dependencies.refresh([issue], opts)
    assert {:ok, _} = CommentCheckpoint.checkpoint(issue, opts)
  end

  defp worker_read(node, index, seconds) do
    if rem(seconds, 60) == 0 do
      worker_checkpoint(index, seconds, read_opts(seconds))
    else
      assert {:ok, [_]} = IssueReadCache.fetch([node["id"]], now: seconds * 1_000)
      assert {:ok, _} = Tracker.fetch_issue_comments(node["id"])
    end
  end

  defp read_opts(seconds) do
    [fetch_issue: fn ids -> IssueReadCache.fetch(ids, now: seconds * 1_000, critical: true) end, background_now: fn -> seconds * 1_000 end]
  end

  defp worker_checkpoint(index, seconds, opts) do
    args = %{"operation" => "checkpoint"}

    if rem(index, 2) == 0 do
      result = DynamicTool.execute("symphony_comments", args, opts)
      assert result["success"], result["output"]
    else
      request = %{"jsonrpc" => "2.0", "id" => seconds, "method" => "tools/call", "params" => %{"name" => "symphony_comments", "arguments" => args}}
      result = MCPServer.handle_request(request, opts)
      refute result["result"]["isError"]
    end
  end

  defp worker_write(node, seconds) do
    result = DynamicTool.execute("linear_graphql", %{"query" => "{ issues(first: 1) { nodes { id } } }"})
    assert result["success"]
    body = "## Symphony Workpad\n\n### Verlauf\n\n- Arbeitsstand bei #{seconds} Sekunden geprüft.\n"

    query = """
    mutation LoadWorkpadUpdate($id: String!, $body: String!) {
      commentUpdate(id: $id, input: {body: $body}) { success comment { id } }
    }
    """

    update =
      DynamicTool.execute("linear_graphql", %{
        "query" => query,
        "variables" => %{"id" => "workpad-#{node["id"]}", "body" => body}
      })

    assert update["success"], update["output"]
    assert {:ok, comments} = Tracker.fetch_issue_comments(node["id"])
    assert Enum.any?(comments, &(&1.body == body))
  end

  defp review_group_reads(members, seconds) do
    for issue <- members do
      args = %{"operation" => "checkpoint", "issue_id" => issue.id}
      result = DynamicTool.execute("symphony_comments", args, background_now: fn -> seconds * 1_000 end)
      assert result["success"], result["output"]
    end

    if rem(seconds, 600) == 0, do: assert({:ok, _} = ActionScope.sources(Enum.map(members, & &1.id), []))
  end

  defp adopt_inputs(id, seconds) do
    opts = [fetch_issue: fn ids -> IssueReadCache.fetch(ids, now: seconds * 1_000, critical: true) end, background_now: fn -> seconds * 1_000 end]
    assert {:ok, payload} = CommentTool.invoke(%{"operation" => "checkpoint", "issue_id" => id}, opts)
    results = Enum.map(payload["inputs"], &%{"key" => &1["key"], "outcome" => "übernommen", "reason" => "Gebundene Lastprüfung übernimmt den Ausgangsstand."})
    if results != [], do: assert({:ok, _} = CommentTool.invoke(%{"operation" => "acknowledge", "issue_id" => id, "results" => results}, opts))
  end

  defp wait_for_poll(server, count) do
    Enum.any?(1..65, fn _ ->
      Process.sleep(100)
      length(Server.calls(server)) > count and ProjectPoller.polling().next_poll_in_ms > 0
    end)
  end

  test "a workspace drains queued pages promptly without polling idle peers or bypassing backoff" do
    root = Path.dirname(Workflow.workflow_file_path())
    server = start_supervised!(Server)
    {:ok, counts} = Agent.start_link(fn -> %{} end)
    contexts = contexts(root, ["one", "two"])
    bump = fn key -> Agent.update(counts, &Map.update(&1, key, 1, fn n -> n + 1 end)) end
    configure_http(server, contexts, Enum.map(contexts, &issue_node/1), bump)
    start_supervised!({WorkerCapacity, contexts: contexts})
    start_supervised!({Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry})
    start_supervised!({ProjectPoller, contexts: contexts})
    background(contexts, 0)
    Agent.update(counts, fn _ -> %{} end)
    before = Server.calls(server)

    for _ <- 1..251, do: Server.publish(server, "one", %{"assigneeIds" => ["other"]})
    Server.publish(server, "one", %{"issueId" => "issue-0"})
    ProjectPoller.refresh()
    assert await_cursor(server, 252)
    background(contexts, 0)
    calls = Enum.drop(Server.calls(server), length(before))
    assert Enum.count(calls, &(elem(&1, 0) == "one" and elem(&1, 2) == :poll)) == 3
    assert Enum.count(calls, &(elem(&1, 0) == "two" and elem(&1, 2) == :poll)) == 1
    assert Agent.get(counts, & &1) == %{read: 1}

    # Obsolete replay messages do not poll a ready or unknown workspace.
    record = :sys.get_state(ProjectPoller).relays["one"].record
    send(ProjectPoller, {:relay_replay, "one", record["generation"], 100})
    send(ProjectPoller, {:relay_replay, "unknown", "old", 0})
    background(contexts, 0)
    assert Server.calls(server) == before ++ calls

    for _ <- 1..201, do: Server.publish(server, "one", %{"assigneeIds" => ["other"]})

    :sys.replace_state(ProjectPoller, fn state ->
      session = state.relays["one"]

      request = fn op, body ->
        result = session.request.(op, body)
        if op == :ack, do: Server.fault(server, "one", "one", :poll, {:error, {:relay_http, 503, "unavailable"}})
        result
      end

      put_in(state.relays["one"].request, request)
    end)

    ProjectPoller.refresh()

    assert Enum.any?(1..100, fn _ ->
             Process.sleep(10)
             :sys.get_state(ProjectPoller).relays["one"].status == :degraded
           end)

    failed_calls = Server.calls(server)
    Process.sleep(30)
    assert Server.calls(server) == failed_calls
    assert Server.consumer(server, "one", "one").cursor == 352
    assert {:ok, [_]} = ProjectPoller.candidates(List.last(contexts))
    assert Agent.get(counts, & &1) == %{read: 1}
  end

  test "thirty-minute idle relay budget includes an undeliverable escalation" do
    root = Path.dirname(Workflow.workflow_file_path())
    server = start_supervised!(Server)
    counts = start_supervised!({Agent, fn -> %{} end})
    [context] = contexts(root, ["one"])
    context = put_in(context.settings.polling.interval_ms, 5_000)

    node =
      context
      |> issue_node()
      |> Map.put("url", "https://linear.example/PRO-0")
      |> Map.put("state", %{"name" => "Yolo Review"})

    bump = fn key -> Agent.update(counts, &Map.update(&1, key, 1, fn n -> n + 1 end)) end
    configure_http(server, [context], [node], bump)
    start_supervised!({WorkerCapacity, contexts: [context]})
    start_supervised!({Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry})
    start_supervised!({ProjectPoller, contexts: [context]})
    assert {:ok, _} = ProjectPoller.candidates(context)
    context = ProjectPoller.context(context)
    context = %{context | yolo_agent_id: "pai", assignee_ids: ["human"], human_handoff_id: "human"}
    context = put_in(context.settings.tracker.openclaw_yolo_agent, "pai")
    issue = ProjectContext.with_context(context, fn -> Client.relay_issue(node) end)
    route = fn _, _ -> {:error, :openclaw_normal_channel_unavailable} end
    proposal = %{"escalation" => %{"cause" => "Route fehlt", "attempts" => "Übergabe bestätigt", "proposal" => "Route prüfen", "decision" => "Benachrichtigen"}}

    ProjectContext.with_context(context, fn ->
      assert {:error, :openclaw_normal_channel_unavailable} = Escalation.notify(issue, proposal, escalation_route: route)
    end)

    Agent.update(counts, fn _ -> %{} end)
    state = %SymphonyElixir.Orchestrator.State{max_concurrent_agents: 0, codex_totals: %{}}

    state =
      Enum.reduce(0..1_800_000//5_000, state, fn now, acc ->
        ProjectPoller.refresh()
        assert {:ok, _} = ProjectPoller.candidates(context)

        ProjectContext.with_context(context, fn ->
          Coordinator.tick(acc, [issue],
            notification_now: fn -> now end,
            escalation_route: route,
            scan: fn _ -> {:ok, %{"versions" => %{}, "last_successful_scan" => "now", "scan_error" => nil}} end,
            start: fn _, _ -> flunk("notification retry must not start a review") end
          )
        end)
      end)

    requests = Agent.get(counts, & &1)
    assert map_size(state.yolo_retries.notifications) == 1
    assert Map.get(requests, :read, 0) >= 1
    assert Enum.sum(Map.values(requests)) <= 50
    assert Map.get(requests, :read, 0) <= 6
  end

  defp await_cursor(server, expected) do
    Enum.any?(1..100, fn _ ->
      Process.sleep(10)
      Server.consumer(server, "one", "one").cursor == expected
    end)
  end

  for {label, workspaces, active} <- [
        {:idle, ["one"], 0},
        {:active, ["one"], 1},
        {:three_projects, ["one", "one", "one"], 3},
        {:two_workspaces, ["one", "one", "two"], 3}
      ] do
    test "five-minute relay budget and reconcile deadline: #{label}" do
      workspaces = unquote(workspaces)
      active = unquote(active)
      root = Path.dirname(Workflow.workflow_file_path())
      server = start_supervised!(Server)
      {:ok, counts} = Agent.start_link(fn -> %{} end)
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      contexts = contexts(root, workspaces)
      nodes = contexts |> Enum.take(active) |> Enum.map(&issue_node/1)
      bump = fn key -> Agent.update(counts, &Map.update(&1, key, 1, fn n -> n + 1 end)) end
      configure_http(server, contexts, nodes, bump)
      start_supervised!({WorkerCapacity, contexts: contexts})
      start_supervised!({Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry})
      start_supervised!({ProjectPoller, contexts: contexts})
      background(contexts, active)
      cold = Agent.get_and_update(counts, &{&1, %{}})

      :sys.replace_state(ProjectPoller, fn state ->
        relays =
          Map.new(state.relays, fn {workspace, session} ->
            record = Map.put(session.record, "reconcile_at", 3_600_001)
            {workspace, %{session | record: record, clock: fn -> Agent.get(clock, & &1) end}}
          end)

        %{state | relays: relays}
      end)

      for seconds <- 5..300//5 do
        Agent.update(clock, fn _ -> seconds * 1_000 end)
        ProjectPoller.refresh()
        background(contexts, active)
      end

      warm = Agent.get_and_update(counts, &{&1, %{}})
      assert warm == %{}
      IO.puts("relay budget #{unquote(label)} cold=#{inspect(cold)} warm=#{inspect(warm)} total=0")

      # Jump to either side of the actual deadline instead of replaying an hour.
      Agent.update(clock, fn _ -> 3_600_000 end)
      ProjectPoller.refresh()
      background(contexts, active)
      assert Agent.get(counts, & &1) == %{}
      Agent.update(clock, fn _ -> 3_600_001 end)
      ProjectPoller.refresh()
      for context <- contexts, do: assert({:ok, _} = ProjectPoller.candidates(context))
      assert Agent.get_and_update(counts, &{&1, %{}}) == %{read: length(Enum.uniq(workspaces))}

      for _ <- 1..5, do: Server.publish(server, "one", %{"issueId" => "issue-0"})
      ProjectPoller.refresh()
      for context <- contexts, do: assert({:ok, _} = ProjectPoller.candidates(context))
      assert Agent.get_and_update(counts, &{&1, %{}}) == %{read: 1}

      for context <- Enum.take(contexts, active) do
        ProjectContext.with_context(context, fn ->
          assert {:ok, _} = CommentCheckpoint.scan(Client.relay_issue(issue_node(context)))
        end)
      end

      assert Agent.get_and_update(counts, &{&1, %{}}) == %{}

      for workspace <- Enum.uniq(workspaces),
          do: Server.fault(server, workspace, "one", :poll, {:error, {:relay_http, 503, "unavailable"}})

      ProjectPoller.refresh()
      for context <- contexts, do: assert({:error, _} = ProjectPoller.candidates(context))
      assert Agent.get(counts, & &1) == %{}
    end
  end

  defp contexts(root, workspaces) do
    for {workspace, index} <- Enum.with_index(workspaces) do
      project = Path.join(root, "budget-project-#{index}")
      File.mkdir_p!(Path.join(project, ".symphony"))
      File.write!(Path.join(project, ".symphony/.env"), "LINEAR_ASSIGNEE=human@example.com\nLINEAR_RELAY_KEY=key-#{workspace}\n")
      {:ok, context} = ProjectContext.load(project, Workflow.workflow_file_path(), %{})

      relay = %{
        "endpoint" => "https://relay.test",
        "key_env" => "LINEAR_RELAY_KEY",
        "consumer_id" => "one",
        "state_root" => Path.join(root, "relay-state"),
        "reconcile_ms" => 3_600_000
      }

      context = put_in(context.settings.tracker.relay, relay)
      context = put_in(context.settings.tracker.app["workspace_id"], workspace)
      context = put_in(context.settings.tracker.assignee, "human@example.com")
      context = put_in(context.settings.tracker.project_slug, "project-#{index}")
      put_in(context.settings.polling.interval_ms, 3_600_000)
    end
  end

  defp issue_node(context) do
    index = String.replace_prefix(context.settings.tracker.project_slug, "project-", "")

    %{
      "id" => "issue-#{index}",
      "identifier" => "PRO-#{index}",
      "title" => "Budget",
      "description" => "",
      "priority" => 0,
      "branchName" => nil,
      "url" => nil,
      "delegate" => nil,
      "team" => nil,
      "createdAt" => nil,
      "updatedAt" => nil,
      "state" => %{"name" => "In Arbeit (AI)"},
      "project" => %{"slugId" => context.settings.tracker.project_slug},
      "assignee" => %{"id" => "human", "email" => "human@example.com", "app" => false},
      "labels" => %{"nodes" => []},
      "inverseRelations" => %{"nodes" => []},
      "comments" => %{"nodes" => []}
    }
  end

  defp background(contexts, active) do
    for context <- contexts, do: assert({:ok, _} = ProjectPoller.candidates(context))

    for context <- Enum.take(contexts, active) do
      ProjectContext.with_context(context, fn ->
        assert {:ok, [issue]} = Relay.background_issues([issue_node(context)["id"]])
        assert {:ok, _} = CommentCheckpoint.background_scan(issue)
      end)
    end
  end

  defp configure_http(server, contexts, nodes, bump, unresolved \\ false) do
    keys =
      Map.new(contexts, fn c ->
        w = c.settings.tracker.app["workspace_id"]
        {"key-#{w}", w}
      end)

    Req.default_options(
      plug: fn conn ->
        if conn.host == "relay.test" do
          Server.http(conn, server, keys)
        else
          bump.(:token)
          Req.Test.json(conn, %{"access_token" => "fixture", "token_type" => "Bearer", "expires_in" => 3600, "scope" => "read,write"})
        end
      end
    )

    workload? = Enum.count(nodes, &(&1["state"]["name"] == "In Arbeit (AI)")) == 5

    initial_comments = if workload?, do: Map.new(nodes, &{&1["id"], initial_workpad(&1, contexts)}), else: %{}
    {:ok, comment_store} = Agent.start_link(fn -> initial_comments end)

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _ ->
      query = payload[:query] || payload["query"]
      app = Config.settings!().tracker.app
      projects = contexts |> Enum.filter(&(&1.settings.tracker.app["workspace_id"] == app["workspace_id"])) |> Enum.map(& &1.settings.tracker.project_slug)

      {kind, data} = budget_response(query, payload, app, projects, nodes, unresolved, comment_store)

      bump.(kind)
      {:ok, %{status: 200, body: %{"data" => data}}}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)
  end

  defp initial_workpad(node, contexts) do
    %{
      "id" => "workpad-#{node["id"]}",
      "agentSession" => nil,
      "isArtificialAgentSessionRoot" => false,
      "bodyData" => nil,
      "parentId" => nil,
      "body" => "## Symphony Workpad\n\n### Verlauf\n\n- Gebundener Arbeitsstand übernommen.\n",
      "issue" => %{"id" => node["id"]},
      "user" => %{"id" => hd(contexts).settings.tracker.app["user_id"], "app" => true},
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-01T00:00:00Z"
    }
  end

  defp budget_response(query, payload, app, projects, nodes, unresolved, comment_store) do
    variables = payload[:variables] || payload["variables"] || %{}

    cond do
      query =~ "commentUpdate(" ->
        budget_comment_update(variables, comment_store)

      query =~ "SymphonyReceipt(" ->
        id = variables["id"] || variables[:id]
        {:receipt, %{"comment" => Agent.get(comment_store, &Map.get(&1, String.replace_prefix(id, "workpad-", "")))}}

      true ->
        budget_read_response(query, payload, app, projects, nodes, unresolved, comment_store)
    end
  end

  defp budget_comment_update(variables, comment_store) do
    id = variables["id"] || variables[:id] || variables["commentId"] || variables[:commentId]
    body = variables["body"] || variables[:body]
    issue_id = String.replace_prefix(id, "workpad-", "")

    comment =
      Agent.get_and_update(comment_store, fn current ->
        old = Map.fetch!(current, issue_id)
        {:ok, timestamp, _} = DateTime.from_iso8601(old["updatedAt"])
        updated = Map.merge(old, %{"body" => body, "updatedAt" => DateTime.to_iso8601(DateTime.add(timestamp, 1, :second))})
        {updated, Map.put(current, issue_id, updated)}
      end)

    {:write, %{"commentUpdate" => %{"success" => true, "comment" => comment, "symphonyReceipt" => comment}}}
  end

  defp budget_read_response(query, payload, app, projects, nodes, unresolved, comment_store) do
    cond do
      query =~ "SymphonyAdvisoryAgents" ->
        agent = %{"id" => "advisor", "app" => true, "active" => true, "organization" => %{"id" => app["workspace_id"]}}
        {:advisory, %{"users" => %{"nodes" => [agent], "pageInfo" => %{"hasNextPage" => false}}}}

      query =~ "YoloBlockers" ->
        {:blockers, %{"issue" => %{"inverseRelations" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}}

      query =~ "SymphonyAppIdentity" ->
        {:identity, %{"viewer" => %{"id" => app["user_id"], "app" => true, "organization" => %{"id" => app["workspace_id"]}}}}

      query =~ "SymphonyHumanAssignees" ->
        {:assignees, %{"users" => %{"nodes" => [%{"id" => "human", "email" => "human@example.com", "app" => false}], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}

      query =~ "SymphonyLinearIssuesById" ->
        {:read, budget_issues_by_id(payload, projects, nodes)}

      query =~ "SymphonyWorkspacePoll" ->
        {:read, budget_workspace_issues(projects, nodes)}

      query =~ "WaitTarget" ->
        {:wait_target, budget_wait_target(payload, projects, nodes)}

      true ->
        budget_comment_response(query, payload, app, projects, nodes, unresolved, comment_store)
    end
  end

  defp budget_comment_response(query, payload, app, projects, nodes, unresolved, comment_store) do
    cond do
      query =~ "SymphonyCommentScanSignal" ->
        data = budget_comments(payload, unresolved, comment_store)
        latest = get_in(data, ["issue", "comments", "nodes"]) |> Enum.take(1)
        foreign = Enum.reject(latest, &(get_in(&1, ["user", "id"]) == app["user_id"]))
        {:comments, %{"issue" => %{"comments" => %{"nodes" => latest}, "foreignComments" => %{"nodes" => foreign}}}}

      query =~ "comments(" ->
        {:comments, budget_comments(payload, unresolved, comment_store)}

      true ->
        {:read, budget_workspace_issues(projects, nodes)}
    end
  end

  defp budget_comments(payload, unresolved, comment_store) do
    variables = payload[:variables] || payload["variables"] || %{}
    id = variables[:id] || variables["id"]

    stored = Agent.get(comment_store, &Map.get(&1, id))

    nodes =
      if stored,
        do: [stored],
        else:
          if(unresolved and id == "yolo-1",
            do: [%{"id" => "workpad-yolo-1", "body" => "## Symphony Workpad\n\nWartemarker-Fehler PRI-999: :wait_target_unresolved; gebundene Zielkennung prüfen."}],
            else: []
          )

    %{"issue" => %{"comments" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}
  end

  defp budget_wait_target(payload, projects, nodes) do
    variables = payload[:variables] || payload["variables"] || %{}
    number = variables[:number] || variables["number"]
    team = variables[:team] || variables["team"]
    matches = Enum.filter(nodes, fn node -> node["identifier"] == "#{team}-#{number}" and node["project"]["slugId"] in projects end)
    %{"issues" => %{"nodes" => matches, "pageInfo" => %{"hasNextPage" => false}}}
  end

  defp budget_issues_by_id(payload, projects, nodes) do
    variables = payload[:variables] || payload["variables"] || %{}
    ids = variables[:ids] || variables["ids"] || []
    %{"issues" => %{"nodes" => Enum.filter(nodes, &(&1["id"] in ids and &1["project"]["slugId"] in projects))}}
  end

  defp budget_workspace_issues(projects, nodes) do
    %{"issues" => %{"nodes" => Enum.filter(nodes, &(&1["project"]["slugId"] in projects)), "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}
  end
end
