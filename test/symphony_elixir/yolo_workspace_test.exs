defmodule SymphonyElixir.YoloWorkspaceTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.ProjectContext

  alias SymphonyElixir.Linear.DurableState
  alias SymphonyElixir.TestRun.PoIncoming
  alias SymphonyElixir.Yolo.{Scope, Workspace}

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

  test "detached checkout fixes the merged SHA, retains source work and rejects unsafe paths", %{root: root} do
    source_status = git(root, ["status", "--porcelain"])
    run = Ecto.UUID.generate()
    assert {:ok, workspace} = Workspace.create("review", run)
    assert workspace.sha == git(root, ["rev-parse", "main"])
    assert Workspace.unchanged?(workspace)
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
    assert :ok = ProjectContext.with_context(context, fn -> journal.write(Map.put(order, "state", "failed")) end)
    assert :ok = PoIncoming.cleanup(context, plan)
    refute File.exists?(workspace.path)
    assert :ok = PoIncoming.cleanup(context, plan)
    [receipt] = Path.wildcard(Path.join(root, "state/runs/po-proof/yolo-workspaces/*.json"))
    assert {:ok, %{"cleaned" => true}} = DurableState.read(receipt)
    File.write!(receipt, "corrupt")
    assert {:error, :runtime_state_corrupt} = PoIncoming.cleanup(context, plan)
  end
end
