defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport
  alias Ecto.Changeset
  alias SymphonyElixir.AutocommitMessage
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{Codex, StringOrMap}
  alias SymphonyElixir.Linear.{Adapter, Client}

  test "autocommit messages include issue identifier, workflow state and explanatory body" do
    assert AutocommitMessage.build(%Issue{identifier: "MT-REVIEW"}, "Review (AI)") ==
             "MT-REVIEW Review (AI) Autocommit\n\nDieser automatische Commit wird im Schritt Review (AI) erstellt und sichert den bis dahin offenen Arbeitsstand für MT-REVIEW. Er ist kein Nachweis, dass Review (AI) bereits abgeschlossen ist."

    assert AutocommitMessage.build(%{identifier: " MT-TEST "}, " Test (AI) ") ==
             "MT-TEST Test (AI) Autocommit\n\nDieser automatische Commit wird im Schritt Test (AI) erstellt und sichert den bis dahin offenen Arbeitsstand für MT-TEST. Er ist kein Nachweis, dass Test (AI) bereits abgeschlossen ist."

    assert AutocommitMessage.build("", "Merge (AI)") =~ "Unbekanntes Issue Merge (AI) Autocommit"
    assert AutocommitMessage.build(nil, "Merge (AI)") =~ "für Unbekanntes Issue"
  end

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "current WORKFLOW after_create hook pushes new worktree branches to origin branches of the same name" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worktree-tracking-#{System.unique_integer([:positive])}"
      )

    current_workflow_path = Path.expand("../../WORKFLOW.md", __DIR__)

    try do
      assert {:ok, %{config: %{"hooks" => %{"after_create" => after_create}}}} =
               Workflow.load(current_workflow_path)

      remote_repo = Path.join(test_root, "remote.git")
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "worktrees")
      workflow_dir = Path.join(test_root, "workflow")
      workflow_file = Path.join(workflow_dir, "WORKFLOW.md")

      File.mkdir_p!(workflow_dir)

      assert {_, 0} = System.cmd("git", ["init", "--bare", remote_repo], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["clone", remote_repo, source_repo], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "checkout", "-b", "main"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"], stderr_to_stdout: true)

      File.write!(Path.join(source_repo, "README.md"), "base\n")
      write_minimal_mix_project!(source_repo, :worktree_tracking)
      install_current_worktree_scripts!(source_repo)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", "README.md"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", "mix.exs"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", "mise.toml"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", ".symphony"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "push", "-u", "origin", "main"], stderr_to_stdout: true)

      write_workflow_file!(workflow_file,
        workspace_root: workspace_root,
        hook_after_create: SymphonyElixir.TestSupport.system_bash_hook(after_create, test_root)
      )

      Workflow.set_workflow_file_path(workflow_file)

      assert {:ok, workspace} =
               File.cd!(source_repo, fn ->
                 Workspace.create_for_issue("MT-TRACK")
               end)

      assert {"origin\n", 0} =
               System.cmd("git", ["-C", source_repo, "config", "--get", "branch.symphony/MT-TRACK.remote"])

      assert {"refs/heads/symphony/MT-TRACK\n", 0} =
               System.cmd("git", [
                 "-C",
                 source_repo,
                 "config",
                 "--get",
                 "branch.symphony/MT-TRACK.merge"
               ])

      File.write!(Path.join(workspace, "README.md"), "base\nchange\n")
      assert {_, 0} = System.cmd("git", ["-C", workspace, "add", "README.md"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", workspace, "commit", "-m", "change"], stderr_to_stdout: true)

      assert {push_output, 0} = System.cmd("git", ["-C", workspace, "push"], stderr_to_stdout: true)
      assert push_output =~ "symphony/MT-TRACK -> symphony/MT-TRACK"

      assert {remote_branch, 0} =
               System.cmd("git", ["-C", source_repo, "ls-remote", "--heads", "origin", "symphony/MT-TRACK"])

      assert remote_branch =~ "refs/heads/symphony/MT-TRACK"
    after
      File.rm_rf(test_root)
    end
  end

  test "current WORKFLOW after_create hook copies env locals and creates issue-specific CLI symlinks" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worktree-env-local-#{System.unique_integer([:positive])}"
      )

    current_workflow_path = Path.expand("../../WORKFLOW.md", __DIR__)

    try do
      assert {:ok, %{config: %{"hooks" => %{"after_create" => after_create}}}} =
               Workflow.load(current_workflow_path)

      remote_repo = Path.join(test_root, "remote.git")
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "worktrees")
      workflow_dir = Path.join(test_root, "workflow")
      workflow_file = Path.join(workflow_dir, "WORKFLOW.md")
      fake_home = Path.join(test_root, "home")
      env_contents = "LINEAR_TEST_PROJECT_SLUG=\"symphony-test-7d8cc05658e6\"\n"

      env_local_contents =
        "SELF_HOSTED=1\nLINEAR_PROJECT_SLUG=\"symphony-07f513c4ae64\"\nLINEAR_TEST_PROJECT_SLUG=\"symphony-test-stale\"\nLINEAR_ASSIGNEE=dev@example.com\nLINEAR_TEST_PROJECT_SLUG = \"symphony-test-local\"\n"

      expected_worktree_env_local =
        "SELF_HOSTED=1\nLINEAR_PROJECT_SLUG=\"symphony-test-local\"\nLINEAR_TEST_PROJECT_SLUG=\"symphony-test-stale\"\nLINEAR_ASSIGNEE=dev@example.com\nLINEAR_TEST_PROJECT_SLUG = \"symphony-test-local\"\n"

      root_env_local_contents = "SYM_CODEX_REASONING_EFFORT=low\n"
      previous_home = System.get_env("HOME")

      File.mkdir_p!(workflow_dir)
      File.mkdir_p!(fake_home)
      on_exit(fn -> restore_env("HOME", previous_home) end)

      assert {_, 0} = System.cmd("git", ["init", "--bare", remote_repo], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["clone", remote_repo, source_repo], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "checkout", "-b", "main"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"], stderr_to_stdout: true)

      File.write!(Path.join(source_repo, "README.md"), "base\n")
      File.write!(Path.join(source_repo, "symphony"), "#!/usr/bin/env bash\n")
      File.write!(Path.join(source_repo, "sym-codex"), "#!/usr/bin/env bash\n")
      File.chmod!(Path.join(source_repo, "symphony"), 0o755)
      File.chmod!(Path.join(source_repo, "sym-codex"), 0o755)
      write_minimal_mix_project!(source_repo, :worktree_env_local)
      install_current_worktree_scripts!(source_repo)
      File.write!(Path.join(source_repo, ".symphony/.env"), env_contents)
      File.write!(Path.join(source_repo, ".symphony/.env.local"), env_local_contents)
      File.write!(Path.join(source_repo, ".env.local"), root_env_local_contents)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", "README.md"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", "symphony"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", "sym-codex"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", ".env.local"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", "mix.exs"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", "mise.toml"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", ".symphony"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "push", "-u", "origin", "main"], stderr_to_stdout: true)

      write_workflow_file!(workflow_file,
        workspace_root: workspace_root,
        hook_after_create: SymphonyElixir.TestSupport.system_bash_hook(after_create, test_root)
      )

      Workflow.set_workflow_file_path(workflow_file)
      System.put_env("HOME", fake_home)

      assert {:ok, workspace} =
               File.cd!(source_repo, fn ->
                 Workspace.create_for_issue("MT-ENV")
               end)

      assert File.read!(Path.join(workspace, ".symphony/.env.local")) == expected_worktree_env_local
      assert File.read!(Path.join(workspace, ".env.local")) == root_env_local_contents
      assert File.read_link!(Path.join(fake_home, ".local/bin/symphony-MT-ENV")) == Path.join(workspace, "symphony")
      assert File.read_link!(Path.join(fake_home, ".local/bin/sym-codex-MT-ENV")) == Path.join(workspace, "sym-codex")

      empty_slug_workspace = Path.join(workspace_root, "MT-EMPTY")
      empty_slug_env_local_contents = "LINEAR_PROJECT_SLUG=\"symphony-07f513c4ae64\"\nLINEAR_TEST_PROJECT_SLUG=\"\"\n"
      File.write!(Path.join(source_repo, ".symphony/.env.local"), empty_slug_env_local_contents)

      assert {_, 0} =
               System.cmd(
                 "python3",
                 [
                   Path.join(source_repo, ".symphony/on_create_worktree.py"),
                   source_repo,
                   empty_slug_workspace
                 ],
                 stderr_to_stdout: true
               )

      assert File.read!(Path.join(empty_slug_workspace, ".symphony/.env.local")) ==
               "LINEAR_PROJECT_SLUG=\"\"\nLINEAR_TEST_PROJECT_SLUG=\"\"\n"

      File.write!(Path.join(source_repo, ".symphony/.env.local"), "SELF_HOSTED=2\n")
      File.write!(Path.join(source_repo, ".env.local"), "SYM_CODEX_REASONING_EFFORT=medium\n")
      assert File.read!(Path.join(workspace, ".symphony/.env.local")) == expected_worktree_env_local
      assert File.read!(Path.join(workspace, ".env.local")) == root_env_local_contents
    after
      File.rm_rf(test_root)
    end
  end

  test "project on_remove_worktree script removes matching issue symlinks" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-on-remove-worktree-#{System.unique_integer([:positive])}"
      )

    script_path = project_worktree_script_path("on_remove_worktree.py")
    source_repo = Path.join(test_root, "source")
    workspace = Path.join(test_root, "PRO-130")
    fake_home = Path.join(test_root, "home")
    managed_symphony_link = Path.join(fake_home, ".local/bin/symphony-PRO-130")
    managed_sym_codex_link = Path.join(fake_home, ".local/bin/sym-codex-PRO-130")
    other_issue_link = Path.join(fake_home, ".local/bin/symphony-PRO-999")
    managed_symphony_target = Path.join(workspace, "symphony")
    managed_sym_codex_target = Path.join(workspace, "sym-codex")
    other_issue_target = Path.join(workspace, "other-symphony")

    try do
      File.mkdir_p!(source_repo)
      File.mkdir_p!(workspace)
      File.mkdir_p!(Path.join(fake_home, ".local/bin"))
      File.write!(managed_symphony_target, "")
      File.write!(managed_sym_codex_target, "")
      File.ln_s!(managed_symphony_target, managed_symphony_link)
      File.ln_s!(managed_sym_codex_target, managed_sym_codex_link)
      File.ln_s!(other_issue_target, other_issue_link)

      assert {"", 0} =
               System.cmd("python3", [script_path, source_repo, workspace],
                 env: [{"HOME", fake_home}],
                 stderr_to_stdout: true
               )

      assert {:error, :enoent} = File.lstat(managed_symphony_link)
      assert {:error, :enoent} = File.lstat(managed_sym_codex_link)
      assert File.read_link!(other_issue_link) == other_issue_target
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) == "MT_Det"
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"
      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) == "compiled artifact\n"
      assert File.read!(Path.join([second_workspace, "tmp", "scratch.txt"])) == "remove me\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "review autocommit markers stay isolated per linked worktree" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-autocommit-worktree-isolation-#{System.unique_integer([:positive])}"
      )

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "worktrees")
      workspace_a = Path.join([workspace_root, "MT-REVIEW-A"])
      workspace_b = Path.join([workspace_root, "MT-REVIEW-B"])

      File.mkdir_p!(Path.dirname(workspace_a))
      File.mkdir_p!(source_repo)
      File.write!(Path.join(source_repo, "README.md"), "base\n")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {_, 0} = System.cmd("git", ["-C", source_repo, "init", "-b", "main"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", "README.md"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "worktree", "add", "-b", "symphony/MT-REVIEW-A", workspace_a, "HEAD"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "worktree", "add", "-b", "symphony/MT-REVIEW-B", workspace_b, "HEAD"], stderr_to_stdout: true)

      marker_path_a = review_autocommit_marker_path!(workspace_a)
      marker_path_b = review_autocommit_marker_path!(workspace_b)

      File.write!(Path.join(workspace_a, "review-a.txt"), "dirty\n")
      assert {:ok, :committed} = Workspace.prepare_review_autocommit(workspace_a, AutocommitMessage.build("MT-REVIEW-A", "Review (AI)"))
      assert File.exists?(marker_path_a)
      refute File.exists?(marker_path_b)

      File.write!(Path.join(workspace_b, "review-b.txt"), "dirty\n")
      assert {:ok, :committed} = Workspace.prepare_review_autocommit(workspace_b, AutocommitMessage.build("MT-REVIEW-B", "Review (AI)"))
      assert File.exists?(marker_path_a)
      assert File.exists?(marker_path_b)

      assert :ok = Workspace.clear_review_autocommit_marker(workspace_a)
      refute File.exists?(marker_path_a)
      assert File.exists?(marker_path_b)
      assert {:ok, :already_recorded} = Workspace.prepare_review_autocommit(workspace_b, AutocommitMessage.build("MT-REVIEW-B", "Review (AI)"))
    after
      File.rm_rf(test_root)
    end
  end

  test "commit_all_changes writes multiline commit messages as subject and body" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-multiline-commit-message-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root)
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "base\n")
      assert {_, 0} = System.cmd("git", ["-C", workspace, "init", "-b", "main"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", workspace, "add", "README.md"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", workspace, "commit", "-m", "initial"], stderr_to_stdout: true)

      File.write!(Path.join(workspace, "README.md"), "base\nchange\n")

      message = AutocommitMessage.build("MT-MULTILINE", "Test (AI)")
      assert {:ok, :committed} = Workspace.commit_all_changes(workspace, message)

      assert {"MT-MULTILINE Test (AI) Autocommit\n", 0} =
               System.cmd("git", ["-C", workspace, "log", "-1", "--pretty=%s"])

      assert {body, 0} = System.cmd("git", ["-C", workspace, "log", "-1", "--pretty=%b"])
      assert body =~ "Dieser automatische Commit wird im Schritt Test (AI) erstellt"
      assert body =~ "Er ist kein Nachweis, dass Test (AI) bereits abgeschlossen ist."
    after
      File.rm_rf(test_root)
    end
  end

  test "review autocommit marker cleanup tolerates localized non-git workspace errors" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-autocommit-localized-non-git-#{System.unique_integer([:positive])}"
      )

    previous_lc_all = System.get_env("LC_ALL")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-NON-GIT")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      File.mkdir_p!(workspace)
      System.put_env("LC_ALL", "de_DE.UTF-8")

      assert :ok = Workspace.clear_review_autocommit_marker(workspace)
    after
      restore_env("LC_ALL", previous_lc_all)
      File.rm_rf(test_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join(workspace_root, "MT-STALE")
      File.mkdir_p!(workspace_root)
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(stale_workspace)
      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join(workspace_root, "MT-SYM")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_outside_root} = SymphonyElixir.PathSafety.canonicalize(outside_root)
      assert {:ok, canonical_workspace_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_outside_root, ^canonical_outside_root, ^canonical_workspace_root}} =
               Workspace.create_for_issue("MT-SYM")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace canonicalizes symlinked workspace roots before creating issue directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      actual_root = Path.join(test_root, "actual-workspaces")
      linked_root = Path.join(test_root, "linked-workspaces")

      File.mkdir_p!(actual_root)
      File.ln_s!(actual_root, linked_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: linked_root)

      assert {:ok, canonical_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(actual_root, "MT-LINK"))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-LINK")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_equals_root, ^canonical_workspace_root, ^canonical_workspace_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17"
      )

      workspace = Path.join(workspace_root, "MT-FAIL")

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL")

      refute File.exists?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      workspace = Path.join(workspace_root, "MT-TIMEOUT")

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT")

      refute File.exists?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace retries after_create after cleaning up a failed fresh workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-retry-#{System.unique_integer([:positive])}"
      )

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      attempt_marker = Path.join(test_root, "after_create.failed")

      File.mkdir_p!(source_repo)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "init", "-b", "main"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"], stderr_to_stdout: true)
      File.write!(Path.join(source_repo, "README.md"), "base\n")
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", "README.md"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"], stderr_to_stdout: true)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: """
        set -eu
        workspace="$PWD"
        issue_key="$(basename "$workspace")"
        branch="symphony/$issue_key"
        source_repo="$SYMPHONY_PROJECT_ROOT"
        if ! git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          rm -rf "$workspace"
        fi
        if git -C "$source_repo" show-ref --verify --quiet "refs/heads/$branch"; then
          git -C "$source_repo" worktree add "$workspace" "$branch"
        else
          git -C "$source_repo" worktree add -b "$branch" "$workspace" main
        fi
        cd "$workspace"
        if [ ! -f "#{attempt_marker}" ]; then
          echo first-failure > "#{attempt_marker}"
          exit 17
        fi
        echo recovered >> README.md
        """
      )

      workspace = Path.join(workspace_root, "MT-RETRY")

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               File.cd!(source_repo, fn ->
                 Workspace.create_for_issue("MT-RETRY")
               end)

      refute File.exists?(workspace)
      assert {"", 0} = System.cmd("git", ["-C", source_repo, "branch", "--list", "symphony/MT-RETRY"], stderr_to_stdout: true)
      assert {worktree_list, 0} = System.cmd("git", ["-C", source_repo, "worktree", "list", "--porcelain"], stderr_to_stdout: true)
      refute worktree_list =~ workspace

      assert {:ok, ^workspace} =
               File.cd!(source_repo, fn ->
                 Workspace.create_for_issue("MT-RETRY")
               end)

      assert File.read!(Path.join(workspace, "README.md")) =~ "recovered\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join(workspace_root, "MT-608")
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")
      untouched_workspace = Path.join(workspace_root, "OTHER-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "linear issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      assigned_to_worker: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.assigned_to_worker
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Fertig"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
  end

  test "linear client includes and normalizes the lightweight last comment signal" do
    raw_issue = %{
      "id" => "issue-comment-signal",
      "identifier" => "MT-COMMENT-SIGNAL",
      "title" => "Comment signal",
      "state" => %{"name" => "Todo (Dialog-AI)"},
      "comments" => %{
        "nodes" => [
          %{
            "id" => "comment-newest",
            "createdAt" => "2026-05-21T09:55:00Z",
            "updatedAt" => "2026-05-21T10:00:00Z"
          },
          %{
            "id" => "comment-older",
            "createdAt" => "2026-05-21T09:58:00Z",
            "updatedAt" => "2026-05-21T09:59:00Z"
          }
        ]
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue)

    assert %{
             id: "comment-newest",
             created_at: ~U[2026-05-21 09:55:00Z],
             updated_at: ~U[2026-05-21 10:00:00Z]
           } = issue.last_comment_signal

    assert Client.candidate_query_for_test(nil) =~ "comments(first: 1, orderBy: updatedAt)"
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.assigned_to_worker
  end

  test "linear client routes email-matched assignees to the worker case-insensitively" do
    raw_issue = %{
      "id" => "issue-email-1",
      "identifier" => "MT-EMAIL-1",
      "title" => "Shared API key routing",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-123",
        "email" => "Dev@Example.com"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "dev@example.com")

    assert issue.assigned_to_worker
  end

  test "linear candidate query filters assignee by email when configured" do
    query = Client.candidate_query_for_test("dev@example.com")

    assert query =~ ~s(assignee: {email: {eqIgnoreCase: "dev@example.com"}})
  end

  test "linear candidate query filters assignee by id when configured" do
    query = Client.candidate_query_for_test("user-123")

    assert query =~ ~s(assignee: {id: {eq: "user-123"}})
  end

  test "linear candidate polling omits assignee filter in yolo mode" do
    previous_yolo = Application.get_env(:symphony_elixir, :yolo)
    previous_request_fun = Application.get_env(:symphony_elixir, :linear_client_request_fun)

    on_exit(fn ->
      restore_app_env(:yolo, previous_yolo)
      restore_app_env(:linear_client_request_fun, previous_request_fun)
    end)

    Application.put_env(:symphony_elixir, :yolo, true)

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _headers ->
      send(self(), {:linear_candidate_query, payload})

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "issues" => %{
               "nodes" => [],
               "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
             }
           }
         }
       }}
    end)

    assert {:ok, []} = Client.fetch_candidate_issues()
    assert_received {:linear_candidate_query, %{"query" => query}}
    refute query =~ "assignee:"
  end

  test "linear team polling spans projects, includes projectless issues and excludes other teams and subteams" do
    previous_request_fun = Application.get_env(:symphony_elixir, :linear_client_request_fun)

    on_exit(fn -> restore_app_env(:linear_client_request_fun, previous_request_fun) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_team_key: "PRO"
    )

    raw_issue = fn id, identifier, project ->
      %{
        "id" => id,
        "identifier" => identifier,
        "title" => identifier,
        "description" => "Team candidate",
        "state" => %{"name" => "Todo (AI)"},
        "project" => project,
        "assignee" => %{"id" => "user-1", "email" => "dev@example.com"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _headers ->
      send(self(), {:team_candidate_poll, payload})

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "issues" => %{
               "nodes" => [
                 raw_issue.("issue-a", "PRO-1", %{"slugId" => "project-a"}),
                 raw_issue.("issue-b", "PRO-2", %{"slugId" => "project-b"}),
                 raw_issue.("issue-none", "PRO-3", nil)
               ],
               "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
             }
           }
         }
       }}
    end)

    assert {:ok, issues} = Client.fetch_candidate_issues()
    assert Enum.map(issues, & &1.identifier) == ["PRO-1", "PRO-2", "PRO-3"]
    assert Enum.all?(issues, & &1.assigned_to_worker)

    assert_receive {:team_candidate_poll,
                    %{
                      "query" => query,
                      "variables" => %{
                        teamKey: "PRO",
                        stateNames: state_names,
                        first: 50,
                        relationFirst: 50,
                        after: nil
                      }
                    }}

    assert "Todo (AI)" in state_names
    assert query =~ "SymphonyLinearTeamPoll"
    assert query =~ "team: {key: {eq: $teamKey}}"
    assert query =~ ~s(assignee: {email: {eqIgnoreCase: "dev@example.com"}})
    refute query =~ "project:"
    refute query =~ "subteam"
  end

  test "linear team candidate polling preserves pagination and yolo routing" do
    previous_request_fun = Application.get_env(:symphony_elixir, :linear_client_request_fun)
    previous_yolo = Application.get_env(:symphony_elixir, :yolo)

    on_exit(fn ->
      restore_app_env(:linear_client_request_fun, previous_request_fun)
      restore_app_env(:yolo, previous_yolo)
    end)

    Application.put_env(:symphony_elixir, :yolo, true)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_team_key: "PRO",
      tracker_assignee: nil,
      tracker_active_states: ["Todo (AI)"]
    )

    raw_issue = fn id, identifier ->
      %{
        "id" => id,
        "identifier" => identifier,
        "title" => identifier,
        "state" => %{"name" => "Todo (AI)"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _headers ->
      send(self(), {:team_candidate_page, payload})

      {nodes, page_info} =
        case payload["variables"].after do
          nil ->
            {[raw_issue.("issue-1", "PRO-1")], %{"hasNextPage" => true, "endCursor" => "cursor-1"}}

          "cursor-1" ->
            {[raw_issue.("issue-2", "PRO-2")], %{"hasNextPage" => false, "endCursor" => nil}}
        end

      {:ok,
       %{
         status: 200,
         body: %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => page_info}}}
       }}
    end)

    assert {:ok, issues} = Client.fetch_candidate_issues()
    assert Enum.map(issues, & &1.identifier) == ["PRO-1", "PRO-2"]

    assert_receive {:team_candidate_page, %{"query" => query, "variables" => %{teamKey: "PRO", after: nil}}}

    refute query =~ "assignee:"

    assert_receive {:team_candidate_page, %{"query" => ^query, "variables" => %{teamKey: "PRO", after: "cursor-1"}}}
  end

  test "linear terminal startup cleanup uses the configured team scope" do
    previous_request_fun = Application.get_env(:symphony_elixir, :linear_client_request_fun)

    on_exit(fn -> restore_app_env(:linear_client_request_fun, previous_request_fun) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_team_key: "PRO"
    )

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _headers ->
      send(self(), {:team_terminal_poll, payload})

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "issues" => %{
               "nodes" => [],
               "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
             }
           }
         }
       }}
    end)

    assert {:ok, []} = Client.fetch_issues_by_states(["Review"])

    assert_receive {:team_terminal_poll,
                    %{
                      "query" => query,
                      "variables" => %{teamKey: "PRO", stateNames: ["Review"]}
                    }}

    assert query =~ "team: {key: {eq: $teamKey}}"
  end

  test "linear team id revalidation treats an issue outside the team as invisible" do
    previous_request_fun = Application.get_env(:symphony_elixir, :linear_client_request_fun)

    on_exit(fn -> restore_app_env(:linear_client_request_fun, previous_request_fun) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_team_key: "PRO"
    )

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _headers ->
      send(self(), {:team_issue_revalidation, payload})

      {:ok,
       %{
         status: 200,
         body: %{"data" => %{"issues" => %{"nodes" => []}}}
       }}
    end)

    assert {:ok, []} = Client.fetch_issue_states_by_ids(["issue-outside-team"])

    assert_receive {:team_issue_revalidation,
                    %{
                      "query" => query,
                      "variables" => %{
                        ids: ["issue-outside-team"],
                        teamKey: "PRO",
                        first: 1,
                        relationFirst: 50
                      }
                    }}

    assert query =~ "SymphonyLinearIssuesByIdInTeam"
    assert query =~ "team: {key: {eq: $teamKey}}"
  end

  test "manual team lookup rejects foreign identifiers while project scope remains unchanged" do
    previous_request_fun = Application.get_env(:symphony_elixir, :linear_client_request_fun)

    on_exit(fn -> restore_app_env(:linear_client_request_fun, previous_request_fun) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_team_key: "PRO"
    )

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _headers ->
      send(self(), {:manual_issue_lookup, payload})
      {:error, :unexpected_request}
    end)

    assert {:error, "Linear issue OTHER-123 is outside configured team scope PRO"} =
             Client.fetch_issue_by_identifier("OTHER-123")

    refute_received {:manual_issue_lookup, _payload}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      tracker_team_key: nil
    )

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _headers ->
      send(self(), {:manual_issue_lookup, payload})

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "issues" => %{
               "nodes" => [
                 %{
                   "id" => "issue-other",
                   "identifier" => "OTHER-123",
                   "title" => "Cross-team project issue",
                   "state" => %{"name" => "In Arbeit (AI)"},
                   "labels" => %{"nodes" => []},
                   "inverseRelations" => %{"nodes" => []}
                 }
               ]
             }
           }
         }
       }}
    end)

    assert {:ok, %Issue{identifier: "OTHER-123"}} = Client.fetch_issue_by_identifier("OTHER-123")

    assert_receive {:manual_issue_lookup, %{"variables" => %{teamKey: "OTHER", number: 123}}}
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client paginates issue state fetches by id beyond one page" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")
    first_batch_ids = Enum.take(issue_ids, 50)
    second_batch_ids = Enum.drop(issue_ids, 50)

    raw_issue = fn issue_id ->
      suffix = String.replace_prefix(issue_id, "issue-", "")

      %{
        "id" => issue_id,
        "identifier" => "MT-#{suffix}",
        "title" => "Issue #{suffix}",
        "description" => "Description #{suffix}",
        "state" => %{"name" => "In Progress"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})

      body = %{
        "data" => %{
          "issues" => %{
            "nodes" => Enum.map(variables.ids, raw_issue)
          }
        }
      }

      {:ok, body}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)

    assert Enum.map(issues, & &1.id) == issue_ids

    assert_receive {:fetch_issue_states_page, query, %{ids: ^first_batch_ids, first: 50, relationFirst: 50}}
    assert query =~ "SymphonyLinearIssuesById"

    assert_receive {:fetch_issue_states_page, ^query, %{ids: ^second_batch_ids, first: 5, relationFirst: 50}}
  end

  test "linear client fetches a single issue by team key and number derived from the identifier" do
    previous_request_fun = Application.get_env(:symphony_elixir, :linear_client_request_fun)

    on_exit(fn ->
      if is_nil(previous_request_fun) do
        Application.delete_env(:symphony_elixir, :linear_client_request_fun)
      else
        Application.put_env(:symphony_elixir, :linear_client_request_fun, previous_request_fun)
      end
    end)

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _headers ->
      send(self(), {:fetch_issue_by_identifier, payload})

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "issues" => %{
               "nodes" => [
                 %{
                   "id" => "issue-49",
                   "identifier" => "PRO-49",
                   "title" => "Shared prompt context",
                   "description" => "Load prompt for manual sessions",
                   "state" => %{"name" => "Planung"},
                   "labels" => %{"nodes" => [%{"name" => "workflow"}]},
                   "inverseRelations" => %{"nodes" => []}
                 }
               ]
             }
           }
         }
       }}
    end)

    assert {:ok, %Issue{identifier: "PRO-49", state: "Planung"} = issue} =
             Client.fetch_issue_by_identifier("PRO-49")

    assert issue.title == "Shared prompt context"

    assert_receive {:fetch_issue_by_identifier,
                    %{
                      "query" => query,
                      "variables" => %{
                        teamKey: "PRO",
                        number: 49,
                        relationFirst: 50
                      }
                    }}

    assert query =~ "SymphonyLinearIssueByIdentifier"
  end

  @tag :manual_in_arbeit_client
  test "linear client includes manual handoff states in candidate polling" do
    previous_request_fun = Application.get_env(:symphony_elixir, :linear_client_request_fun)

    on_exit(fn ->
      if is_nil(previous_request_fun) do
        Application.delete_env(:symphony_elixir, :linear_client_request_fun)
      else
        Application.put_env(:symphony_elixir, :linear_client_request_fun, previous_request_fun)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo (AI)", "Review (AI)"]
    )

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _headers ->
      send(self(), {:fetch_candidate_issues, payload})

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "issues" => %{
               "nodes" => []
             }
           }
         }
       }}
    end)

    assert {:ok, []} = Client.fetch_candidate_issues()

    assert_receive {:fetch_candidate_issues,
                    %{
                      "query" => query,
                      "variables" => %{
                        projectSlug: "project",
                        stateNames: [
                          "Todo (AI)",
                          "Review (AI)",
                          "In Arbeit",
                          "Freigabe Implementierung",
                          "Freigabe Review",
                          "Todo (Dialog-AI)"
                        ],
                        first: 50,
                        relationFirst: 50,
                        after: nil
                      }
                    }}

    assert query =~ "state: {name: {in: $stateNames}}"
    assert query =~ "project: {slugId: {eq: $projectSlug}}"
    refute query =~ "$teamKey"
  end

  test "linear client includes manual approval states in candidate polling in yolo mode" do
    previous_yolo = Application.get_env(:symphony_elixir, :yolo)
    previous_request_fun = Application.get_env(:symphony_elixir, :linear_client_request_fun)

    on_exit(fn ->
      restore_app_env(:yolo, previous_yolo)

      if is_nil(previous_request_fun) do
        Application.delete_env(:symphony_elixir, :linear_client_request_fun)
      else
        Application.put_env(:symphony_elixir, :linear_client_request_fun, previous_request_fun)
      end
    end)

    Application.put_env(:symphony_elixir, :yolo, true)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo (AI)", "Review (AI)"]
    )

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _headers ->
      send(self(), {:fetch_candidate_issues, payload})

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "issues" => %{
               "nodes" => []
             }
           }
         }
       }}
    end)

    assert {:ok, []} = Client.fetch_candidate_issues()

    assert_receive {:fetch_candidate_issues,
                    %{
                      "variables" => %{
                        stateNames: [
                          "Todo (AI)",
                          "Review (AI)",
                          "In Arbeit",
                          "Freigabe Implementierung",
                          "Freigabe Review",
                          "Todo (Dialog-AI)"
                        ]
                      }
                    }}
  end

  test "linear client paginates issue comment bodies beyond the first page" do
    previous_request_fun = Application.get_env(:symphony_elixir, :linear_client_request_fun)

    on_exit(fn ->
      if is_nil(previous_request_fun) do
        Application.delete_env(:symphony_elixir, :linear_client_request_fun)
      else
        Application.put_env(:symphony_elixir, :linear_client_request_fun, previous_request_fun)
      end
    end)

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _headers ->
      send(self(), {:fetch_issue_comments, payload})

      case payload["variables"] do
        %{id: "issue-1", first: 50, after: nil} ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "issue" => %{
                   "comments" => %{
                     "nodes" => [%{"body" => "older note"}],
                     "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-1"}
                   }
                 }
               }
             }
           }}

        %{id: "issue-1", first: 50, after: "cursor-1"} ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "issue" => %{
                   "comments" => %{
                     "nodes" => [%{"body" => "## Symphony Workpad\n\npresent"}],
                     "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                   }
                 }
               }
             }
           }}
      end
    end)

    assert {:ok, ["older note", "## Symphony Workpad\n\npresent"]} =
             Client.fetch_issue_comment_bodies("issue-1")

    assert_receive {:fetch_issue_comments,
                    %{
                      "query" => query,
                      "variables" => %{id: "issue-1", first: 50, after: nil}
                    }}

    assert query =~ "SymphonyLinearIssueComments"

    assert_receive {:fetch_issue_comments,
                    %{
                      "query" => ^query,
                      "variables" => %{id: "issue-1", first: 50, after: "cursor-1"}
                    }}
  end

  test "linear adapter exposes structured issue comments" do
    previous_request_fun = Application.get_env(:symphony_elixir, :linear_client_request_fun)

    on_exit(fn ->
      if is_nil(previous_request_fun) do
        Application.delete_env(:symphony_elixir, :linear_client_request_fun)
      else
        Application.put_env(:symphony_elixir, :linear_client_request_fun, previous_request_fun)
      end
    end)

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _headers ->
      send(self(), {:fetch_issue_comments, payload})

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "issue" => %{
               "comments" => %{
                 "nodes" => [
                   %{
                     "id" => "comment-1",
                     "body" => "comment body",
                     "createdAt" => "2026-05-19T10:00:00Z",
                     "updatedAt" => "2026-05-19T10:01:00Z"
                   }
                 ],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }
         }
       }}
    end)

    write_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, [%{id: "comment-1", body: "comment body", created_at: %DateTime{}, updated_at: %DateTime{}}]} =
             Adapter.fetch_issue_comments("issue-1")

    assert_receive {:fetch_issue_comments,
                    %{
                      "variables" => %{
                        id: "issue-1",
                        first: 50,
                        after: nil
                      }
                    }}
  end

  test "linear client rejects malformed issue identifiers before hitting the api" do
    assert {:error, {:invalid_issue_identifier, "not-an-issue"}} =
             Client.fetch_issue_by_identifier("not-an-issue")
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400, diagnostics}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )

        assert diagnostics.status == 400
        assert diagnostics.classification == "graphql"
        assert diagnostics.extensions_codes == ["BAD_USER_INPUT"]

        assert diagnostics.errors == [
                 %{
                   "message" => "Variable \"$ids\" got invalid value",
                   "extensions" => %{"code" => "BAD_USER_INPUT"}
                 }
               ]
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
    assert log =~ ~s(classification="graphql")
    assert log =~ ~s(errorCodes=["BAD_USER_INPUT"])
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "todo issue with non-terminal blocker is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo (AI)",
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Arbeit (AI)"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "in arbeit ai issue with non-terminal blocker is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-in-arbeit-1",
      identifier: "MT-1001A",
      title: "Blocked active work",
      state: "In Arbeit (AI)",
      blocked_by: [%{id: "blocker-1a", identifier: "MT-1002A", state: "Review (AI)"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo (AI)",
      assigned_to_worker: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker remains dispatch-eligible in yolo mode" do
    previous_yolo = Application.get_env(:symphony_elixir, :yolo)

    on_exit(fn -> restore_app_env(:yolo, previous_yolo) end)

    Application.put_env(:symphony_elixir, :yolo, true)

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-yolo",
      identifier: "MT-1007-YOLO",
      title: "Owned elsewhere",
      state: "Todo (AI)",
      assigned_to_worker: false
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "manual approval issues remain dispatch-eligible in yolo mode" do
    previous_yolo = Application.get_env(:symphony_elixir, :yolo)

    on_exit(fn -> restore_app_env(:yolo, previous_yolo) end)

    Application.put_env(:symphony_elixir, :yolo, true)

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    planning_issue = %Issue{
      id: "yolo-planung",
      identifier: "MT-YOLO-1",
      title: "Yolo keeps manual planning",
      state: "Planung"
    }

    issues = [
      %Issue{
        id: "yolo-freigabe-implementierung",
        identifier: "MT-YOLO-2",
        title: "Yolo skips implementation approval",
        state: "Freigabe Implementierung"
      },
      %Issue{
        id: "yolo-freigabe-review",
        identifier: "MT-YOLO-3",
        title: "Yolo skips review approval",
        state: "Freigabe Review"
      }
    ]

    assert Enum.all?(issues, &Orchestrator.should_dispatch_issue_for_test(&1, state))
    refute Orchestrator.should_dispatch_issue_for_test(planning_issue, state)
  end

  test "todo issue with terminal blockers remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo (AI)",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Review"}]
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "in arbeit ai issue with terminal blockers remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-in-arbeit-1",
      identifier: "MT-1003A",
      title: "Ready active work",
      state: "In Arbeit (AI)",
      blocked_by: [%{id: "blocker-2a", identifier: "MT-1004A", state: "Review"}]
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "completed issue in the same active state is not dispatched again until the state changes" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      completed_states: %{"ready-2" => "review (ai)"},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    same_state_issue = %Issue{
      id: "ready-2",
      identifier: "MT-1008",
      title: "Review already done",
      state: "Review (AI)"
    }

    changed_state_issue = %{same_state_issue | state: "Test (AI)"}

    refute Orchestrator.should_dispatch_issue_for_test(same_state_issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(changed_state_issue, state)
  end

  test "dispatch revalidation skips stale todo issue once a non-terminal blocker appears" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo (AI)",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo (AI)",
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Arbeit (AI)"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"
    assert skipped_issue.blocked_by == [%{id: "blocker-3", identifier: "MT-1006", state: "In Arbeit (AI)"}]
  end

  test "dispatch revalidation skips stale in arbeit ai issue once a non-terminal blocker appears" do
    stale_issue = %Issue{
      id: "blocked-in-arbeit-2",
      identifier: "MT-1005A",
      title: "Stale blocked active work",
      state: "In Arbeit (AI)",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-in-arbeit-2",
      identifier: "MT-1005A",
      title: "Stale blocked active work",
      state: "In Arbeit (AI)",
      blocked_by: [%{id: "blocker-3a", identifier: "MT-1006A", state: "Review (AI)"}]
    }

    fetcher = fn ["blocked-in-arbeit-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005A"

    assert skipped_issue.blocked_by == [
             %{id: "blocker-3a", identifier: "MT-1006A", state: "Review (AI)"}
           ]
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      config = Config.settings!()
      assert config.hooks.after_create =~ "echo after_create > after_create.log"
      assert config.hooks.before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    previous_timeout = Application.get_env(:symphony_elixir, :workspace_hook_timeout_ms)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:symphony_elixir, :workspace_hook_timeout_ms)
      else
        Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, previous_timeout)
      end
    end)

    Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, 10)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "release command binding preserves custom workflow commands and explicit overrides" do
    override = System.get_env("SYMPHONY_CODEX_COMMAND")
    on_exit(fn -> restore_env("SYMPHONY_CODEX_COMMAND", override) end)
    System.delete_env("SYMPHONY_CODEX_COMMAND")
    System.put_env("SYMPHONY_RELEASE_ROOT", "/synthetic/release with spaces")

    for command <- ["custom-agent --profile local app-server", "codex app-server"] do
      write_workflow_file!(Workflow.workflow_file_path(), codex_command: command)
      assert Config.local_codex_command() == command
    end

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "sym-codex --observer")
    assert Config.local_codex_command() == "'/synthetic/release with spaces/sym-codex' --observer"
    System.put_env("SYMPHONY_CODEX_COMMAND", "explicit --profile personal")
    assert Config.local_codex_command() == "explicit --profile personal"
    System.put_env("SYMPHONY_CODEX_COMMAND", "  ")
    assert Config.local_codex_command() == "'/synthetic/release with spaces/sym-codex' --observer"
    System.delete_env("SYMPHONY_RELEASE_ROOT")
    helper = Path.join(Path.dirname(Workflow.default_workflow_file_path()), "sym-codex")
    command = Config.local_codex_command()
    assert command == "'#{helper}' --observer"
    assert {output, 0} = System.cmd("/bin/bash", ["--noprofile", "--norc", "-c", "PATH=/usr/bin:/bin #{command} --help"], stderr_to_stdout: true)
    assert output =~ "Usage:"

    python = System.get_env("SYMPHONY_PYTHON")
    on_exit(fn -> restore_env("SYMPHONY_PYTHON", python) end)
    System.delete_env("SYMPHONY_PYTHON")
    File.write!(Workflow.workflow_file_path(), "---\ntracker:\n  kind: linear\n  auth_mode: app\ncodex:\n  command: sym-codex --observer\n---\n")
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
    {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
    app_command = Config.local_codex_command()
    assert app_command =~ "SYMPHONY_PYTHON="
    assert {app_output, 0} = System.cmd("/bin/bash", ["--noprofile", "--norc", "-c", "PATH=/usr/bin:/bin #{app_command} --help"], stderr_to_stdout: true)
    assert app_output =~ "Usage:"
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: nil,
      max_concurrent_agents: nil,
      codex_approval_policy: nil,
      codex_thread_sandbox: nil,
      codex_turn_sandbox_policy: nil,
      codex_turn_timeout_ms: nil,
      codex_read_timeout_ms: nil,
      codex_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.api_key == nil
    assert config.tracker.project_slug == nil
    assert config.tracker.team_key == nil
    assert config.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
    assert config.worker.max_concurrent_agents_per_host == nil
    assert config.agent.max_concurrent_agents == 10
    assert config.codex.command == "codex app-server"

    assert config.tracker.active_states == [
             "Todo (AI)",
             "Planung (AI)",
             "In Arbeit (AI)",
             "PreReview (AI)",
             "Review (AI)",
             "Test (AI)",
             "Abbruch (AI)",
             "Merge (AI)"
           ]

    assert config.tracker.terminal_states == ["Review", "Fertig", "Abgebrochen"]

    assert config.codex.approval_policy == %{
             "reject" => %{
               "sandbox_approval" => true,
               "rules" => true,
               "mcp_elicitations" => true
             }
           }

    assert config.codex.thread_sandbox == "workspace-write"

    assert {:ok, canonical_default_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [canonical_default_workspace_root],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert config.codex.turn_timeout_ms == 3_600_000
    assert config.codex.read_timeout_ms == 30_000
    assert config.codex.stall_timeout_ms == 300_000
    assert config.server.port == 4_000
    assert config.server.host == "127.0.0.1"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server --model gpt-5.3-codex")
    assert Config.settings!().codex.command == "codex app-server --model gpt-5.3-codex"

    explicit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-explicit-sandbox-root-#{System.unique_integer([:positive])}"
      )

    explicit_workspace = Path.join(explicit_root, "MT-EXPLICIT")
    explicit_cache = Path.join(explicit_workspace, "cache")
    File.mkdir_p!(explicit_cache)

    on_exit(fn -> File.rm_rf(explicit_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: explicit_root,
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [explicit_workspace, explicit_cache]
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "on-request"
    assert config.codex.thread_sandbox == "workspace-write"

    assert Config.codex_turn_sandbox_policy(explicit_workspace) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [explicit_workspace, explicit_cache]
           }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_concurrent_agents"

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "worker.max_concurrent_agents_per_host"

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_read_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.read_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.stall_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Planung" => 0, "Fertig" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.approval_policy == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.thread_sandbox == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_sandbox_policy: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_sandbox_policy"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "future-policy",
      codex_thread_sandbox: "future-sandbox",
      codex_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "future-policy"
    assert config.codex.thread_sandbox == "future-sandbox"

    assert :ok = Config.validate!()

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")
    assert Config.settings!().codex.command == "codex app-server"
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    project_slug_env_var = "SYMP_LINEAR_PROJECT_SLUG_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"
    project_slug = "resolved-project-slug"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)
    previous_project_slug = System.get_env(project_slug_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)
    System.put_env(project_slug_env_var, project_slug)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
      restore_env(project_slug_env_var, previous_project_slug)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      tracker_project_slug: "$#{project_slug_env_var}",
      workspace_root: "$#{workspace_env_var}",
      codex_command: "#{codex_bin} app-server"
    )

    config = Config.settings!()
    assert config.tracker.api_key == api_key
    assert config.tracker.project_slug == project_slug
    assert config.workspace.root == Path.expand(workspace_root)
    assert config.codex.command == "#{codex_bin} app-server"
  end

  test "linear config requires exactly one project or team scope and resolves team env references" do
    team_key_env_var = "SYMP_LINEAR_TEAM_KEY_#{System.unique_integer([:positive])}"
    previous_team_key = System.get_env(team_key_env_var)

    on_exit(fn -> restore_env(team_key_env_var, previous_team_key) end)
    System.put_env(team_key_env_var, "PRO")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      tracker_team_key: nil
    )

    assert :ok = Config.validate!()
    assert {:ok, {:project, "project"}} = Config.linear_scope()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_team_key: "$#{team_key_env_var}"
    )

    assert :ok = Config.validate!()
    assert Config.settings!().tracker.team_key == "PRO"
    assert {:ok, {:team, "PRO"}} = Config.linear_scope()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      tracker_team_key: "PRO"
    )

    assert {:error, :multiple_linear_scopes} = Config.validate!()
    assert {:error, :multiple_linear_scopes} = Config.linear_scope()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_team_key: nil
    )

    assert {:error, :missing_linear_scope} = Config.validate!()
    assert {:error, :missing_linear_scope} = Config.linear_scope()
  end

  test "linear scope falls back to repository environment for fields missing from the workflow" do
    env_names = ["LINEAR_PROJECT_SLUG", "LINEAR_TEAM_KEY"]
    previous_env = Map.new(env_names, fn name -> {name, System.get_env(name)} end)

    on_exit(fn ->
      Enum.each(previous_env, fn {name, value} -> restore_env(name, value) end)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "$LINEAR_PROJECT_SLUG",
      tracker_team_key: nil
    )

    for {project_slug, team_key, expected_scope} <- [
          {"symphony-project", "", {:ok, {:project, "symphony-project"}}},
          {"", "QAI", {:ok, {:team, "QAI"}}},
          {"symphony-project", "QAI", {:error, :multiple_linear_scopes}},
          {"", "", {:error, :missing_linear_scope}}
        ] do
      System.put_env("LINEAR_PROJECT_SLUG", project_slug)
      System.put_env("LINEAR_TEAM_KEY", team_key)

      assert Config.linear_scope() == expected_scope
    end
  end

  test "direct linear scopes and explicit env references take precedence over field fallbacks" do
    project_env_var = "SYMP_EXPLICIT_PROJECT_SLUG_#{System.unique_integer([:positive])}"
    team_env_var = "SYMP_EXPLICIT_TEAM_KEY_#{System.unique_integer([:positive])}"
    env_names = ["LINEAR_PROJECT_SLUG", "LINEAR_TEAM_KEY", project_env_var, team_env_var]
    previous_env = Map.new(env_names, fn name -> {name, System.get_env(name)} end)

    on_exit(fn ->
      Enum.each(previous_env, fn {name, value} -> restore_env(name, value) end)
    end)

    System.put_env("LINEAR_PROJECT_SLUG", "fallback-project")
    System.put_env("LINEAR_TEAM_KEY", "")
    System.put_env(project_env_var, "referenced-project")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "direct-project",
      tracker_team_key: nil
    )

    assert {:ok, {:project, "direct-project"}} = Config.linear_scope()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "$#{project_env_var}",
      tracker_team_key: nil
    )

    assert {:ok, {:project, "referenced-project"}} = Config.linear_scope()

    System.put_env("LINEAR_PROJECT_SLUG", "")
    System.put_env("LINEAR_TEAM_KEY", "fallback-team")
    System.put_env(team_env_var, "REFERENCED")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_team_key: "direct-team"
    )

    assert {:ok, {:team, "direct-team"}} = Config.linear_scope()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_team_key: "$#{team_env_var}"
    )

    assert {:ok, {:team, "REFERENCED"}} = Config.linear_scope()
  end

  test "CLI loads repository-local app binding and team scope before validating the shared workflow" do
    project_root =
      Path.join(System.tmp_dir!(), "symphony-cli-team-scope-#{System.unique_integer([:positive])}")

    env_names =
      ~w(LINEAR_API_KEY LINEAR_ASSIGNEE LINEAR_PROJECT_SLUG LINEAR_TEAM_KEY LINEAR_APP_CLIENT_ID LINEAR_APP_WORKSPACE_ID LINEAR_APP_USER_ID LINEAR_APP_INSTALLATION_ID LINEAR_APP_SECRET)

    previous_env = Map.new(env_names, fn name -> {name, System.get_env(name)} end)
    parent = self()

    on_exit(fn ->
      Enum.each(previous_env, fn {name, value} -> restore_env(name, value) end)
      File.rm_rf(project_root)
    end)

    Enum.each(env_names, &System.delete_env/1)
    config_dir = SymphonyElixir.EnvFile.config_dir(project_root)
    File.mkdir_p!(config_dir)

    File.write!(
      Path.join(config_dir, ".env.local"),
      "LINEAR_API_KEY=test-token\nLINEAR_ASSIGNEE=dev@example.invalid\nLINEAR_PROJECT_SLUG=\nLINEAR_TEAM_KEY=QAI\n" <>
        "LINEAR_APP_CLIENT_ID=synthetic-client\nLINEAR_APP_WORKSPACE_ID=synthetic-workspace\nLINEAR_APP_USER_ID=synthetic-app\n" <>
        "LINEAR_APP_INSTALLATION_ID=synthetic-installation\nLINEAR_APP_SECRET=synthetic-secret\n"
    )

    workflow_file = Path.expand("../../WORKFLOW.md", __DIR__)

    deps = %{
      file_regular?: &File.regular?/1,
      load_env_files: &SymphonyElixir.EnvFile.load_runtime/1,
      set_workflow_file_path: fn path ->
        :ok = Workflow.set_workflow_file_path(path)
        Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
        :ok
      end,
      validate_startup_requirements: fn ->
        send(parent, {:scope_before_start, Config.linear_scope()})
        Config.validate_startup_requirements()
      end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.run(workflow_file, project_root, deps)
    assert_received {:scope_before_start, {:ok, {:team, "QAI"}}}
    assert Config.settings!().tracker.app["state_root"] == Path.join(project_root, ".symphony/state")
    assert System.get_env("LINEAR_APP_SECRET") == nil
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.api_key == "env:#{api_key_env_var}"
    assert config.workspace.root == "env:#{workspace_env_var}"
  end

  test "config leaves optional string settings nil when env indirection is missing" do
    project_slug_env_var = "SYMP_MISSING_PROJECT_SLUG_#{System.unique_integer([:positive])}"
    previous_project_slug = System.get_env(project_slug_env_var)

    on_exit(fn ->
      restore_env(project_slug_env_var, previous_project_slug)
    end)

    System.delete_env(project_slug_env_var)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "$#{project_slug_env_var}"
    )

    assert Config.settings!().tracker.project_slug == nil
  end

  test "config resolves built-in project worktrees root from the invocation directory" do
    original_cwd = File.cwd!()
    project_root = Path.join(System.tmp_dir!(), "symphony-project-root-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.cd!(original_cwd)
      File.rm_rf(project_root)
    end)

    File.mkdir_p!(project_root)
    File.cd!(project_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "$SYMPHONY_PROJECT_WORKTREES_ROOT"
    )

    assert Config.settings!().workspace.root == project_root <> "-worktrees"
  end

  test "runtime paths fall back to the invocation directory when git common dir output is empty" do
    original_cwd = File.cwd!()
    original_path = System.get_env("PATH")
    test_root = Path.join(System.tmp_dir!(), "symphony-empty-git-root-#{System.unique_integer([:positive])}")
    fake_bin = Path.join(test_root, "bin")
    fake_git = Path.join(fake_bin, "git")

    on_exit(fn ->
      File.cd!(original_cwd)
      restore_env("PATH", original_path)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(fake_bin)
    File.write!(fake_git, "#!/bin/sh\nexit 0\n")
    File.chmod!(fake_git, 0o755)
    System.put_env("PATH", "#{fake_bin}:#{original_path}")
    File.cd!(test_root)

    assert SymphonyElixir.RuntimePaths.project_worktrees_root() == test_root <> "-worktrees"
  end

  test "config resolves built-in project worktrees root from the source repo when invoked from a worktree" do
    original_cwd = File.cwd!()

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-project-worktree-root-#{System.unique_integer([:positive])}"
      )

    source_repo = Path.join(test_root, "source")
    worktree_root = source_repo <> "-worktrees"
    worktree = Path.join(worktree_root, "PRO-49")

    on_exit(fn ->
      File.cd!(original_cwd)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(source_repo)
    assert {_, 0} = System.cmd("git", ["-C", source_repo, "init", "-b", "main"], stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"], stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"], stderr_to_stdout: true)
    File.write!(Path.join(source_repo, "README.md"), "base\n")
    assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", "README.md"], stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"], stderr_to_stdout: true)
    File.mkdir_p!(worktree_root)

    assert {_, 0} =
             System.cmd(
               "git",
               ["-C", source_repo, "worktree", "add", "-b", "symphony/PRO-49", worktree, "HEAD"],
               stderr_to_stdout: true
             )

    File.cd!(worktree)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "$SYMPHONY_PROJECT_WORKTREES_ROOT"
    )

    assert Config.settings!().workspace.root == worktree_root
  end

  test "config supports per-state max concurrent agent overrides" do
    workflow = """
    ---
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 2)
    assert :ok = Config.validate!()
    assert Config.settings!().worker.max_concurrent_agents_per_host == 2
  end

  test "config keeps only AI/Codex managed active states" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "Planung", "Freigabe Review", "Review (AI)", "Abbruch (AI)", "Fertig"]
    )

    assert Config.settings!().tracker.active_states == ["Review (AI)", "Abbruch (AI)"]
  end

  test "schema helpers cover custom type and state limit validation" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)

    assert Schema.normalize_state_limits(nil) == %{}

    assert Schema.normalize_state_limits(%{"In Progress" => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert changeset.errors == [
             limits: {"state names must not be blank", []},
             limits: {"limits must be positive integers", []}
           ]
  end

  test "workspace defaults follow the runtime temp directory without recompilation" do
    previous_tmpdir = System.get_env("TMPDIR")

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-workspace-default-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: nil)
    assert {:ok, _settings} = Schema.parse(%{})

    try do
      for name <- ["first", "second"] do
        tmpdir = Path.join(test_root, name)
        File.mkdir_p!(tmpdir)
        System.put_env("TMPDIR", tmpdir)
        assert System.tmp_dir!() == tmpdir
        expected_root = Path.join(tmpdir, "symphony_workspaces")

        for config <- [%{}, %{workspace: %{}}, %{workspace: %{root: nil}}] do
          assert {:ok, settings} = Schema.parse(config)
          assert settings.workspace.root == expected_root
        end

        assert Config.settings!().workspace.root == expected_root
      end
    after
      restore_env("TMPDIR", previous_tmpdir)
      File.rm_rf!(test_root)
    end
  end

  test "schema parse normalizes policy keys and env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{empty_secret_env}"},
               workspace: %{root: "$#{missing_workspace_env}"},
               codex: %{approval_policy: %{reject: %{sandbox_approval: true}}}
             })

    assert settings.tracker.api_key == nil
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")

    assert settings.codex.approval_policy == %{
             "reject" => %{"sandbox_approval" => true}
           }

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{missing_secret_env}"},
               workspace: %{root: ""}
             })

    assert settings.tracker.api_key == "fallback-linear-token"
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
  end

  test "schema resolves sandbox policies from explicit and default workspaces" do
    explicit_policy = %{"type" => "workspaceWrite", "writableRoots" => ["/tmp/explicit"]}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: explicit_policy},
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == explicit_policy

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: nil},
             workspace: %Schema.Workspace{root: ""}
           }) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               codex: %Codex{turn_sandbox_policy: nil},
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("/tmp/workspace")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "schema keeps workspace roots raw while sandbox helpers expand only for local use" do
    assert {:ok, settings} =
             Schema.parse(%{
               workspace: %{root: "~/.symphony-workspaces"},
               codex: %{}
             })

    assert settings.workspace.root == "~/.symphony-workspaces"

    assert Schema.resolve_turn_sandbox_policy(settings) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("~/.symphony-workspaces")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert {:ok, remote_policy} =
             Schema.resolve_runtime_turn_sandbox_policy(settings, nil, remote: true)

    assert remote_policy == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["~/.symphony-workspaces"],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "workspace hooks receive built-in project and workflow path variables" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-env-#{System.unique_integer([:positive])}"
      )

    project_root = Path.join(test_root, "project")
    workspace_root = project_root <> "-worktrees"
    env_log = Path.join(test_root, "hook-env.log")
    original_cwd = File.cwd!()

    on_exit(fn ->
      File.cd!(original_cwd)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(project_root)
    File.cd!(project_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "$SYMPHONY_PROJECT_WORKTREES_ROOT",
      hook_after_create: "printf '%s\\n%s\\n%s\\n%s\\n' \"$SYMPHONY_PROJECT_ROOT\" \"$SYMPHONY_PROJECT_WORKTREES_ROOT\" \"$SYMPHONY_WORKFLOW_DIR\" \"$SYMPHONY_WORKFLOW_FILE\" > \"#{env_log}\""
    )

    issue = %Issue{id: "issue-hook-env", identifier: "MT-HOOK-ENV"}

    assert {:ok, workspace} = Workspace.create_for_issue(issue)
    assert workspace == Path.join(workspace_root, "MT-HOOK-ENV")

    [logged_project_root, logged_worktrees_root, logged_workflow_dir, logged_workflow_file] =
      env_log
      |> File.read!()
      |> String.split("\n", trim: true)

    assert logged_project_root == project_root
    assert logged_worktrees_root == workspace_root
    assert logged_workflow_dir == SymphonyElixir.RuntimePaths.workflow_dir()
    assert logged_workflow_file == Workflow.workflow_file_path()
  end

  test "runtime sandbox policy resolution passes explicit policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-100")
      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => ["relative/path"],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "futureSandbox",
          nested: %{flag: true}
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "futureSandbox",
               "nested" => %{"flag" => true}
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             SymphonyElixir.PathSafety.canonicalize(path)
  end

  test "runtime sandbox policy resolution defaults when omitted and ignores workspace for explicit policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      settings = Config.settings!()

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:ok, default_policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [canonical_workspace_root]

      assert {:ok, blank_workspace_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, "")

      assert blank_workspace_policy == default_policy

      read_only_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}}
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, 123)

      future_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "futureSandbox", "nested" => %{"flag" => true}}}
      }

      assert {:ok, %{"type" => "futureSandbox", "nested" => %{"flag" => true}}} =
               Schema.resolve_runtime_turn_sandbox_policy(future_settings, 123)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  test "remote workspace lifecycle uses ssh host aliases from worker config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-workspace-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_root = "~/.symphony-remote-workspaces"
      workspace_path = "/remote/home/.symphony-remote-workspaces/MT-SSH-WS"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
          ;;
      esac

      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_run: "echo before-run",
        hook_after_run: "echo after-run",
        hook_before_remove: "echo before-remove"
      )

      assert Config.settings!().worker.ssh_hosts == ["worker-01:2200"]
      assert Config.settings!().workspace.root == workspace_root
      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_before_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_after_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.remove_issue_workspaces("MT-SSH-WS", "worker-01:2200")

      trace = File.read!(trace_file)
      assert trace =~ "-p 2200 worker-01 bash -lc"
      assert trace =~ "__SYMPHONY_WORKSPACE__"
      assert trace =~ "~/.symphony-remote-workspaces/MT-SSH-WS"
      assert trace =~ "${workspace#~/}"
      assert trace =~ "echo before-run"
      assert trace =~ "echo after-run"
      assert trace =~ "echo before-remove"
      assert trace =~ "rm -rf"
      assert trace =~ workspace_path
    after
      File.rm_rf(test_root)
    end
  end

  defp write_minimal_mix_project!(repo_root, app_name) when is_binary(repo_root) and is_atom(app_name) do
    File.write!(
      Path.join(repo_root, "mix.exs"),
      """
      defmodule #{Macro.camelize(Atom.to_string(app_name))}.MixProject do
        use Mix.Project

        def project do
          [
            app: #{inspect(app_name)},
            version: "0.1.0",
            deps: []
          ]
        end
      end
      """
    )

    File.write!(
      Path.join(repo_root, "mise.toml"),
      """
      [tools]
      erlang = "28"
      elixir = "1.19.5-otp-28"
      """
    )
  end

  defp install_current_worktree_scripts!(repo_root) when is_binary(repo_root) do
    symphony_dir = Path.join(repo_root, ".symphony")
    File.mkdir_p!(symphony_dir)
    File.cp!(project_worktree_script_path("on_create_worktree.py"), Path.join(symphony_dir, "on_create_worktree.py"))
    File.cp!(project_worktree_script_path("on_remove_worktree.py"), Path.join(symphony_dir, "on_remove_worktree.py"))
  end

  defp project_worktree_script_path(filename) when is_binary(filename) do
    Path.expand("../../.symphony/#{filename}", __DIR__)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp review_autocommit_marker_path!(workspace) do
    {output, 0} =
      System.cmd("git", [
        "-C",
        workspace,
        "rev-parse",
        "--path-format=absolute",
        "--git-path",
        "symphony.review-ai-autocommit.done"
      ])

    String.trim(output)
  end
end
