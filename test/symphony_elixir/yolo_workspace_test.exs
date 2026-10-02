defmodule SymphonyElixir.YoloWorkspaceTest do
  use SymphonyElixir.TestSupport
  alias Mix.Tasks.Openclaw.Recover, as: RecoverCommand
  alias SymphonyElixir.ProjectContext

  alias SymphonyElixir.Linear.DurableState
  alias SymphonyElixir.TestRun.PoIncoming
  alias SymphonyElixir.Yolo.{Delivery, Nonstart, OpenClaw}
  alias SymphonyElixir.Yolo.OpenClaw.Journal
  alias SymphonyElixir.Yolo.{ReviewCheckouts, Runner, Scope, Store, Workspace}

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(Path.join(root, ".symphony"))
    File.write!(Path.join(root, ".symphony/.env"), "LINEAR_ASSIGNEE=human@example.com\n")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "human@example.com", workspace_root: Path.join(root, "worktrees"))
    {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    ProjectContext.bind(context)
    git(root, ["init", "-b", "main"])
    File.write!(Path.join(root, "tracked"), "merged version")
    git(root, ["add", "tracked"])
    git(root, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"])
    git(root, ["remote", "add", "origin", root])
    Application.put_env(:symphony_elixir, :test_instance_state_root, Path.join(root, "state"))

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :test_instance_state_root)
      System.delete_env("SYMPHONY_TEST_RUN_STAGE")
      System.delete_env("SYMPHONY_TEST_RUN_PLAN")
    end)

    %{root: root, context: context}
  end

  defp git(root, args) do
    assert {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    String.trim(output)
  end

  for scenario <- [:clean, :dirty, :ignored, :journal, :artifacts, :delivery, :completed, :history, :wrong_sha] do
    @tag creating_scenario: scenario
    test "interrupted creating checkout #{scenario} is recovered conservatively before starting", %{root: root, context: context, creating_scenario: scenario} do
      context = %{context | yolo_agent_id: "pai"}
      ProjectContext.bind(put_in(context.settings.tracker.app["state_root"], Path.join(root, "state")))
      id = Ecto.UUID.generate()
      assert {:ok, workspace} = Workspace.create("review", id)
      assert {:ok, record} = Store.read("review")
      attempt = %{"id" => id, "members" => [], "workspace" => workspace.path, "sha" => workspace.sha, "cleanup_contract" => 1, "checkout_cleanup" => "creating"}
      attempt = if scenario == :wrong_sha, do: Map.put(attempt, "sha", String.duplicate("0", 40)), else: attempt
      record = Map.put(record, "attempt", attempt)
      record = if scenario == :delivery, do: Map.put(record, "deliveries", %{"member" => %{"run_id" => id}}), else: record
      record = if scenario == :completed, do: put_in(record, ["attempt", "completed"], %{"member" => "done"}), else: record
      assert :ok = Store.write("review", record)
      if scenario == :dirty, do: File.write!(Path.join(workspace.path, "tracked"), "changed")

      if scenario == :ignored do
        File.write!(Path.join(workspace.path, ".gitignore"), "scratch\n")
        File.write!(Path.join(workspace.path, "scratch"), "keep")
      end

      if scenario == :artifacts, do: File.mkdir_p!(Path.join([context.settings.workspace.root, "yolo-runs", id]))

      if scenario in [:journal, :history] do
        order = %{"id" => id, "group" => "review", "members" => [], "state" => "completed"}
        assert :ok = Journal.write(order)
        if scenario == :history, do: assert(:ok == Journal.write(%{order | "id" => Ecto.UUID.generate()}))
      end

      opts = [fetch: fn _ -> {:error, :fixture_stop} end, project: fn -> {:ok, []} end]
      result = Runner.run("review", [], [], opts)
      assert {:ok, current} = Store.read("review")

      if scenario == :clean do
        assert result == {:error, :fixture_stop}
        assert current["attempt"]["checkout_cleanup"] == "removed"
        refute File.exists?(workspace.path)
        assert {:error, :fixture_stop} = Runner.run("review", [], [], opts)
      else
        expected = if scenario == :delivery, do: :fixture_stop, else: :yolo_review_checkout_cleanup_unconfirmed
        assert result == {:error, expected}
        assert File.dir?(workspace.path)
      end
    end
  end

  for confirmed <- [true, false] do
    @tag cleanup_confirmed: confirmed
    test "removed checkout needs receipt (#{confirmed})", %{root: root, context: context, cleanup_confirmed: confirmed} do
      ProjectContext.bind(put_in(%{context | yolo_agent_id: "pai"}.settings.tracker.app["state_root"], Path.join(root, "state")))
      id = "06401b58-5134-4ed5-8639-bf331fea05dc"
      assert {:ok, workspace} = Workspace.create("review", id)
      {:ok, record} = Store.read("review")
      attempt = %{"id" => id, "members" => [], "workspace" => workspace.path, "sha" => workspace.sha, "cleanup_contract" => 1, "checkout_cleanup" => "pending"}
      attempt = if confirmed, do: Map.put(attempt, "cleanup_proof", Map.take(attempt, ~w(id workspace sha))), else: attempt
      assert :ok = Store.write("review", Map.merge(record, %{"attempt" => attempt, "checkout_cleanup_blocked" => true}))
      assert :ok = Workspace.remove("review", workspace, id)
      result = Store.lock("review", fn -> Nonstart.reconcile("review") end)
      assert {:ok, current} = Store.read("review")

      if confirmed do
        assert result == :ok
        assert current["attempt"]["checkout_cleanup"] == "removed"
        assert :ok = Store.lock("review", fn -> Nonstart.reconcile("review") end)
      else
        assert result == {:error, :yolo_review_checkout_cleanup_unconfirmed}
        assert current["attempt"]["checkout_cleanup"] == "pending"
      end
    end
  end

  test "missing checkout binding and unreadable journal retain the interrupted attempt", %{root: root, context: context} do
    ProjectContext.bind(put_in(%{context | yolo_agent_id: "pai"}.settings.tracker.app["state_root"], Path.join(root, "state")))
    {:ok, record} = Store.read("review")
    attempt = %{"id" => Ecto.UUID.generate(), "members" => [], "cleanup_contract" => 1, "checkout_cleanup" => "creating"}
    assert :ok = Store.write("review", Map.put(record, "attempt", attempt))
    File.mkdir_p!(Path.dirname(Journal.path("review")))
    File.write!(Journal.path("review"), "unreadable fixture")
    refute Nonstart.resolved_external_attempt?("review", attempt)
    assert {:error, :yolo_review_checkout_cleanup_unconfirmed} = Store.lock("review", fn -> Nonstart.reconcile("review") end)
    assert {:ok, %{"attempt" => ^attempt}} = Store.read("review")
  end

  test "V3 operator command checks binding without requiring external source files", %{root: root, context: context} do
    path = Path.join(root, "legacy-binding.json")
    File.write!(path, Jason.encode!(%{"version" => 3, "binding" => %{}}))
    isolated = %{context | env: Map.put(context.env, "SYMPHONY_ROOT_DIR", root)}

    ProjectContext.with_context(isolated, fn ->
      assert_raise Mix.Error, "OpenClaw recovery refused: openclaw_local_nonstart_unconfirmed", fn ->
        RecoverCommand.run(["--project", root, "--evidence", path])
      end
    end)
  end

  @legacy_scenarios [
    :safe,
    :started,
    :observed,
    :session,
    :truncated,
    :offline,
    :snapshots_safe,
    :snapshot_execution,
    :snapshots_empty,
    :snapshots_invalid
  ]
  for scenario <- @legacy_scenarios ++ [:missing_failure, :foreign_failure, :artifacts] do
    @tag legacy_scenario: scenario
    test "legacy proof #{scenario}", %{root: root, context: context, legacy_scenario: scenario} do
      alias SymphonyElixir.Yolo.OpenClaw.{LocalNonstart, Recovery}
      agent = Ecto.UUID.generate()
      member = Ecto.UUID.generate()
      context = %{context | yolo_agent_id: agent, env: Map.put(context.env, "OPENCLAW_YOLO_AGENT", "po")}
      context = put_in(context.settings.tracker.openclaw_yolo_agent, "po")
      context = put_in(context.settings.tracker.app["workspace_id"], Ecto.UUID.generate())
      ProjectContext.bind(put_in(context.settings.tracker.app["state_root"], Path.join(root, "state")))
      id = "e1c7b225-ba82-4baa-a4cf-ff0d1e9effa0"
      assert {:ok, workspace} = Workspace.create("review", id)
      {:ok, record} = Store.read("review")
      attempt = %{"id" => id, "members" => [member], "workspace" => workspace.path, "sha" => workspace.sha, "cleanup_contract" => 1, "checkout_cleanup" => "creating"}
      failure = %{"group" => "review", "run_id" => id, "reason" => "{:linear_api_request, :linear_app_request_unavailable}"}
      failure = if scenario == :foreign_failure, do: Map.put(failure, "run_id", Ecto.UUID.generate()), else: failure
      record = Map.merge(record, %{"attempt" => attempt, "failure" => failure})
      record = if scenario == :missing_failure, do: Map.delete(record, "failure"), else: record
      assert :ok = Store.write("review", record)

      order = %{
        "id" => id,
        "group" => "review",
        "project_id" => context.id,
        "agent" => "po",
        "linear_agent_id" => agent,
        "linear_workspace_id" => context.settings.tracker.app["workspace_id"],
        "members" => [%{"id" => member}],
        "session_id" => "agent:po:symphony:#{OpenClaw.digest(context.id)}:review:#{id}",
        "payload_sha256" => String.duplicate("a", 64),
        "workspace" => workspace.path,
        "sha" => workspace.sha,
        "state" => "cancel_pending",
        "writable" => false,
        "cancel_requested" => true,
        "acceptance_observed" => false,
        "execution_observed" => false,
        "abort_error" => %{"method" => "sessions.abort", "code" => "NOT_LINKED", "reason" => "owner_connection_lost", "retryable" => false}
      }

      order = if scenario == :started, do: Map.put(order, "submit_started", true), else: order
      order = if scenario == :observed, do: Map.put(order, "execution_observed", true), else: order
      order = if scenario == :artifacts, do: Map.put(order, "checkout_proof", %{"bound" => true}), else: order

      order =
        case scenario do
          :snapshots_safe ->
            observation = %{"acceptance_observed" => false, "execution_observed" => false}
            config = %{"producer_id" => "fixture", "consumer_account_id" => "fixture", "key_id" => "fixture"}
            snapshot = %{"sequence" => 1, "projection" => %{"observation" => observation}}
            order |> Map.drop(~w(acceptance_observed execution_observed)) |> Map.put("linear_bridge", %{"config" => config, "snapshots" => [snapshot]})

          :snapshot_execution ->
            observation = %{"acceptance_observed" => false, "execution_observed" => true}
            Map.put(order, "linear_bridge", %{"snapshots" => [%{"projection" => %{"observation" => observation}}]})

          :snapshots_empty ->
            Map.put(order, "linear_bridge", %{"snapshots" => []})

          :snapshots_invalid ->
            Map.put(order, "linear_bridge", %{"snapshots" => [%{"projection" => %{}}]})

          _ ->
            order
        end

      assert :ok = Journal.write(order)

      transport = fn
        ["--version"] ->
          {:ok, "2026.9.4"}

        ["gateway", "call", "agents.list" | _] ->
          {:ok, ~s({"agents":[{"id":"po"}]})}

        ["gateway", "call", "sessions.list", "--params", raw | _] ->
          assert Jason.decode!(raw)["search"] == order["session_id"]
          send(self(), :legacy_session_check)

          case scenario do
            :offline -> {:error, :openclaw_gateway_unavailable}
            :session -> {:ok, Jason.encode!(%{"sessions" => [%{"key" => order["session_id"]}]})}
            :truncated -> {:ok, ~s({"sessions":[],"hasMore":true})}
            _ -> {:ok, ~s({"sessions":[],"count":0})}
          end

        _ ->
          flunk("legacy nonstart must not submit or abort")
      end

      binding = Map.take(order, ~w(id group project_id agent linear_agent_id linear_workspace_id session_id payload_sha256 workspace sha members))
      evidence = %{"version" => 3, "binding" => binding}
      opts = [transport: transport]

      if scenario in [:safe, :snapshots_safe] do
        journal_before = File.read!(Journal.path("review"))
        assert {:ok, %{"state" => "rejected"}} = Recovery.resolve(evidence, false, opts)
        assert File.read!(Journal.path("review")) == journal_before
        operator_context = %{ProjectContext.current() | yolo_agent_id: nil}
        dry_run = fn -> Recovery.resolve(evidence, false, opts) end
        assert {:ok, %{"state" => "rejected"}} = ProjectContext.with_context(operator_context, dry_run)
        assert {:ok, fixed} = LocalNonstart.recover(order, opts)
        assert fixed["local_nonstart"]["failure"] == failure
        assert fixed["before_recovery"]["abort_error"] == order["abort_error"]
        refute fixed["terminal"]
        assert {:ok, ^fixed} = LocalNonstart.recover(fixed, opts)
        assert :ok = Delivery.reconcile("review")
        assert :ok = Store.lock("review", fn -> Nonstart.reconcile("review") end)
        assert :ok = Journal.available("review")
        refute File.exists?(workspace.path)
        assert {:ok, %{"attempt" => %{"checkout_cleanup" => "removed"}}} = Store.read("review")
        next = Map.merge(order, %{"id" => Ecto.UUID.generate(), "state" => "unknown"})
        assert :ok = Journal.write(next)
        assert {:ok, ^fixed} = Recovery.resolve(evidence, true, opts)
        assert {:ok, ^next} = Journal.read("review")
      else
        assert {:error, :openclaw_local_nonstart_unconfirmed} = LocalNonstart.recover(order, opts)
        assert {:ok, ^order} = Journal.read("review")
        assert Journal.pending?(order)
        assert File.dir?(workspace.path)
      end
    end
  end

  test "detached checkout fixes the merged SHA, retains source work and rejects unsafe paths", %{root: root} do
    source_status = git(root, ["status", "--porcelain"])
    run = Ecto.UUID.generate()
    assert {:ok, workspace} = Workspace.create("review", run)
    assert workspace.sha == git(root, ["rev-parse", "main"])
    assert Workspace.unchanged?(workspace)
    refute Workspace.owned_review?(%{}, run)
    assert {:error, :yolo_review_checkout_unsafe} = Workspace.remove_review(%{}, run, true)
    assert File.read!(Path.join(workspace.path, "tracked")) == "merged version"
    assert git(root, ["status", "--porcelain"]) == source_status <> "\n?? worktrees/"
    assert {:error, :yolo_workspace_unavailable} = Workspace.create("review", run)
    assert {:error, :yolo_workspace_unavailable} = Workspace.create("../escape", Ecto.UUID.generate())
    assert {:error, :yolo_workspace_unavailable} = Workspace.create("incoming", "../escape")
    File.write!(Path.join(workspace.path, "tracked"), "unexpected edit")
    refute Workspace.unchanged?(workspace)
    git(workspace.path, ["restore", "tracked"])
    git(root, ["worktree", "remove", workspace.path])
    File.mkdir_p!(workspace.path)
    refute Workspace.unchanged?(workspace)
  end

  test "review compatibility helpers retain safe removal and explicit unknown results" do
    run = Ecto.UUID.generate()
    assert {:ok, workspace} = Workspace.create("review", run)
    assert {:ok, true} = Workspace.review_checkout_present?(run)
    assert {:error, :yolo_review_checkout_unknown} = Workspace.review_checkout_present?("invalid")
    assert {:error, :yolo_checkout_unknown} = Workspace.checkout_present?("foreign", run)
    assert :ok = Workspace.remove_review(workspace, run)
    assert {:ok, false} = Workspace.review_checkout_present?(run)
  end

  test "inventory dry run and apply preserve dirty, active, reserved, journaled and unknown review checkouts", %{root: root, context: context} do
    context = %{context | yolo_agent_id: "pai"}
    context = put_in(context.settings.tracker.app["state_root"], Path.join(root, "state"))
    ProjectContext.bind(context)
    workspaces = for _ <- 1..7, do: elem(Workspace.create("review", Ecto.UUID.generate()), 1)
    [orphan, dirty, active, reserved, journaled, unknown, unlisted] = workspaces
    File.write!(Path.join(dirty.path, "tracked"), "changed")
    {:ok, record} = Store.read("review")
    record = Map.put(record, "attempt", %{"id" => Path.basename(active.path)})
    record = Map.put(record, "deliveries", %{"member" => %{"run_id" => Path.basename(reserved.path)}})
    :ok = Store.write("review", record)
    :ok = Journal.write(%{"id" => Path.basename(journaled.path), "group" => "review", "members" => [], "state" => "completed", "workspace" => journaled.path})
    entries = Enum.map([orphan, dirty, active, reserved, journaled], &%{"path" => &1.path, "sha" => &1.sha})
    entries = entries ++ [%{"path" => unknown.path, "sha" => String.duplicate("0", 40)}]
    inventory = %{"version" => 1, "checkouts" => entries}

    assert {:ok, dry} = ReviewCheckouts.sweep(inventory)
    assert dry["mode"] == "dry_run"
    assert dry["before"] == 7 and dry["after"] == 7
    assert dry["removable"] == 1 and dry["removed"] == 0
    assert {:ok, applied} = ReviewCheckouts.sweep(inventory, true)
    assert applied["before"] == 7 and applied["after"] == 6
    assert applied["removed"] == 1
    refute File.exists?(orphan.path)
    assert Enum.all?([dirty, active, reserved, journaled, unknown, unlisted], &File.dir?(&1.path))
  end

  test "inventory checks every other PO group with its own store and journal", %{root: root, context: context} do
    context = %{context | yolo_agent_id: "pai"}
    context = put_in(context.settings.tracker.app["state_root"], Path.join(root, "state"))
    ProjectContext.bind(context)

    groups = ~w(incoming planning in_progress blocker)

    fixtures =
      Map.new(groups, fn group ->
        [orphan, dirty, active, reserved, journaled, unknown] =
          for _ <- 1..6, do: elem(Workspace.create(group, Ecto.UUID.generate()), 1)

        File.write!(Path.join(dirty.path, "tracked"), "changed")
        {:ok, record} = Store.read(group)

        record =
          record
          |> Map.put("attempt", %{"id" => Path.basename(active.path)})
          |> Map.put("deliveries", %{"member" => %{"run_id" => Path.basename(reserved.path)}})

        assert :ok = Store.write(group, record)
        assert :ok = Journal.write(%{"id" => Path.basename(journaled.path), "group" => group, "members" => [], "state" => "completed", "workspace" => journaled.path})

        {group,
         %{
           orphan: orphan,
           dirty: dirty,
           active: active,
           reserved: reserved,
           journaled: journaled,
           unknown: unknown
         }}
      end)

    entries =
      Enum.flat_map(groups, fn group ->
        fixture = fixtures[group]

        Enum.map([fixture.orphan, fixture.dirty, fixture.active, fixture.reserved, fixture.journaled], &%{"path" => &1.path, "sha" => &1.sha}) ++
          [%{"path" => fixture.unknown.path, "sha" => String.duplicate("0", 40)}]
      end)

    inventory = %{"version" => 1, "checkouts" => entries}
    assert {:ok, dry} = ReviewCheckouts.sweep(inventory)
    assert dry["before"] == 24 and dry["after"] == 24
    assert dry["removable"] == 4 and dry["removed"] == 0
    assert {:ok, applied} = ReviewCheckouts.sweep(inventory, true)
    assert applied["before"] == 24 and applied["after"] == 20
    assert applied["removed"] == 4

    for group <- groups do
      fixture = fixtures[group]
      refute File.exists?(fixture.orphan.path)
      assert Enum.all?([fixture.dirty, fixture.active, fixture.reserved, fixture.journaled, fixture.unknown], &File.dir?(&1.path))
    end
  end

  test "inventory refuses malformed inputs, ambiguous reservations and unavailable Git inventory", %{root: root, context: context} do
    context = %{context | yolo_agent_id: "pai"}
    ProjectContext.bind(context)
    assert {:ok, workspace} = Workspace.create("review", Ecto.UUID.generate())
    inventory = %{"version" => 1, "checkouts" => [%{"path" => workspace.path, "sha" => workspace.sha}]}

    assert {:error, :review_checkout_inventory_invalid} = ReviewCheckouts.sweep(%{})
    assert {:error, :review_checkout_inventory_invalid} = ReviewCheckouts.sweep(%{inventory | "checkouts" => [%{"path" => workspace.path}]})
    invalid_path = Path.join([root, "worktrees", "yolo", "review", "invalid"])
    assert {:ok, %{"entries" => [%{"status" => "protected"}]}} = ReviewCheckouts.sweep(%{inventory | "checkouts" => [%{"path" => invalid_path, "sha" => workspace.sha}]})
    assert {:ok, record} = Store.read("review")

    for fields <- [
          %{"attempt" => %{"id" => nil}},
          %{"attempt" => nil, "deliveries" => %{"member" => %{}}},
          %{"attempt" => nil, "deliveries" => ["unknown"]}
        ] do
      assert :ok = Store.write("review", Map.merge(record, fields))
      assert {:ok, %{"entries" => [%{"status" => "protected"}]}} = ReviewCheckouts.sweep(inventory)
      assert File.dir?(workspace.path)
    end

    assert :ok = Store.write("review", record)
    File.write!(Store.path("review"), "corrupt")
    assert {:error, :yolo_state_corrupt} = ReviewCheckouts.sweep(inventory)
    assert :ok = Store.write("review", record)
    non_repo = Path.join(root, "not-a-repository")
    File.mkdir_p!(non_repo)
    File.write!(Path.join(non_repo, ".git"), "invalid")
    ProjectContext.bind(%{context | root: non_repo})
    assert {:error, :review_checkout_listing_unavailable} = ReviewCheckouts.sweep(inventory)
  end

  test "failed receipt removes its checkout for each PO group", %{root: root, context: context} do
    ProjectContext.bind(%{context | test_instance: %{"name" => "proof"}})
    System.put_env("SYMPHONY_TEST_RUN_STAGE", "run")
    System.put_env("SYMPHONY_TEST_RUN_PLAN", Path.join(root, "missing-plan.json"))
    run_id = Ecto.UUID.generate()
    assert {:error, :yolo_workspace_unavailable} = Workspace.create("review", run_id)
    assert {listing, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root)
    assert length(Regex.scan(~r/^worktree /m, listing)) == 1

    assert {:error, :yolo_workspace_unavailable} = Workspace.create("incoming", Ecto.UUID.generate())
    assert {:error, :yolo_workspace_unavailable} = Workspace.create("blocker", Ecto.UUID.generate())
    assert {listing, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root)
    assert length(Regex.scan(~r/^worktree /m, listing)) == 1
  end

  test "operator command verifies the project binding before dry run and apply", %{root: root} do
    File.write!(Path.join(root, ".symphony/.env.local"), "LINEAR_YOLO_AGENT=Pai\n")
    assert {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    context = %{context | yolo_agent_id: "pai"}
    ProjectContext.bind(context)

    workspaces =
      for group <- ~w(incoming planning in_progress blocker review) do
        assert {:ok, workspace} = Workspace.create(group, Ecto.UUID.generate())
        workspace
      end

    inventory_path = Path.join(root, "inventory.json")
    File.write!(inventory_path, Jason.encode!(%{"version" => 1, "checkouts" => Enum.map(workspaces, &%{"path" => &1.path, "sha" => &1.sha})}))

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      query = payload[:query] || payload["query"]

      nodes =
        if query =~ "SymphonyHumanAssignees" do
          [%{"id" => "11111111-1111-4111-8111-111111111111", "email" => "human@example.com", "app" => false}]
        else
          [%{"id" => "pai", "name" => "Pai", "app" => true, "active" => true, "isAssignable" => true}]
        end

      {:ok, %{status: 200, body: %{"data" => %{"users" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}}}}}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)
    isolated = %{context | env: Map.put(context.env, "SYMPHONY_ROOT_DIR", root)}

    ProjectContext.with_context(isolated, fn ->
      for {extra, mode, before_count, after_count} <- [{[], "dry_run", 5, 5}, {["--apply"], "apply", 5, 0}] do
        output = ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Yolo.ReviewCheckouts.run(["--project", root, "--inventory", inventory_path] ++ extra) end)
        summary = Jason.decode!(String.trim(output))
        assert summary["mode"] == mode
        assert summary["before"] == before_count
        assert summary["after"] == after_count
      end

      assert_raise Mix.Error, ~r/PO checkout cleanup refused/, fn ->
        Mix.Tasks.Yolo.ReviewCheckouts.run(["--project", root, "--inventory", Path.join(root, "missing.json")])
      end
    end)

    assert Enum.all?(workspaces, &(not File.exists?(&1.path)))
  end

  test "AppServer launches the real shell and profile helper in its bound group checkout", %{root: root, context: context} do
    installation = Path.join(root, "installation")
    File.mkdir_p!(Path.join(installation, "scripts"))

    for file <- ["sym-codex", "sym-codex-mcp", "scripts/codex-app-context.py"] do
      File.cp!(Path.expand(file), Path.join(installation, file))
    end

    for file <- ["WORKFLOW.md", "mix.exs"], do: File.write!(Path.join(installation, file), "")
    bin = Path.join(root, "fake-bin")
    File.mkdir_p!(bin)
    python = System.find_executable("python3")
    path = SymphonyElixir.TestSupport.script_path(bin)
    trace = Path.join(root, "launch.json")

    File.write!(Path.join(bin, "codex"), """
    #!#{python}
    import json, os, sys
    from pathlib import Path
    Path(#{Jason.encode!(trace)}).write_text(json.dumps({
      "cwd": os.getcwd(), "scope": json.loads(os.environ["SYMPHONY_YOLO_SCOPE"]),
      "profile": os.environ["CODEX_HOME"], "args": sys.argv[1:]}))
    for line in sys.stdin:
      msg = json.loads(line)
      method = msg.get("method")
      if method == "initialize":
        print(json.dumps({"id": msg["id"], "result": {}}), flush=True)
      elif method == "thread/start":
        print(json.dumps({"id": msg["id"], "result": {"thread": {"id": "po-thread"}}}), flush=True)
      elif method == "turn/start":
        print(json.dumps({"id": msg["id"], "result": {"turn": {"id": "po-turn"}}}), flush=True)
        print(json.dumps({"method": "turn/completed", "params": {"threadId": "po-thread", "turn": {"id": "po-turn", "status": "completed"}}}), flush=True)
    """)

    File.chmod!(Path.join(bin, "codex"), 0o755)
    command = "/usr/bin/env " <> Enum.map_join(["PATH=#{path}", "HOME=#{root}/personal", "CODEX_HOME=#{root}/personal/.codex", "SYMPHONY_PYTHON=#{python}"], " ", &shell_quote/1)
    command = command <> " /bin/bash " <> shell_quote(Path.join(installation, "sym-codex")) <> " --app-server"
    context = %{context | yolo_agent_id: "pai", human_handoff_id: "human", assignee_ids: ["human"]}
    context = put_in(context.settings.codex.command, command)
    context = put_in(context.settings.codex.turn_timeout_ms, 5_000)
    context = put_in(context.settings.tracker.app["state_root"], Path.join(root, "app-state"))
    ProjectContext.bind(context)
    run_id = Ecto.UUID.generate()
    {:ok, workspace} = Workspace.create("incoming", run_id)
    issue = %Issue{id: Ecto.UUID.generate(), identifier: "PRI-129", title: "PO fixture", state: "Backlog"}

    assert {:ok, %{session_id: "po-thread-po-turn"}} =
             Scope.with_scope("incoming", [issue], run_id, fn -> AppServer.run(workspace.path, "PO fixture", issue) end, workspace: workspace)

    launched = trace |> File.read!() |> Jason.decode!()
    assert launched["cwd"] == workspace.path
    assert launched["scope"]["workspace"] == workspace.path
    assert launched["scope"]["sha"] == workspace.sha
    assert launched["scope"]["members"] == [issue.id]
    assert launched["scope"]["run_id"] == run_id
    assert Enum.any?(launched["args"], &(String.starts_with?(&1, "mcp_servers.symphony_linear.env=") and String.contains?(&1, "SYMPHONY_YOLO_SCOPE")))
    assert File.read!(Path.join(launched["profile"], "config.toml")) =~ root
    assert Workspace.unchanged?(workspace)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  test "test receipts clean only their unchanged checkout and remain resumable", %{root: root, context: context} do
    ProjectContext.bind(%{context | test_instance: %{"name" => "proof"}})
    plan = %{"run_id" => "po-proof", "source" => %{"sha" => git(root, ["rev-parse", "HEAD"])}}
    plan_path = Path.join(root, "test-plan.json")
    :ok = DurableState.write(plan_path, plan)
    System.put_env("SYMPHONY_TEST_RUN_PLAN", plan_path)
    System.put_env("SYMPHONY_TEST_RUN_STAGE", "run")
    assert {:ok, workspace} = Workspace.create("incoming", Ecto.UUID.generate())
    git(root, ["worktree", "lock", workspace.path])
    assert {:error, :test_po_workspace_cleanup_unconfirmed} = PoIncoming.cleanup(context, plan)
    git(root, ["worktree", "unlock", workspace.path])
    File.write!(Path.join(workspace.path, "tracked"), "preserve unexpected work")
    assert {:error, :test_po_workspace_cleanup_unconfirmed} = PoIncoming.cleanup(context, plan)
    assert File.read!(Path.join(workspace.path, "tracked")) == "preserve unexpected work"
    git(workspace.path, ["restore", "tracked"])
    journal = SymphonyElixir.Yolo.OpenClaw.Journal
    order = %{"id" => Ecto.UUID.generate(), "group" => "incoming", "state" => "unknown", "members" => [], "workspace" => workspace.path}
    assert :ok = ProjectContext.with_context(context, fn -> journal.write(order) end)
    assert {:error, :test_po_workspace_cleanup_unconfirmed} = PoIncoming.cleanup(context, plan)
    assert File.dir?(workspace.path)
    assert {:ok, _} = ProjectContext.with_context(context, fn -> journal.update(order, %{"state" => "failed"}) end)
    assert :ok = PoIncoming.cleanup(context, plan)
    refute File.exists?(workspace.path)
    assert :ok = PoIncoming.cleanup(context, plan)
    [receipt] = Path.wildcard(Path.join(root, "state/runs/po-proof/yolo-workspaces/*.json"))
    assert {:ok, %{"cleaned" => true}} = DurableState.read(receipt)
    File.write!(receipt, "corrupt")
    assert {:error, :runtime_state_corrupt} = PoIncoming.cleanup(context, plan)
  end
end
