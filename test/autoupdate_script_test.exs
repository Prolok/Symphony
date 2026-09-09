defmodule AutoupdateScriptTest do
  use ExUnit.Case, async: true

  @script_source Path.expand("../autoupdate", __DIR__)
  @update_prompt "Neue Symphony Version verfügbar. Update ausführen j/n?"

  test "exits quietly when upstream has no new commit" do
    %{root_dir: root_dir, worktree_dir: worktree_dir} = build_git_fixture!()
    %{bin_dir: bin_dir, make_log: make_log} = build_make_fixture!(root_dir)

    on_exit(fn -> File.rm_rf(root_dir) end)

    assert {"", 0} = run_autoupdate(worktree_dir, "j\n", bin_dir, make_log)
    refute File.exists?(make_log)
  end

  test "declining an available update leaves the checkout unchanged" do
    %{root_dir: root_dir, seed_dir: seed_dir, worktree_dir: worktree_dir} = build_git_fixture!()
    %{bin_dir: bin_dir, make_log: make_log} = build_make_fixture!(root_dir)
    old_head = git_output!(worktree_dir, ["rev-parse", "HEAD"])

    push_remote_commit!(seed_dir, "v2\n", "remote update")

    on_exit(fn -> File.rm_rf(root_dir) end)

    for answer <- ["n\n", "Nein\n", "maybe\n", ""] do
      assert {output, 0} = run_autoupdate(worktree_dir, answer, bin_dir, make_log)
      assert output == @update_prompt
    end

    assert {output, 0} = run_autoupdate(worktree_dir, "n\n", bin_dir, make_log)
    assert output == @update_prompt
    refute output =~ "Symphony Update läuft…"
    assert git_output!(worktree_dir, ["rev-parse", "HEAD"]) == old_head
    refute File.exists?(make_log)
  end

  test "detects an update from fetched head when upstream tracking ref is stale" do
    %{root_dir: root_dir, repo_dir: repo_dir, bin_dir: bin_dir, make_log: make_log} =
      build_stale_tracking_fixture!()

    on_exit(fn -> File.rm_rf(root_dir) end)

    assert {output, 0} = run_autoupdate(repo_dir, "n\n", bin_dir, make_log)

    assert output == @update_prompt
    refute output =~ "Symphony Update läuft…"
    refute File.exists?(make_log)
  end

  test "accepted update pulls the new commit and runs make all" do
    %{root_dir: root_dir, seed_dir: seed_dir, worktree_dir: worktree_dir} = build_git_fixture!()
    %{bin_dir: bin_dir, make_log: make_log} = build_make_fixture!(root_dir)

    push_remote_commit!(seed_dir, "v2\n", "remote update")
    remote_head = git_output!(seed_dir, ["rev-parse", "HEAD"])

    on_exit(fn -> File.rm_rf(root_dir) end)

    assert {output, 0} = run_autoupdate(worktree_dir, "YeS\n", bin_dir, make_log)

    assert output =~ @update_prompt
    assert output =~ "Symphony Update läuft…"
    assert git_output!(worktree_dir, ["rev-parse", "HEAD"]) == remote_head

    assert File.read!(make_log) ==
             "make args=all mix_deps=unset mix_build_root=unset mix_build_path=unset\n"
  end

  defp build_git_fixture! do
    root_dir = Path.join(System.tmp_dir!(), "symphony-autoupdate-#{System.unique_integer([:positive])}")
    remote_dir = Path.join(root_dir, "remote.git")
    seed_dir = Path.join(root_dir, "seed")
    worktree_dir = Path.join(root_dir, "worktree")

    File.mkdir_p!(root_dir)

    git!(root_dir, ["init", "--bare", remote_dir])
    git!(root_dir, ["clone", remote_dir, seed_dir])
    configure_user!(seed_dir)

    File.write!(Path.join(seed_dir, "README.md"), "v1\n")
    File.mkdir_p!(Path.join(seed_dir, "scripts"))
    File.cp!(Path.expand("../scripts/mix-runtime", __DIR__), Path.join(seed_dir, "scripts/mix-runtime"))
    File.write!(Path.join(seed_dir, "mise.toml"), "[tools]\n")
    git!(seed_dir, ["add", "README.md", "scripts", "mise.toml"])
    git!(seed_dir, ["commit", "-m", "initial"])
    git!(seed_dir, ["branch", "-M", "main"])
    git!(seed_dir, ["push", "-u", "origin", "main"])
    git!(root_dir, ["--git-dir", remote_dir, "symbolic-ref", "HEAD", "refs/heads/main"])

    git!(root_dir, ["clone", remote_dir, worktree_dir])
    configure_user!(worktree_dir)

    %{root_dir: root_dir, seed_dir: seed_dir, worktree_dir: worktree_dir}
  end

  defp build_stale_tracking_fixture! do
    root_dir =
      Path.join(System.tmp_dir!(), "symphony-autoupdate-stale-#{System.unique_integer([:positive])}")

    repo_dir = Path.join(root_dir, "repo")
    bin_dir = Path.join(root_dir, "bin")
    make_log = Path.join(root_dir, "make.log")

    File.mkdir_p!(repo_dir)
    File.mkdir_p!(bin_dir)

    File.write!(Path.join(bin_dir, "git"), """
    #!/usr/bin/env bash
    if [ "$1" = "-C" ]; then
      shift 2
    fi

    case "$1" in
      rev-parse)
        if [ "$2" = "--is-inside-work-tree" ]; then
          exit 0
        fi

        if [ "$2" = "--abbrev-ref" ]; then
          printf 'origin/main\\n'
          exit 0
        fi
        ;;
      status)
        exit 0
        ;;
      fetch)
        exit 0
        ;;
      merge-base)
        exit 0
        ;;
      rev-list)
        if [ "$3" = "HEAD..FETCH_HEAD" ]; then
          printf '1\\n'
          exit 0
        fi

        if [ "$3" = "HEAD..origin/main" ]; then
          printf '0\\n'
          exit 0
        fi
        ;;
      pull)
        printf 'git pull should not run when update is declined\\n' >&2
        exit 1
        ;;
    esac

    printf 'unexpected git args: %s\\n' "$*" >&2
    exit 1
    """)

    File.chmod!(Path.join(bin_dir, "git"), 0o755)

    %{root_dir: root_dir, repo_dir: repo_dir, bin_dir: bin_dir, make_log: make_log}
  end

  defp build_make_fixture!(root_dir) do
    bin_dir = Path.join(root_dir, "bin")
    make_log = Path.join(root_dir, "make.log")

    File.mkdir_p!(bin_dir)
    SymphonyElixir.TestSupport.install_runtime_fixture!(Path.join(root_dir, "worktree"), bin_dir)

    for tool <- ["codex", "mix"] do
      File.write!(Path.join(bin_dir, tool), "#!/bin/bash\nexit 0\n")
      File.chmod!(Path.join(bin_dir, tool), 0o755)
    end

    # The fixture config is part of the clean checkout used by autoupdate.
    git!(Path.join(root_dir, "worktree"), ["checkout", "--", "mise.toml"])

    File.write!(Path.join(bin_dir, "make"), """
    #!/usr/bin/env bash
    printf 'make args=%s mix_deps=%s mix_build_root=%s mix_build_path=%s\\n' \
      "$*" \
      "${MIX_DEPS_PATH-unset}" \
      "${MIX_BUILD_ROOT-unset}" \
      "${MIX_BUILD_PATH-unset}" >> "$MAKE_LOG"
    """)

    File.chmod!(Path.join(bin_dir, "make"), 0o755)

    %{bin_dir: bin_dir, make_log: make_log}
  end

  defp push_remote_commit!(repo_dir, contents, message) do
    File.write!(Path.join(repo_dir, "README.md"), contents)
    git!(repo_dir, ["add", "README.md"])
    git!(repo_dir, ["commit", "-m", message])
    git!(repo_dir, ["push", "origin", "main"])
  end

  defp configure_user!(repo_dir) do
    git!(repo_dir, ["config", "user.email", "symphony@example.com"])
    git!(repo_dir, ["config", "user.name", "Symphony Test"])
  end

  defp run_autoupdate(repo_dir, input, bin_dir, make_log) do
    System.cmd(
      "/bin/bash",
      ["-c", "printf '%s' \"$AUTOUPDATE_INPUT\" | \"$AUTOUPDATE_SCRIPT\" \"$SYMPHONY_REPO\""],
      env: [
        {"AUTOUPDATE_INPUT", input},
        {"AUTOUPDATE_SCRIPT", @script_source},
        {"SYMPHONY_REPO", repo_dir},
        {"MAKE_LOG", make_log},
        {"MIX_DEPS_PATH", "/tmp/foreign-deps"},
        {"MIX_BUILD_ROOT", "/tmp/foreign-build"},
        {"MIX_BUILD_PATH", "/tmp/foreign-build-path"},
        {"PATH", SymphonyElixir.TestSupport.script_path(bin_dir)}
      ],
      stderr_to_stdout: true
    )
  end

  defp git!(repo_dir, args) do
    assert {_output, 0} = System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true)
    :ok
  end

  defp git_output!(repo_dir, args) do
    assert {output, 0} = System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true)
    String.trim(output)
  end
end
