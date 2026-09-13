defmodule SymphonyElixir.ProjectRateLimitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.{DynamicTool, MCPServer}
  alias SymphonyElixir.Linear.{DurableState, RateLimit}
  alias SymphonyElixir.{ProjectContext, ProjectPoller, WorkerCapacity}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "$LINEAR_PROJECT_SLUG")
    root = Path.dirname(Workflow.workflow_file_path())
    client = "cross-project-#{System.unique_integer([:positive])}"

    contexts =
      for {name, workspace} <- [{"A", "shared"}, {"B", "shared"}, {"C", "independent"}] do
        project = Path.join(root, name)
        File.mkdir_p!(Path.join(project, ".symphony"))

        File.write!(Path.join(project, ".symphony/.env"), """
        LINEAR_PROJECT_SLUG=#{name}
        LINEAR_ASSIGNEE=dev@example.com
        """)

        {:ok, context} = ProjectContext.load(project, Workflow.workflow_file_path(), %{})
        context = put_in(context.settings.tracker.app["workspace_id"], workspace)
        context = put_in(context.settings.tracker.app["client_id"], client)
        put_in(context.settings.polling.interval_ms, 60_000)
      end

    parent = self()

    Req.default_options(
      plug: fn conn ->
        send(parent, :token_request)
        Req.Test.json(conn, %{"access_token" => "synthetic-token", "token_type" => "Bearer", "expires_in" => 3600, "scope" => "read,write"})
      end
    )

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _headers ->
      query = payload[:query] || payload["query"]
      binding = Config.settings!().tracker.app
      send(parent, {:http, binding["workspace_id"], query})

      data =
        cond do
          String.contains?(query, "SymphonyAppIdentity") ->
            %{"viewer" => %{"id" => binding["user_id"], "app" => true, "organization" => %{"id" => binding["workspace_id"]}}}

          String.contains?(query, "SymphonyHumanAssignees") ->
            %{"users" => %{"nodes" => [%{"id" => "human", "email" => "dev@example.com", "app" => false}], "pageInfo" => %{"hasNextPage" => false}}}

          true ->
            send(parent, {:candidates, binding["workspace_id"]})
            %{"issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}}
        end

      {:ok, %{status: 200, body: %{"data" => data}}}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)
    {:ok, contexts: contexts}
  end

  test "regular project roots share a cooldown across both tool entrypoints", %{contexts: [a, b, c]} do
    assert a.settings.tracker.app["state_root"] == Path.join(a.root, ".symphony/state")
    assert b.settings.tracker.app["state_root"] == Path.join(b.root, ".symphony/state")
    refute a.settings.tracker.app["state_root"] == b.settings.tracker.app["state_root"]
    limit(a, "3600")

    ProjectContext.with_context(b, fn ->
      args = %{"query" => "query { viewer { id } }"}
      result = DynamicTool.execute("linear_graphql", args)
      refute result["success"]
      assert Jason.decode!(result["output"])["error"]["classification"] == "rate_limited"

      response = MCPServer.handle_request(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => %{"name" => "linear_graphql", "arguments" => args}})
      assert response["result"]["isError"]
      [content] = response["result"]["content"]
      assert Jason.decode!(content["text"])["error"]["classification"] == "rate_limited"
    end)

    refute_received :token_request
    refute_received {:http, _, _}
    assert :ok = RateLimit.check(c.settings.tracker.app)
    assert :ok = RateLimit.check(Map.put(b.settings.tracker.app, "client_id", "different-client"))
  end

  for order <- [:limited_first, :limited_last] do
    test "polling isolates results and deadlines with #{order}", %{contexts: [a, b, c]} do
      contexts = if unquote(order) == :limited_first, do: [a, b, c], else: [c, a, b]
      start_supervised!({Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry})
      start_supervised!({WorkerCapacity, contexts: contexts})
      start_supervised!({ProjectPoller, contexts: contexts})
      assert {:ok, []} = ProjectPoller.candidates(a)
      assert_received {:candidates, "shared"}
      assert_received {:candidates, "independent"}
      drain_http()

      limit(b, "3600")
      ProjectPoller.refresh()
      assert {:error, _} = ProjectPoller.candidates(a)
      assert {:error, _} = ProjectPoller.candidates(b)
      assert {:ok, []} = ProjectPoller.candidates(c)
      assert_received {:candidates, "independent"}
      refute_received {:http, "shared", _}
      refute_received {:candidates, "shared"}
      assert ProjectPoller.polling().next_poll_in_ms <= 60_000

      # Even explicit refreshes cannot issue HTTP for a blocked app.
      ProjectPoller.refresh()
      assert {:ok, []} = ProjectPoller.candidates(c)
      assert_received {:candidates, "independent"}
      refute_received {:http, "shared", _}

      limit(c, "7200")
      drain_http()
      ProjectPoller.refresh()
      assert {:error, _} = ProjectPoller.candidates(c)
      assert ProjectPoller.polling().next_poll_in_ms > 3_590_000
      assert ProjectPoller.polling().next_poll_in_ms <= 3_600_000
      refute_received {:http, _, _}

      # Advance only this fixture's persisted deadline, without a real wait.
      expire(a)
      ProjectPoller.refresh()
      assert {:ok, []} = ProjectPoller.candidates(a)
      assert {:ok, []} = ProjectPoller.candidates(b)
      assert {:error, _} = ProjectPoller.candidates(c)
      assert_received {:candidates, "shared"}
      refute_received {:http, "independent", _}
      assert ProjectPoller.polling().next_poll_in_ms <= 60_000
    end
  end

  test "startup defers a pre-limited workspace and still polls an independent workspace", %{
    contexts: [a, b, c]
  } do
    limit(a, "3600")
    start_supervised!({Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry})
    start_supervised!({WorkerCapacity, contexts: [a, b, c]})
    start_supervised!({ProjectPoller, contexts: [a, b, c]})

    assert {:error, {:linear_api_request, {:linear_app_rate_limited, _}}} =
             ProjectPoller.candidates(a)

    assert {:error, {:linear_api_request, {:linear_app_rate_limited, _}}} =
             ProjectPoller.candidates(b)

    assert {:ok, []} = ProjectPoller.candidates(c)
    assert_received {:candidates, "independent"}
    refute_received {:http, "shared", _}
    refute_received {:candidates, "shared"}
    assert ProjectPoller.polling().next_poll_in_ms <= 60_000

    expire(a)
    ProjectPoller.refresh()
    assert {:ok, []} = ProjectPoller.candidates(a)
    assert {:ok, []} = ProjectPoller.candidates(b)
    assert_received {:candidates, "shared"}
  end

  test "startup also defers a provider rate limit without a server deadline", %{
    contexts: [a | _rest]
  } do
    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn _payload, _headers ->
      {:ok,
       %{
         status: 200,
         body: %{
           "errors" => [%{"extensions" => %{"code" => "RATELIMITED"}}]
         }
       }}
    end)

    assert {:ok, %{verified_workspaces: verified}, {:continue, :poll}} =
             ProjectPoller.init(contexts: [a])

    assert verified == MapSet.new()
    :ets.delete(ProjectPoller)
  end

  test "startup isolates a temporary verification failure from an independent workspace", %{
    contexts: [a, _b, c]
  } do
    parent = self()

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _headers ->
      query = payload[:query] || payload["query"]
      workspace = Config.settings!().tracker.app["workspace_id"]

      cond do
        String.contains?(query, "SymphonyAppIdentity") ->
          app = Config.settings!().tracker.app
          data = %{"viewer" => %{"id" => app["user_id"], "app" => true, "organization" => %{"id" => workspace}}}
          {:ok, %{status: 200, body: %{"data" => data}}}

        String.contains?(query, "SymphonyHumanAssignees") and workspace == "shared" ->
          {:ok, %{status: 503, body: "temporarily unavailable"}}

        String.contains?(query, "SymphonyHumanAssignees") ->
          users = %{"nodes" => [%{"id" => "human", "email" => "dev@example.com", "app" => false}], "pageInfo" => %{"hasNextPage" => false}}
          {:ok, %{status: 200, body: %{"data" => %{"users" => users}}}}

        true ->
          send(parent, {:isolated_candidate_poll, workspace})
          issues = %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}
          {:ok, %{status: 200, body: %{"data" => %{"issues" => issues}}}}
      end
    end)

    start_supervised!({Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry})
    start_supervised!({WorkerCapacity, contexts: [a, c]})
    start_supervised!({ProjectPoller, contexts: [a, c]})

    assert {:error, {:linear_api_status, 503, %{classification: "http"}}} =
             ProjectPoller.candidates(a)

    assert {:ok, []} = ProjectPoller.candidates(c)
    assert_received {:isolated_candidate_poll, "independent"}
    refute_received {:isolated_candidate_poll, "shared"}
  end

  test "startup also isolates temporary identity unavailability by workspace", %{
    contexts: [a, _b, c]
  } do
    parent = self()

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _headers ->
      query = payload[:query] || payload["query"]
      app = Config.settings!().tracker.app
      workspace = app["workspace_id"]

      cond do
        String.contains?(query, "SymphonyAppIdentity") and workspace == "shared" ->
          {:ok, %{status: 503, body: "temporarily unavailable"}}

        String.contains?(query, "SymphonyAppIdentity") ->
          viewer = %{"id" => app["user_id"], "app" => true, "organization" => %{"id" => workspace}}
          {:ok, %{status: 200, body: %{"data" => %{"viewer" => viewer}}}}

        String.contains?(query, "SymphonyHumanAssignees") ->
          users = %{"nodes" => [%{"id" => "human", "email" => "dev@example.com", "app" => false}], "pageInfo" => %{"hasNextPage" => false}}
          {:ok, %{status: 200, body: %{"data" => %{"users" => users}}}}

        true ->
          send(parent, {:identity_isolated_candidate_poll, workspace})
          issues = %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}
          {:ok, %{status: 200, body: %{"data" => %{"issues" => issues}}}}
      end
    end)

    start_supervised!({Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry})
    start_supervised!({WorkerCapacity, contexts: [a, c]})
    start_supervised!({ProjectPoller, contexts: [a, c]})

    assert {:error, {:linear_api_request, :linear_app_identity_unavailable}} =
             ProjectPoller.candidates(a)

    assert {:ok, []} = ProjectPoller.candidates(c)
    assert_received {:identity_isolated_candidate_poll, "independent"}
    refute_received {:identity_isolated_candidate_poll, "shared"}
  end

  test "a fresh BEAM transport runtime observes another project's persisted cooldown", %{contexts: [a, b, _c]} do
    limit(a, "3600")

    script = """
    [root, encoded] = System.argv()
    Application.put_env(:symphony_elixir, :linear_rate_limit_root, root)
    Application.ensure_all_started(:req)
    Logger.configure(level: :emergency)
    Req.default_options(plug: fn _ -> raise "unexpected token HTTP" end)
    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn _, _ -> raise "unexpected GraphQL HTTP" end)
    context = encoded |> Base.decode64!() |> :erlang.binary_to_term()
    SymphonyElixir.ProjectContext.with_context(context, fn ->
      args = %{"query" => "query { viewer { id } }"}
      dynamic = SymphonyElixir.Codex.DynamicTool.execute("linear_graphql", args)
      mcp = SymphonyElixir.Codex.MCPServer.handle_request(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => %{"name" => "linear_graphql", "arguments" => args}})
      IO.puts(Jason.encode!(%{dynamic: dynamic, mcp: mcp}))
    end)
    """

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        [
          "--erl",
          "+S 2:2",
          "-pa",
          Path.expand("_build/test/lib/*/ebin"),
          "-e",
          script,
          Config.linear_rate_limit_root(),
          Base.encode64(:erlang.term_to_binary(b))
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    result = Jason.decode!(output)
    assert Jason.decode!(result["dynamic"]["output"])["error"]["classification"] == "rate_limited"
    [content] = result["mcp"]["result"]["content"]
    assert Jason.decode!(content["text"])["error"]["classification"] == "rate_limited"
  end

  defp limit(context, seconds) do
    assert {:ok, _} = RateLimit.request(context.settings.tracker.app, fn -> {:ok, %{status: 429, headers: %{"retry-after" => seconds}}} end)
  end

  defp expire(context) do
    binding = context.settings.tracker.app
    key = :crypto.hash(:sha256, Jason.encode!([binding["workspace_id"], binding["client_id"]])) |> Base.encode16(case: :lower)
    path = Path.join(Config.linear_rate_limit_root(), key <> ".json")
    {:ok, record} = DurableState.read(path)
    assert :ok = DurableState.write(path, Map.put(record, "retry_at_ms", System.system_time(:millisecond) - 1))
  end

  defp drain_http do
    receive do
      {:http, _, _} -> drain_http()
      :token_request -> drain_http()
    after
      0 -> :ok
    end
  end
end
