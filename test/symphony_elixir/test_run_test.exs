defmodule SymphonyElixir.TestRunTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.{MCPServer, TestTool}
  alias SymphonyElixir.Linear.{DurableState, WriteContext}
  alias SymphonyElixir.{ProjectContext, RoutineTest, TestRun}
  alias SymphonyElixir.Relay.Store
  alias SymphonyElixir.RelayFixture, as: RelayServer
  alias SymphonyElixir.RoutineRuntimeFixture, as: RuntimeFixture
  alias SymphonyElixir.TestRun.PoHandoff, as: PoHandoff
  alias SymphonyElixir.Yolo.Store, as: YoloStore

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

  test "corrected build cleans only the hash-bound original plan without rebinding journals", ctx do
    assert {:ok, _} = TestRun.execute("prepare")
    original_plan = File.read!(ctx.plan_path)
    original_journal = File.read!(journal_path(ctx.root))
    recovery = %{"plan_path" => ctx.plan_path, "source" => ctx.plan["source"], "plan_sha256" => Base.encode16(:crypto.hash(:sha256, original_plan), case: :lower)}
    instance = %{ctx.instance | "source" => Map.put(ctx.instance["source"], "source_sha256", String.duplicate("c", 64))} |> Map.put("cleanup_recovery", recovery)
    Application.put_env(:symphony_elixir, :test_instance, instance)
    Agent.update(ctx.source_agent, &%{&1 | calls: []})

    for stage <- ["prepare", "run", "probe", "delegate", "withdraw"] do
      System.put_env("SYMPHONY_TEST_RUN_STAGE", stage)
      assert {:error, :invalid_test_run} = TestRun.execute("cleanup")
    end

    System.put_env("SYMPHONY_TEST_RUN_STAGE", "cleanup")
    for stage <- ["prepare", "probe", "delegate", "withdraw"], do: assert({:error, :invalid_test_run} = TestRun.execute(stage))

    for patch <- [%{"plan_path" => ctx.plan_path <> ".other"}, %{"source" => %{}}, %{"plan_sha256" => String.duplicate("0", 64)}] do
      Application.put_env(:symphony_elixir, :test_instance, Map.put(instance, "cleanup_recovery", Map.merge(recovery, patch)))
      assert {:error, :invalid_test_run} = TestRun.execute("cleanup")
    end

    assert count_calls(ctx.source_agent, "mutation") == 0
    assert File.read!(journal_path(ctx.root)) == original_journal
    Application.put_env(:symphony_elixir, :test_instance, instance)
    Application.put_env(:symphony_elixir, :yolo, true)
    assert {:error, :invalid_test_run} = TestRun.execute("cleanup")
    Application.put_env(:symphony_elixir, :yolo, false)
    File.rm!(journal_path(ctx.root))
    assert {:error, :invalid_test_run} = TestRun.execute("cleanup")
    File.write!(journal_path(ctx.root), original_journal)
    changed = Enum.map(ctx.contexts, &put_in(&1.settings.tracker.app["user_id"], "foreign"))
    Application.put_env(:symphony_elixir, :project_contexts, changed)
    assert {:error, :test_journal_identity_mismatch} = TestRun.execute("cleanup")
    Application.put_env(:symphony_elixir, :project_contexts, ctx.contexts)
    assert {:ok, cleaned} = TestRun.execute("cleanup")
    assert Enum.all?(cleaned["fixtures"], & &1["deleted"])
    assert {:ok, ^cleaned} = TestRun.execute("cleanup")
    assert cleaned["source"] == ctx.plan["source"]
    assert File.read!(ctx.plan_path) == original_plan
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 0
  end

  test "standalone failure-probe prepares fixtures and permits normal cleanup", ctx do
    :ok = DurableState.write(ctx.plan_path, Map.put(ctx.plan, "scenario", "failure-probe"))
    assert {:ok, prepared} = TestRun.execute("prepare")
    assert [%{"created" => true, "deleted" => false}] = prepared["fixtures"]
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 1
    assert {:ok, cleaned} = TestRun.execute("cleanup")
    assert [%{"deleted" => true}] = cleaned["fixtures"]
    assert Agent.get(ctx.source_agent, &map_size(&1.issues)) == 0
  end

  test "CLI stages apply the yolo flag before project preparation and cleanup recovery", ctx do
    :ok = DurableState.write(ctx.plan_path, Map.put(ctx.plan, "yolo", true))

    for stage <- ["prepare", "probe"] do
      Application.put_env(:symphony_elixir, :yolo, false)
      System.put_env("SYMPHONY_TEST_RUN_STAGE", stage)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   SymphonyElixir.CLI.run_test_stage(
                     stage,
                     fn ->
                       assert Config.yolo?()
                       :ok
                     end,
                     ["--test-instance", "dev", "--yolo"]
                   )
        end)

      assert output =~ "Test run result="
    end

    original_plan = File.read!(ctx.plan_path)
    recovery = %{"plan_path" => ctx.plan_path, "source" => ctx.plan["source"], "plan_sha256" => Base.encode16(:crypto.hash(:sha256, original_plan), case: :lower)}
    instance = %{ctx.instance | "source" => Map.put(ctx.instance["source"], "source_sha256", String.duplicate("c", 64))} |> Map.put("cleanup_recovery", recovery)
    Application.put_env(:symphony_elixir, :test_instance, instance)
    System.put_env("SYMPHONY_TEST_RUN_STAGE", "cleanup")

    ExUnit.CaptureIO.capture_io(fn ->
      assert {:error, _} =
               SymphonyElixir.CLI.run_test_stage(
                 "cleanup",
                 fn ->
                   refute Config.yolo?()
                   :ok
                 end,
                 []
               )
    end)

    assert Agent.get(ctx.source_agent, &map_size(&1.issues)) == 1
    Application.put_env(:symphony_elixir, :yolo, false)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok =
                 SymphonyElixir.CLI.run_test_stage(
                   "cleanup",
                   fn ->
                     assert Config.yolo?()
                     :ok
                   end,
                   ["--yolo"]
                 )
      end)

    assert "Test run result=" <> result = output
    assert [%{"deleted" => true}] = Jason.decode!(result)["fixtures"]
    assert File.read!(ctx.plan_path) == original_plan
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 1
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
    assert {:error, {:test_relay_preflight, :degraded}} = TestRun.execute("prepare")
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
    checkout = Path.join([ctx.root, "review", Ecto.UUID.generate(), String.duplicate("long-checkout-", 8)])
    File.mkdir_p!(checkout)
    assert byte_size(checkout) > 104
    {context, config, request} = File.cd!(checkout, fn -> routine_context(ctx) end)
    socket = context.settings.worker.test_executor_socket
    socket_root = Path.dirname(socket)
    assert {:ok, ^socket} = SymphonyElixir.PathSafety.canonicalize(socket)
    assert byte_size(socket) < 104
    assert Bitwise.band(File.stat!(socket_root).mode, 0o777) == 0o700

    other_root = File.cd!(checkout, &SymphonyElixir.TestSupport.routine_socket_root/0)
    refute other_root == socket_root
    marker = Path.join(other_root, "owned-by-another-run")
    File.write!(marker, "preserve")
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
    await_routine_result(socket, request)
    :ok = stop_supervised(SymphonyElixir.TestExecutor)
    File.rm_rf!(socket_root)
    refute File.exists?(socket_root)
    assert File.read!(marker) == "preserve"
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

  test "managed early owner failure recovers the old run before permitting another start", ctx do
    {context, config, request} = routine_context(ctx)
    startup = %{context | assignee_ids: nil}
    parent = self()

    runner = fn job, contexts, settings, _runtime, owner ->
      source = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}
      source = if job["cleanup"], do: %{}, else: source
      result = RoutineTest.run(job, contexts, settings, source, owner)
      send(parent, {:early_result, result})
      Map.put(result, "evidence", "fixture")
    end

    :sys.replace_state(SymphonyElixir.ProjectPoller, &Keyword.put(&1, :context, startup))
    start_supervised!({SymphonyElixir.TestExecutor, contexts: [startup], name: __MODULE__.Executor, runner: runner})
    socket = context.settings.worker.test_executor_socket
    assert {:ok, _} = TestTool.request(socket, request)
    assert_receive {:early_result, %{"status" => "failed", "cleanup" => false}}, 5_000
    await_routine_result(socket, request)
    directory = Path.join([config["result_root"], request["issue_id"], request["run_id"]])
    for file <- ~w(plan.json control.json fixtures.json), do: refute(File.exists?(Path.join(directory, file)))
    next = %{request | "run_id" => "after-early-cleanup"}
    assert {:error, {:test_executor_rejected, "test_environment_needs_cleanup"}} = TestTool.request(socket, next)

    :sys.replace_state(SymphonyElixir.ProjectPoller, &Keyword.put(&1, :context, context))
    assert {:ok, _} = TestTool.request(socket, %{request | "operation" => "cleanup"})
    assert_receive {:early_result, recovered}, 5_000
    assert recovered["status"] == "failed"
    assert recovered["cleanup"]
    assert recovered["fixtures"] == []
    assert recovered["source"]["sha"] == request["head_sha"]
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 0
    await_routine_result(socket, request)
    cleanup_request = %{request | "operation" => "cleanup"}
    assert {:ok, %{"status" => "failed", "cleanup" => true}} = TestTool.request(socket, cleanup_request)
    assert {:ok, _} = TestTool.request(socket, next)
    assert_receive {:early_result, %{"status" => "passed", "cleanup" => true}}, 5_000
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 1
  end

  test "early routine recovery preserves damaged or foreign fixture journals", ctx do
    {context, config, request} = routine_context(ctx)

    for kind <- ["corrupt", "foreign"] do
      job = routine_job(config, %{request | "run_id" => "early-" <> kind})
      recovery = %{job | "cleanup" => true}
      assert RoutineTest.run(recovery, [context], config, %{}, self())["cleanup"]
      {:ok, plan} = DurableState.read(Path.join(job["directory"], "plan.json"))
      {:ok, journal} = TestRun.routine_journal(context, plan, job["directory"])
      foreign = Jason.encode!(Map.put(journal, "source", %{"sha" => "foreign"}))
      bytes = if kind == "corrupt", do: "invalid", else: foreign
      path = Path.join(job["directory"], "fixtures.json")
      File.write!(path, bytes)
      result = RoutineTest.run(recovery, [context], config, %{}, self())
      refute result["cleanup"]
      assert result["status"] == "failed"
      assert File.read!(path) == bytes
    end

    assert count_calls(ctx.source_agent, "CreateTestFixture") == 0
    assert count_calls(ctx.source_agent, "DeleteTestFixture") == 0
  end

  defp await_routine_result(socket, request, attempts \\ 100) do
    assert attempts > 0
    assert {:ok, result} = TestTool.request(socket, %{request | "operation" => "result"})

    if result["running"] do
      Process.sleep(20)
      await_routine_result(socket, request, attempts - 1)
    end
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

  test "routine cleanup ignores isolated PO receipts with the same run ID", ctx do
    {context, config, request} = routine_context(ctx)
    job = routine_job(config, request)
    plan = %{"instance" => "routine", "run_id" => request["run_id"], "scenario" => "bootstrap", "source" => ctx.plan["source"]}

    paths =
      for directory <- ["derived", "yolo-workspaces"] do
        path = Path.join([ctx.root, "test-state", "runs", plan["run_id"], directory, "foreign.json"])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "foreign receipt")
        path
      end

    stage = fn operation ->
      TestRun.with_routine(context, plan, job["directory"], operation, fn -> TestRun.execute(operation) end)
    end

    assert {:ok, _} = stage.("prepare")
    complete(ctx.source_agent)
    assert {:ok, %{"fixtures" => [%{"complete" => true}]}} = stage.("probe")
    assert {:ok, %{"fixtures" => [%{"deleted" => true}]}} = stage.("cleanup")
    assert Enum.all?(paths, &(File.read!(&1) == "foreign receipt"))
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

  test "a transient probe transport failure recovers without recreating fixtures", ctx do
    {context, config, request} = routine_context(ctx)
    job = routine_job(config, request)
    inject_probe_responses(ctx, [{:error, :offline}, :pass])

    runtime = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}
    result = RoutineTest.run(job, [context], config, runtime, self())
    assert result["status"] == "passed", inspect(result)
    assert result["cleanup"]
    assert map_size(result["sessions"]) == 1
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 1
    assert count_calls(ctx.source_agent, "DeleteTestFixture") == 1
  end

  test "temporary HTTP probe failures recover after both bounded delays", ctx do
    {context, config, request} = routine_context(ctx)
    inject_probe_responses(ctx, [http_probe_error(503), http_probe_error(504), :pass])
    runtime = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}
    result = RoutineTest.run(routine_job(config, request), [context], config, runtime, self())
    assert result["status"] == "passed", inspect(result)
    assert result["cleanup"]
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 1
    assert count_calls(ctx.source_agent, "DeleteTestFixture") == 1
  end

  test "managed exhausted probe retries expose their cause and keep failure after cleanup", ctx do
    {context, _config, request} = routine_context(ctx)
    inject_probe_responses(ctx, [{:error, :offline}])
    parent = self()

    runner = fn job, contexts, settings, _runtime, owner ->
      runtime = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}
      result = RoutineTest.run(job, contexts, settings, runtime, owner)
      send(parent, {:retried_result, result})
      Map.put(result, "evidence", "fixture")
    end

    start_supervised!({SymphonyElixir.TestExecutor, contexts: [context], name: __MODULE__.Executor, runner: runner})
    socket = context.settings.worker.test_executor_socket
    assert {:ok, _} = TestTool.request(socket, request)
    assert_receive {:retried_result, result}, 12_000
    assert result["status"] == "failed", inspect(result)
    assert result["error"] == "linear_temporarily_unavailable", inspect(result)
    assert result["cleanup"]
    assert result["cleanup_error"] == nil
    assert result["originals_preserved"]
    assert result["run_id"] == request["run_id"]
    assert result["source"] == %{"checkout" => request["checkout"], "sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}
    assert [%{"deleted" => true}] = result["fixtures"]
    assert Agent.get(ctx.source_agent, & &1.probe_attempts) == 3
    assert_receive {:probe_attempt, 1, probe}
    assert_receive {:probe_attempt, 2, ^probe}
    assert_receive {:probe_attempt, 3, ^probe}
    refute Process.alive?(probe)
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 1
    assert count_calls(ctx.source_agent, "DeleteTestFixture") == 1
    await_routine_result(socket, request)
    assert {:ok, %{"status" => "failed", "cleanup" => true, "failure" => "linear_temporarily_unavailable"}} = TestTool.request(socket, %{request | "operation" => "cleanup"})
    assert Agent.get(ctx.source_agent, & &1.probe_attempts) == 3
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 1
    assert count_calls(ctx.source_agent, "DeleteTestFixture") == 1
    refute_receive {:probe_attempt, _, _}
  end

  for {status, expected} <- [{401, "linear_access_denied"}, {403, "linear_access_denied"}, {429, "linear_rate_limited"}, {400, "preflight_or_runtime_failed"}] do
    @tag probe_http_status: status, expected_error: expected
    test "probe HTTP #{status} fails without retries", ctx do
      {context, config, request} = routine_context(ctx)
      inject_probe_responses(ctx, [http_probe_error(ctx.probe_http_status)])
      runtime = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}
      result = RoutineTest.run(routine_job(config, request), [context], config, runtime, self())
      assert result["status"] == "failed"
      assert result["error"] == ctx.expected_error
      assert Agent.get(ctx.source_agent, & &1.probe_attempts) == 1
      assert count_calls(ctx.source_agent, "CreateTestFixture") == 1
    end
  end

  test "a GraphQL validation failure on HTTP 503 is never retried", ctx do
    {context, config, request} = routine_context(ctx)
    response = {:ok, %{status: 503, body: %{"errors" => [%{"message" => "invalid", "extensions" => %{"code" => "BAD_USER_INPUT"}}]}}}
    inject_probe_responses(ctx, [response])
    runtime = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}
    result = RoutineTest.run(routine_job(config, request), [context], config, runtime, self())
    assert result["status"] == "failed"
    assert result["error"] == "preflight_or_runtime_failed"
    assert Agent.get(ctx.source_agent, & &1.probe_attempts) == 1
    assert result["cleanup"]
  end

  for outcome <- ["cancelled", "timeout"] do
    @tag retry_outcome: outcome
    test "#{outcome} interrupts probe backoff before another request", ctx do
      {context, config, request} = routine_context(ctx)
      inject_probe_responses(ctx, [{:error, :offline}])
      timeout = if ctx.retry_outcome == "timeout", do: 1, else: 30
      runtime = %{"sha" => request["head_sha"], "source_sha256" => request["source_sha256"]}
      job = routine_job(config, request)
      task = Task.async(fn -> RoutineTest.run(job, [context], %{config | "timeout" => timeout}, runtime, self()) end)
      assert_receive {:probe_attempt, 1, probe}, 2_000
      if ctx.retry_outcome == "cancelled", do: Process.send_after(task.pid, :cancel_test, 100)
      assert {:ok, result} = Task.yield(task, 1_500)
      assert result["status"] == "failed"
      assert result["error"] == ctx.retry_outcome
      assert result["cleanup"]
      refute Process.alive?(probe)
      assert Agent.get(ctx.source_agent, & &1.probe_attempts) == 1
      assert count_calls(ctx.source_agent, "DeleteTestFixture") == 1
    end
  end

  defp http_probe_error(status), do: {:ok, %{status: status, body: "fixture failure"}}

  defp inject_probe_responses(ctx, responses) do
    request_fun = Application.fetch_env!(:symphony_elixir, :linear_client_request_fun)
    parent = self()

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, headers ->
      if TestRun.stage() == "probe" and (payload["query"] || payload[:query]) =~ "query TestFixture(" do
        attempt = next_probe_attempt(ctx.source_agent)

        send(parent, {:probe_attempt, attempt, self()})

        probe_response(Enum.at(responses, attempt - 1, List.last(responses)), request_fun, payload, headers)
      else
        request_fun.(payload, headers)
      end
    end)
  end

  defp probe_response(:pass, request_fun, payload, headers), do: request_fun.(payload, headers)
  defp probe_response(response, _request_fun, _payload, _headers), do: response

  defp next_probe_attempt(source) do
    Agent.get_and_update(source, fn state ->
      attempt = Map.get(state, :probe_attempts, 0) + 1
      {attempt, Map.put(state, :probe_attempts, attempt)}
    end)
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

    socket_root = SymphonyElixir.TestSupport.routine_socket_root()
    context = put_in(context.settings.worker.test_executor, config)
    context = put_in(context.settings.worker.test_executor_socket, Path.join(socket_root, "e.sock"))
    context = %{context | test_instance: nil}
    workspace = Path.join(context.settings.workspace.root, "PRO-769")
    git!(context.root, ["worktree", "add", "-qb", "symphony/PRO-769", workspace])
    {json, 0} = System.cmd("python3", [Path.expand("../../scripts/test-instance.py", __DIR__), "source", workspace])
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

  test "CLI probe preserves the app failure, stops without retry and leaves the fixture journal recoverable", ctx do
    assert {:ok, prepared} = TestRun.execute("prepare")
    journal_path = Path.join([ctx.root, "test-state", "runs", "fixture-run", "fixtures.json"])
    before = File.read!(journal_path)
    calls = count_calls(ctx.source_agent, "TestFixture(")
    Agent.update(ctx.source_agent, &%{&1 | failure: :probe_transport})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        output =
          ExUnit.CaptureIO.capture_io(fn ->
            assert {:error, message} = SymphonyElixir.CLI.run_test_stage("probe", fn -> :ok end)
            assert message =~ "Laufjournal erhalten"
          end)

        assert output == "Test run failure={\"code\":\"linear_app_request_unavailable\"}\n"
        refute output =~ "Test run result="
      end)

    assert log =~ "reason=timeout elapsed_ms="
    assert log =~ "stage=probe run_id=fixture-run"
    first = hd(prepared["fixtures"])
    assert log =~ "issue_id=#{first["id"]} issue_identifier=#{first["identifier"]}"
    assert count_calls(ctx.source_agent, "TestFixture(") == calls + 1
    assert File.read!(journal_path) == before
    Agent.update(ctx.source_agent, &%{&1 | failure: nil})

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = SymphonyElixir.CLI.run_test_stage("cleanup", fn -> :ok end)
      end)

    assert "Test run result=" <> json = output
    assert Enum.all?(Jason.decode!(json)["fixtures"], & &1["deleted"])
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

  test "delegation scenario gates only its fixture and verifies events with unchanged human ownership", ctx do
    {contexts, context, target} = prepare_delegation(ctx)
    assert target["test_delegate_id"] == "fixture-agent"
    System.put_env("SYMPHONY_TEST_RUN_STAGE", "run")
    issue = %Issue{id: target["id"], state: "Todo (AI)", assignee_id: @human}
    refute TestRun.start_allowed?(issue)
    assert TestRun.start_allowed?(%{issue | delegate_id: "fixture-agent"})
    refute TestRun.start_allowed?(%{issue | delegate_id: "other"})
    refute TestRun.start_allowed?(%{issue | id: "unrelated"})
    assert {:ok, journal} = TestRun.execute("probe")
    assert length(journal["fixtures"]) == 1
    assert {:ok, bound} = TestRun.bind_contexts(contexts)
    assert Enum.all?(bound, &(length(&1.settings.tracker.app["allowed_issue_ids"]) == 1))

    cache_delegation(context, target, nil, 1)
    assert {:ok, _} = TestRun.execute("delegate")
    assert get_in(Agent.get(ctx.source_agent, & &1.issues), [target["id"], "delegate", "id"]) == "fixture-agent"
    assert {:ok, unchanged} = TestRun.execute("probe")
    refute Enum.any?(unchanged["fixtures"], & &1["delegation_assigned"])
    cache_delegation(context, target, "fixture-agent", 2)
    assert {:ok, assigned} = TestRun.execute("probe")
    assert Enum.any?(assigned["fixtures"], & &1["delegation_assigned"])
    assert {:ok, _} = TestRun.execute("withdraw")
    assert get_in(Agent.get(ctx.source_agent, & &1.issues), [target["id"], "delegate", "id"]) == nil
    cache_delegation(context, target, nil, 3)
    assert {:ok, withdrawn} = TestRun.execute("probe")
    assert Enum.any?(withdrawn["fixtures"], & &1["delegation_withdrawn"])
    assert count_calls(ctx.source_agent, "mutation TestDelegation") == 2
    assert {:ok, cleaned} = TestRun.execute("cleanup")
    assert Enum.all?(cleaned["fixtures"], & &1["deleted"])
  end

  test "handoff scenario retains scope until both explicit receipts and undelegation exist", ctx do
    {contexts, context, _} = prepare_delegation(ctx, "po_handoff")
    assert {:ok, prepared} = TestRun.execute("prepare")
    assert length(prepared["fixtures"]) == 3
    members = Enum.filter(prepared["fixtures"], & &1["po_handoff"])
    assert Enum.sort(Enum.map(members, & &1["initial_state"])) == ["BLOCKER", "Yolo Review"]
    System.put_env("SYMPHONY_TEST_RUN_STAGE", "run")
    assert {:ok, bound} = TestRun.bind_contexts(contexts)
    assert length(Enum.find(bound, &(&1.name == context.name)).settings.tracker.app["allowed_issue_ids"]) == 3
    for member <- members, do: assert(TestRun.review_fixture?(member["id"]))
    refute TestRun.review_fixture?("foreign")

    for member <- members do
      issue = %Issue{id: member["id"], state: member["initial_state"], delegate_id: "fixture-agent"}
      assert TestRun.start_allowed?(issue)
      refute TestRun.start_allowed?(%{issue | state: "In Arbeit (AI)"})
      refute TestRun.start_allowed?(%{issue | delegate_id: nil})

      ProjectContext.with_context(context, fn ->
        group = if member["initial_state"] == "Yolo Review", do: "review", else: "blocker"
        {:ok, record} = YoloStore.read(group)
        assert {:ok, ^member} = PoHandoff.probe(%{}, member)

        :ok =
          YoloStore.write(
            group,
            Map.put(record, "attempt", %{
              "session_id" => "handoff-" <> group,
              "completed" => %{member["id"] => "actual checks"},
              "sha" => "merged-sha",
              "workspace" => "separate-checkout"
            })
          )

        node = %{"state" => %{"name" => member["initial_state"]}, "assignee" => %{"id" => @human}, "delegate" => %{"id" => "fixture-agent"}}
        assert {:ok, ^member} = PoHandoff.probe(node, member)
        assert {:ok, checked} = PoHandoff.probe(node |> Map.put("delegate", nil) |> put_in(["state", "name"], if(member["initial_state"] == "Yolo Review", do: "Review", else: "BLOCKER")), member)
        assert checked["handoff_receipt"]["sha"] == "merged-sha"

        if member["initial_state"] == "Yolo Review" do
          waiting = Map.put(member, "po_followup", true)
          assert {:ok, waited} = PoHandoff.probe(node, waiting)
          assert waited["handoff_receipt"]["sha"] == "merged-sha"
          assert {:ok, ^waiting} = PoHandoff.probe(Map.put(node, "delegate", nil), waiting)
        end

        File.write!(YoloStore.path(group), "corrupt")
        assert {:error, :yolo_state_corrupt} = PoHandoff.probe(node, member)
      end)
    end

    assert {:ok, cleaned} = TestRun.execute("cleanup")
    assert Enum.all?(cleaned["fixtures"], & &1["deleted"])
    refute TestRun.review_fixture?(hd(members)["id"])
  end

  test "mixed PO scenario reserves exactly three project members and a separate bootstrap", ctx do
    {contexts, context, _} = prepare_delegation(ctx, "po_incoming")
    assert {:ok, prepared} = TestRun.execute("prepare")
    assert length(prepared["fixtures"]) == 4
    members = Enum.filter(prepared["fixtures"], & &1["po_incoming"])
    assert Enum.sort(Enum.map(members, & &1["initial_state"])) == ["Backlog", "Definiert", "Todo"]
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 4
    System.put_env("SYMPHONY_TEST_RUN_STAGE", "run")
    assert {:ok, bound} = TestRun.bind_contexts(contexts)
    project = Enum.find(bound, &(&1.name == context.name))
    assert length(project.settings.tracker.app["allowed_issue_ids"]) == 4

    for member <- members do
      issue = %Issue{id: member["id"], state: member["initial_state"], delegate_id: "fixture-agent"}
      assert TestRun.start_allowed?(issue)
      refute TestRun.start_allowed?(%{issue | state: "In Arbeit (AI)"})
      refute TestRun.start_allowed?(%{issue | delegate_id: nil})
    end

    assert {:ok, pending} = TestRun.execute("probe")
    refute Enum.any?(pending["fixtures"], & &1["complete"])

    ProjectContext.with_context(context, fn ->
      alias SymphonyElixir.Yolo.Store
      {:ok, record} = Store.read("incoming")
      completed = Map.new(members, &{&1["id"], "Verworfen: bereits erfüllt"})
      :ok = Store.write("incoming", Map.put(record, "attempt", %{"completed" => completed, "session_id" => "one-session", "sha" => "merged-sha", "workspace" => "owned-workspace"}))
    end)

    Agent.update(ctx.source_agent, fn state ->
      issues =
        Map.new(state.issues, fn {id, issue} ->
          if Enum.any?(members, &(&1["id"] == id)) do
            {id,
             Map.merge(issue, %{
               "state" => %{"name" => "Verworfen"},
               "assignee" => %{"id" => @human},
               "labels" => %{"nodes" => Enum.map([~s(Skip "Freigabe Implementierung"), ~s(Skip "Freigabe Review")], &%{"name" => &1})}
             })}
          else
            {id, issue}
          end
        end)

      %{state | issues: issues}
    end)

    assert {:ok, receipts} = TestRun.execute("probe")
    assert Enum.all?(Enum.filter(receipts["fixtures"], & &1["po_incoming"]), &(&1["po_receipt"]["session_id"] == "one-session"))

    ProjectContext.with_context(context, fn ->
      File.write!(YoloStore.path("incoming"), "corrupt")
    end)

    assert {:error, :yolo_state_corrupt} = TestRun.execute("probe")
    assert {:ok, cleaned} = TestRun.execute("cleanup")
    assert Enum.all?(cleaned["fixtures"], & &1["deleted"])
  end

  test "one probe reuses its verified PO context but the next probe resolves freshly", ctx do
    {contexts, _, _} = prepare_delegation(ctx, "po_aggregation")
    unresolved = unresolved_contexts(contexts)
    Application.put_env(:symphony_elixir, :project_contexts, unresolved)
    Agent.update(ctx.source_agent, &%{&1 | calls: []})

    assert {:ok, pending} = TestRun.execute("probe")
    refute Enum.any?(pending["fixtures"], & &1["complete"])
    assert count_calls(ctx.source_agent, "SymphonyHumanAssignees") == 1
    assert count_calls(ctx.source_agent, "SymphonyYoloAgent") == 1
    assert count_calls(ctx.source_agent, "TestFixture(") == 4
    assert count_calls(ctx.source_agent, "SymphonyLinearIssueComments") == 4
    assert SymphonyElixir.Projects.configured() == unresolved

    assert {:ok, _} = TestRun.execute("probe")
    assert count_calls(ctx.source_agent, "SymphonyHumanAssignees") == 2
    assert count_calls(ctx.source_agent, "SymphonyYoloAgent") == 2
    assert count_calls(ctx.source_agent, "TestFixture(") == 8
    assert count_calls(ctx.source_agent, "SymphonyLinearIssueComments") == 8
    assert count_calls(ctx.source_agent, "mutation") == 0
  end

  test "incoming and handoff probes share only identities and still observe delegation changes", ctx do
    for scenario <- ["po_incoming", "po_handoff", "po_followup"] do
      {contexts, _, target} = prepare_delegation(ctx, scenario)
      Application.put_env(:symphony_elixir, :project_contexts, unresolved_contexts(contexts))
      Agent.update(ctx.source_agent, &%{&1 | calls: []})
      assert {:ok, pending} = TestRun.execute("probe")
      refute Enum.any?(pending["fixtures"], & &1["complete"])
      assert count_calls(ctx.source_agent, "SymphonyHumanAssignees") == 1
      assert count_calls(ctx.source_agent, "SymphonyYoloAgent") == 1

      Agent.update(ctx.source_agent, fn state -> put_in(state.issues[target["id"]]["delegate"], %{"id" => "foreign"}) end)
      assert {:error, :test_fixture_changed_externally} = TestRun.execute("probe")
      assert count_calls(ctx.source_agent, "SymphonyYoloAgent") == 2
      Agent.update(ctx.source_agent, fn state -> put_in(state.issues[target["id"]]["delegate"], %{"id" => "fixture-agent"}) end)

      assert {:ok, cleaned} = TestRun.execute("cleanup")
      assert Enum.all?(cleaned["fixtures"], & &1["deleted"])
      assert count_calls(ctx.source_agent, "SymphonyYoloAgent") == 2
      File.rm!(journal_path(ctx.root))
    end
  end

  test "failed probe identity is not retried or retained and cleanup needs no agent lookup", ctx do
    {contexts, _, _} = prepare_delegation(ctx, "po_aggregation")
    Application.put_env(:symphony_elixir, :project_contexts, unresolved_contexts(contexts))
    before = File.read!(journal_path(ctx.root))

    for {failure, error} <- [
          {:agent_timeout, {:linear_api_request, :linear_app_request_unavailable}},
          {:agent_incomplete, :linear_yolo_agent_incomplete_response},
          {:agent_missing, {:linear_yolo_agent_not_found, "Fixture Agent"}}
        ] do
      Agent.update(ctx.source_agent, &%{&1 | calls: [], failure: failure})
      assert {:error, ^error} = TestRun.execute("probe")
      assert count_calls(ctx.source_agent, "SymphonyYoloAgent") == 1
      assert count_calls(ctx.source_agent, "TestFixture(") == 0
      assert count_calls(ctx.source_agent, "mutation") == 0
      assert File.read!(journal_path(ctx.root)) == before
    end

    Agent.update(ctx.source_agent, &%{&1 | calls: [], failure: nil})
    assert {:ok, _} = TestRun.execute("probe")
    assert count_calls(ctx.source_agent, "SymphonyYoloAgent") == 1
    changed = Enum.map(unresolved_contexts(contexts), &put_in(&1.settings.tracker.yolo_agent, "Different"))
    Application.put_env(:symphony_elixir, :project_contexts, changed)
    assert {:error, {:linear_yolo_agent_invalid, "Different"}} = TestRun.execute("probe")
    assert count_calls(ctx.source_agent, "SymphonyYoloAgent") == 2

    Agent.update(ctx.source_agent, &%{&1 | failure: :agent_timeout})
    assert {:ok, cleaned} = TestRun.execute("cleanup")
    assert Enum.all?(cleaned["fixtures"], & &1["deleted"])
    assert count_calls(ctx.source_agent, "SymphonyYoloAgent") == 2
  end

  defp unresolved_contexts(contexts) do
    Enum.map(contexts, fn context ->
      if context.name == "symphony-test",
        do: %{context | assignee_ids: nil, human_handoff_id: nil, yolo_agent_id: nil},
        else: context
    end)
  end

  test "required PO status and complete team pages are checked before any fixture mutation", ctx do
    [context] = ctx.contexts
    context = put_in(context.settings.tracker.yolo_agent, "Fixture Agent")
    context = %{context | yolo_agent_id: "fixture-agent", human_handoff_id: @human}
    Application.put_env(:symphony_elixir, :project_contexts, [context])
    :ok = DurableState.write(ctx.plan_path, Map.put(ctx.plan, "scenario", "po_aggregation"))

    for {failure, expected} <- [
          {:missing_aggregate_state, {:test_scenario_states_unavailable, ["Umsetzungsticket erstellt"]}},
          {:duplicate_aggregate_state, {:test_scenario_states_unavailable, ["Umsetzungsticket erstellt"]}},
          {:incomplete_states, :yolo_page_incomplete},
          {:multiple_teams, :test_scenario_team_unconfirmed},
          {:states_transport, {:linear_api_request, :linear_app_request_unavailable}}
        ] do
      Agent.update(ctx.source_agent, &%{&1 | calls: [], failure: failure})
      assert {:error, ^expected} = TestRun.execute("prepare")
      assert count_calls(ctx.source_agent, "mutation") == 0
      refute File.exists?(journal_path(ctx.root))
    end

    Agent.update(ctx.source_agent, &%{&1 | calls: [], failure: :paged_states})
    assert {:ok, prepared} = TestRun.execute("prepare")
    assert count_calls(ctx.source_agent, "TestScenarioStates") == 2
    assert length(prepared["fixtures"]) == 4
    assert Enum.all?(prepared["fixtures"], &(&1["project"] == "symphony-test"))
    bootstrap = Enum.find(prepared["fixtures"], &(&1["initial_state"] == "Todo (AI)"))
    refute bootstrap["test_delegate_id"]
    refute bootstrap["po_aggregation"]
    System.put_env("SYMPHONY_TEST_RUN_STAGE", "run")
    assert TestRun.start_allowed?(%Issue{id: bootstrap["id"], state: "Todo (AI)"})
    assert {:ok, [_]} = TestRun.bind_contexts([context])

    for fixtures <- [tl(prepared["fixtures"]), Enum.map(prepared["fixtures"], &Map.put(&1, "initial_state", "Todo (AI)")), List.replace_at(prepared["fixtures"], 0, List.last(prepared["fixtures"]))] do
      :ok = DurableState.write(journal_path(ctx.root), Map.put(prepared, "fixtures", fixtures))
      assert {:error, :test_fixtures_not_prepared} = TestRun.bind_contexts([context])
    end

    :ok = DurableState.write(journal_path(ctx.root), prepared)
    assert {:ok, _} = TestRun.execute("cleanup")
  end

  test "delegation preflight and scenario replacement fail before creating or adopting fixtures", ctx do
    :ok = DurableState.write(ctx.plan_path, Map.put(ctx.plan, "scenario", "delegation"))
    assert {:error, :test_agent_delegation_unavailable} = TestRun.execute("prepare")
    assert count_calls(ctx.source_agent, "CreateTestFixture") == 0
    :ok = DurableState.write(ctx.plan_path, ctx.plan)
    assert {:ok, _} = TestRun.execute("prepare")
    :ok = DurableState.write(ctx.plan_path, Map.put(ctx.plan, "scenario", "delegation"))
    assert {:error, :test_journal_identity_mismatch} = TestRun.execute("probe")
    :ok = DurableState.write(ctx.plan_path, Map.put(ctx.plan, "scenario", "unknown"))
    assert {:error, :invalid_public_test_plan} = TestRun.execute("prepare")
  end

  test "derived scenarios prepare only their original members and retain strict phase bounds", ctx do
    for scenario <- ["po_aggregation", "po_followup"] do
      {contexts, context, _} = prepare_delegation(ctx, scenario)
      assert {:ok, prepared} = TestRun.execute("prepare")
      members = Enum.filter(prepared["fixtures"], &(&1["test_delegate_id"] != nil))
      assert length(members) == if(scenario == "po_aggregation", do: 3, else: 1)
      assert Enum.all?(members, &(&1["test_delegate_id"] == "fixture-agent"))
      assert Enum.all?(members, &String.contains?(&1["description"], "po-proof-fixture-run.md"))
      System.put_env("SYMPHONY_TEST_RUN_STAGE", "run")
      assert {:ok, bound} = TestRun.bind_contexts(contexts)
      bound_context = Enum.find(bound, &(&1.name == context.name))
      assert length(bound_context.settings.tracker.app["allowed_issue_ids"]) == length(members) + 1
      first = hd(members)
      assert TestRun.start_allowed?(%Issue{id: first["id"], state: first["initial_state"], delegate_id: "fixture-agent"})
      refute TestRun.start_allowed?(%Issue{id: first["id"], state: "In Arbeit (AI)", delegate_id: "fixture-agent"})
      refute TestRun.start_allowed?(%Issue{id: "child", state: first["initial_state"], delegate_id: "fixture-agent"})
      assert {:ok, _} = TestRun.execute("probe")
      assert {:ok, cleaned} = TestRun.execute("cleanup")
      assert Enum.all?(cleaned["fixtures"], & &1["deleted"])
      File.rm!(Path.join([ctx.root, "test-state", "runs", "fixture-run", "fixtures.json"]))
      System.put_env("SYMPHONY_TEST_RUN_STAGE", "prepare")
    end
  end

  test "isolated aggregation permits only journal-bound closed origins for recovery", ctx do
    {contexts, context, first} = prepare_delegation(ctx, "po_aggregation")
    System.put_env("SYMPHONY_TEST_RUN_STAGE", "run")
    assert {:ok, [bound]} = TestRun.bind_contexts(contexts)

    ProjectContext.with_context(bound, fn ->
      alias SymphonyElixir.Yolo.Operations
      closed = %Issue{id: first["id"], state: "Umsetzungsticket erstellt", delegate_id: "fixture-agent"}
      source = %{"title" => nil, "description" => nil, "project_id" => nil, "team_id" => nil, "assignee_id" => nil, "delegate_id" => "fixture-agent"}
      refute TestRun.start_allowed?(closed)

      assert :ok =
               Operations.run("recovery-gate", %{"kind" => "aggregate", "origin_ids" => [closed.id]}, fn intent ->
                 Operations.save(Map.merge(intent, %{"closing" => [closed.id], "sources" => %{closed.id => source}}))
               end)

      assert TestRun.start_allowed?(closed)
      refute TestRun.start_allowed?(%{closed | delegate_id: nil})
      refute TestRun.start_allowed?(%{closed | title: "changed"})
      {:ok, [intent]} = Operations.pending([closed.id])
      :ok = Operations.save(Map.put(intent, "done", true))
      refute TestRun.start_allowed?(closed)
    end)

    assert context.id == bound.id
    assert {:ok, _} = TestRun.execute("cleanup")
  end

  defp prepare_delegation(ctx, scenario \\ "delegation") do
    plan = Map.put(ctx.plan, "scenario", scenario)
    :ok = DurableState.write(ctx.plan_path, plan)

    contexts =
      Enum.map(ctx.contexts, fn context ->
        if context.name == "symphony-test" do
          context = put_in(context.settings.tracker.yolo_agent, "Fixture Agent")
          %{context | yolo_agent_id: "fixture-agent", human_handoff_id: @human}
        else
          context
        end
      end)

    Application.put_env(:symphony_elixir, :project_contexts, contexts)
    assert {:ok, prepared} = TestRun.execute("prepare")
    target = Enum.find(prepared["fixtures"], &(&1["test_delegate_id"] != nil))
    context = Enum.find(contexts, &(&1.name == target["project"]))
    {contexts, context, target}
  end

  test "uncertain writes and invalid cache observations cannot report a delegation pass", ctx do
    alias SymphonyElixir.TestRun.Delegation
    {_contexts, context, target} = prepare_delegation(ctx)
    plan = Map.put(ctx.plan, "scenario", "delegation")
    assert {:error, :test_agent_project_missing} = Delegation.preflight([], plan)
    {:ok, journal} = DurableState.read(journal_path(ctx.root))

    for change <- [&Map.delete(&1, "test_delegate_id"), &Map.put(&1, "test_delegate_id", nil), &Map.put(&1, "test_delegate_id", "")] do
      incomplete = Map.update!(journal, "fixtures", &Enum.map(&1, change))
      :ok = DurableState.write(journal_path(ctx.root), incomplete)
      assert {:error, :test_delegation_fixture_unconfirmed} = TestRun.execute("delegate")
      assert count_calls(ctx.source_agent, "mutation TestDelegation") == 0
    end

    :ok = DurableState.write(journal_path(ctx.root), journal)
    assert {:error, :test_delegation_cache_unconfirmed} = TestRun.execute("delegate")
    cache_delegation(context, target, "fixture-agent", 1)
    assert {:error, :test_initial_delegation_unconfirmed} = TestRun.execute("delegate")
    assert {:error, :test_assigned_delegation_unconfirmed} = TestRun.execute("withdraw")
    cache_delegation(context, target, nil, 1)

    assert {:error, :test_delegation_changed_externally} =
             Delegation.change("delegate", %{"delegate" => %{"id" => "foreign"}}, context, target)

    Agent.update(ctx.source_agent, &%{&1 | failure: :reject_delegation})
    assert {:error, :test_delegation_write_unconfirmed} = TestRun.execute("delegate")
    Agent.update(ctx.source_agent, &%{&1 | failure: :lost_delegation})
    assert {:error, _} = TestRun.execute("delegate")
    Agent.update(ctx.source_agent, &%{&1 | failure: nil})
    assert {:ok, _} = TestRun.execute("delegate")
    assert count_calls(ctx.source_agent, "mutation TestDelegation") == 2

    cache_delegation(context, target, "fixture-agent", 2, 100)
    assert {:ok, snapshot} = TestRun.execute("probe")
    refute Enum.any?(snapshot["fixtures"], & &1["delegation_assigned"])
    cache_delegation(context, target, "fixture-agent", "invalid")
    assert {:error, :test_delegation_cache_unconfirmed} = TestRun.execute("probe")
    Agent.update(ctx.source_agent, &%{&1 | failure: :transport})
    assert {:error, _} = Delegation.preflight([context], plan)
    Agent.update(ctx.source_agent, &%{&1 | failure: nil})
    assert {:ok, _} = TestRun.execute("cleanup")
  end

  defp cache_delegation(context, fixture, delegate, cursor, reconcile_at \\ 99) do
    alias SymphonyElixir.Relay.Store
    tracker = context.settings.tracker
    {:ok, consumer} = Store.identity(tracker.relay, tracker.app["workspace_id"])
    path = Store.path(tracker.relay, tracker.app["workspace_id"], consumer)
    {:ok, record} = DurableState.read(path)
    node = %{"id" => fixture["id"], "assignee" => %{"id" => @human}, "delegate" => if(delegate, do: %{"id" => delegate})}
    record = Map.merge(record, %{"phase" => "ready", "dirty" => [], "cursor" => cursor, "reconcile_at" => reconcile_at, "issues" => %{fixture["id"] => node}, "epochs" => %{fixture["id"] => cursor}})
    :ok = DurableState.write(path, record)
  end

  defp respond_query("query TestScenarioTeams" <> _, _variables, state) do
    teams = if state.failure == :multiple_teams, do: [%{"id" => "team"}, %{"id" => "other"}], else: [%{"id" => "team"}]
    answer(%{"project" => %{"teams" => page(teams)}}, state)
  end

  defp respond_query("query TestScenarioStates" <> _, _variables, %{failure: :states_transport} = state), do: {{:error, :offline}, state}

  defp respond_query("query TestScenarioStates" <> _, variables, state) do
    names = ["Todo (AI)", "Planung (AI)", "Backlog", "Todo", "Definiert", "BLOCKER", "Yolo Review", "Review", "Verworfen", "Umsetzungsticket erstellt"]
    nodes = Enum.map(names, &%{"id" => &1, "name" => &1})

    result =
      case state.failure do
        :missing_aggregate_state ->
          page(Enum.reject(nodes, &(&1["name"] == "Umsetzungsticket erstellt")))

        :duplicate_aggregate_state ->
          page(nodes ++ [%{"id" => "duplicate", "name" => "Umsetzungsticket erstellt"}])

        :incomplete_states ->
          %{"nodes" => nodes}

        :paged_states ->
          if variables["after"] == nil,
            do: %{"nodes" => Enum.take(nodes, 4), "pageInfo" => %{"hasNextPage" => true, "endCursor" => "next"}},
            else: page(Enum.drop(nodes, 4))

        _ ->
          page(nodes)
      end

    answer(%{"team" => %{"states" => result}}, state)
  end

  defp respond_query("query TestDelegationSchema" <> _, _variables, state) do
    answer(%{"__type" => %{"inputFields" => [%{"name" => "delegateId"}]}}, state)
  end

  defp respond_query("query SymphonyYoloAgent" <> _, _variables, %{failure: :agent_timeout} = state),
    do: {{:error, %Req.TransportError{reason: :timeout}}, state}

  defp respond_query("query SymphonyYoloAgent" <> _, _variables, %{failure: :agent_incomplete} = state),
    do: answer(%{"users" => %{"nodes" => []}}, state)

  defp respond_query("query SymphonyYoloAgent" <> _, _variables, %{failure: :agent_missing} = state),
    do: answer(%{"users" => page([])}, state)

  defp respond_query("query SymphonyYoloAgent" <> _, _variables, state) do
    answer(%{"users" => page([%{"id" => "fixture-agent", "name" => "Fixture Agent", "app" => true, "active" => true, "isAssignable" => true}])}, state)
  end

  defp respond_query("mutation TestDelegation" <> _, variables, state) do
    assert Map.keys(variables["input"]) == ["delegateId"]
    delegate = variables["input"]["delegateId"]
    updated = put_in(state.issues[variables["id"]]["delegate"], if(delegate, do: %{"id" => delegate}))

    case state.failure do
      :reject_delegation -> answer(%{"issueUpdate" => %{"success" => false}}, state)
      :lost_delegation -> {{:error, :lost_response}, updated}
      _ -> answer(%{"issueUpdate" => %{"success" => true, "issue" => updated.issues[variables["id"]]}}, updated)
    end
  end

  defp respond_query("query TestFixture(" <> _, _variables, %{failure: :probe_transport} = state),
    do: {{:error, %Req.TransportError{reason: :timeout}}, state}

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
            "nodes" => [
              %{
                "id" => "team",
                "states" => %{
                  "nodes" => Enum.map(["Todo (AI)", "Backlog", "Todo", "Definiert", "BLOCKER", "Yolo Review", "Review"], &%{"id" => if(&1 == "Todo (AI)", do: "todo", else: &1), "name" => &1})
                }
              }
            ]
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
  defp schema_fields(_), do: Enum.map(~w(id title description teamId projectId assigneeId delegateId stateId), &%{"name" => &1})

  defp create_response(input, state) do
    issue = %{
      "id" => input["id"],
      "identifier" => "PRO-#{map_size(state.issues) + 1}",
      "title" => input["title"],
      "description" => input["description"],
      "project" => %{"id" => input["projectId"]},
      "team" => %{"id" => input["teamId"]},
      "assignee" => if(input["assigneeId"], do: %{"id" => input["assigneeId"]}),
      "delegate" => if(input["delegateId"], do: %{"id" => input["delegateId"]}),
      "state" => %{"name" => if(input["stateId"] == "todo", do: "Todo (AI)", else: input["stateId"])}
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
