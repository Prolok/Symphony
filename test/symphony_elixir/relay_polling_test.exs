defmodule SymphonyElixir.RelayPollingTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{CommentCheckpoint, ProjectContext, ProjectPoller, Relay, WorkerCapacity}
  alias SymphonyElixir.RelayFixture, as: Server

  test "warm project ticks, running issue reads and comment background do not call Linear; gates remain fresh" do
    owner = self()
    root = Path.dirname(Workflow.workflow_file_path())
    project = Path.join(root, "relay-project")
    File.mkdir_p!(Path.join(project, ".symphony"))
    File.write!(Path.join(project, ".symphony/.env"), "LINEAR_ASSIGNEE=human@example.com\nLINEAR_RELAY_KEY=relay-key\n")
    {:ok, context} = ProjectContext.load(project, Workflow.workflow_file_path(), %{})

    config = %{
      "endpoint" => "https://relay.test",
      "key_env" => "LINEAR_RELAY_KEY",
      "consumer_id" => "one",
      "state_root" => Path.join(root, "relay-state"),
      "reconcile_ms" => 3_600_000
    }

    context = put_in(context.settings.tracker.relay, config)
    context = put_in(context.settings.tracker.assignee, "human@example.com")
    context = put_in(context.settings.polling.interval_ms, 3_600_000)
    server = start_supervised!(Server)

    node = %{
      "id" => "issue",
      "identifier" => "PRO-1",
      "title" => "Fixture",
      "state" => %{"name" => "In Arbeit (AI)"},
      "project" => %{"slugId" => context.settings.tracker.project_slug},
      "assignee" => %{"id" => "human", "email" => "human@example.com", "app" => false}
    }

    {:ok, sources} = Agent.start_link(fn -> [] end)
    {:ok, issue_source} = Agent.start_link(fn -> [node] end)

    Req.default_options(
      plug: fn conn ->
        if conn.host == "relay.test",
          do: Server.http(conn, server, %{"relay-key" => "synthetic-workspace"}),
          else: Req.Test.json(conn, %{"access_token" => "synthetic-token", "token_type" => "Bearer", "expires_in" => 3600, "scope" => "read,write"})
      end
    )

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _headers ->
      query = payload[:query] || payload["query"]
      send(owner, {:linear, query})

      data =
        cond do
          query =~ "SymphonyAppIdentity" -> %{"viewer" => %{"id" => "synthetic-app", "app" => true, "organization" => %{"id" => "synthetic-workspace"}}}
          query =~ "SymphonyHumanAssignees" -> %{"users" => %{"nodes" => [%{"id" => "human", "email" => "human@example.com", "app" => false}], "pageInfo" => %{"hasNextPage" => false}}}
          query =~ "SymphonyWorkspacePoll" -> %{"issues" => %{"nodes" => Agent.get(issue_source, & &1), "pageInfo" => %{"hasNextPage" => false}}}
          query =~ "SymphonyLinearIssuesById" -> %{"issues" => %{"nodes" => Agent.get(issue_source, & &1)}}
          query =~ "comment(id:" -> %{"comment" => nil}
          query =~ "issue(id: $id) { id }" -> %{"issue" => %{"id" => "issue"}}
          true -> %{"issue" => %{"comments" => %{"nodes" => Agent.get(sources, & &1), "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}
        end

      body = %{"data" => data}
      body = if query =~ "comment(id:", do: Map.put(body, "errors", [%{"path" => ["comment"], "message" => "Entity not found: Comment", "extensions" => %{"code" => "INPUT_ERROR"}}]), else: body
      {:ok, %{status: 200, body: body, headers: %{"X-Complexity" => ["17"]}}}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)
    assert {:ok, session} = Relay.open([context])
    assert {:ok, [^node]} = session.fetch.(["issue"])
    start_supervised!({WorkerCapacity, contexts: [context]})
    start_supervised!({Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry})
    start_supervised!({ProjectPoller, contexts: [context]})
    assert {:ok, [issue]} = ProjectPoller.candidates(context)
    context = ProjectPoller.context(context)

    ProjectContext.with_context(context, fn ->
      assert Relay.enabled?()
      assert Relay.Config.current() == config
      assert {:ok, _} = CommentCheckpoint.background_scan(issue)
      flush_requests()

      for _ <- 1..10 do
        ProjectPoller.refresh()
        assert {:ok, [_]} = ProjectPoller.candidates(context)
        assert {:ok, [_]} = Relay.background_issues(["issue"])
        assert {:ok, _} = CommentCheckpoint.background_scan(issue)
      end

      refute_received {:linear, _}
      dialog = %{issue | state: "Todo (Dialog-AI)"}
      state = %Orchestrator.State{max_concurrent_agents: 1}
      assert Orchestrator.should_dispatch_issue_for_test(dialog, state)
      observed_at = System.monotonic_time(:millisecond) - 7_200_000
      observed = Orchestrator.observe_dialog_full_check_for_test(dialog, state, observed_at)
      refute Orchestrator.should_dispatch_issue_for_test(dialog, observed)
      refute_received {:linear, _}
      # Deleting an older comment need not change the latest-comment signal.
      # The captured relay epoch still invalidates the dialog observation.
      Server.publish(server, "synthetic-workspace", %{"type" => "Comment", "commentId" => "older", "action" => "remove"})
      ProjectPoller.refresh()
      assert {:ok, [next]} = ProjectPoller.candidates(context)
      next = %{next | state: "Todo (Dialog-AI)"}
      assert Orchestrator.should_dispatch_issue_for_test(next, observed)
      observed = Orchestrator.observe_dialog_full_check_for_test(dialog, observed, observed_at)
      assert Orchestrator.should_dispatch_issue_for_test(next, observed)
      flush_requests()
      # Every explicit checkpoint still scans Linear even when the relay is idle.
      assert {:ok, _} = CommentCheckpoint.scan(issue)
      assert_received {:linear, _}
      flush_requests()
      for _ <- 1..5, do: Server.publish(server, "synthetic-workspace", %{"type" => "Comment", "commentId" => "comment"})
      ProjectPoller.refresh()
      assert {:ok, [_]} = ProjectPoller.candidates(context)
      assert_received {:linear, query}
      assert query =~ "SymphonyWorkspacePoll"
      refute_received {:linear, _}
      assert {:ok, _} = CommentCheckpoint.background_scan(issue)
      assert_received {:linear, _}
      flush_requests()

      for {body, timestamp} <- [{"created", "2026-09-14T00:00:00Z"}, {"edited", "2026-09-14T00:01:00Z"}] do
        comment = %{"id" => "comment", "body" => body, "issue" => %{"id" => "issue"}, "user" => %{"id" => "human", "app" => false}, "updatedAt" => timestamp}
        Agent.update(sources, fn _ -> [comment] end)
        Server.publish(server, "synthetic-workspace", %{"type" => "Comment", "commentId" => "comment"})
        ProjectPoller.refresh()
        assert {:ok, [_]} = ProjectPoller.candidates(context)
        assert {:ok, inbox} = CommentCheckpoint.background_scan(issue)
        assert Enum.any?(inbox["versions"], fn {_, v} -> v["source"]["body"] == body end)
      end

      Agent.update(sources, fn _ -> [] end)
      Server.publish(server, "synthetic-workspace", %{"type" => "Comment", "commentId" => "comment", "action" => "remove"})
      ProjectPoller.refresh()
      assert {:ok, [_]} = ProjectPoller.candidates(context)
      assert {:ok, inbox} = CommentCheckpoint.background_scan(issue)
      assert Enum.all?(inbox["versions"], fn {_, v} -> v["deleted"] end)

      for updated <- [
            put_in(node["state"]["name"], "Fertig"),
            put_in(node["project"]["slugId"], "other"),
            Map.put(node, "assignee", %{"id" => "other", "email" => "other@example.com", "app" => false}),
            Map.put(node, "assignee", nil)
          ] do
        Agent.update(issue_source, fn _ -> [updated] end)
        Server.publish(server, "synthetic-workspace", %{"assigneeIds" => ["human", "other"]})
        ProjectPoller.refresh()
        assert {:ok, []} = ProjectPoller.candidates(context)
        assert {:ok, [current]} = Relay.background_issues(["issue"])
        assert current.state == updated["state"]["name"]
      end

      Agent.update(issue_source, fn _ -> [] end)
      Server.publish(server, "synthetic-workspace", %{"action" => "remove"})
      ProjectPoller.refresh()
      assert {:ok, []} = ProjectPoller.candidates(context)
      assert {:ok, []} = Relay.background_issues(["issue"])
      flush_requests()
      Server.fault(server, "synthetic-workspace", "one", :poll, {:error, {:relay_http, 503, "unavailable"}})
      ProjectPoller.refresh()
      assert {:error, {:relay_not_ready, :degraded, _}} = ProjectPoller.candidates(context)
      assert {:error, _} = Relay.background_issues(["issue"])
      assert {:error, _} = CommentCheckpoint.background_scan(issue)
      refute_received {:linear, _}
      assert ProjectPoller.polling().relay["synthetic-workspace"].status == :degraded
      snapshot = %{running: [], retrying: [], codex_totals: %{}, rate_limits: nil, polling: ProjectPoller.polling()}

      snapshot_server =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, :snapshot} -> GenServer.reply(from, snapshot)
          end
        end)

      api = SymphonyElixirWeb.Presenter.state_payload(snapshot_server, 1_000)
      assert api.relay["synthetic-workspace"].status == :degraded
      assert api.relay["synthetic-workspace"].error =~ "relay_http, 503"
    end)

    assert {:error, :relay_context_required} = ProjectPoller.relay_issues(nil, [])
    assert {:error, :relay_context_required} = ProjectPoller.comment_epoch(nil, "issue")
    foreign = put_in(context.settings.tracker.app["workspace_id"], "unbound")
    assert {:error, :relay_unavailable} = ProjectPoller.relay_issues(foreign, ["issue"])

    assert ProjectPoller.polling().relay["synthetic-workspace"].execution == %{"human" => "zuständig"}

    stop_supervised!(ProjectPoller)
    assert {:error, :relay_unavailable} = ProjectPoller.relay_issues(context, ["issue"])

    ProjectContext.with_context(context, fn ->
      flush_requests()
      assert {:error, :relay_unavailable} = SymphonyElixir.Tracker.fetch_candidate_issues()
      refute_received {:linear, _}
    end)
  end

  defp flush_requests do
    receive do
      {:linear, _} -> flush_requests()
    after
      0 -> :ok
    end
  end
end
