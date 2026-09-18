defmodule SymphonyElixir.LinearBudgetTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{CommentCheckpoint, ProjectContext}

  test "five-minute transport budget with idle, active and multi-workspace fixtures" do
    orchestrator = Process.whereis(Orchestrator)
    :sys.suspend(orchestrator)
    on_exit(fn -> :sys.resume(orchestrator) end)
    owner = self()
    {:ok, counts} = Agent.start_link(fn -> %{} end)
    bump = fn key -> Agent.update(counts, &Map.update(&1, key, 1, fn n -> n + 1 end)) end

    Req.default_options(
      plug: fn conn ->
        {:ok, form, conn} = Plug.Conn.read_body(conn)
        if String.starts_with?(URI.decode_query(form)["client_id"], "budget-"), do: bump.(:token)
        Req.Test.json(conn, %{"access_token" => "synthetic-budget", "token_type" => "Bearer", "expires_in" => 2_592_000, "scope" => "read,write"})
      end
    )

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _ ->
      query = payload[:query] || payload["query"]
      app = Config.settings!().tracker.app

      {kind, data} =
        cond do
          query =~ "SymphonyAppIdentity" ->
            {:identity, %{"viewer" => %{"id" => app["user_id"], "app" => true, "organization" => %{"id" => app["workspace_id"]}}}}

          query =~ "SymphonyWorkspacePoll" ->
            {:candidates, %{"issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}

          query =~ "SymphonyCommentScanSignal" ->
            {:signal, %{"issue" => %{"comments" => %{"nodes" => [source()]}}}}

          query =~ "comments(" and not (query =~ "SymphonyLinearIssuesById") ->
            {:pages, %{"issue" => %{"comments" => %{"nodes" => [source()], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}}

          true ->
            {:status, %{"issues" => %{"nodes" => []}}}
        end

      if self() == owner, do: bump.(kind)
      {:ok, %{status: 200, body: %{"data" => data}}}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)

    for {label, workspaces, active, expected} <- [
          {:idle, ["one"], 0, 60},
          {:active, ["one"], 1, 132},
          {:three_projects, ["one", "one", "one"], 3, 276},
          {:two_workspaces, ["one", "one", "two"], 3, 336}
        ] do
      if pid = Process.whereis(SymphonyElixir.Linear.AppAuth), do: GenServer.stop(pid)
      contexts = contexts(workspaces, label)
      tick(contexts, active, 0)
      cold = Agent.get_and_update(counts, &{&1, %{}})
      for seconds <- 5..25//5, do: tick(contexts, active, seconds)
      assert Map.get(Agent.get(counts, & &1), :signal, 0) == 0
      tick(contexts, active, 30)
      assert Map.get(Agent.get(counts, & &1), :signal, 0) == active
      for seconds <- 35..295//5, do: tick(contexts, active, seconds)
      assert Map.get(Agent.get(counts, & &1), :pages, 0) == 0
      tick(contexts, active, 300)
      warm = Agent.get_and_update(counts, &{&1, %{}})
      IO.puts("budget #{label} cold=#{inspect(cold)} warm=#{inspect(warm)} total=#{Enum.sum(Map.values(warm))}")
      assert Enum.sum(Map.values(warm)) == expected
      assert Map.get(warm, :identity, 0) == 0
      assert Map.get(warm, :token, 0) == 0
      assert Map.get(warm, :pages, 0) == active
      assert Map.get(warm, :signal, 0) == active * 11
    end
  end

  defp contexts(workspaces, label) do
    for {workspace, index} <- Enum.with_index(workspaces) do
      root = Path.join(Path.dirname(Workflow.workflow_file_path()), "#{label}-#{index}")
      File.mkdir_p!(Path.join(root, ".symphony"))
      File.write!(Path.join(root, ".symphony/.env"), "LINEAR_ASSIGNEE=00000000-0000-4000-8000-000000000001\n")
      {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
      context = put_in(context.settings.tracker.app["workspace_id"], workspace)
      context = put_in(context.settings.tracker.app["client_id"], "budget-#{System.pid()}-#{label}")
      context = put_in(context.settings.polling.interval_ms, 5_000)
      context = put_in(context.settings.tracker.project_slug, "project-#{index}")
      put_in(context.settings.tracker.assignee, "00000000-0000-4000-8000-000000000001")
    end
  end

  defp tick(contexts, active, seconds) do
    assert {:ok, _} = Client.fetch_project_candidates(contexts)

    for context <- Enum.take(contexts, active) do
      ProjectContext.with_context(context, fn ->
        assert {:ok, _} = Client.fetch_issue_states_by_ids(["issue"])
        issue = %Issue{id: "issue", identifier: "PRO-1", state: "In Arbeit (AI)"}
        assert {:ok, _} = CommentCheckpoint.background_scan(issue, background_now: fn -> seconds * 1_000 end)
      end)
    end
  end

  defp source do
    %{"id" => "comment", "body" => "unchanged", "issue" => %{"id" => "issue"}, "user" => %{"id" => "human", "app" => false}, "updatedAt" => "2026-09-14T00:00:00Z"}
  end
end
