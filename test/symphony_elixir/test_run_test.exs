defmodule SymphonyElixir.TestRunTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.DurableState
  alias SymphonyElixir.{ProjectContext, TestRun}
  alias SymphonyElixir.RelayFixture, as: RelayServer

  @human "11111111-1111-4111-8111-111111111111"

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    Application.put_env(:symphony_elixir, :test_instance_state_root, Path.join(root, "test-state"))

    source = %{
      "checkout" => root,
      "sha" => String.duplicate("a", 40),
      "source_sha256" => String.duplicate("b", 64),
      "dirty" => false
    }

    projects =
      Map.new(
        ["symphony-test", "symphony-test-tilor"],
        &{&1, %{"project_id" => &1, "workspace_id" => "synthetic-workspace", "slug_id" => &1}}
      )

    instance = %{
      "name" => "dev",
      "source" => source,
      "manifest" => %{
        "workspace_root" => Path.join(root, "worktrees"),
        "project_root" => Path.join(root, "fixtures"),
        "projects" => projects
      }
    }

    Application.put_env(:symphony_elixir, :test_instance, instance)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "$SYMPHONY_PROJECT_WORKTREES_ROOT",
      tracker_assignee: @human,
      tracker_project_slug: "$LINEAR_PROJECT_SLUG"
    )

    codex = Path.join(root, "fake-codex.py")

    File.write!(codex, ~S"""
    import sys,json
    for line in sys.stdin:
        message=json.loads(line)
        result={'thread': {'id': 'thread-fixture'}} if message.get('method') == 'thread/start' else {}
        if 'id' in message: print(json.dumps({'id':message['id'],'result':result}),flush=True)
    """)

    contexts =
      for {name, _} <- Enum.sort(projects) do
        project = Path.join(root, "fixtures/" <> name)
        File.mkdir_p!(Path.join(project, ".symphony"))

        File.write!(
          Path.join(project, ".symphony/.env"),
          "LINEAR_ASSIGNEE=#{@human}\nLINEAR_PROJECT_SLUG=#{name}\nLINEAR_RELAY_KEY=fixture-relay-key\n"
        )

        File.write!(Path.join(project, ".gitignore"), ".symphony/\n")
        git!(project, ["init", "-q"])
        git!(project, ["add", ".gitignore"])

        git!(project, [
          "-c",
          "user.name=Fixture",
          "-c",
          "user.email=fixture@example.invalid",
          "commit",
          "-qm",
          "fixture"
        ])

        git!(project, ["update-ref", "refs/remotes/origin/main", "HEAD"])
        {:ok, context} = ProjectContext.load(project, Workflow.workflow_file_path(), %{})

        context =
          put_in(context.settings.tracker.relay, %{
            "endpoint" => "https://relay.test",
            "key_env" => "LINEAR_RELAY_KEY",
            "state_root" => Path.join(root, "test-state/relay"),
            "reconcile_ms" => 3_600_000
          })

        context = put_in(context.env["SYMPHONY_CODEX_COMMAND"], "#{System.find_executable("python3")} #{codex}")
        %{context | assignee_ids: [@human]}
      end

    Application.put_env(:symphony_elixir, :project_contexts, contexts)
    plan = %{"run_id" => "fixture-run", "evidence" => "live", "instance" => "dev", "source" => source}
    plan_path = Path.join(root, "plan.json")
    :ok = DurableState.write(plan_path, plan)
    System.put_env("SYMPHONY_TEST_RUN_PLAN", plan_path)
    System.put_env("SYMPHONY_TEST_RUN_STAGE", "prepare")
    server = start_supervised!(RelayServer)
    source_agent = start_supervised!({Agent, fn -> %{issues: %{}, comments: %{}, failure: nil, calls: []} end})

    Req.default_options(
      plug: fn conn ->
        if conn.host == "relay.test",
          do: RelayServer.http(conn, server, %{"fixture-relay-key" => "synthetic-workspace"}),
          else:
            Req.Test.json(conn, %{
              "access_token" => "synthetic-token",
              "token_type" => "Bearer",
              "expires_in" => 3600,
              "scope" => "read,write"
            })
      end
    )

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _ ->
      payload = payload |> Jason.encode!() |> Jason.decode!()
      Agent.get_and_update(source_agent, fn state -> respond(payload["query"], payload["variables"] || %{}, state) end)
    end)

    on_exit(fn ->
      for key <- [
            :test_instance_state_root,
            :test_instance,
            :test_instance_owner,
            :project_contexts,
            :linear_client_request_fun
          ],
          do: Application.delete_env(:symphony_elixir, key)

      System.delete_env("SYMPHONY_TEST_RUN_PLAN")
      System.delete_env("SYMPHONY_TEST_RUN_STAGE")
    end)

    context = %{
      root: root,
      instance: instance,
      contexts: contexts,
      source_agent: source_agent,
      server: server,
      plan: plan,
      plan_path: plan_path
    }

    {:ok, context}
  end

  test "two journaled fixtures bootstrap once, bind only their IDs and clean up idempotently", ctx do
    assert {:ok, prepared} = TestRun.execute("prepare")
    assert length(prepared["fixtures"]) == 2
    assert Enum.all?(prepared["fixtures"], & &1["created"])
    assert {:ok, ^prepared} = TestRun.execute("prepare")
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 2
    System.put_env("SYMPHONY_TEST_RUN_STAGE", "run")
    assert {:ok, bound} = TestRun.bind_contexts(ctx.contexts)

    for context <- bound do
      assert context.settings.tracker.active_states == ["Todo (AI)"]
      assert [id] = context.settings.tracker.app["allowed_issue_ids"]
      assert Enum.any?(prepared["fixtures"], &(&1["id"] == id and &1["project"] == context.name))
      assert context.workflow.config["tracker"]["active_states"] == ["Todo (AI)"]
    end

    assert {:ok, pending} = TestRun.execute("probe")
    refute Enum.any?(pending["fixtures"], & &1["complete"])
    complete(ctx.source_agent)
    assert {:ok, ready} = TestRun.execute("probe")
    assert Enum.all?(ready["fixtures"], & &1["complete"])
    assert {:ok, cleaned} = TestRun.execute("cleanup")
    assert Enum.all?(cleaned["fixtures"], & &1["deleted"])
    assert {:ok, ^cleaned} = TestRun.execute("cleanup")
    assert Agent.get(ctx.source_agent, &map_size(&1.issues)) == 0
    assert {:error, :test_creation_requires_reconciliation} = TestRun.execute("prepare")
    assert {:error, :test_fixtures_not_prepared} = TestRun.bind_contexts(ctx.contexts)
  end

  test "lost creation response retains intent and recovery does not create another ticket", ctx do
    Agent.update(ctx.source_agent, &%{&1 | failure: :lost_create})
    assert {:error, _} = TestRun.execute("prepare")
    assert {:error, :test_creation_requires_reconciliation} = TestRun.execute("prepare")
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 1
    Agent.update(ctx.source_agent, &%{&1 | failure: nil})
    assert {:ok, restored} = TestRun.execute("cleanup")
    assert [%{"deleted" => true}] = restored["fixtures"]
  end

  test "unconfirmed absence, changed fields and modified worktrees remain visible", ctx do
    Agent.update(ctx.source_agent, &%{&1 | failure: :reject_create})
    assert {:error, _} = TestRun.execute("prepare")
    Agent.update(ctx.source_agent, &%{&1 | failure: nil})
    assert {:error, :test_fixture_missing} = TestRun.execute("cleanup")
    File.rm!(journal_path(ctx.root))
    assert {:ok, journal} = TestRun.execute("prepare")
    [fixture | _] = journal["fixtures"]
    Agent.update(ctx.source_agent, &put_in(&1.issues[fixture["id"]]["title"], "An unrelated edit"))
    assert {:error, :test_fixture_changed_externally} = TestRun.execute("cleanup")
    assert Agent.get(ctx.source_agent, & &1.issues[fixture["id"]]["title"]) == "An unrelated edit"
    Agent.update(ctx.source_agent, &put_in(&1.issues[fixture["id"]]["title"], fixture["title"]))
    context = Enum.find(ctx.contexts, &(&1.name == fixture["project"]))
    path = Path.join(context.settings.workspace.root, fixture["identifier"])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "foreign.txt"), "preserve")
    assert {:error, :test_workspace_changed_or_cleanup_failed} = TestRun.execute("cleanup")
    assert File.read!(Path.join(path, "foreign.txt")) == "preserve"
  end

  test "missing plans, changed source or bindings, and corrupt journals never release workers", ctx do
    System.delete_env("SYMPHONY_TEST_RUN_STAGE")
    assert {:ok, contexts} = TestRun.bind_contexts(ctx.contexts)
    assert contexts == ctx.contexts
    System.put_env("SYMPHONY_TEST_RUN_STAGE", "run")
    assert {:error, :test_fixtures_not_prepared} = TestRun.bind_contexts(ctx.contexts)
    File.write!(ctx.plan_path, "broken")
    assert {:error, :invalid_public_test_plan} = TestRun.execute("prepare")
    :ok = DurableState.write(ctx.plan_path, Map.put(ctx.plan, "source", %{}))
    assert {:error, :invalid_test_run} = TestRun.execute("prepare")
    :ok = DurableState.write(ctx.plan_path, ctx.plan)
    :ok = DurableState.write(journal_path(ctx.root), %{"run_id" => "unrelated"})
    assert {:error, :test_journal_identity_mismatch} = TestRun.execute("prepare")
    Application.delete_env(:symphony_elixir, :test_instance)
    assert {:error, :invalid_test_run} = TestRun.execute("cleanup")
  end

  test "schema and transport failures stop before successful creation", ctx do
    for failure <- [:schema, :graphql_errors, :transport] do
      Agent.update(ctx.source_agent, &%{&1 | failure: failure})
      assert {:error, _} = TestRun.execute("prepare")
      assert Agent.get(ctx.source_agent, & &1.issues) == %{}
    end
  end

  test "another unfinished or corrupt journal blocks new work until explicit cleanup", ctx do
    assert {:ok, _} = TestRun.execute("prepare")
    System.delete_env("SYMPHONY_TEST_RUN_PLAN")
    assert {:error, :test_environment_needs_cleanup} = TestRun.bind_contexts(ctx.contexts)
    File.write!(journal_path(ctx.root), "invalid")
    assert {:error, :test_environment_journal_corrupt} = TestRun.bind_contexts(ctx.contexts)
  end

  test "relay and Codex prerequisites fail before fixture creation", ctx do
    [first | rest] = ctx.contexts
    invalid = put_in(first.env["SYMPHONY_CODEX_COMMAND"], "/missing-fixture-codex")
    Application.put_env(:symphony_elixir, :project_contexts, [invalid | rest])
    assert {:error, _} = TestRun.execute("prepare")
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 0
    invalid = put_in(first.settings.tracker.relay["endpoint"], "http://invalid")
    Application.put_env(:symphony_elixir, :project_contexts, [invalid | rest])
    assert {:error, _} = TestRun.execute("prepare")
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 0
  end

  test "clean owned worktrees and already deleted remote issues recover idempotently", ctx do
    assert {:ok, journal} = TestRun.execute("prepare")

    contexts =
      Enum.map(ctx.contexts, fn context ->
        fixture = Enum.find(journal["fixtures"], &(&1["project"] == context.name))
        path = Path.join(context.settings.workspace.root, fixture["identifier"])
        File.mkdir_p!(context.settings.workspace.root)
        git!(context.root, ["worktree", "add", "-b", "symphony/" <> fixture["identifier"], path, "origin/main"])

        hook = """
        issue_dir="$PWD"
        issue_name="${issue_dir##*/}"
        cd "$SYMPHONY_PROJECT_ROOT"
        git worktree remove "$issue_dir"
        git branch -D "symphony/$issue_name"
        """

        put_in(context.settings.hooks.before_remove, hook)
      end)

    Application.put_env(:symphony_elixir, :project_contexts, contexts)
    [first | _] = journal["fixtures"]
    Agent.update(ctx.source_agent, &%{&1 | issues: Map.delete(&1.issues, first["id"])})
    assert {:ok, cleaned} = TestRun.execute("cleanup")
    assert Enum.all?(cleaned["fixtures"], & &1["deleted"])

    for context <- contexts do
      assert Path.wildcard(Path.join(context.settings.workspace.root, "*")) == []
      assert git!(context.root, ["branch", "--list", "symphony/*"]) == ""
    end
  end

  test "unconfirmed deletion and malformed responses retain fixtures and permit retry", ctx do
    assert {:ok, _} = TestRun.execute("prepare")
    Agent.update(ctx.source_agent, &%{&1 | failure: :reject_delete})
    assert {:error, :test_cleanup_unconfirmed} = TestRun.execute("cleanup")
    Agent.update(ctx.source_agent, &%{&1 | failure: :malformed})
    assert {:error, :test_runtime_query_failed} = TestRun.execute("probe")
    Agent.update(ctx.source_agent, &%{&1 | failure: nil})
    assert {:ok, cleaned} = TestRun.execute("cleanup")
    assert Enum.all?(cleaned["fixtures"], & &1["deleted"])
  end

  test "failed schema request after access preflight retains an empty environment", ctx do
    Agent.update(ctx.source_agent, &%{&1 | failure: :schema_transport})
    assert {:error, _} = TestRun.execute("prepare")
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 0
  end

  defp journal_path(root), do: Path.join(root, "test-state/runs/fixture-run/fixtures.json")

  defp count_calls(source, name),
    do: Agent.get(source, fn state -> Enum.count(state.calls, &String.contains?(&1, name)) end)

  defp complete(source) do
    Agent.update(source, fn state ->
      issues = Map.new(state.issues, fn {id, issue} -> {id, put_in(issue["state"]["name"], "Planung (AI)")} end)

      comments =
        Map.new(issues, fn {id, _} ->
          {id,
           [
             %{
               "id" => "comment-" <> id,
               "body" => "## Symphony Workpad\n\nBootstrap complete",
               "issue" => %{"id" => id},
               "user" => %{"id" => "synthetic-app"}
             }
           ]}
        end)

      %{state | issues: issues, comments: comments}
    end)
  end

  defp respond(query, variables, state) do
    state = %{state | calls: state.calls ++ [query]}

    case state.failure do
      :malformed -> {{:ok, %{status: 200, body: %{}}}, state}
      :transport -> {{:error, :offline}, state}
      :graphql_errors -> {{:ok, %{status: 200, body: %{"errors" => [%{"message" => "fixture failure"}]}}}, state}
      _ -> respond_query(query, variables, state)
    end
  end

  defp respond_query(query, variables, state) do
    cond do
      query =~ "SymphonyAppIdentity" ->
        answer(
          %{"viewer" => %{"id" => "synthetic-app", "app" => true, "organization" => %{"id" => "synthetic-workspace"}}},
          state
        )

      query =~ "SymphonyWorkspacePoll" ->
        answer(%{"issues" => page([])}, state)

      query =~ "TestFixtureSchema" ->
        schema_response(state)

      query =~ "CreateTestFixture" ->
        create_response(variables["input"], state)

      query =~ "DeleteTestFixture" ->
        delete_response(variables["id"], state)

      query =~ "TestFixture(" ->
        answer(%{"issue" => state.issues[variables["id"]]}, state)

      query =~ "SymphonyLinearIssueComments" ->
        answer(%{"issue" => %{"comments" => page(Map.get(state.comments, variables["id"], []))}}, state)

      true ->
        answer(%{"users" => page([%{"id" => @human, "email" => "human@example.com", "app" => false}])}, state)
    end
  end

  defp schema_response(%{failure: :schema_transport} = state), do: {{:error, :offline}, state}

  defp schema_response(state) do
    fields = schema_fields(state.failure)

    answer(
      %{
        "__type" => %{"inputFields" => fields},
        "project" => %{
          "teams" => %{
            "nodes" => [%{"id" => "team", "states" => %{"nodes" => [%{"id" => "todo", "name" => "Todo (AI)"}]}}]
          }
        }
      },
      state
    )
  end

  defp delete_response(_id, %{failure: :reject_delete} = state),
    do: answer(%{"issueDelete" => %{"success" => false}}, state)

  defp delete_response(id, state),
    do: answer(%{"issueDelete" => %{"success" => true}}, %{state | issues: Map.delete(state.issues, id)})

  defp schema_fields(:schema), do: []
  defp schema_fields(_), do: Enum.map(~w(id title description teamId projectId assigneeId stateId), &%{"name" => &1})

  defp create_response(input, state) do
    issue = %{
      "id" => input["id"],
      "identifier" => "PRO-#{map_size(state.issues) + 1}",
      "title" => input["title"],
      "description" => input["description"],
      "project" => %{"id" => input["projectId"]},
      "team" => %{"id" => input["teamId"]},
      "assignee" => %{"id" => input["assigneeId"]},
      "state" => %{"name" => "Todo (AI)"}
    }

    updated = put_in(state.issues[issue["id"]], issue)

    case state.failure do
      :lost_create -> {{:error, :lost_response}, updated}
      :reject_create -> answer(%{"issueCreate" => %{"success" => false}}, state)
      _ -> answer(%{"issueCreate" => %{"success" => true, "issue" => Map.take(issue, ~w(id identifier))}}, updated)
    end
  end

  defp page(nodes), do: %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}
  defp answer(data, state), do: {{:ok, %{status: 200, body: %{"data" => data}}}, state}

  defp git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
