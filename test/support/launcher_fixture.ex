defmodule SymphonyElixir.LauncherFixture do
  @moduledoc false
  import ExUnit.Callbacks, only: [on_exit: 1]
  import ExUnit.Assertions

  @script_source Path.expand("../../symphony", __DIR__)
  @mix_runtime_source Path.expand("../../scripts/mix-runtime", __DIR__)

  def build_script_fixture!(opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, System.tmp_dir!())
    suffix = Keyword.get(opts, :suffix, &random_suffix/0)
    root_dir = reserve_root!(base_dir, suffix)
    on_exit(fn -> File.rm_rf!(root_dir) end)

    repo_dir = Path.join(root_dir, "repo with spaces")
    home_dir = Path.join(root_dir, "home")
    bin_dir = Path.join(root_dir, "bin")

    File.mkdir_p!(repo_dir)
    File.mkdir_p!(Path.join(repo_dir, "bin"))
    File.mkdir_p!(Path.join(repo_dir, "scripts"))
    File.mkdir_p!(Path.join(repo_dir, ".codex/skills/symphony-test"))
    File.mkdir_p!(bin_dir)

    File.cp!(@script_source, Path.join(repo_dir, "symphony"))
    File.cp!(@mix_runtime_source, Path.join(repo_dir, "scripts/mix-runtime"))
    File.cp!(Path.expand("../../scripts/service-lock.py", __DIR__), Path.join(repo_dir, "scripts/service-lock.py"))
    File.write!(Path.join(repo_dir, "sym-codex"), "#!/usr/bin/env bash\n")
    File.write!(Path.join(repo_dir, "sym-watch"), "#!/usr/bin/env bash\n")

    File.write!(Path.join(repo_dir, "bin/symphony"), """
    #!/usr/bin/env bash
    printf 'symphony-stub cwd=%s\\n' "$(pwd -P)"
    printf 'symphony-stub codex_command=%s\\n' "${SYMPHONY_CODEX_COMMAND:-}"
    printf 'symphony-stub project_root=%s\\n' "${SYMPHONY_PROJECT_ROOT:-}"
    printf 'symphony-stub source_repo=%s\\n' "${SYMPHONY_SOURCE_REPO:-}"
    printf 'symphony-stub workflow_file=%s\\n' "${SYMPHONY_WORKFLOW_FILE:-}"
    printf 'symphony-stub workflow_interactive_file=%s\\n' "${SYMPHONY_WORKFLOW_INTERACTIVE_FILE:-}"
    printf 'symphony-stub workflow_dialog_file=%s\\n' "${SYMPHONY_WORKFLOW_DIALOG_FILE:-}"
    printf 'symphony-stub workflow_dir=%s\\n' "${SYMPHONY_WORKFLOW_DIR:-}"
    printf 'symphony-stub worktrees_root=%s\\n' "${SYMPHONY_PROJECT_WORKTREES_ROOT:-}"
    printf 'symphony-stub mix_deps=%s mix_build_root=%s mix_build_path=%s\\n' \
      "${MIX_DEPS_PATH-unset}" \
      "${MIX_BUILD_ROOT-unset}" \
      "${MIX_BUILD_PATH-unset}"
    printf 'symphony-stub args=%s\\n' "$*"
    """)

    SymphonyElixir.TestSupport.install_runtime_fixture!(repo_dir, bin_dir)
    File.write!(Path.join(bin_dir, "codex"), "#!/bin/bash\nexit 0\n")
    File.chmod!(Path.join(bin_dir, "codex"), 0o755)

    File.write!(Path.join(bin_dir, "mix"), """
    #!/usr/bin/env bash
    printf '%s\\n' "$1" >> "$PWD/.mix-calls"

    case "$1" in
      deps.loadpaths)
        exit "${SYMPHONY_TEST_DEPS_LOADPATHS_STATUS:-0}"
        ;;
      deps.get)
        exit "${SYMPHONY_TEST_DEPS_GET_STATUS:-0}"
        ;;
      compile)
        exit "${SYMPHONY_TEST_COMPILE_STATUS:-0}"
        ;;
      escript.build)
        exit "${SYMPHONY_TEST_ESCRIPT_STATUS:-0}"
        ;;
      run)
        exit 0
        ;;
    esac

    exit 1
    """)

    File.chmod!(Path.join(repo_dir, "symphony"), 0o755)
    File.chmod!(Path.join(repo_dir, "sym-codex"), 0o755)
    File.chmod!(Path.join(repo_dir, "sym-watch"), 0o755)
    File.chmod!(Path.join(repo_dir, "bin/symphony"), 0o755)
    File.chmod!(Path.join(repo_dir, "scripts/mix-runtime"), 0o755)
    File.chmod!(Path.join(bin_dir, "mise"), 0o755)
    File.chmod!(Path.join(bin_dir, "mix"), 0o755)

    %{root_dir: root_dir, home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir}
  end

  def run_script(repo_dir, home_dir, bin_dir, args, opts \\ []) do
    run_script_path(Path.join(repo_dir, "symphony"), home_dir, bin_dir, args, opts)
  end

  def run_script_path(script_path, home_dir, bin_dir, args, opts) do
    cmd_opts =
      [
        env:
          [
            {"HOME", home_dir},
            {"BASH_ENV", nil},
            {"ENV", nil},
            {"PATH", SymphonyElixir.TestSupport.script_path(bin_dir)}
          ] ++ Keyword.get(opts, :env, []),
        stderr_to_stdout: true
      ]
      |> maybe_put_cd(Keyword.get(opts, :cd))

    System.cmd("/bin/bash", [script_path | args], cmd_opts)
  end

  defp maybe_put_cd(opts, nil), do: opts
  defp maybe_put_cd(opts, cd), do: Keyword.put(opts, :cd, cd)

  def await_service_unlock(home_dir) do
    # The detached guardian observes owner exit asynchronously. Sequential
    # preflight cases must await its kernel-lock release before reusing HOME.
    script = """
    import fcntl, pathlib, signal, sys
    path = pathlib.Path(sys.argv[1]) / ".cache/symphony/service.lock"
    if path.exists():
        signal.alarm(5)
        with path.open() as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
    """

    assert {_, 0} = System.cmd(System.find_executable("python3"), ["-c", script, home_dir], stderr_to_stdout: true)
  end

  # mkdir is the ownership boundary: never adopt or clean an existing candidate.
  defp reserve_root!(base_dir, suffix) do
    root_dir = Path.join(base_dir, "symphony-script-#{suffix.()}")

    case File.mkdir(root_dir) do
      :ok -> root_dir
      {:error, :eexist} -> reserve_root!(base_dir, suffix)
      {:error, reason} -> raise File.Error, reason: reason, action: "create fixture directory", path: root_dir
    end
  end

  defp random_suffix, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end
