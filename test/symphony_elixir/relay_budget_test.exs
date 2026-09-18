defmodule SymphonyElixir.RelayBudgetTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{CommentCheckpoint, ProjectContext, ProjectPoller, Relay, WorkerCapacity}
  alias SymphonyElixir.RelayFixture, as: Server

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

      assert Agent.get_and_update(counts, &{&1, %{}}) == if(active == 0, do: %{}, else: %{comments: active * 3})

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
      "state" => %{"name" => "In Arbeit (AI)"},
      "project" => %{"slugId" => context.settings.tracker.project_slug},
      "assignee" => %{"id" => "human", "email" => "human@example.com", "app" => false}
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

  defp configure_http(server, contexts, nodes, bump) do
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

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _ ->
      query = payload[:query] || payload["query"]
      app = Config.settings!().tracker.app
      projects = contexts |> Enum.filter(&(&1.settings.tracker.app["workspace_id"] == app["workspace_id"])) |> Enum.map(& &1.settings.tracker.project_slug)

      {kind, data} =
        cond do
          query =~ "SymphonyAppIdentity" ->
            {:identity, %{"viewer" => %{"id" => app["user_id"], "app" => true, "organization" => %{"id" => app["workspace_id"]}}}}

          query =~ "SymphonyHumanAssignees" ->
            {:assignees, %{"users" => %{"nodes" => [%{"id" => "human", "email" => "human@example.com", "app" => false}], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}

          query =~ "comments(" and not (query =~ "SymphonyWorkspacePoll") ->
            {:comments, %{"issue" => %{"comments" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}}

          true ->
            {:read, %{"issues" => %{"nodes" => Enum.filter(nodes, &(&1["project"]["slugId"] in projects)), "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}
        end

      bump.(kind)
      {:ok, %{status: 200, body: %{"data" => data}}}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)
  end
end
