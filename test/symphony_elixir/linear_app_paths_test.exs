defmodule SymphonyElixir.LinearAppPathsTest do
  use SymphonyElixir.TestSupport

  alias Absinthe.Phase.Parse
  alias SymphonyElixir.Codex.{DynamicTool, LinearGraphqlTool, MCPServer}
  alias SymphonyElixir.EnvFile
  alias SymphonyElixir.Linear.{Adapter, IssueLease, WriteContext}

  setup do
    old_workflow = Workflow.workflow_file_path()
    project = Path.join(System.tmp_dir!(), "app-paths-#{System.unique_integer([:positive])}")
    root = Path.join(project, ".symphony/state")
    File.mkdir_p!(root)
    System.put_env("SYMPHONY_LINEAR_ENV_DIR", Path.dirname(root))

    binding = %{
      "client_secret_env" => "SYMPHONY_TEST_PATHS_SECRET",
      "workspace_id" => "workspace",
      "user_id" => "app",
      "client_id" => "client",
      "state_root" => root,
      "installation_id" => "install"
    }

    workflow = Path.join(root, "WORKFLOW.md")

    config = %{
      "tracker" => %{"kind" => "linear", "auth_mode" => "app", "api_key" => "synthetic-personal", "app" => binding, "project_slug" => "pilot", "assignee" => "07fed51a-0ba0-4314-9179-a62cfb3af28d"}
    }

    File.write!(workflow, "---\n" <> Jason.encode!(config) <> "\n---\nSynthetic instruction\n")
    # A separate store models a fresh installation; a live store refuses identity changes.
    Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    Workflow.set_workflow_file_path(workflow)
    Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
    System.put_env("SYMPHONY_TEST_PATHS_SECRET", "synthetic-secret")
    old_req_options = Req.default_options()

    Req.default_options(
      plug: fn conn ->
        Req.Test.json(conn, %{"access_token" => "synthetic-app", "token_type" => "Bearer", "expires_in" => 2_591_999, "scope" => "read write"})
      end
    )

    Application.put_env(:symphony_elixir, :linear_client_request_fun, &request/2)

    on_exit(fn ->
      System.delete_env("SYMPHONY_TEST_PATHS_SECRET")
      Req.default_options(old_req_options)
      Application.delete_env(:symphony_elixir, :linear_client_request_fun)
      Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
      Workflow.set_workflow_file_path(old_workflow)
      Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
      File.rm_rf!(project)
    end)

    {:ok, root: root, binding: binding, config: config, workflow: workflow}
  end

  test "Tracker, dynamic tool, MCP and local fallback share app identity and runtime-owned receipts", %{root: root} do
    context = %{"run_id" => "run", "phase" => "Review (AI)", "session_id" => "session"}

    WriteContext.with_context(context, fn ->
      assert :ok = Tracker.create_comment("issue", "tracker reply")
      assert :ok = Adapter.update_comment("existing", "edited reply")
      assert %{"success" => true} = DynamicTool.execute("linear_graphql", %{"query" => create_query("dynamic reply")})
      assert %{"isError" => false} = LinearGraphqlTool.mcp_call(%{"query" => create_query("mcp reply")})

      assert %{"result" => %{"isError" => false}} =
               MCPServer.handle_request(%{
                 "jsonrpc" => "2.0",
                 "id" => 2,
                 "method" => "tools/call",
                 "params" => %{"name" => "linear_graphql", "arguments" => %{"query" => create_query("server reply")}}
               })

      assert :ok = Tracker.create_comment("issue", SymphonyElixir.Dialog.format_answer_comment("Dialog answer", "thread", true))
      assert {:ok, _} = Client.graphql(~s|mutation { issueUpdate(id: "issue", input: {title: "allowed"}) { success } }|)
      assert :ok = Tracker.update_issue_state("issue", "Planung")
    end)

    records = Path.wildcard(Path.join([root, "comments", "*.intent.json"])) |> Enum.map(&(File.read!(&1) |> Jason.decode!()))
    assert length(records) == 6
    assert Enum.all?(records, &(&1["context"] == context))
    assert Enum.all?(records, &(&1["workspace_id"] == "workspace" and &1["author_id"] == "app"))
    assert Enum.any?(records, &(&1["output_type"] == "dialog"))
    refute inspect(records) =~ "synthetic-secret"
  end

  test "all tool entrypoints visibly stop on missing client secret despite a personal API key" do
    System.delete_env("SYMPHONY_TEST_PATHS_SECRET")
    assert {:error, _} = Tracker.create_comment("issue", "blocked")
    assert %{"success" => false} = DynamicTool.execute("linear_graphql", %{"query" => create_query("blocked")})
    assert %{"isError" => true} = LinearGraphqlTool.mcp_call(%{"query" => create_query("blocked")})
    refute_received :http_write
  end

  test "app rate limits retain their classification through dynamic and MCP tool responses" do
    for status <- [400, 403, 429] do
      Application.put_env(:symphony_elixir, :linear_client_request_fun, fn _, _ ->
        {:ok, %{status: status, body: %{"errors" => [%{"extensions" => %{"code" => "RATELIMITED"}}]}}}
      end)

      assert %{"success" => false, "output" => output} = DynamicTool.execute("linear_graphql", "{ viewer { id } }")
      assert %{"error" => %{"classification" => "rate_limited"}} = Jason.decode!(output)
      assert %{"isError" => true, "content" => [%{"text" => output}]} = LinearGraphqlTool.mcp_call("{ viewer { id } }")
      assert %{"error" => %{"classification" => "rate_limited"}} = Jason.decode!(output)
      refute_received :http_write
    end
  end

  test "fallback EnvFile loading cannot change pinned auth while personal keys remain ignored", %{root: root} do
    env = Config.linear_runtime_env()
    System.put_env(env)
    File.write!(Path.join(root, ".env.local"), "LINEAR_API_KEY=synthetic-personal\n")
    assert :ok = EnvFile.load(root, override_existing: true)
    refute Map.has_key?(Config.settings!().tracker, :api_key)
    assert :ok = Tracker.create_comment("issue", "fallback reply")
    File.write!(Path.join(root, ".env.local"), "SYMPHONY_LINEAR_AUTH_MODE=legacy\n")
    assert {:error, :linear_runtime_binding_changed} = EnvFile.load(root, override_existing: true)
    assert System.get_env("SYMPHONY_LINEAR_AUTH_MODE") == "app"
    System.delete_env("SYMPHONY_LINEAR_BINDING_HASH")
    assert {:error, :linear_runtime_binding_missing} = Config.settings()
    System.delete_env("LINEAR_API_KEY")
  end

  test "app worker requires one app-owned active workpad before entering its callback", %{root: root} do
    directory = Path.join(root, "priv/linear_app")
    File.mkdir_p!(directory)
    File.write!(Path.join(root, ".symphony-release.json"), "{}")
    File.write!(Path.join(directory, "issue_lease.py"), "import sys\nprint('locked', flush=True)\nsys.stdin.read()\n")
    System.put_env("SYMPHONY_RELEASE_ROOT", root)
    Process.put(:workpad_comments, [])
    assert :bootstrap = IssueLease.run(%Issue{id: "issue"}, fn -> :bootstrap end)
    refute_received :http_write
    Process.put(:workpad_comments, [%{"id" => "old", "body" => "## Symphony Workpad (historisch, inaktiv)", "user" => %{"id" => "human"}}])
    assert {:error, :workpad_comment_not_found} = IssueLease.run(%Issue{id: "issue"}, fn -> flunk("incomplete transfer") end)
    Process.put(:workpad_comments, [%{"id" => "active", "body" => "## Symphony Workpad\n\nExisting work", "user" => %{"id" => "app"}, "issue" => %{"id" => "issue"}}])
    assert :entered = IssueLease.run(%Issue{id: "issue"}, fn -> :entered end)
  end

  test "human scope remains explicit and unexpected candidates including dialog stop activation", %{binding: binding} do
    tracker = %{auth_mode: "app", app: Map.put(binding, "allowed_issue_ids", ["only"])}
    assert :ok = Client.validate_candidate_scope(tracker, [%Issue{id: "only"}])

    assert {:error, :linear_app_candidate_scope_changed} =
             Client.validate_candidate_scope(tracker, [%Issue{id: "extra", state: "Todo (Dialog-AI)"}])

    assert :ok = Client.validate_candidate_scope(%{auth_mode: "app", app: %{}}, [%Issue{id: "extra"}])
  end

  test "app polling retains existing email and UUID filters and human routing", %{workflow: workflow, config: config} do
    for assignee <- ["Human@Example.invalid", "00000000-0000-4000-8000-000000000001"] do
      changed = put_in(config, ["tracker", "assignee"], assignee)
      File.write!(workflow, "---\n" <> Jason.encode!(changed) <> "\n---\nSynthetic\n")
      Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
      Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
      owner = self()

      Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, headers ->
        query = payload[:query] || payload["query"]

        if query =~ "SymphonyAppIdentity" do
          request(payload, headers)
        else
          send(owner, {:candidate_query, query})

          nodes = [
            %{"id" => "human-issue", "identifier" => "SYN-1", "state" => %{"name" => "Todo (AI)"}, "assignee" => %{"id" => "00000000-0000-4000-8000-000000000001", "email" => "human@example.invalid"}}
          ]

          {:ok, %{status: 200, body: %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}}}
        end
      end)

      assert {:ok, [%Issue{assigned_to_worker: true, assignee_id: "00000000-0000-4000-8000-000000000001"}]} = Client.fetch_candidate_issues()
      assert_received {:candidate_query, query}

      if String.contains?(assignee, "@"),
        do: assert(query =~ ~s|assignee: {email: {eqIgnoreCase: "human@example.invalid"}}|),
        else: assert(query =~ ~s|assignee: {id: {eq: "#{assignee}"}}|)

      assert query =~ "project: {slugId: {eq: $projectSlug}}"
    end
  end

  test "app mode supports configured SSH workers with host-provided credentials", %{workflow: workflow, config: config} do
    assert :ok = Config.validate_startup_requirements()
    config = Map.put(config, "worker", %{"ssh_hosts" => ["remote-host"]})
    File.write!(workflow, "---\n" <> Jason.encode!(config) <> "\n---\nSynthetic instruction\n")
    assert :ok = WorkflowStore.force_reload()
    assert :ok = Config.validate_startup_requirements()
  end

  test "workspace hooks and non-auth helpers strip the sentinel while the trusted runtime keeps it", %{root: root} do
    name = "SYMPHONY_TEST_PATHS_SECRET"
    assert System.get_env(name) == "synthetic-secret"
    script = "test -z \"${SYMPHONY_TEST_PATHS_SECRET+x}\""
    assert :ok = SymphonyElixir.HookRunner.run_local(script, root, "secret-boundary", env: %{name => "synthetic-secret"})
    assert {"", 0} = System.cmd("sh", ["-c", script], env: SymphonyElixir.RuntimePaths.cleaned_builtin_system_env())
    assert System.get_env(name) == "synthetic-secret"
    refute inspect(Config.linear_runtime_env()) =~ "synthetic-secret"
    refute inspect(Config.settings!()) =~ "synthetic-secret"
  end

  test "SSH command and port children exclude the referenced secret", %{root: root} do
    previous_path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", previous_path) end)
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    executable = Path.join(bin, "ssh")

    File.write!(executable, """
    #!/bin/sh
    test -z "${SYMPHONY_TEST_PATHS_SECRET+x}" || exit 1
    printf 'absent'
    """)

    File.chmod!(executable, 0o755)
    System.put_env("PATH", bin <> ":" <> previous_path)

    assert {:ok, {"absent", 0}} =
             SymphonyElixir.SSH.run("synthetic-host", "true", env: [{"SYMPHONY_TEST_PATHS_SECRET", "synthetic-secret"}])

    assert {:ok, port} = SymphonyElixir.SSH.start_port("synthetic-host", "true")
    assert_receive {^port, {:data, "absent"}}, 1_000
    assert_receive {^port, {:exit_status, 0}}, 1_000
    assert System.get_env("SYMPHONY_TEST_PATHS_SECRET") == "synthetic-secret"
  end

  test "workflow reload accepts prose but rejects an identity or scope switch", %{workflow: workflow, config: config} do
    File.write!(workflow, "---\n" <> Jason.encode!(config) <> "\n---\nUpdated prose\n")
    assert :ok = WorkflowStore.force_reload()
    changed = put_in(config, ["tracker", "auth_mode"], "legacy")
    File.write!(workflow, "---\n" <> Jason.encode!(changed) <> "\n---\nUpdated prose\n")
    assert {:error, :auth_binding_change_requires_restart} = WorkflowStore.force_reload()
    assert Config.settings!().tracker.auth_mode == "app"
  end

  test "workflow instructions resolve global skills only inside their bound release", context do
    System.put_env("SYMPHONY_RELEASE_ROOT", context.root)
    prompt = "globals={{ runtime.global_skill_roots_text }}"
    File.write!(context.workflow, "---\n" <> Jason.encode!(context.config) <> "\n---\n" <> prompt)
    assert :ok = WorkflowStore.force_reload()
    issue = %Issue{id: "issue", identifier: "PRO-676", state: "In Arbeit (AI)"}
    assert PromptBuilder.build_prompt(issue) == "globals=#{context.root}/.symphony/codex/skills"
  end

  defp create_query(body), do: "mutation { commentCreate(input: {issueId: \"issue\", body: #{Jason.encode!(body)}}) { success } }"

  defp request(payload, headers) do
    assert {"Authorization", "Bearer synthetic-app"} in headers
    query = payload[:query] || payload["query"]

    cond do
      query =~ "SymphonyCommentAction" ->
        states = %{"nodes" => [%{"id" => "state", "name" => "Planung"}], "pageInfo" => %{"hasNextPage" => false}}
        issue = %{"id" => "issue", "team" => %{"states" => states}}
        {:ok, %{status: 200, body: %{"data" => %{"issue" => issue}}}}

      query =~ "SymphonyLinearIssuesById" ->
        {:ok, %{status: 200, body: %{"data" => %{"issues" => %{"nodes" => [%{"id" => "issue", "state" => %{"name" => "Review (AI)"}}]}}}}}

      query =~ "SymphonyLinearIssueComments" ->
        {:ok, %{status: 200, body: %{"data" => %{"issue" => %{"comments" => %{"nodes" => Process.get(:workpad_comments), "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}}}}

      query =~ "SymphonyReceipt" ->
        {:ok,
         %{status: 200, body: %{"data" => %{"comment" => %{"id" => "existing", "body" => "before", "updatedAt" => "2026-09-10T00:00:00Z", "user" => %{"id" => "app"}, "issue" => %{"id" => "issue"}}}}}}

      query =~ "SymphonyAppIdentity" ->
        {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "app", "app" => true, "organization" => %{"id" => "workspace"}}}}}}

      true ->
        respond(payload)
    end
  end

  defp input_value(%Absinthe.Language.Variable{name: name}, variables), do: variables[name]
  defp input_value(%Absinthe.Language.ObjectValue{fields: fields}, variables), do: Map.new(fields, &{&1.name, input_value(&1.value, variables)})
  defp input_value(%{value: value}, _variables), do: value

  defp respond(payload) do
    send(self(), :http_write)
    {:ok, %{input: %{definitions: [operation]}}} = Parse.run(payload["query"])
    variables = payload["variables"] |> Jason.encode!() |> Jason.decode!()

    data =
      operation.selection_set.selections
      |> Enum.filter(&(&1.name in ["commentCreate", "commentUpdate"]))
      |> Map.new(fn field ->
        args = Map.new(field.arguments, &{&1.name, input_value(&1.value, variables)})
        comment = %{"id" => args["input"]["id"] || args["id"], "body" => args["input"]["body"], "updatedAt" => "2026-09-10T00:00:00Z", "user" => %{"id" => "app"}, "issue" => %{"id" => "issue"}}
        {field.alias || field.name, %{"success" => true, "symphonyReceipt" => comment, "comment" => comment}}
      end)

    data = if payload["query"] =~ "SymphonyResolveStateId", do: %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state"}]}}}}, else: data
    data = if payload["query"] =~ "issueUpdate", do: Map.put(data, "issueUpdate", %{"success" => true}), else: data
    {:ok, %{status: 200, body: %{"data" => data}}}
  end
end
