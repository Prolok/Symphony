defmodule Mix.Tasks.Workspace.BeforeRemoveTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Workspace.BeforeRemove

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("workspace.before_remove")
    temp_cwd = temp_root("workspace-before-remove-cwd")
    original_cwd = File.cwd!()
    File.mkdir_p!(temp_cwd)
    File.cd!(temp_cwd)

    on_exit(fn ->
      File.cd!(original_cwd)
      File.rm_rf!(temp_cwd)
    end)

    :ok
  end

  test "prints help" do
    output =
      capture_io(fn ->
        BeforeRemove.run(["--help"])
      end)

    assert output =~ "mix workspace.before_remove"
  end

  test "fails on invalid options" do
    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      BeforeRemove.run(["--wat"])
    end
  end

  test "ignores relative workspace and source repo overrides" do
    with_path([], fn ->
      output =
        capture_io(fn ->
          BeforeRemove.run([
            "--branch",
            "feature/relative-overrides",
            "--workspace",
            "relative-worktree",
            "--source-repo",
            "relative-source"
          ])
        end)

      assert output == ""
    end)
  end

  test "no-ops when branch is unavailable" do
    with_path([], fn ->
      in_temp_dir(fn ->
        output =
          capture_io(fn ->
            BeforeRemove.run([])
          end)

        assert output == ""
      end)
    end)
  end

  test "no-ops when gh is unavailable" do
    with_path([], fn ->
      output =
        capture_io(fn ->
          BeforeRemove.run(["--branch", "feature/no-gh"])
        end)

      assert output == ""
    end)
  end

  test "no-ops when gh command lookup succeeds but System.cmd raises" do
    with_fake_binaries(
      %{
        "gh" => """
        #!/bin/sh
        exit 0
        """
      },
      fn _log_path ->
        unique = System.unique_integer([:positive, :monotonic])
        missing_cwd = Path.join(System.tmp_dir!(), "workspace-before-remove-gh-missing-cwd-#{unique}")
        original_cwd = File.cwd!()

        try do
          File.mkdir_p!(missing_cwd)
          File.cd!(missing_cwd)
          File.rm_rf!(missing_cwd)

          output =
            capture_io(fn ->
              BeforeRemove.run(["--branch", "feature/broken-gh"])
            end)

          assert output == ""
        after
          File.cd!(original_cwd)
        end
      end
    )
  end

  test "uses current branch for lookup when branch option is omitted" do
    with_fake_gh_and_git(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
        printf '101\n102\n'
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "close" ] && [ "$3" = "101" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "close" ] && [ "$3" = "102" ]; then
        printf 'boom\n' >&2
        exit 17
      fi

      exit 99
      """,
      """
      #!/bin/sh
      printf 'feature/workpad\n'
      exit 0
      """,
      fn log_path ->
        {output, error_output} =
          capture_task_output(fn ->
            BeforeRemove.run([])
          end)

        assert output =~ "Closed PR #101 for branch feature/workpad"
        assert error_output =~ "Failed to close PR #102 for branch feature/workpad"

        log = File.read!(log_path)

        assert log =~
                 "pr list --repo openai/symphony --head feature/workpad --state open --json number --jq .[].number"

        assert log =~ "pr close 101 --repo openai/symphony"
        assert log =~ "pr close 102 --repo openai/symphony"
      end
    )
  end

  test "closes open pull requests for the branch and tolerates close failures" do
    with_fake_gh(fn log_path ->
      File.write!(log_path, "")

      {output, error_output} =
        capture_task_output(fn ->
          BeforeRemove.run(["--branch", "feature/workpad"])
        end)

      assert output =~ "Closed PR #101 for branch feature/workpad"
      assert error_output =~ "Failed to close PR #102 for branch feature/workpad"
      refute output =~ "Removed Git worktree"

      log = File.read!(log_path)

      assert log =~ "auth status"
      assert log =~ "pr list --repo openai/symphony --head feature/workpad --state open --json number --jq .[].number"
      assert log =~ "pr close 101 --repo openai/symphony"
      assert log =~ "pr close 102 --repo openai/symphony"

      {second_output, error_output} =
        capture_task_output(fn ->
          Mix.Task.reenable("workspace.before_remove")
          BeforeRemove.run(["--branch", "feature/workpad"])
        end)

      assert second_output =~ "Closed PR #101 for branch feature/workpad"
      assert error_output =~ "Failed to close PR #102 for branch feature/workpad"
    end)
  end

  test "formats close failures without command stderr output" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
        printf '102\n'
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "close" ] && [ "$3" = "102" ]; then
        exit 17
      fi

      exit 99
      """,
      fn log_path ->
        error_output =
          capture_io(:stderr, fn ->
            Mix.Task.reenable("workspace.before_remove")
            BeforeRemove.run(["--branch", "feature/no-output"])
          end)

        assert error_output =~ "Failed to close PR #102 for branch feature/no-output: exit 17"
        refute error_output =~ "output="
        log = File.read!(log_path)
        assert log =~ "pr list --repo openai/symphony --head feature/no-output --state open --json number --jq .[].number"
        assert log =~ "pr close 102 --repo openai/symphony"
      end
    )
  end

  test "no-ops when PR list fails for current branch" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
        exit 1
      fi

      exit 99
      """,
      fn log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run(["--branch", "feature/list-fails"])
          end)

        assert output == ""

        log = File.read!(log_path)
        assert log =~ "auth status"

        assert log =~
                 "pr list --repo openai/symphony --head feature/list-fails --state open --json number --jq .[].number"

        refute log =~ "pr close"
      end
    )
  end

  test "no-ops when git current branch is blank" do
    with_fake_gh_and_git(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      exit 99
      """,
      """
      #!/bin/sh
      printf '\n'
      exit 0
      """,
      fn log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run([])
          end)

        assert output == ""

        log = File.read!(log_path)
        assert log == ""
        refute log =~ "pr list"
      end
    )
  end

  test "no-ops when gh auth is unavailable" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"
      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 1
      fi
      exit 99
      """,
      fn log_path ->
        BeforeRemove.run(["--branch", "feature/no-auth"])

        log = File.read!(log_path)
        assert log =~ "auth status"
        refute log =~ "pr list"
      end
    )
  end

  test "removes the current linked git worktree and prunes its metadata" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
        exit 0
      fi

      exit 99
      """,
      fn log_path ->
        %{root: root, source_repo: source_repo, worktree: worktree, worktree_git_dir: worktree_git_dir} =
          create_worktree_fixture!("symphony/mt-123")

        original_cwd = File.cwd!()

        try do
          File.cd!(worktree)

          output =
            capture_io(fn ->
              BeforeRemove.run([])
            end)

          assert output =~ "Deleted local branch symphony/mt-123"
          assert output =~ "Removed Git worktree #{worktree}"
        after
          File.cd!(original_cwd)
        end

        refute File.exists?(worktree)
        refute File.exists?(worktree_git_dir)

        {worktree_list, 0} = System.cmd("git", ["-C", source_repo, "worktree", "list", "--porcelain"])
        refute worktree_list =~ worktree

        assert {"", 1} =
                 System.cmd("git", [
                   "-C",
                   source_repo,
                   "show-ref",
                   "--verify",
                   "--quiet",
                   "refs/heads/symphony/mt-123"
                 ])

        log = File.read!(log_path)
        assert log =~ "auth status"
        assert log =~ "pr list --repo openai/symphony --head symphony/mt-123 --state open --json number --jq .[].number"

        File.rm_rf!(root)
      end
    )
  end

  test "removes an empty -worktrees base directory after deleting the last worktree" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
        exit 0
      fi

      exit 99
      """,
      fn _log_path ->
        %{
          root: root,
          source_repo: source_repo,
          worktree: worktree,
          worktree_git_dir: worktree_git_dir
        } =
          create_worktree_fixture!(
            "symphony/pro-141-last-worktree",
            worktree_relative_path: "repo-worktrees/PRO-141"
          )

        worktrees_base_dir = source_repo <> "-worktrees"
        original_cwd = File.cwd!()

        try do
          File.cd!(worktree)

          output =
            capture_io(fn ->
              BeforeRemove.run([])
            end)

          assert output =~ "Removed Git worktree #{worktree}"
          assert output =~ "Removed empty worktrees base directory #{worktrees_base_dir}"
        after
          File.cd!(original_cwd)
        end

        refute File.exists?(worktree)
        refute File.exists?(worktree_git_dir)
        refute File.exists?(worktrees_base_dir)

        {worktree_list, 0} = System.cmd("git", ["-C", source_repo, "worktree", "list", "--porcelain"])
        refute worktree_list =~ worktree

        File.rm_rf!(root)
      end
    )
  end

  test "keeps a non-empty -worktrees base directory after deleting a worktree" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
        exit 0
      fi

      exit 99
      """,
      fn _log_path ->
        %{root: root, source_repo: source_repo, worktree: worktree} =
          create_worktree_fixture!(
            "symphony/pro-141-keep-base-dir",
            worktree_relative_path: "repo-worktrees/PRO-141"
          )

        worktrees_base_dir = source_repo <> "-worktrees"
        sentinel = Path.join(worktrees_base_dir, "keep.txt")
        File.write!(sentinel, "keep\n")
        original_cwd = File.cwd!()

        try do
          File.cd!(worktree)

          output =
            capture_io(fn ->
              BeforeRemove.run([])
            end)

          assert output =~ "Removed Git worktree #{worktree}"
          refute output =~ "Removed empty worktrees base directory #{worktrees_base_dir}"
        after
          File.cd!(original_cwd)
        end

        assert File.dir?(worktrees_base_dir)
        assert File.read!(sentinel) == "keep\n"

        File.rm_rf!(root)
      end
    )
  end

  test "does not remove an unrelated empty -worktrees directory after deleting a worktree" do
    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
        exit 0
      fi

      exit 99
      """,
      fn _log_path ->
        %{root: root, source_repo: source_repo, worktree: worktree, worktree_git_dir: worktree_git_dir} =
          create_worktree_fixture!(
            "symphony/pro-141-unrelated-base-dir",
            worktree_relative_path: "other-worktrees/PRO-141"
          )

        unrelated_base_dir = Path.dirname(worktree)
        refute unrelated_base_dir == source_repo <> "-worktrees"
        original_cwd = File.cwd!()

        try do
          File.cd!(worktree)

          output =
            capture_io(fn ->
              BeforeRemove.run([])
            end)

          assert output =~ "Removed Git worktree #{worktree}"
          refute output =~ "Removed empty worktrees base directory #{unrelated_base_dir}"
        after
          File.cd!(original_cwd)
        end

        refute File.exists?(worktree)
        refute File.exists?(worktree_git_dir)
        assert File.dir?(unrelated_base_dir)

        File.rm_rf!(root)
      end
    )
  end

  test "supports workspace and source repo overrides with repo auto-detection" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-overrides-#{unique}")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)

    try do
      with_fake_binaries(
        %{
          "gh" => """
          #!/bin/sh
          printf 'gh %s\\n' "$*" >> "$GH_LOG"

          if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
            exit 0
          fi

          if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
            printf '101\\n'
            exit 0
          fi

          if [ "$1" = "pr" ] && [ "$2" = "close" ] && [ "$3" = "101" ]; then
            exit 0
          fi

          exit 99
          """,
          "git" => """
          #!/bin/sh
          printf 'git %s\\n' "$*" >> "$GH_LOG"

          if [ "$1" = "-C" ] && [ "$2" = "#{workspace}" ] && [ "$3" = "remote" ] && [ "$4" = "get-url" ] && [ "$5" = "origin" ]; then
            printf 'git@github.com:acme/widget.git\\n'
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
            printf 'worktree #{workspace}\\nHEAD abc123\\nbranch refs/heads/feature/derived\\n'
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "ls-remote" ] && [ "$4" = "--exit-code" ] && [ "$5" = "--heads" ] && [ "$6" = "origin" ] && [ "$7" = "feature/derived" ]; then
            printf 'abc123\\trefs/heads/feature/derived\\n'
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "push" ] && [ "$4" = "origin" ] && [ "$5" = "--delete" ] && [ "$6" = "feature/derived" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "show-ref" ] && [ "$4" = "--verify" ] && [ "$5" = "--quiet" ] && [ "$6" = "refs/heads/feature/derived" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "branch" ] && [ "$4" = "-D" ] && [ "$5" = "feature/derived" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "prune" ]; then
            exit 0
          fi

          exit 99
          """
        },
        fn log_path ->
          output =
            capture_io(fn ->
              BeforeRemove.run(["--workspace", workspace, "--source-repo", source_repo])
            end)

          assert output =~ "Closed PR #101 for branch feature/derived"
          assert output =~ "Deleted remote branch feature/derived"
          assert output =~ "Deleted local branch feature/derived"
          log = File.read!(log_path)
          assert log =~ "gh pr list --repo acme/widget --head feature/derived --state open --json number --jq .[].number"
          assert log =~ "gh pr close 101 --repo acme/widget"
          assert log =~ "git -C #{workspace} remote get-url origin"
          assert log =~ "git -C #{source_repo} worktree list --porcelain"
          assert log =~ "git -C #{source_repo} ls-remote --exit-code --heads origin feature/derived"
          assert log =~ "git -C #{source_repo} push origin --delete feature/derived"
          assert log =~ "git -C #{source_repo} worktree remove --force #{workspace}"
          assert log =~ "git -C #{source_repo} show-ref --verify --quiet refs/heads/feature/derived"
          assert log =~ "git -C #{source_repo} branch -D feature/derived"
          assert log =~ "git -C #{source_repo} worktree prune"
        end
      )
    after
      File.rm_rf!(root)
    end
  end

  test "skips PR lookup when the overridden workspace branch is blank" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-blank-branch-#{unique}")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)

    try do
      with_fake_binaries(
        %{
          "git" => """
          #!/bin/sh
          printf 'git %s\\n' "$*" >> "$GH_LOG"

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "show-ref" ] && [ "$4" = "--verify" ] && [ "$5" = "--quiet" ] && [ "$6" = "refs/heads/feature/blank-branch" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "branch" ] && [ "$4" = "-D" ] && [ "$5" = "feature/blank-branch" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "prune" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
            printf 'worktree #{workspace}\\nHEAD abc123\\nbranch refs/heads/feature/blank-branch\\n'
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "ls-remote" ] && [ "$4" = "--exit-code" ] && [ "$5" = "--heads" ] && [ "$6" = "origin" ] && [ "$7" = "feature/blank-branch" ]; then
            exit 2
          fi

          exit 99
          """
        },
        fn log_path ->
          output =
            capture_io(fn ->
              BeforeRemove.run(["--workspace", workspace, "--source-repo", source_repo, "--repo", "acme/widget"])
            end)

          assert output =~ "Removed Git worktree #{workspace}"
          log = File.read!(log_path)
          assert log =~ "git -C #{source_repo} worktree list --porcelain"
          assert log =~ "git -C #{source_repo} ls-remote --exit-code --heads origin feature/blank-branch"
          assert log =~ "git -C #{source_repo} show-ref --verify --quiet refs/heads/feature/blank-branch"
          assert log =~ "git -C #{source_repo} branch -D feature/blank-branch"
          refute log =~ "push origin --delete feature/blank-branch"
          refute log =~ "gh "
        end
      )
    after
      File.rm_rf!(root)
    end
  end

  test "skips PR lookup when the overridden workspace branch cannot be read" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-branch-error-#{unique}")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)

    try do
      with_fake_binaries(
        %{
          "git" => """
          #!/bin/sh
          printf 'git %s\\n' "$*" >> "$GH_LOG"

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "show-ref" ] && [ "$4" = "--verify" ] && [ "$5" = "--quiet" ] && [ "$6" = "refs/heads/feature/branch-error" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "branch" ] && [ "$4" = "-D" ] && [ "$5" = "feature/branch-error" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "prune" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
            printf 'worktree #{workspace}\\nHEAD abc123\\nbranch refs/heads/feature/branch-error\\n'
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "ls-remote" ] && [ "$4" = "--exit-code" ] && [ "$5" = "--heads" ] && [ "$6" = "origin" ] && [ "$7" = "feature/branch-error" ]; then
            exit 2
          fi

          exit 99
          """
        },
        fn log_path ->
          output =
            capture_io(fn ->
              BeforeRemove.run(["--workspace", workspace, "--source-repo", source_repo, "--repo", "acme/widget"])
            end)

          assert output =~ "Removed Git worktree #{workspace}"
          log = File.read!(log_path)
          assert log =~ "git -C #{source_repo} worktree list --porcelain"
          assert log =~ "git -C #{source_repo} ls-remote --exit-code --heads origin feature/branch-error"
          assert log =~ "git -C #{source_repo} show-ref --verify --quiet refs/heads/feature/branch-error"
          assert log =~ "git -C #{source_repo} branch -D feature/branch-error"
          refute log =~ "push origin --delete feature/branch-error"
          refute log =~ "gh "
        end
      )
    after
      File.rm_rf!(root)
    end
  end

  test "parses supported GitHub remote URL formats and falls back for unsupported ones" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-remote-parse-#{unique}")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)

    try do
      with_fake_binaries(
        %{
          "gh" => """
          #!/bin/sh
          printf 'gh %s\\n' "$*" >> "$GH_LOG"

          if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
            exit 0
          fi

          if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
            exit 0
          fi

          exit 99
          """,
          "git" => """
          #!/bin/sh
          printf 'git %s\\n' "$*" >> "$GH_LOG"

          if [ "$1" = "-C" ] && [ "$2" = "#{workspace}" ] && [ "$3" = "remote" ] && [ "$4" = "get-url" ] && [ "$5" = "origin" ]; then
            if [ "$REMOTE_URL" = "__ERROR__" ]; then
              exit 1
            fi

            printf '%s\\n' "$REMOTE_URL"
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
            printf 'worktree #{workspace}\\nHEAD abc123\\nbranch refs/heads/feature/remote-parse\\n'
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "ls-remote" ] && [ "$4" = "--exit-code" ] && [ "$5" = "--heads" ] && [ "$6" = "origin" ] && [ "$7" = "feature/remote-parse" ]; then
            exit 2
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "show-ref" ] && [ "$4" = "--verify" ] && [ "$5" = "--quiet" ] && [ "$6" = "refs/heads/feature/remote-parse" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "branch" ] && [ "$4" = "-D" ] && [ "$5" = "feature/remote-parse" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "prune" ]; then
            exit 0
          fi

          exit 99
          """
        },
        fn log_path ->
          cases = [
            {"ssh://git@github.com/acme/ssh-widget.git", "acme/ssh-widget"},
            {"https://github.com/acme/https-widget.git", "acme/https-widget"},
            {"http://github.com/acme/http-widget.git", "acme/http-widget"},
            {"https://github.com/acme/extra/widget.git", "openai/symphony"},
            {"git@gitlab.com:acme/widget.git", "openai/symphony"},
            {"__ERROR__", "openai/symphony"}
          ]

          Enum.each(cases, fn {remote_url, expected_repo} ->
            File.write!(log_path, "")

            with_env(%{"REMOTE_URL" => remote_url}, fn ->
              capture_io(fn ->
                Mix.Task.reenable("workspace.before_remove")

                BeforeRemove.run([
                  "--workspace",
                  workspace,
                  "--source-repo",
                  source_repo,
                  "--branch",
                  "feature/remote-parse"
                ])
              end)
            end)

            log = File.read!(log_path)

            assert log =~
                     "gh pr list --repo #{expected_repo} --head feature/remote-parse --state open --json number --jq .[].number"

            assert log =~ "git -C #{source_repo} worktree list --porcelain"
            assert log =~ "git -C #{source_repo} ls-remote --exit-code --heads origin feature/remote-parse"
            assert log =~ "git -C #{source_repo} show-ref --verify --quiet refs/heads/feature/remote-parse"
            assert log =~ "git -C #{source_repo} branch -D feature/remote-parse"
            refute log =~ "push origin --delete feature/remote-parse"
          end)
        end
      )
    after
      File.rm_rf!(root)
    end
  end

  test "logs an error when the linked worktree source repo cannot be entered" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-cd-failure-#{unique}")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)

    git_script = """
    #!/bin/sh
    if [ "$1" = "rev-parse" ] && [ "$2" = "--show-toplevel" ]; then
      printf '%s\n' "#{workspace}"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{workspace}" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--git-common-dir" ]; then
      printf '%s\n' "#{Path.join(source_repo, ".git")}"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{workspace}" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--absolute-git-dir" ]; then
      printf '%s\n' "#{Path.join(workspace, ".git")}"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
      printf 'worktree #{workspace}\nHEAD abc123\nbranch refs/heads/feature/cd-failure\n'
      exit 0
    fi

    exit 99
    """

    try do
      with_fake_binaries(%{"gh" => "#!/bin/sh\nexit 1\n", "git" => git_script}, fn _log_path ->
        error_output =
          capture_io(:stderr, fn ->
            BeforeRemove.run(["--branch", "feature/cd-failure"])
          end)

        assert error_output =~ "Failed to change directory to #{source_repo}"
      end)
    after
      File.rm_rf!(root)
    end
  end

  test "skips worktree removal when the current workspace is not a linked worktree" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-not-linked-#{unique}")
    workspace = Path.join(root, "wt")
    git_dir = Path.join(workspace, ".git")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)

    git_script = """
    #!/bin/sh
    if [ "$1" = "rev-parse" ] && [ "$2" = "--show-toplevel" ]; then
      printf '%s\n' "#{workspace}"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{workspace}" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--git-common-dir" ]; then
      printf '%s\n' "#{git_dir}"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{workspace}" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--absolute-git-dir" ]; then
      printf '%s\n' "#{git_dir}"
      exit 0
    fi

    exit 99
    """

    try do
      with_fake_binaries(%{"gh" => "#!/bin/sh\nexit 1\n", "git" => git_script}, fn _log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run(["--branch", "feature/not-linked"])
          end)

        assert output == ""
      end)
    after
      File.rm_rf!(root)
    end
  end

  test "resolves relative git paths when deriving the linked worktree source repo for an explicit workspace path" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-relative-git-paths-#{unique}")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)

    git_script = """
    #!/bin/sh
    printf '%s\\n' "$*" >> "$GH_LOG"

    if [ "$1" = "rev-parse" ] && [ "$2" = "--show-toplevel" ]; then
      printf '%s\\n' "#{workspace}"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{workspace}" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--git-common-dir" ]; then
      printf '%s\\n' "../repo/.git"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{workspace}" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--absolute-git-dir" ]; then
      printf '%s\\n' ".git"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
      printf 'worktree #{workspace}\\nHEAD abc123\\nbranch refs/heads/feature/relative-git-paths\\n'
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "ls-remote" ] && [ "$4" = "--exit-code" ] && [ "$5" = "--heads" ] && [ "$6" = "origin" ] && [ "$7" = "feature/relative-git-paths" ]; then
      exit 2
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ]; then
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "show-ref" ] && [ "$4" = "--verify" ] && [ "$5" = "--quiet" ] && [ "$6" = "refs/heads/feature/relative-git-paths" ]; then
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "branch" ] && [ "$4" = "-D" ] && [ "$5" = "feature/relative-git-paths" ]; then
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "prune" ]; then
      exit 0
    fi

    exit 99
    """

    try do
      with_fake_binaries(%{"gh" => "#!/bin/sh\nexit 1\n", "git" => git_script}, fn log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run(["--branch", "feature/relative-git-paths"])
          end)

        assert output =~ "Removed Git worktree #{workspace}"
        assert output =~ "Deleted local branch feature/relative-git-paths"

        log = File.read!(log_path)
        assert log =~ "-C #{workspace} rev-parse --git-common-dir"
        assert log =~ "-C #{workspace} rev-parse --absolute-git-dir"
        assert log =~ "-C #{source_repo} worktree list --porcelain"
      end)
    after
      File.rm_rf!(root)
    end
  end

  test "skips worktree removal when git path resolution fails" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-path-failure-#{unique}")
    workspace = Path.join(root, "wt")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)

    git_script = """
    #!/bin/sh
    if [ "$1" = "rev-parse" ] && [ "$2" = "--show-toplevel" ]; then
      printf '%s\n' "#{workspace}"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{workspace}" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--git-common-dir" ]; then
      exit 1
    fi

    exit 99
    """

    try do
      with_fake_binaries(%{"gh" => "#!/bin/sh\nexit 1\n", "git" => git_script}, fn _log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run(["--branch", "feature/path-failure"])
          end)

        assert output == ""
      end)
    after
      File.rm_rf!(root)
    end
  end

  test "resolves relative git paths when deriving the linked worktree source repo" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-relative-git-path-#{unique}")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)

    git_script = """
    #!/bin/sh
    printf 'git %s\\n' "$*" >> "$GH_LOG"

    if [ "$1" = "-C" ] && [ "$2" = "#{workspace}" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--git-common-dir" ]; then
      printf '../repo/.git\\n'
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{workspace}" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--absolute-git-dir" ]; then
      printf '.git\\n'
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
      printf 'worktree #{workspace}\\nHEAD abc123\\nbranch refs/heads/feature/relative-git-path\\n'
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "ls-remote" ] && [ "$4" = "--exit-code" ] && [ "$5" = "--heads" ] && [ "$6" = "origin" ] && [ "$7" = "feature/relative-git-path" ]; then
      exit 2
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ]; then
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "show-ref" ] && [ "$4" = "--verify" ] && [ "$5" = "--quiet" ] && [ "$6" = "refs/heads/feature/relative-git-path" ]; then
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "branch" ] && [ "$4" = "-D" ] && [ "$5" = "feature/relative-git-path" ]; then
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "prune" ]; then
      exit 0
    fi

    exit 99
    """

    try do
      with_fake_binaries(%{"gh" => "#!/bin/sh\nexit 1\n", "git" => git_script}, fn log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run(["--branch", "feature/relative-git-path", "--workspace", workspace])
          end)

        assert output =~ "Deleted local branch feature/relative-git-path"
        assert output =~ "Removed Git worktree #{workspace}"

        log = File.read!(log_path)
        assert log =~ "git -C #{workspace} rev-parse --git-common-dir"
        assert log =~ "git -C #{workspace} rev-parse --absolute-git-dir"
        assert log =~ "git -C #{source_repo} worktree list --porcelain"
        assert log =~ "git -C #{source_repo} show-ref --verify --quiet refs/heads/feature/relative-git-path"
      end)
    after
      File.rm_rf!(root)
    end
  end

  test "logs remove worktree failures" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-remove-failure-#{unique}")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)
    original_cwd = File.cwd!()

    git_script = """
    #!/bin/sh
    if [ "$1" = "rev-parse" ] && [ "$2" = "--show-toplevel" ]; then
      printf '%s\n' "#{workspace}"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{workspace}" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--git-common-dir" ]; then
      printf '%s\n' "#{Path.join(source_repo, ".git")}"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{workspace}" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--absolute-git-dir" ]; then
      printf '%s\n' "#{Path.join(workspace, ".git")}"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
      printf 'worktree #{workspace}\nHEAD abc123\nbranch refs/heads/feature/remove-failure\n'
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ]; then
      printf 'boom\n' >&2
      exit 17
    fi

    if [ "$1" = "-C" ] && [ "$3" = "worktree" ] && [ "$4" = "prune" ]; then
      exit 0
    fi

    exit 99
    """

    try do
      with_fake_binaries(%{"gh" => "#!/bin/sh\nexit 1\n", "git" => git_script}, fn _log_path ->
        error_output =
          capture_io(:stderr, fn ->
            BeforeRemove.run(["--branch", "feature/remove-failure"])
          end)

        assert error_output =~ "Failed to remove Git worktree #{workspace}: exit 17"
        assert error_output =~ "output=\"boom\""
      end)
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
    end
  end

  test "skips remote branch deletion when the branch is not present on origin" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-remote-missing-#{unique}")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)

    try do
      with_fake_binaries(
        %{
          "git" => """
          #!/bin/sh
          printf 'git %s\\n' "$*" >> "$GH_LOG"

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
            printf 'worktree #{workspace}\\nHEAD abc123\\nbranch refs/heads/feature/missing-remote\\n'
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "ls-remote" ] && [ "$4" = "--exit-code" ] && [ "$5" = "--heads" ] && [ "$6" = "origin" ] && [ "$7" = "feature/missing-remote" ]; then
            exit 2
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "show-ref" ] && [ "$4" = "--verify" ] && [ "$5" = "--quiet" ] && [ "$6" = "refs/heads/feature/missing-remote" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "branch" ] && [ "$4" = "-D" ] && [ "$5" = "feature/missing-remote" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "prune" ]; then
            exit 0
          fi

          exit 99
          """
        },
        fn log_path ->
          output =
            capture_io(fn ->
              BeforeRemove.run([
                "--branch",
                "feature/missing-remote",
                "--repo",
                "acme/widget",
                "--workspace",
                workspace,
                "--source-repo",
                source_repo
              ])
            end)

          assert output =~ "Removed Git worktree #{workspace}"
          log = File.read!(log_path)
          assert log =~ "git -C #{source_repo} worktree list --porcelain"
          assert log =~ "git -C #{source_repo} ls-remote --exit-code --heads origin feature/missing-remote"
          assert log =~ "git -C #{source_repo} show-ref --verify --quiet refs/heads/feature/missing-remote"
          assert log =~ "git -C #{source_repo} branch -D feature/missing-remote"
          refute log =~ "push origin --delete feature/missing-remote"
        end
      )
    after
      File.rm_rf!(root)
    end
  end

  test "skips remote branch deletion when the linked worktree has no branch metadata" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-detached-#{unique}")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)

    try do
      with_fake_binaries(
        %{
          "git" => """
          #!/bin/sh
          printf 'git %s\\n' "$*" >> "$GH_LOG"

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
            printf 'HEAD deadbeef\\nbranch refs/heads/ignored\\n\\nworktree #{workspace}\\nHEAD abc123\\ndetached\\n'
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "prune" ]; then
            exit 0
          fi

          exit 99
          """
        },
        fn log_path ->
          output =
            capture_io(fn ->
              BeforeRemove.run([
                "--workspace",
                workspace,
                "--source-repo",
                source_repo
              ])
            end)

          assert output =~ "Removed Git worktree #{workspace}"
          log = File.read!(log_path)
          assert log =~ "git -C #{source_repo} worktree list --porcelain"
          refute log =~ "ls-remote"
          refute log =~ "push origin --delete"
        end
      )
    after
      File.rm_rf!(root)
    end
  end

  test "skips cleanup when worktree metadata cannot be loaded" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-metadata-error-#{unique}")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)

    try do
      with_fake_binaries(
        %{
          "git" => """
          #!/bin/sh
          printf 'git %s\\n' "$*" >> "$GH_LOG"

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
            exit 1
          fi

          exit 99
          """
        },
        fn log_path ->
          output =
            capture_io(fn ->
              BeforeRemove.run([
                "--workspace",
                workspace,
                "--source-repo",
                source_repo
              ])
            end)

          assert output == ""
          log = File.read!(log_path)
          assert log =~ "git -C #{source_repo} worktree list --porcelain"
          refute log =~ "worktree remove"
          refute log =~ "push origin --delete"
        end
      )
    after
      File.rm_rf!(root)
    end
  end

  test "logs prune worktree failures" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-prune-failure-#{unique}")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)
    original_cwd = File.cwd!()

    git_script = """
    #!/bin/sh
    if [ "$1" = "rev-parse" ] && [ "$2" = "--show-toplevel" ]; then
      printf '%s\n' "#{workspace}"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{workspace}" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--git-common-dir" ]; then
      printf '%s\n' "#{Path.join(source_repo, ".git")}"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{workspace}" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--absolute-git-dir" ]; then
      printf '%s\n' "#{Path.join(workspace, ".git")}"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
      printf 'worktree #{workspace}\nHEAD abc123\nbranch refs/heads/feature/prune-failure\n'
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ]; then
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "show-ref" ] && [ "$4" = "--verify" ] && [ "$5" = "--quiet" ] && [ "$6" = "refs/heads/feature/prune-failure" ]; then
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "branch" ] && [ "$4" = "-D" ] && [ "$5" = "feature/prune-failure" ]; then
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$3" = "worktree" ] && [ "$4" = "prune" ]; then
      printf 'stale metadata\n' >&2
      exit 23
    fi

    exit 99
    """

    try do
      with_fake_binaries(%{"gh" => "#!/bin/sh\nexit 1\n", "git" => git_script}, fn _log_path ->
        {output, error_output} =
          capture_task_output(fn ->
            BeforeRemove.run(["--branch", "feature/prune-failure"])
          end)

        assert output =~ "Removed Git worktree #{workspace}"
        assert error_output =~ "Failed to prune Git worktrees in #{source_repo}: exit 23"
        assert error_output =~ "output=\"stale metadata\""
      end)
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
    end
  end

  test "removes an empty -worktrees base directory even when pruning worktrees fails" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-prune-base-dir-#{unique}")
    source_repo = Path.join(root, "repo")
    worktrees_base_dir = source_repo <> "-worktrees"
    workspace = Path.join(worktrees_base_dir, "feature-prune-failure")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)
    File.write!(Path.join(workspace, "sentinel.txt"), "cleanup me\n")

    git_script = """
    #!/bin/sh
    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
      printf 'worktree #{workspace}\\nHEAD abc123\\nbranch refs/heads/feature/prune-failure\\n'
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "ls-remote" ] && [ "$4" = "--exit-code" ] && [ "$5" = "--heads" ] && [ "$6" = "origin" ] && [ "$7" = "feature/prune-failure" ]; then
      exit 2
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ] && [ "$5" = "--force" ] && [ "$6" = "#{workspace}" ]; then
      rm -rf "$6"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "show-ref" ] && [ "$4" = "--verify" ] && [ "$5" = "--quiet" ] && [ "$6" = "refs/heads/feature/prune-failure" ]; then
      exit 1
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "prune" ]; then
      printf 'stale metadata\\n' >&2
      exit 23
    fi

    exit 99
    """

    try do
      with_fake_binaries(%{"gh" => "#!/bin/sh\nexit 1\n", "git" => git_script}, fn _log_path ->
        {output, error_output} =
          capture_task_output(fn ->
            BeforeRemove.run([
              "--branch",
              "feature/prune-failure",
              "--workspace",
              workspace,
              "--source-repo",
              source_repo
            ])
          end)

        assert output =~ "Removed Git worktree #{workspace}"
        assert output =~ "Removed empty worktrees base directory #{worktrees_base_dir}"
        assert error_output =~ "Failed to prune Git worktrees in #{source_repo}: exit 23"
        assert error_output =~ "output=\"stale metadata\""
        refute File.exists?(workspace)
        refute File.exists?(worktrees_base_dir)
      end)
    after
      File.rm_rf!(root)
    end
  end

  test "skips worktree removal when git path resolution returns an empty path" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-empty-path-#{unique}")
    workspace = Path.join(root, "wt")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)

    git_script = """
    #!/bin/sh
    if [ "$1" = "rev-parse" ] && [ "$2" = "--show-toplevel" ]; then
      printf '%s\n' "#{workspace}"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{workspace}" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--git-common-dir" ]; then
      printf '\n'
      exit 0
    fi

    exit 99
    """

    try do
      with_fake_binaries(%{"gh" => "#!/bin/sh\nexit 1\n", "git" => git_script}, fn _log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run(["--branch", "feature/empty-path"])
          end)

        assert output == ""
      end)
    after
      File.rm_rf!(root)
    end
  end

  test "resolves relative git paths when removing a linked worktree" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-relative-git-paths-#{unique}")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)

    git_script = """
    #!/bin/sh
    printf 'git %s\\n' "$*" >> "$GH_LOG"

    if [ "$1" = "rev-parse" ] && [ "$2" = "--show-toplevel" ]; then
      printf '%s\\n' "#{workspace}"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{workspace}" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--git-common-dir" ]; then
      printf '../repo/.git\\n'
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{workspace}" ] && [ "$3" = "rev-parse" ] && [ "$4" = "--absolute-git-dir" ]; then
      printf '.git\\n'
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
      printf 'worktree #{workspace}\\nHEAD abc123\\nbranch refs/heads/feature/relative-git-paths\\n'
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "ls-remote" ] && [ "$4" = "--exit-code" ] && [ "$5" = "--heads" ] && [ "$6" = "origin" ] && [ "$7" = "feature/relative-git-paths" ]; then
      exit 2
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ]; then
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "show-ref" ] && [ "$4" = "--verify" ] && [ "$5" = "--quiet" ] && [ "$6" = "refs/heads/feature/relative-git-paths" ]; then
      exit 1
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "prune" ]; then
      exit 0
    fi

    exit 99
    """

    try do
      with_fake_binaries(%{"git" => git_script}, fn log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run(["--branch", "feature/relative-git-paths"])
          end)

        assert output =~ "Removed Git worktree #{workspace}"

        log = File.read!(log_path)
        assert log =~ "git rev-parse --show-toplevel"
        assert log =~ "git -C #{workspace} rev-parse --git-common-dir"
        assert log =~ "git -C #{workspace} rev-parse --absolute-git-dir"
        assert log =~ "git -C #{source_repo} worktree list --porcelain"
        assert log =~ "git -C #{source_repo} worktree remove --force #{workspace}"
        assert log =~ "git -C #{source_repo} worktree prune"
      end)
    after
      File.rm_rf!(root)
    end
  end

  test "logs remote branch deletion failures and continues cleanup" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-remote-delete-failure-#{unique}")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)

    try do
      with_fake_binaries(
        %{
          "git" => """
          #!/bin/sh
          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
            printf 'worktree #{workspace}\\nHEAD abc123\\nbranch refs/heads/feature/delete-failure\\n'
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "ls-remote" ] && [ "$4" = "--exit-code" ] && [ "$5" = "--heads" ] && [ "$6" = "origin" ] && [ "$7" = "feature/delete-failure" ]; then
            printf 'abc123\\trefs/heads/feature/delete-failure\\n'
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "push" ] && [ "$4" = "origin" ] && [ "$5" = "--delete" ] && [ "$6" = "feature/delete-failure" ]; then
            printf 'permission denied\\n' >&2
            exit 19
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "show-ref" ] && [ "$4" = "--verify" ] && [ "$5" = "--quiet" ] && [ "$6" = "refs/heads/feature/delete-failure" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "branch" ] && [ "$4" = "-D" ] && [ "$5" = "feature/delete-failure" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "prune" ]; then
            exit 0
          fi

          exit 99
          """
        },
        fn _log_path ->
          {output, error_output} =
            capture_task_output(fn ->
              BeforeRemove.run([
                "--branch",
                "feature/delete-failure",
                "--repo",
                "acme/widget",
                "--workspace",
                workspace,
                "--source-repo",
                source_repo
              ])
            end)

          assert output =~ "Deleted local branch feature/delete-failure"
          assert output =~ "Removed Git worktree #{workspace}"
          assert error_output =~ "Failed to delete remote branch feature/delete-failure: exit 19"
          assert error_output =~ "output=\"permission denied\""
        end
      )
    after
      File.rm_rf!(root)
    end
  end

  test "logs local branch deletion failures and continues cleanup" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-local-delete-failure-#{unique}")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)

    try do
      with_fake_binaries(
        %{
          "git" => """
          #!/bin/sh
          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
            printf 'worktree #{workspace}\\nHEAD abc123\\nbranch refs/heads/feature/local-delete-failure\\n'
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "ls-remote" ] && [ "$4" = "--exit-code" ] && [ "$5" = "--heads" ] && [ "$6" = "origin" ] && [ "$7" = "feature/local-delete-failure" ]; then
            exit 2
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "show-ref" ] && [ "$4" = "--verify" ] && [ "$5" = "--quiet" ] && [ "$6" = "refs/heads/feature/local-delete-failure" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "branch" ] && [ "$4" = "-D" ] && [ "$5" = "feature/local-delete-failure" ]; then
            printf 'checked out elsewhere\\n' >&2
            exit 21
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "prune" ]; then
            exit 0
          fi

          exit 99
          """
        },
        fn _log_path ->
          {output, error_output} =
            capture_task_output(fn ->
              BeforeRemove.run([
                "--branch",
                "feature/local-delete-failure",
                "--repo",
                "acme/widget",
                "--workspace",
                workspace,
                "--source-repo",
                source_repo
              ])
            end)

          assert output =~ "Removed Git worktree #{workspace}"
          assert error_output =~ "Failed to delete local branch feature/local-delete-failure: exit 21"
          assert error_output =~ "output=\"checked out elsewhere\""
        end
      )
    after
      File.rm_rf!(root)
    end
  end

  test "skips local branch deletion when the branch no longer exists locally" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-local-missing-#{unique}")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)

    try do
      with_fake_binaries(
        %{
          "git" => """
          #!/bin/sh
          printf 'git %s\\n' "$*" >> "$GH_LOG"

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
            printf 'worktree #{workspace}\\nHEAD abc123\\nbranch refs/heads/feature/local-missing\\n'
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "ls-remote" ] && [ "$4" = "--exit-code" ] && [ "$5" = "--heads" ] && [ "$6" = "origin" ] && [ "$7" = "feature/local-missing" ]; then
            exit 2
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "show-ref" ] && [ "$4" = "--verify" ] && [ "$5" = "--quiet" ] && [ "$6" = "refs/heads/feature/local-missing" ]; then
            exit 1
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "prune" ]; then
            exit 0
          fi

          exit 99
          """
        },
        fn log_path ->
          output =
            capture_io(fn ->
              BeforeRemove.run([
                "--branch",
                "feature/local-missing",
                "--repo",
                "acme/widget",
                "--workspace",
                workspace,
                "--source-repo",
                source_repo
              ])
            end)

          assert output =~ "Removed Git worktree #{workspace}"

          log = File.read!(log_path)
          assert log =~ "git -C #{source_repo} show-ref --verify --quiet refs/heads/feature/local-missing"
          refute log =~ "git -C #{source_repo} branch -D feature/local-missing"
        end
      )
    after
      File.rm_rf!(root)
    end
  end

  test "logs local branch lookup failures and still prunes worktrees" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-local-check-failure-#{unique}")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)

    try do
      with_fake_binaries(
        %{
          "git" => """
          #!/bin/sh
          printf 'git %s\\n' "$*" >> "$GH_LOG"

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
            printf 'worktree #{workspace}\\nHEAD abc123\\nbranch refs/heads/feature/local-check-failure\\n'
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "ls-remote" ] && [ "$4" = "--exit-code" ] && [ "$5" = "--heads" ] && [ "$6" = "origin" ] && [ "$7" = "feature/local-check-failure" ]; then
            exit 2
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "show-ref" ] && [ "$4" = "--verify" ] && [ "$5" = "--quiet" ] && [ "$6" = "refs/heads/feature/local-check-failure" ]; then
            printf 'fatal: not a git repository\\n' >&2
            exit 7
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "prune" ]; then
            exit 0
          fi

          exit 99
          """
        },
        fn log_path ->
          {output, error_output} =
            capture_task_output(fn ->
              BeforeRemove.run([
                "--branch",
                "feature/local-check-failure",
                "--repo",
                "acme/widget",
                "--workspace",
                workspace,
                "--source-repo",
                source_repo
              ])
            end)

          assert output =~ "Removed Git worktree #{workspace}"

          assert error_output =~
                   "Failed to check local branch feature/local-check-failure in #{source_repo}: exit 7"

          assert error_output =~ "output=\"fatal: not a git repository\""

          log = File.read!(log_path)
          assert log =~ "git -C #{source_repo} show-ref --verify --quiet refs/heads/feature/local-check-failure"
          assert log =~ "git -C #{source_repo} worktree prune"
          refute log =~ "git -C #{source_repo} branch -D feature/local-check-failure"
        end
      )
    after
      File.rm_rf!(root)
    end
  end

  test "does not derive the delete target from an unrelated workspace override" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-wrong-workspace-#{unique}")
    wrong_workspace = Path.join(root, "workflow-dir")
    actual_workspace = Path.join(root, "workspaces/PRO-12")
    source_repo = Path.join(root, "repo")

    File.rm_rf!(root)
    File.mkdir_p!(wrong_workspace)
    File.mkdir_p!(actual_workspace)
    File.mkdir_p!(source_repo)

    try do
      with_fake_binaries(
        %{
          "git" => """
          #!/bin/sh
          printf 'git %s\\n' "$*" >> "$GH_LOG"

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
            printf 'worktree #{actual_workspace}\\nHEAD abc123\\nbranch refs/heads/symphony/PRO-12\\n'
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{wrong_workspace}" ] && [ "$3" = "branch" ] && [ "$4" = "--show-current" ]; then
            printf 'unrelated-feature\\n'
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "push" ] && [ "$4" = "origin" ] && [ "$5" = "--delete" ] && [ "$6" = "unrelated-feature" ]; then
            exit 0
          fi

          exit 99
          """
        },
        fn log_path ->
          output =
            capture_io(fn ->
              BeforeRemove.run([
                "--workspace",
                wrong_workspace,
                "--source-repo",
                source_repo
              ])
            end)

          assert output == ""

          log = File.read!(log_path)
          assert log =~ "git -C #{source_repo} worktree list --porcelain"
          refute log =~ "git -C #{wrong_workspace} branch --show-current"
          refute log =~ "push origin --delete unrelated-feature"
          refute log =~ "worktree remove --force #{wrong_workspace}"
        end
      )
    after
      File.rm_rf!(root)
    end
  end

  test "restores to source repo when the original working directory is already gone" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-missing-cwd-#{unique}")
    starting_cwd = Path.join(root, "gone")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")
    original_cwd = File.cwd!()

    File.rm_rf!(root)
    File.mkdir_p!(starting_cwd)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)

    try do
      with_fake_binaries(
        %{
          "gh" => """
          #!/bin/sh
          if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
            rm -rf "#{starting_cwd}"
            exit 1
          fi

          exit 99
          """,
          "git" => """
          #!/bin/sh
          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
            printf 'worktree #{workspace}\\nHEAD abc123\\nbranch refs/heads/feature/missing-cwd\\n'
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "ls-remote" ] && [ "$4" = "--exit-code" ] && [ "$5" = "--heads" ] && [ "$6" = "origin" ] && [ "$7" = "feature/missing-cwd" ]; then
            exit 2
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "show-ref" ] && [ "$4" = "--verify" ] && [ "$5" = "--quiet" ] && [ "$6" = "refs/heads/feature/missing-cwd" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "branch" ] && [ "$4" = "-D" ] && [ "$5" = "feature/missing-cwd" ]; then
            exit 0
          fi

          if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "prune" ]; then
            exit 0
          fi

          exit 99
          """
        },
        fn _log_path ->
          File.cd!(starting_cwd)

          capture_io(fn ->
            BeforeRemove.run([
              "--branch",
              "feature/missing-cwd",
              "--repo",
              "openai/symphony",
              "--workspace",
              workspace,
              "--source-repo",
              source_repo
            ])
          end)

          assert File.cwd!() == source_repo
        end
      )
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
    end
  end

  test "leaves cwd unchanged when both the original directory and source repo disappear" do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-missing-all-#{unique}")
    workspace = Path.join(root, "wt")
    source_repo = Path.join(root, "repo")
    original_cwd = File.cwd!()

    File.rm_rf!(root)
    File.mkdir_p!(workspace)
    File.mkdir_p!(source_repo)

    git_script = """
    #!/bin/sh
    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "list" ] && [ "$5" = "--porcelain" ]; then
      printf 'worktree #{workspace}\\nHEAD abc123\\nbranch refs/heads/feature/missing-all\\n'
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "ls-remote" ] && [ "$4" = "--exit-code" ] && [ "$5" = "--heads" ] && [ "$6" = "origin" ] && [ "$7" = "feature/missing-all" ]; then
      exit 2
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ]; then
      rm -rf "#{workspace}"
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "show-ref" ] && [ "$4" = "--verify" ] && [ "$5" = "--quiet" ] && [ "$6" = "refs/heads/feature/missing-all" ]; then
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "branch" ] && [ "$4" = "-D" ] && [ "$5" = "feature/missing-all" ]; then
      exit 0
    fi

    if [ "$1" = "-C" ] && [ "$2" = "#{source_repo}" ] && [ "$3" = "worktree" ] && [ "$4" = "prune" ]; then
      rm -rf "#{source_repo}"
      exit 0
    fi

    exit 99
    """

    try do
      with_fake_binaries(%{"git" => git_script}, fn _log_path ->
        File.cd!(workspace)

        capture_io(fn ->
          BeforeRemove.run([
            "--branch",
            "feature/missing-all",
            "--repo",
            "openai/symphony",
            "--workspace",
            workspace,
            "--source-repo",
            source_repo
          ])
        end)

        assert {:error, _reason} = File.cwd()
        File.cd!(original_cwd)
      end)
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
    end
  end

  defp with_fake_gh(fun) do
    with_fake_binaries(
      %{
        "gh" => """
        #!/bin/sh
        printf '%s\n' "$*" >> "$GH_LOG"

        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
          exit 0
        fi

        if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
          printf '101\n102\n'
          exit 0
        fi

        if [ "$1" = "pr" ] && [ "$2" = "close" ] && [ "$3" = "101" ]; then
          exit 0
        fi

        if [ "$1" = "pr" ] && [ "$2" = "close" ] && [ "$3" = "102" ]; then
          printf 'boom\n' >&2
          exit 17
        fi

        exit 99
        """
      },
      fun
    )
  end

  defp with_fake_gh(script, fun) do
    with_fake_binaries(%{"gh" => script}, fun)
  end

  defp with_fake_gh_and_git(gh_script, git_script, fun) do
    with_fake_binaries(%{"gh" => gh_script, "git" => git_script}, fun)
  end

  defp with_fake_binaries(scripts, fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-task-test-#{unique}")
    bin_dir = Path.join(root, "bin")
    log_path = Path.join(root, "gh.log")

    try do
      File.rm_rf!(root)
      File.mkdir_p!(bin_dir)
      File.write!(log_path, "")
      original_path = System.get_env("PATH") || ""
      path_with_binaries = Enum.join([bin_dir, original_path], ":")

      Enum.each(scripts, fn {name, script} ->
        path = Path.join(bin_dir, name)
        File.write!(path, script)
        File.chmod!(path, 0o755)
      end)

      with_env(
        %{
          "GH_LOG" => log_path,
          "PATH" => path_with_binaries
        },
        fn ->
          fun.(log_path)
        end
      )
    after
      File.rm_rf!(root)
    end
  end

  defp with_path(paths, fun) do
    with_env(%{"PATH" => Enum.join(paths, ":")}, fun)
  end

  defp with_env(overrides, fun) do
    keys = Map.keys(overrides)
    previous = Map.new(keys, fn key -> {key, System.get_env(key)} end)

    try do
      Enum.each(overrides, fn {key, value} -> System.put_env(key, value) end)
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp create_worktree_fixture!(branch, opts \\ []) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-worktree-#{unique}")
    origin_repo = Path.join(root, "origin.git")
    source_repo = Path.join(root, "repo")
    worktree_relative_path = Keyword.get(opts, :worktree_relative_path, "wt")
    worktree = Path.join(root, worktree_relative_path)

    File.rm_rf!(root)
    File.mkdir_p!(root)
    File.mkdir_p!(Path.dirname(worktree))

    git_cmd!(["init", "--bare", origin_repo])
    git_cmd!(["init", "-b", "main", source_repo])
    git_cmd!(["-C", source_repo, "config", "user.email", "test@example.com"])
    git_cmd!(["-C", source_repo, "config", "user.name", "Test User"])
    git_cmd!(["-C", source_repo, "remote", "add", "origin", origin_repo])
    File.write!(Path.join(source_repo, "README.md"), "fixture\n")
    git_cmd!(["-C", source_repo, "add", "README.md"])
    git_cmd!(["-C", source_repo, "commit", "-m", "init"])
    git_cmd!(["-C", source_repo, "push", "-u", "origin", "main"])
    git_cmd!(["-C", source_repo, "worktree", "add", worktree, "-b", branch, "HEAD"])
    git_cmd!(["-C", worktree, "push", "-u", "origin", branch])

    worktree_git_dir = git_cmd!(["-C", worktree, "rev-parse", "--absolute-git-dir"])

    %{
      root: root,
      source_repo: source_repo,
      worktree: worktree,
      worktree_git_dir: String.trim(worktree_git_dir)
    }
  end

  defp git_cmd!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with exit #{status}: #{output}")
    end
  end

  defp in_temp_dir(fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-empty-dir-#{unique}")

    File.rm_rf!(root)
    File.mkdir_p!(root)

    original_cwd = File.cwd!()

    try do
      File.cd!(root)
      fun.()
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
    end
  end

  defp capture_task_output(fun) do
    parent = self()
    ref = make_ref()

    error_output =
      capture_io(:stderr, fn ->
        output =
          capture_io(fn ->
            fun.()
          end)

        send(parent, {ref, output})
      end)

    output =
      receive do
        {^ref, output} -> output
      after
        1_000 -> flunk("Timed out waiting for captured task output")
      end

    {output, error_output}
  end

  defp temp_root(prefix) do
    unique = System.unique_integer([:positive, :monotonic])
    Path.join(System.tmp_dir!(), "#{prefix}-#{unique}")
  end
end
