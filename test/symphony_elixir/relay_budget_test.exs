defmodule SymphonyElixir.RelayBudgetTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{CommentCheckpoint, ProjectContext, ProjectPoller, Relay, WorkerCapacity}
  alias SymphonyElixir.RelayFixture, as: Server

  for {label, workspaces, active} <- [
        {:idle, ["one"], 0},
        {:active, ["one"], 1},
        {:three_projects, ["one", "one", "one"], 3},
        {:two_workspaces, ["one", "one", "two"], 3}
      ] do
    @tag timeout: 180_000
    test "hourly relay budget: #{label}" do
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

      for seconds <- 5..3600//5 do
        Agent.update(clock, fn _ -> seconds * 1_000 end)
        ProjectPoller.refresh()
        background(contexts, active)
      end

      warm = Agent.get_and_update(counts, &{&1, %{}})
      assert warm == %{}
      IO.puts("relay budget #{unquote(label)} cold=#{inspect(cold)} warm=#{inspect(warm)} total=0")

      # Safety snapshots are counted separately from idle traffic.
      Agent.update(clock, fn _ -> 4_500_001 end)
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
        "reconcile_ms" => 3_600_000,
        "owners" => %{"human" => "one"}
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
