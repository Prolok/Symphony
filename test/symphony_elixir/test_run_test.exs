defmodule SymphonyElixir.TestRunTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.{MCPServer, TestTool}
  alias SymphonyElixir.Linear.{DurableState, WriteContext}
  alias SymphonyElixir.{ProjectContext, RoutineTest, TestRun}
  alias SymphonyElixir.Relay.Store
  alias SymphonyElixir.RelayFixture, as: RelayServer
  alias SymphonyElixir.RoutineRuntimeFixture, as: RuntimeFixture

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
        ["symphony-test"],
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

  test "one journaled fixture bootstraps once, bind only their IDs and clean up idempotently", ctx do
    assert {:ok, prepared} = TestRun.execute("prepare")
    assert length(prepared["fixtures"]) == 1
    assert Enum.all?(prepared["fixtures"], & &1["created"])
    assert {:ok, ^prepared} = TestRun.execute("prepare")
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 1
    System.put_env("SYMPHONY_TEST_RUN_STAGE", "run")
    assert {:ok, bound} = TestRun.bind_contexts(ctx.contexts)

    for context <- bound do
      assert "Planung (AI)" in context.settings.tracker.active_states
      assert [id] = context.settings.tracker.app["allowed_issue_ids"]
      assert Enum.any?(prepared["fixtures"], &(&1["id"] == id and &1["project"] == context.name))
      assert "Planung (AI)" in context.workflow.config["tracker"]["active_states"]
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

  test "run binding rejects missing, duplicate, foreign and unready fixture assignments", ctx do
    assert {:ok, prepared} = TestRun.execute("prepare")
    [fixture] = prepared["fixtures"]
    System.put_env("SYMPHONY_TEST_RUN_STAGE", "run")

    for fixtures <- [
          [],
          [fixture, fixture],
          [Map.put(fixture, "project", "unknown")],
          [Map.put(fixture, "id", "")],
          [Map.put(fixture, "created", false)],
          [Map.put(fixture, "deleted", true)],
          [nil]
        ] do
      :ok = DurableState.write(journal_path(ctx.root), Map.put(prepared, "fixtures", fixtures))
      assert {:error, :test_fixtures_not_prepared} = TestRun.bind_contexts(ctx.contexts)
    end

    :ok = DurableState.write(journal_path(ctx.root), prepared)
    assert {:error, :test_fixtures_not_prepared} = TestRun.bind_contexts([])
    assert {:error, :test_fixtures_not_prepared} = TestRun.bind_contexts(ctx.contexts ++ ctx.contexts)
    assert {:ok, [_]} = TestRun.bind_contexts(ctx.contexts)
  end

  test "run binding rejects an empty project set before fixture preparation", ctx do
    System.put_env("SYMPHONY_TEST_RUN_STAGE", "run")
    assert {:error, :test_fixtures_not_prepared} = TestRun.bind_contexts([])
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 0
    refute File.exists?(journal_path(ctx.root))
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

  test "bootstrap may finish after its status transition without starting planning", ctx do
    assert {:ok, prepared} = TestRun.execute("prepare")
    System.put_env("SYMPHONY_TEST_RUN_STAGE", "run")
    assert {:ok, [context | _]} = TestRun.bind_contexts(ctx.contexts)
    start_supervised!({SymphonyElixir.WorkerCapacity, contexts: [context]})
    fixture = Enum.find(prepared["fixtures"], &(&1["project"] == context.name))

    issue = %Issue{
      id: fixture["id"],
      identifier: fixture["identifier"],
      title: fixture["title"],
      state: "Todo (AI)",
      assigned_to_worker: true,
      assignee_id: @human
    }

    worker =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)

    ProjectContext.with_context(context, fn ->
      state = %Orchestrator.State{external_poll: true}
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
      changed = %{issue | state: "Planung (AI)"}
      refute Orchestrator.should_dispatch_issue_for_test(changed, state)
      state = %{state | running: %{issue.id => %{pid: worker, ref: nil, identifier: issue.identifier, issue: issue, run_mode: :regular, started_at: DateTime.utc_now()}}}
      kept = Orchestrator.reconcile_issue_states_for_test([changed], state)
      assert Map.has_key?(kept.running, issue.id)
      assert Process.alive?(worker)
    end)
  end

  test "cleanup retries keep reporting leftover branches after a failed removal hook", ctx do
    assert {:ok, journal} = TestRun.execute("prepare")
    [fixture | _] = journal["fixtures"]
    context = Enum.find(ctx.contexts, &(&1.name == fixture["project"]))
    path = Path.join(context.settings.workspace.root, fixture["identifier"])
    File.mkdir_p!(context.settings.workspace.root)
    git!(context.root, ["worktree", "add", "-b", "symphony/" <> fixture["identifier"], path, "origin/main"])
    context = put_in(context.settings.hooks.before_remove, "exit 1")
    Application.put_env(:symphony_elixir, :project_contexts, [context | Enum.reject(ctx.contexts, &(&1.id == context.id))])
    assert {:error, :test_workspace_changed_or_cleanup_failed} = TestRun.execute("cleanup")
    refute File.exists?(path)
    assert {:error, :test_workspace_changed_or_cleanup_failed} = TestRun.execute("cleanup")
    assert count_calls(ctx.source_agent, "DeleteTestFixture") == 0
  end

  test "cleanup preserves foreign branches, detached heads and replaced repositories", ctx do
    assert {:ok, journal} = TestRun.execute("prepare")
    [fixture | _] = journal["fixtures"]
    context = Enum.find(ctx.contexts, &(&1.name == fixture["project"]))
    path = Path.join(context.settings.workspace.root, fixture["identifier"])
    File.mkdir_p!(context.settings.workspace.root)
    git!(context.root, ["worktree", "add", "-b", "symphony/" <> fixture["identifier"], path, "origin/main"])
    git!(path, ["checkout", "-b", "foreign-work"])
    marker = Path.join(ctx.root, "cleanup-hook-called")
    context = put_in(context.settings.hooks.before_remove, "touch \"#{marker}\"")
    Application.put_env(:symphony_elixir, :project_contexts, [context | Enum.reject(ctx.contexts, &(&1.id == context.id))])

    assert {:error, :test_workspace_changed_or_cleanup_failed} = TestRun.execute("cleanup")
    refute File.exists?(marker)
    assert File.dir?(path)
    assert String.trim(git!(path, ["branch", "--show-current"])) == "foreign-work"
    assert count_calls(ctx.source_agent, "DeleteTestFixture") == 0

    git!(path, ["checkout", "--detach"])
    assert {:error, :test_workspace_changed_or_cleanup_failed} = TestRun.execute("cleanup")
    refute File.exists?(marker)
    assert File.dir?(path)

    git!(context.root, ["worktree", "remove", path])
    git!(context.root, ["clone", "--no-local", context.root, path])
    git!(path, ["checkout", "-b", "symphony/" <> fixture["identifier"]])
    assert String.trim(git!(path, ["rev-parse", "HEAD"])) == fixture["project_head"]
    assert {:error, :test_workspace_changed_or_cleanup_failed} = TestRun.execute("cleanup")
    refute File.exists?(marker)
    assert File.dir?(path)
    assert count_calls(ctx.source_agent, "DeleteTestFixture") == 0
  end

  test "bootstrap journals the actual post-hook worktree base", ctx do
    assert {:ok, journal} = TestRun.execute("prepare")
    [fixture | _] = journal["fixtures"]
    context = Enum.find(ctx.contexts, &(&1.name == fixture["project"]))
    advanced = git!(context.root, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "Advanced remote"]) |> String.trim()

    hook = """
    set -eu
    workspace="$PWD"
    rmdir "$workspace"
    git -C "$SYMPHONY_PROJECT_ROOT" update-ref refs/remotes/origin/main #{advanced}
    git -C "$SYMPHONY_PROJECT_ROOT" worktree add -b symphony/#{fixture["identifier"]} "$workspace" origin/main
    """

    context = put_in(context.settings.hooks.after_create, hook)
    System.put_env("SYMPHONY_TEST_RUN_STAGE", "run")

    ProjectContext.with_context(context, fn ->
      assert {:ok, path} = Workspace.create_for_issue(%{id: fixture["id"], identifier: fixture["identifier"]})
      assert String.trim(git!(path, ["rev-parse", "HEAD"])) == advanced
      foreign = %{issue_id: "foreign", issue_identifier: "PRO-0"}
      assert {:error, :test_workspace_base_unconfirmed} = TestRun.record_workspace(path, foreign, true)
    end)

    receipt_path = Path.join([Path.dirname(journal_path(ctx.root)), "workspaces", fixture["id"] <> ".json"])
    assert {:ok, receipt} = DurableState.read(receipt_path)
    assert receipt["head"] == advanced
    File.write!(receipt_path, "corrupt")
    assert {:error, :test_workspace_changed_or_cleanup_failed} = TestRun.execute("cleanup")
    :ok = DurableState.write(receipt_path, receipt)

    context =
      put_in(context.settings.hooks.before_remove, "git -C \"$SYMPHONY_PROJECT_ROOT\" worktree remove \"$PWD\" && git -C \"$SYMPHONY_PROJECT_ROOT\" branch -D symphony/#{fixture["identifier"]}")

    Application.put_env(:symphony_elixir, :project_contexts, [context | Enum.reject(ctx.contexts, &(&1.id == context.id))])
    assert {:ok, cleaned} = TestRun.execute("cleanup")
    assert Enum.all?(cleaned["fixtures"], & &1["deleted"])
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

  test "an existing run cannot be adopted from another result directory or instance", ctx do
    assert {:ok, journal} = TestRun.execute("prepare")
    before = File.read!(journal_path(ctx.root))
    alternate = Path.join(ctx.root, "other-results/plan.json")
    :ok = DurableState.write(alternate, ctx.plan)
    System.put_env("SYMPHONY_TEST_RUN_PLAN", alternate)

    assert {:error, :test_journal_identity_mismatch} = TestRun.execute("prepare")
    assert {:error, :test_environment_needs_cleanup} = TestRun.bind_contexts(ctx.contexts)
    assert File.read!(journal_path(ctx.root)) == before
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 1

    System.put_env("SYMPHONY_TEST_RUN_PLAN", ctx.plan_path)
    :ok = DurableState.write(ctx.plan_path, Map.put(ctx.plan, "instance", "another"))
    Application.put_env(:symphony_elixir, :test_instance, Map.put(ctx.instance, "name", "another"))
    assert {:error, :test_journal_identity_mismatch} = TestRun.execute("cleanup")
    assert {:error, :test_environment_needs_cleanup} = TestRun.bind_contexts(ctx.contexts)
    assert count_calls(ctx.source_agent, "DeleteTestFixture") == 0

    :ok = DurableState.write(ctx.plan_path, ctx.plan)
    Application.put_env(:symphony_elixir, :test_instance, ctx.instance)
    assert {:ok, ^journal} = TestRun.execute("prepare")
    assert {:ok, _} = TestRun.execute("cleanup")
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
    Application.put_env(:symphony_elixir, :project_contexts, ctx.contexts)
    {:ok, consumer} = Store.identity(first.settings.tracker.relay, "synthetic-workspace")
    RelayServer.fault(ctx.server, "synthetic-workspace", consumer, :register, {:error, {:relay_http, 503, "unavailable"}})
    assert {:error, :test_relay_preflight_failed} = TestRun.execute("prepare")
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 0
    refute File.exists?(journal_path(ctx.root))
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

  test "managed executor drives the existing fixture lifecycle through one regular runtime", ctx do
    {context, config, request} = routine_context(ctx)
    parent = self()

    runner = fn job, contexts, settings, _runtime, owner ->
      source = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}
      result = SymphonyElixir.RoutineTest.run(job, contexts, settings, source, owner)
      send(parent, {:routine_result, result})
      Map.put(result, "evidence", "fixture")
    end

    start_supervised!({SymphonyElixir.TestExecutor, contexts: [context], name: __MODULE__.Executor, runner: runner})
    assert {:ok, %{"running" => true}} = TestTool.request(context.settings.worker.test_executor_socket, request)
    assert_receive {:routine_result, result}, 10_000
    assert result["status"] == "passed", inspect(result)
    assert result["cleanup"]
    assert result["originals_preserved"]
    assert map_size(result["sessions"]) == 1
    assert [%{"deleted" => true, "complete" => true}] = result["fixtures"]
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 1
    assert count_calls(ctx.source_agent, "DeleteTestFixture") == 1
    assert Application.get_env(:symphony_elixir, :project_contexts) == ctx.contexts
    assert config["result_root"] != context.settings.workspace.root
  end

  test "routine runtime mismatch and access failures precede fixture creation", ctx do
    {context, config, request} = routine_context(ctx)
    job = routine_job(config, request)
    result = SymphonyElixir.RoutineTest.run(job, [context], config, %{}, self())
    assert result["error"] == "runtime_source_mismatch", inspect(result)
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 0
    Agent.update(ctx.source_agent, &%{&1 | failure: :transport})
    result = SymphonyElixir.RoutineTest.run(job, [context], config, %{}, self())
    assert result["status"] == "failed"
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 0
    Agent.update(ctx.source_agent, &%{&1 | failure: :auth})
    result = SymphonyElixir.RoutineTest.run(job, [context], config, %{}, self())
    assert result["error"] == "linear_access_denied"
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 0
  end

  test "routine caller authorization uses resolved polling context instead of startup context", ctx do
    {context, config, request} = routine_context(ctx)
    startup = %{context | assignee_ids: nil}
    job = routine_job(config, request)
    runtime = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}

    result = RoutineTest.run(job, [startup], config, runtime, self())
    assert result["status"] == "passed", inspect(result)
    assert result["cleanup"]
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 1

    recovery = RoutineTest.run(%{job | "cleanup" => true}, [startup], config, %{}, self())
    assert recovery["status"] == "failed"
    assert recovery["cleanup"]
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 1

    :sys.replace_state(SymphonyElixir.ProjectPoller, &Keyword.put(&1, :context, %{context | assignee_ids: []}))
    denied = routine_job(config, %{request | "run_id" => "revoked-owner"})
    result = RoutineTest.run(denied, [context], config, runtime, self())
    assert result["status"] == "failed"
    assert result["error"] == "test_owner_mismatch"
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 1
  end

  test "routine caller authorization fails closed for missing, moved or unavailable polling context", ctx do
    {context, config, request} = routine_context(ctx)
    job = routine_job(config, request)

    for current <- [%{context | id: "removed"}, put_in(context.settings.workspace.root, ctx.root)] do
      :sys.replace_state(SymphonyElixir.ProjectPoller, &Keyword.put(&1, :context, current))
      assert RoutineTest.run(job, [context], config, %{}, self())["error"] == "test_owner_mismatch"
    end

    :ok = stop_supervised(RuntimeFixture)
    assert RoutineTest.run(job, [context], config, %{}, self())["error"] == "runtime_unavailable"
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 0
  end

  test "resolved routine context still rejects foreign people, app assignees and project scopes", ctx do
    {context, config, request} = routine_context(ctx)
    startup = %{context | assignee_ids: nil}
    owner = Agent.get(ctx.source_agent, & &1.issues[request["issue_id"]])
    job = routine_job(config, request)
    runtime = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}

    for invalid <- [
          put_in(owner["assignee"]["id"], "another-person"),
          put_in(owner["assignee"]["app"], true),
          put_in(owner["project"]["slugId"], "another-project")
        ] do
      Agent.update(ctx.source_agent, &put_in(&1.issues[request["issue_id"]], invalid))
      assert RoutineTest.run(job, [startup], config, runtime, self())["error"] == "test_owner_mismatch"
      refute File.exists?(Path.join(job["directory"], "plan.json"))
    end

    Agent.update(ctx.source_agent, &put_in(&1.issues[request["issue_id"]], owner))
    foreign_workspace = put_in(startup.settings.tracker.app["workspace_id"], "another-workspace")
    result = RoutineTest.run(job, [foreign_workspace], config, runtime, self())
    assert result["error"] == "routine_test_project_binding_rejected"
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 0
  end

  test "routine authorization and cleanup recovery reject mismatched owners and plans", ctx do
    {context, config, request} = routine_context(ctx)
    job = routine_job(config, request)
    runtime = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}
    assert RoutineTest.run(job, [], config, runtime, self())["error"] == "test_owner_mismatch"
    malformed = %{context | settings: nil}
    assert RoutineTest.run(job, [malformed], config, runtime, self())["error"] == "preflight_or_runtime_failed"
    Agent.update(ctx.source_agent, &put_in(&1.issues[request["issue_id"]]["identifier"], "PRO-999"))
    assert RoutineTest.run(job, [context], config, runtime, self())["error"] == "test_owner_mismatch"
    Agent.update(ctx.source_agent, &put_in(&1.issues[request["issue_id"]]["identifier"], request["identifier"]))
    recovery = %{job | "cleanup" => true}
    result = RoutineTest.run(recovery, [context], config, runtime, self())
    assert result["status"] == "failed"
    assert result["cleanup"]
    :ok = DurableState.write(Path.join(job["directory"], "plan.json"), %{"source" => "foreign"})
    assert RoutineTest.run(recovery, [context], config, runtime, self())["error"] == "test_plan_identity_mismatch"
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 0
  end

  for {name, response, expected} <- [
        {"HTTP auth", {:ok, %{status: 403, body: %{"errors" => [%{"message" => "denied"}]}}}, "linear_access_denied"},
        {"HTTP rate limit", {:ok, %{status: 429, body: %{"errors" => [%{"message" => "limited"}]}}}, "linear_rate_limited"},
        {"app cooldown", {:error, {:linear_app_rate_limited, %{retry_after_ms: 1_000}}}, "linear_rate_limited"}
      ] do
    @tag binding_response: response, expected_error: expected
    test "routine target preflight distinguishes #{name} without creating fixtures", ctx do
      {context, config, request} = routine_context(ctx)
      request_fun = Application.fetch_env!(:symphony_elixir, :linear_client_request_fun)

      Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, headers ->
        if (payload["query"] || payload[:query]) =~ "SymphonyRoutineBinding", do: ctx.binding_response, else: request_fun.(payload, headers)
      end)

      result = RoutineTest.run(routine_job(config, request), [context], config, %{}, self())
      assert result["error"] == ctx.expected_error, inspect(result)
      assert count_calls(ctx.source_agent, "CreateTestFixture") == 0
    end
  end

  test "runtime failures and damaged journals retain failed results for recovery", ctx do
    {context, config, request} = routine_context(ctx)
    runtime = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}
    job = routine_job(config, request)
    result = RoutineTest.run(job, [context], %{config | "timeout" => "invalid"}, runtime, self())
    assert result["error"] == "preflight_or_runtime_failed"
    assert result["cleanup"]
  end

  for failure <- [:bad_snapshot, :probe_exit, :corrupt_journal, :stop_rejected, :stopped_runtime] do
    @tag runtime_failure: failure
    test "routine #{failure} preserves failure and records cleanup availability", ctx do
      {context, config, request} = routine_context(ctx)
      runtime = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}
      failure = ctx.runtime_failure
      job = routine_job(config, %{request | "run_id" => Atom.to_string(failure)})
      server = SymphonyElixir.Projects.server(context)

      stop_result =
        case failure do
          :stop_rejected -> {:error, :worker_busy}
          :stopped_runtime -> :exit
          _ -> :ok
        end

      :sys.replace_state(server, fn opts ->
        opts
        |> Keyword.put(:stop_result, stop_result)
        |> Keyword.put(:snapshot_transform, fn snapshot ->
          if failure == :probe_exit, do: exit(:probe_failed)
          if failure == :corrupt_journal, do: File.write!(Path.join(job["directory"], "fixtures.json"), "corrupt")
          if failure == :bad_snapshot, do: :unavailable, else: snapshot
        end)
      end)

      result = RoutineTest.run(job, [context], config, runtime, self())
      assert result["status"] == "failed", inspect({failure, result})
      if failure in [:corrupt_journal, :stop_rejected, :stopped_runtime], do: refute(result["cleanup"])
    end
  end

  test "cancel during the polling interval stops the waiting run", ctx do
    {context, config, request} = routine_context(ctx)
    job = routine_job(config, request)
    parent = self()

    :sys.replace_state(SymphonyElixir.Projects.server(context), fn opts ->
      opts
      |> Keyword.put(:complete, fn -> :ok end)
      |> Keyword.put(:snapshot_transform, fn snapshot ->
        send(parent, :probe_observed)
        snapshot
      end)
    end)

    runtime = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}
    task = Task.async(fn -> RoutineTest.run(job, [context], config, runtime, self()) end)
    assert_receive :probe_observed, 2_000
    Process.send_after(task.pid, :cancel_test, 100)
    result = Task.await(task, 2_000)
    assert result["error"] == "cancelled"
    assert result["cleanup"]
  end

  test "unavailable probe supervisor fails the run and still cleans its fixtures", ctx do
    {context, config, request} = routine_context(ctx)
    job = routine_job(config, request)
    runtime = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}
    supervisor = Process.whereis(SymphonyElixir.TaskSupervisor)
    Process.unregister(SymphonyElixir.TaskSupervisor)

    try do
      result = RoutineTest.run(job, [context], config, runtime, self())
      assert result["error"] == "runtime_unavailable"
      assert result["cleanup"]
    after
      Process.register(supervisor, SymphonyElixir.TaskSupervisor)
    end
  end

  test "completed sessions remain observable after workers leave the live snapshot", ctx do
    {context, config, request} = routine_context(ctx)
    job = routine_job(config, request)
    runtime = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}

    :sys.replace_state(SymphonyElixir.Projects.server(context), fn opts ->
      Keyword.put(opts, :snapshot_transform, fn snapshot ->
        ProjectContext.with_context(context, fn ->
          Enum.each(snapshot.running, &RoutineTest.record_session(&1.issue_id, &1.session_id))
        end)

        %{running: []}
      end)
    end)

    result = RoutineTest.run(job, [context], config, runtime, self())
    assert result["status"] == "passed"
    assert map_size(result["sessions"]) == 1
    assert result["cleanup"]
  end

  test "routine worktree receipts record only the created owned worktree", ctx do
    {context, config, request} = routine_context(ctx)
    job = routine_job(config, request)
    plan = %{"instance" => "routine", "run_id" => request["run_id"], "scenario" => "bootstrap", "source" => ctx.plan["source"]}
    DurableState.write(Path.join(job["directory"], "plan.json"), plan)
    assert {:ok, %{"fixtures" => [fixture]}} = TestRun.with_routine(context, plan, job["directory"], "prepare", fn -> TestRun.execute("prepare") end)
    path = Path.join(context.settings.workspace.root, fixture["identifier"])
    git!(context.root, ["worktree", "add", "-qb", "symphony/" <> fixture["identifier"], path])
    issue = %{issue_id: fixture["id"], issue_identifier: fixture["identifier"]}

    ProjectContext.with_context(context, fn ->
      assert :ok = RoutineTest.record_workspace(path, issue, true)
      foreign = %{issue | issue_id: "foreign"}
      assert {:error, :test_workspace_base_unconfirmed} = RoutineTest.record_workspace(path, foreign, true)
    end)

    assert {:ok, receipt} = DurableState.read(Path.join([job["directory"], "workspaces", fixture["id"] <> ".json"]))
    assert receipt["path"] == path
    assert receipt["source"] == plan["source"]
  end

  test "unreadable source evidence cannot report originals as preserved", ctx do
    {context, config, request} = routine_context(ctx)
    runtime = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}
    bin = Path.join(ctx.root, "source-failure-bin")
    File.mkdir_p!(bin)
    previous = System.fetch_env!("PATH")
    on_exit(fn -> System.put_env("PATH", previous) end)

    for {id, script} <- [{"malformed", "printf 'invalid-json'"}, {"unavailable", "exit 1"}] do
      File.write!(Path.join(bin, "python3"), "#!/bin/sh\n" <> script <> "\n")
      File.chmod!(Path.join(bin, "python3"), 0o755)
      System.put_env("PATH", bin <> ":" <> previous)
      job = routine_job(config, %{request | "run_id" => id, "scenario" => "failure-probe"})
      result = RoutineTest.run(job, [context], config, runtime, self())
      assert result["status"] == "failed"
      refute result["originals_preserved"]
    end
  end

  test "workflow probe requires actual merged PR and preserves the merge receipt through cleanup", ctx do
    {context, config, request} = routine_context(ctx)
    job = routine_job(config, %{request | "scenario" => "workflow"})
    plan = %{"instance" => "routine", "run_id" => request["run_id"], "scenario" => "workflow", "source" => ctx.plan["source"]}

    stage = fn operation ->
      TestRun.with_routine(context, plan, job["directory"], operation, fn -> TestRun.execute(operation) end)
    end

    assert {:ok, journal} = stage.("prepare")
    [fixture] = journal["fixtures"]
    assert fixture["description"] =~ "regulären Workflow"
    complete(ctx.source_agent)
    assert {:ok, %{"fixtures" => [%{"complete" => false}]}} = stage.("probe")

    Agent.update(ctx.source_agent, fn state ->
      state = put_in(state.issues[fixture["id"]]["state"]["name"], "Review")
      update_in(state.comments[fixture["id"]], fn [comment] -> [%{comment | "body" => "## Symphony Workpad\nMerge-Evidenz: fixture"}] end)
    end)

    git!(context.root, ["remote", "add", "origin", "https://github.com/Prolok/symphony-test.git"])
    bin = Path.join(ctx.root, "fake-gh")
    File.mkdir_p!(bin)
    response = Path.join(bin, "response.json")
    File.write!(response, "[]")
    File.write!(Path.join(bin, "gh"), "#!/bin/sh\ncat '#{response}'\n")
    File.chmod!(Path.join(bin, "gh"), 0o755)
    previous = System.fetch_env!("PATH")
    System.put_env("PATH", bin <> ":" <> previous)
    on_exit(fn -> System.put_env("PATH", previous) end)
    assert {:ok, %{"fixtures" => [%{"complete" => false}]}} = stage.("probe")
    sha = String.duplicate("c", 40)
    url = "https://github.com/Prolok/symphony-test/pull/1"
    File.write!(response, Jason.encode!([%{"state" => "MERGED", "mergeCommit" => %{"oid" => sha}, "headRefOid" => sha, "url" => url}]))
    assert {:ok, %{"fixtures" => [%{"complete" => true, "merge" => merge}]}} = stage.("probe")
    assert merge == %{"state" => "MERGED", "commit" => sha, "head" => sha, "url" => url}
    assert {:ok, %{"fixtures" => [%{"deleted" => true, "merge" => ^merge}]}} = stage.("cleanup")
  end

  test "routine cancellation timeout failure and recovery clean only their fixtures", ctx do
    {context, config, request} = routine_context(ctx)
    runtime = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}

    for {id, scenario, timeout, cancel} <- [{"failure", "failure-probe", 30, false}, {"cancel", "bootstrap", 30, true}, {"timeout", "bootstrap", 0, false}] do
      request = %{request | "run_id" => id, "scenario" => scenario}
      job = routine_job(config, request)
      if cancel, do: send(self(), :cancel_test)
      result = SymphonyElixir.RoutineTest.run(job, [context], %{config | "timeout" => timeout}, runtime, self())
      assert result["status"] == "failed", inspect(result)
      assert result["cleanup"], inspect(result)
      assert result["error"] in ["intentional_failure_probe", "cancelled", "timeout"]
      recovery = SymphonyElixir.RoutineTest.run(%{job | "cleanup" => true}, [context], config, runtime, self())
      assert recovery["status"] == "failed"
      assert recovery["cleanup"], inspect(recovery)
    end

    assert Agent.get(ctx.source_agent, &map_size(&1.issues)) == 1
  end

  test "cancel arriving inside the successful final probe cannot pass", ctx do
    {context, config, request} = routine_context(ctx)
    job = routine_job(config, request)
    caller = self()

    :sys.replace_state(SymphonyElixir.Projects.server(context), fn opts ->
      Keyword.put(opts, :complete, fn ->
        complete(ctx.source_agent)
        count = Process.get(:probe_count, 0) + 1
        Process.put(:probe_count, count)
        if count == 2, do: send(caller, :cancel_test)
      end)
    end)

    runtime = Map.take(request, ~w(head_sha source_sha256)) |> Map.put("sha", request["head_sha"])
    result = SymphonyElixir.RoutineTest.run(job, [context], config, runtime, self())
    assert result["status"] == "failed"
    assert result["error"] == "cancelled"
    assert result["cleanup"]
  end

  test "own planning descriptions remain bound through lost responses while external edits block cleanup", ctx do
    {context, config, request} = routine_context(ctx)
    job = routine_job(config, %{request | "scenario" => "workflow"})
    plan = %{"instance" => "routine", "run_id" => request["run_id"], "scenario" => "workflow", "source" => ctx.plan["source"]}
    :ok = DurableState.write(Path.join(job["directory"], "plan.json"), plan)
    :ok = DurableState.write(Path.join(job["directory"], "control.json"), %{"active" => true})

    stage = fn operation ->
      TestRun.with_routine(context, plan, job["directory"], operation, fn -> TestRun.execute(operation) end)
    end

    assert {:ok, %{"fixtures" => [fixture]}} = stage.("prepare")
    Agent.update(ctx.source_agent, &put_in(&1.issues[fixture["id"]]["state"]["name"], "Planung (AI)"))

    for failure <- [nil, :lost_description] do
      description = "## Zusammenfassung\n\nGeplanter Lauf #{inspect(failure)}\n\n---\n\n" <> fixture["description"]
      Agent.update(ctx.source_agent, &%{&1 | failure: failure})

      result =
        ProjectContext.with_context(context, fn ->
          WriteContext.with_context(%{issue_id: fixture["id"], phase: "Planung (AI)", run_id: "planning-run"}, fn ->
            Client.graphql("mutation OwnFixtureDescription($id: String!, $description: String!) { changed: issueUpdate(id: $id, input: {description: $description}) { success } }", %{
              id: fixture["id"],
              description: description
            })
          end)
        end)

      if failure, do: assert(match?({:error, _}, result)), else: assert(match?({:ok, _}, result))
      Agent.update(ctx.source_agent, &%{&1 | failure: nil})
      assert {:ok, _} = stage.("probe")
    end

    # The fallback MCP helper has no service process context or executor ETS.
    previous_settings = Application.get_env(:symphony_elixir, :service_settings)
    Application.put_env(:symphony_elixir, :service_settings, context.settings)
    System.put_env("SYMPHONY_PROJECT_ROOT", context.root)
    System.put_env("SYMPHONY_ISSUE_ID", fixture["id"])
    System.put_env("SYMPHONY_PHASE", "Planung (AI)")

    try do
      result =
        MCPServer.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "linear_graphql",
            "arguments" => %{
              "query" => "mutation OwnFixtureDescription($id: String!, $description: String!) { changed: issueUpdate(id: $id, input: {description: $description}) { success } }",
              "variables" => %{"id" => fixture["id"], "description" => "MCP planning description"}
            }
          }
        })

      refute result["result"]["isError"], inspect(result)
      assert {:ok, _} = stage.("probe")
    after
      if previous_settings,
        do: Application.put_env(:symphony_elixir, :service_settings, previous_settings),
        else: Application.delete_env(:symphony_elixir, :service_settings)

      for key <- ~w(SYMPHONY_PROJECT_ROOT SYMPHONY_ISSUE_ID SYMPHONY_PHASE), do: System.delete_env(key)
    end

    receipt_path = Path.join([job["directory"], "descriptions", fixture["id"] <> ".json"])
    assert {:ok, receipt} = DurableState.read(receipt_path)
    assert receipt["source"] == plan["source"]
    assert receipt["writer"]["phase"] == "Planung (AI)"
    DurableState.write(receipt_path, %{receipt | "source" => %{}})
    assert {:error, :test_fixture_changed_externally} = stage.("probe")
    File.write!(receipt_path, "corrupt")
    assert {:error, :test_fixture_changed_externally} = stage.("probe")
    DurableState.write(receipt_path, receipt)

    TestRun.with_routine(context, plan, job["directory"], "probe", fn ->
      assert {:error, :test_description_update_unbound} = TestRun.record_description_intent(fixture["id"], nil, %{})
      Agent.update(ctx.source_agent, &%{&1 | failure: :transport})
      assert {:error, _} = TestRun.record_description_intent(fixture["id"], "unconfirmed", %{"phase" => "Planung (AI)"})
      Agent.update(ctx.source_agent, &%{&1 | failure: nil})
    end)

    ProjectContext.with_context(context, fn ->
      assert {:error, :invalid_graphql_document} = RoutineTest.prepare_description_updates(%{"query" => "mutation {"})

      assert {:error, :duplicate_fixture_description_update} =
               RoutineTest.prepare_description_updates(%{
                 "query" => "mutation { a: issueUpdate(id: \"same\", input: {description: \"one\"}) { success } b: issueUpdate(id: \"same\", input: {description: \"two\"}) { success } }"
               })

      assert :ok = RoutineTest.prepare_description_updates(%{"query" => "mutation { issueUpdate(id: \"foreign\", input: {description: \"foreign\"}) { success } }"})
    end)

    rejected =
      ProjectContext.with_context(context, fn ->
        WriteContext.with_context(%{issue_id: fixture["id"], phase: "In Arbeit (AI)"}, fn ->
          Client.graphql("mutation OwnFixtureDescription($id: String!, $description: String!) { changed: issueUpdate(id: $id, input: {description: $description}) { success } }", %{
            id: fixture["id"],
            description: "not allowed"
          })
        end)
      end)

    assert {:error, :test_description_update_unbound} = rejected

    own = Agent.get(ctx.source_agent, & &1.issues[fixture["id"]]["description"])
    Agent.update(ctx.source_agent, &put_in(&1.issues[fixture["id"]]["description"], "external edit"))
    assert {:error, :test_fixture_changed_externally} = stage.("cleanup")
    assert count_calls(ctx.source_agent, "DeleteTestFixture") == 0
    Agent.update(ctx.source_agent, &put_in(&1.issues[fixture["id"]]["description"], own))
    assert {:ok, %{"fixtures" => [%{"deleted" => true}]}} = stage.("cleanup")
  end

  test "a slow final probe is bounded by the remaining deadline", ctx do
    {context, config, request} = routine_context(ctx)
    job = routine_job(config, request)

    :sys.replace_state(SymphonyElixir.Projects.server(context), fn opts ->
      Keyword.put(opts, :complete, fn ->
        complete(ctx.source_agent)
        count = Process.get(:probe_count, 0) + 1
        Process.put(:probe_count, count)
        if count == 2, do: Process.sleep(1_200)
      end)
    end)

    runtime = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}
    result = SymphonyElixir.RoutineTest.run(job, [context], %{config | "timeout" => 1}, runtime, self())
    assert result["status"] == "failed"
    assert result["error"] == "timeout"
    assert result["cleanup"]
  end

  test "blocked probe calls are stopped on cancel or timeout before cleanup", ctx do
    {context, config, request} = routine_context(ctx)
    parent = self()
    request_fun = Application.fetch_env!(:symphony_elixir, :linear_client_request_fun)

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, headers ->
      if TestRun.stage() == "probe" and (payload["query"] || payload[:query]) =~ "query TestFixture(" do
        send(parent, {:blocked_probe, self()})
        receive do: (:release_probe -> :ok)
      end

      request_fun.(payload, headers)
    end)

    for {run_id, timeout, expected} <- [{"blocked-cancel", 30, "cancelled"}, {"blocked-timeout", 1, "timeout"}, {"blocked-crash", 30, "runtime_unavailable"}] do
      job = routine_job(config, %{request | "run_id" => run_id})
      runtime = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}
      task = Task.async(fn -> SymphonyElixir.RoutineTest.run(job, [context], %{config | "timeout" => timeout}, runtime, self()) end)
      assert_receive {:blocked_probe, probe}, 2_000
      if expected == "cancelled", do: send(task.pid, :cancel_test)
      if expected == "runtime_unavailable", do: Process.exit(probe, :kill)
      assert {:ok, result} = Task.yield(task, 2_500)
      refute Process.alive?(probe)
      assert result["status"] == "failed"
      assert result["error"] == expected
      assert result["cleanup"]
    end
  end

  defp routine_job(config, request) do
    directory = Path.join([config["result_root"], request["issue_id"], request["run_id"]])
    File.mkdir_p!(directory)
    %{"request" => Map.delete(request, "operation"), "directory" => directory, "cleanup" => false}
  end

  defp routine_context(ctx) do
    [context] = ctx.contexts
    Application.delete_env(:symphony_elixir, :test_instance)
    config = ctx.instance["manifest"]["projects"][context.name]

    config =
      Map.merge(config, %{"teams" => [%{"id" => "team", "key" => "PRO"}], "scenarios" => ["bootstrap", "workflow", "failure-probe"], "timeout" => 30, "result_root" => Path.join(ctx.root, "managed")})

    socket_root = Path.join(File.cwd!(), "tmp/rt-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(socket_root) end)
    context = put_in(context.settings.worker.test_executor, config)
    context = put_in(context.settings.worker.test_executor_socket, Path.join(socket_root, "e.sock"))
    context = %{context | test_instance: nil}
    workspace = Path.join(context.settings.workspace.root, "PRO-769")
    git!(context.root, ["worktree", "add", "-qb", "symphony/PRO-769", workspace])
    {json, 0} = System.cmd("python3", ["scripts/test-instance.py", "source", workspace])
    source = Jason.decode!(json)
    id = "33333333-3333-4333-8333-333333333333"

    owner = %{
      "id" => id,
      "identifier" => "PRO-769",
      "title" => "Caller",
      "state" => %{"name" => "Test (AI)"},
      "project" => %{"id" => "symphony-test", "slugId" => "symphony-test"},
      "assignee" => %{"id" => @human, "app" => false},
      "team" => %{"id" => "team", "key" => "PRO"},
      "labels" => page([]),
      "relations" => page([]),
      "inverseRelations" => page([])
    }

    Agent.update(ctx.source_agent, &put_in(&1.issues[id], owner))

    request = %{
      "operation" => "start",
      "run_id" => "routine-live-fixture",
      "scenario" => "bootstrap",
      "head_sha" => source["sha"],
      "source_sha256" => source["source_sha256"],
      "issue_id" => id,
      "identifier" => "PRO-769",
      "checkout" => workspace
    }

    start_supervised!({Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry})
    relay_opts = [name: SymphonyElixir.ProjectPoller, source: ctx.source_agent, context: context]
    relay = start_supervised!({RuntimeFixture, relay_opts})

    complete = fn -> complete(ctx.source_agent) end
    fixture_opts = [name: SymphonyElixir.Projects.server(context), source: ctx.source_agent, complete: complete]

    start_supervised!(
      Supervisor.child_spec({RuntimeFixture, fixture_opts},
        id: :fixture_project
      )
    )

    assert Process.alive?(relay)

    ProjectContext.with_context(context, fn ->
      WriteContext.with_context(%{issue_id: id}, fn ->
        assert {:ok, _} = SymphonyElixir.CommentCheckpoint.bound_issue(id)
      end)
    end)

    assert :ok = SymphonyElixir.TestExecutor.verify_target(context, config)
    {context, config, request}
  end

  defp journal_path(root), do: Path.join(root, "test-state/runs/fixture-run/fixtures.json")

  defp count_calls(source, name),
    do: Agent.get(source, fn state -> Enum.count(state.calls, &String.contains?(&1, name)) end)

  defp complete(source) do
    Agent.update(source, fn state ->
      issues =
        Map.new(state.issues, fn {id, issue} ->
          {id, if(issue["title"] == "Caller", do: issue, else: put_in(issue["state"]["name"], "Planung (AI)"))}
        end)

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
      :auth -> {{:ok, %{status: 403, body: %{"errors" => [%{"message" => "denied"}]}}}, state}
      :graphql_errors -> {{:ok, %{status: 200, body: %{"errors" => [%{"message" => "fixture failure"}]}}}, state}
      _ -> respond_routine_query(query, variables, state)
    end
  end

  defp respond_routine_query(query, variables, state) do
    cond do
      query =~ "OwnFixtureDescription" ->
        updated = put_in(state.issues[variables["id"]]["description"], variables["description"])

        if state.failure == :lost_description,
          do: {{:error, :lost_response}, updated},
          else: answer(%{"changed" => %{"success" => true}}, updated)

      query =~ "SymphonyRoutineBinding" ->
        answer(
          %{
            "project" => %{"id" => "symphony-test", "name" => "symphony-test", "slugId" => "symphony-test", "teams" => page([%{"id" => "team", "key" => "PRO"}])},
            "viewer" => %{"organization" => %{"id" => "synthetic-workspace", "urlKey" => "prolok"}}
          },
          state
        )

      query =~ "SymphonyLinearIssuesById" ->
        answer(%{"issues" => page(Enum.map(variables["ids"], &state.issues[&1]))}, state)

      true ->
        respond_query(query, variables, state)
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

defmodule SymphonyElixir.RoutineRuntimeFixture do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  @impl true
  def init(opts), do: {:ok, opts}
  @impl true
  def handle_call({:relay_issues, _, []}, _from, opts), do: {:reply, {:ok, []}, opts}

  def handle_call({:context, id}, _from, opts) do
    context = Keyword.fetch!(opts, :context)
    {:reply, if(context.id == id, do: context), opts}
  end

  def handle_call({:stop_test_fixture, _}, _from, opts) do
    case Keyword.get(opts, :stop_result, :ok) do
      :exit -> {:stop, :fixture_stop_failed, opts}
      result -> {:reply, result, opts}
    end
  end

  def handle_call(:snapshot, _from, opts) do
    Keyword.fetch!(opts, :complete).()

    running =
      Agent.get(Keyword.fetch!(opts, :source), fn state ->
        for {id, issue} <- state.issues, issue["title"] != "Caller", do: %{issue_id: id, session_id: "fixture-session-" <> id}
      end)

    snapshot = Keyword.get(opts, :snapshot_transform, &Function.identity/1).(%{running: running})
    {:reply, snapshot, opts}
  end
end
