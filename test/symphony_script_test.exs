defmodule SymphonyScriptTest do
  use ExUnit.Case, async: true

  @script_source Path.expand("../symphony", __DIR__)
  @mix_runtime_source Path.expand("../scripts/mix-runtime", __DIR__)

  test "the launcher requires Python 3.11 before update or build" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    python = System.find_executable("python3")
    fake_python = Path.join(bin_dir, "python3")

    for minor <- [9, 10] do
      File.write!(fake_python, """
      #!/bin/bash
      if [[ "$1" == -c ]]; then
        shift
        exec #{shell_quote(python)} -c 'import sys; sys.version_info=(3,#{minor},0); code=sys.argv.pop(1); exec(code)' "$@"
      fi
      exec #{shell_quote(python)} "$@"
      """)

      File.chmod!(fake_python, 0o755)
      File.write!(Path.join(repo_dir, "WORKFLOW.md"), "---\ntracker:\n  auth_mode: app\n---\n")

      assert {output, 1} = run_script(repo_dir, home_dir, bin_dir, [], env: [{"SYMPHONY_PYTHON", nil}])
      assert output == "mix-runtime: Python 3.11 oder neuer ist erforderlich\n"
      refute File.exists?(Path.join(repo_dir, ".mix-calls"))
      refute File.exists?(Path.join(repo_dir, "_build"))
      refute File.exists?(Path.join(home_dir, ".local/bin"))
      await_service_unlock(home_dir)
    end
  end

  for project_venv? <- [false, true] do
    @tag timeout: 60_000
    test "launcher → AppServer → bound app helper survives login PATH reset with project venv=#{project_venv?}" do
      %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
      project = Path.join(bin_dir, "project")
      workspace = Path.join(project, "workspaces/worker")
      bad_bin = Path.join(bin_dir, "incompatible-python")
      trace = Path.join(bin_dir, "worker.trace")
      File.mkdir_p!(workspace)
      File.mkdir_p!(home_dir)
      File.mkdir_p!(bad_bin)

      # Real release preparation, launcher and helper scripts; only external
      # build tools and Codex's JSON-RPC peer are fixtures. No tracker calls.
      for name <- ["sym-codex", "sym-codex-mcp", "scripts/installation-release.py", "scripts/codex-app-context.py"] do
        File.cp!(Path.expand("../#{name}", __DIR__), Path.join(repo_dir, name))
      end

      File.write!(Path.join(repo_dir, "mix.exs"), "# fixture\n")
      File.write!(Path.join(repo_dir, ".gitignore"), ".symphony/installations/\n_build/\n")

      config = %{
        "tracker" => %{
          "kind" => "linear",
          "auth_mode" => "app",
          "app" => %{
            "client_secret_env" => "SYMPHONY_TEST_START_SECRET",
            "workspace_id" => "workspace",
            "user_id" => "app",
            "client_id" => "client",
            "installation_id" => "install",
            "state_root" => Path.join(project, ".symphony/state")
          }
        },
        "workspace" => %{"root" => Path.dirname(workspace)},
        "codex" => %{"read_timeout_ms" => 5_000}
      }

      File.write!(Path.join(repo_dir, "WORKFLOW.md"), "---\n#{Jason.encode!(config)}\n---\nSynthetic instructions\n")

      # Pin the actual compiled Elixir modules, so the escript stand-in calls
      # the production AppServer.start_session/2, including Port.open(-lc).
      elixir = System.find_executable("elixir")
      File.write!(Path.join(bin_dir, "runtime/erl"), "#!/bin/bash\nexec #{shell_quote(System.find_executable("erl"))} \"$@\"\n")
      code_paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin")) |> Enum.map(&Path.expand/1)
      runner = Path.join(bin_dir, "start-session.exs")

      File.write!(runner, """
      alias SymphonyElixir.{Workflow, Codex.AppServer}
      :ok = Workflow.set_workflow_file_path(System.fetch_env!("SYMPHONY_WORKFLOW_FILE"))
      IO.puts("launcher-ready")
      {:ok, session} = AppServer.start_session(#{inspect(workspace)})
      IO.puts("started=" <> session.thread_id)
      AppServer.stop_session(session)
      """)

      File.write!(Path.join(repo_dir, "bin/symphony"), """
      #!/bin/bash
      exec #{shell_quote(elixir)} #{Enum.map_join(code_paths, " ", &("-pa " <> shell_quote(&1)))} #{shell_quote(runner)}
      """)

      # Deterministically model a login profile selecting an incompatible
      # Python even on hosts whose real login Python is sufficiently recent.
      File.write!(Path.join(bin_dir, "bash"), """
      #!/bin/bash
      if [[ "$1" == -lc ]]; then
        printf 'login-path-reset\\n' >> #{shell_quote(trace)}
        exec /bin/bash -lc 'export PATH="$1"; eval "$2"' worker #{shell_quote(bad_bin <> ":/usr/bin:/bin")} "$2"
      fi
      exec /bin/bash "$@"
      """)

      File.write!(Path.join(bad_bin, "python3"), """
      #!#{System.find_executable("python3")}
      import builtins, runpy, sys
      with open(#{inspect(trace)}, "a") as trace:
          trace.write("incompatible-python-used\\n")
      sys.version_info = (3, 9, 6)
      original_import = builtins.__import__
      def old_python_import(name, *args, **kwargs):
          if name == "tomllib":
              raise ModuleNotFoundError("No module named 'tomllib'")
          return original_import(name, *args, **kwargs)
      builtins.__import__ = old_python_import
      sys.argv = sys.argv[1:]
      if sys.argv[0] == "-c":
          code = sys.argv.pop(1)
          exec(code)
      else:
          runpy.run_path(sys.argv[0], run_name="__main__")
      """)

      if unquote(project_venv?) do
        venv = Path.join(project, ".venv")
        File.mkdir_p!(Path.join(venv, "bin"))
        File.ln_s!(Path.join(bad_bin, "python3"), Path.join(venv, "bin/python3"))

        File.write!(Path.join(venv, "bin/activate"), """
        export VIRTUAL_ENV=#{shell_quote(venv)}
        export PATH="$VIRTUAL_ENV/bin:$PATH"
        printf 'project-venv-active\\n' >> #{shell_quote(trace)}
        """)
      end

      File.write!(Path.join(bin_dir, "codex"), """
      #!/bin/bash
      set -eu
      # Bash 3.2 does not apply errexit to a failed [[ ... ]] expression.
      [[ "$*" == *app-server* ]] || exit 1
      [[ "$CODEX_HOME" == "$SYMPHONY_RELEASE_ROOT/.symphony/codex/projects/"* ]] || exit 1
      [[ -L "$CODEX_HOME/sessions" ]] || exit 1
      [[ "$(readlink "$CODEX_HOME/sessions")" == "$SYMPHONY_CODEX_STATE_ROOT/sessions" ]] || exit 1
      [[ "$SYMPHONY_LINEAR_AUTH_MODE" == app ]] || exit 1
      [[ "$*" == *SYMPHONY_PYTHON* ]] || exit 1
      [[ -n "$SYMPHONY_LINEAR_BINDING_HASH" ]] || exit 1
      printf 'codex-app-bound\\n' >> #{shell_quote(trace)}
      "$SYMPHONY_RELEASE_ROOT/sym-codex-mcp"
      printf 'mcp-helper-started\\n' >> #{shell_quote(trace)}
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf 'initialize\\n' >> #{shell_quote(trace)}
            printf '%s\\n' '{"id":1,"result":{}}' ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"bound-worker"}}}' ;;
        esac
      done
      """)

      for path <- [Path.join(bin_dir, "bash"), Path.join(bad_bin, "python3"), Path.join(bin_dir, "codex")] do
        File.chmod!(path, 0o755)
      end

      for args <- [["init", "-q"], ["add", "."], ["-c", "user.name=Synthetic", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"]] do
        assert {_, 0} = System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true)
      end

      assert {output, 0} =
               run_script(repo_dir, home_dir, bin_dir, [],
                 cd: project,
                 env:
                   SymphonyElixir.TestSupport.cleared_symphony_runtime_env() ++
                     [
                       {"SYMPHONY_PYTHON", nil},
                       {"SYMPHONY_CODEX_COMMAND", nil},
                       {"CODEX_HOME", Path.join(home_dir, ".codex")},
                       {"SYMPHONY_LINEAR_ENV_DIR", Path.join(project, ".symphony")}
                     ]
               )

      assert output =~ "launcher-ready"
      assert output =~ "started=bound-worker"
      evidence = File.read!(trace)
      assert evidence =~ "login-path-reset"
      assert evidence =~ "codex-app-bound"
      assert evidence =~ "mcp-helper-started"
      assert evidence =~ "initialize"
      assert evidence =~ "project-venv-active" == unquote(project_venv?)
      refute evidence =~ "incompatible-python-used"
      refute File.exists?(Path.join(home_dir, ".local/bin"))
    end
  end

  test "an isolated release binds helpers without creating global symlinks" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    project_dir = Path.join(System.tmp_dir!(), "symphony-script-project-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf(home_dir)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(project_dir)
    end)

    File.mkdir_p!(project_dir)
    File.write!(Path.join(project_dir, "WORKFLOW.md"), "---\n---\n")

    assert {output, 0} = run_script(repo_dir, home_dir, bin_dir, ["--port", "4001"], cd: project_dir)
    assert output =~ "symphony-stub args=--port 4001"
    assert output =~ "symphony-stub cwd=#{project_dir}"
    assert output =~ "symphony-stub codex_command=\n"
    assert output =~ "symphony-stub project_root=\n"
    assert output =~ "symphony-stub source_repo=\n"
    assert output =~ "symphony-stub workflow_file=#{Path.join(repo_dir, "WORKFLOW.md")}"
    assert output =~ "symphony-stub workflow_interactive_file=#{Path.join(repo_dir, "WORKFLOW_INTERACTIVE.md")}"
    assert output =~ "symphony-stub workflow_dialog_file=#{Path.join(repo_dir, "WORKFLOW_DIALOG.md")}"
    assert output =~ "symphony-stub workflow_dir=#{repo_dir}"
    assert output =~ "symphony-stub worktrees_root=\n"
    refute File.exists?(Path.join(home_dir, ".local/bin/sym-codex"))
    refute File.exists?(Path.join(home_dir, ".local/bin/sym-watch"))
  end

  test "a regular release preserves the explicit local Codex override" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    on_exit(fn -> Enum.each([home_dir, repo_dir, bin_dir], &File.rm_rf/1) end)
    command = "custom-codex --profile local app-server"
    assert {output, 0} = run_script(repo_dir, home_dir, bin_dir, [], env: [{"SYMPHONY_CODEX_COMMAND", command}])
    assert output =~ "symphony-stub codex_command=#{command}\n"
  end

  test "symphony runs autoupdate before launching escript" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()

    File.write!(Path.join(repo_dir, "autoupdate"), """
    #!/usr/bin/env bash
    printf 'autoupdate project=%s\\n' "$1"
    """)

    File.chmod!(Path.join(repo_dir, "autoupdate"), 0o755)

    on_exit(fn ->
      File.rm_rf(home_dir)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {output, 0} = run_script(repo_dir, home_dir, bin_dir, ["--port", "4001"])

    assert String.starts_with?(output, "autoupdate project=#{repo_dir}\n")
    assert output =~ "symphony-stub args=--port 4001\n"
  end

  test "symphony repairs dependencies and builds the binary before launching" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()

    on_exit(fn ->
      File.rm_rf(home_dir)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {output, 0} =
             run_script(repo_dir, home_dir, bin_dir, [], env: [{"SYMPHONY_TEST_DEPS_LOADPATHS_STATUS", "1"}])

    assert output =~ "symphony-stub"

    assert File.read!(Path.join(repo_dir, ".mix-calls")) ==
             "deps.loadpaths\ndeps.get\ncompile\nescript.build\nrun\n"
  end

  test "symphony clears inherited Mix artifact paths before preflight and launch" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()

    on_exit(fn ->
      File.rm_rf(home_dir)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {output, 0} =
             run_script(repo_dir, home_dir, bin_dir, [],
               env: [
                 {"MIX_DEPS_PATH", "/tmp/foreign-deps"},
                 {"MIX_BUILD_ROOT", "/tmp/foreign-build-root"},
                 {"MIX_BUILD_PATH", "/tmp/foreign-build-path"}
               ]
             )

    assert output =~ "symphony-stub mix_deps=unset mix_build_root=unset mix_build_path=unset"
  end

  test "symphony fails before polling when the local build cannot be repaired" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()

    on_exit(fn ->
      File.rm_rf(home_dir)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {output, 9} =
             run_script(repo_dir, home_dir, bin_dir, [], env: [{"SYMPHONY_TEST_COMPILE_STATUS", "9"}])

    refute output =~ "symphony-stub"
    assert File.read!(Path.join(repo_dir, ".mix-calls")) == "deps.loadpaths\ncompile\n"
  end

  test "symphony fails before polling when dependency repair fails" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()

    on_exit(fn ->
      File.rm_rf(home_dir)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {output, 7} =
             run_script(repo_dir, home_dir, bin_dir, [],
               env: [
                 {"SYMPHONY_TEST_DEPS_LOADPATHS_STATUS", "1"},
                 {"SYMPHONY_TEST_DEPS_GET_STATUS", "7"}
               ]
             )

    refute output =~ "symphony-stub"
    assert File.read!(Path.join(repo_dir, ".mix-calls")) == "deps.loadpaths\ndeps.get\n"
  end

  test "symphony fails before polling when the escript build fails" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()

    on_exit(fn ->
      File.rm_rf(home_dir)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {output, 6} =
             run_script(repo_dir, home_dir, bin_dir, [], env: [{"SYMPHONY_TEST_ESCRIPT_STATUS", "6"}])

    refute output =~ "symphony-stub"

    assert File.read!(Path.join(repo_dir, ".mix-calls")) ==
             "deps.loadpaths\ncompile\nescript.build\n"
  end

  test "parallel service starts reject the second invocation before autoupdate and build" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    autoupdate_path = Path.join(repo_dir, "autoupdate")

    File.write!(autoupdate_path, """
    #!/usr/bin/env bash
    marker="$1/.autoupdate-running"
    if ! mkdir "$marker" 2>/dev/null; then
      printf 'autoupdate overlap\n' >&2
      exit 8
    fi
    sleep 0.2
    rmdir "$marker"
    """)

    File.chmod!(autoupdate_path, 0o755)

    on_exit(fn ->
      File.rm_rf(home_dir)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    tasks =
      for _ <- 1..2 do
        Task.async(fn -> run_script(repo_dir, home_dir, bin_dir, []) end)
      end

    results = Enum.map(tasks, &Task.await(&1, 30_000))

    assert Enum.sort(Enum.map(results, &elem(&1, 1))) == [0, 1]
    assert Enum.any?(results, fn {output, status} -> status == 1 and output =~ "Symphony läuft bereits" end)
    refute Enum.any?(results, fn {output, _status} -> output =~ "overlap" end)
  end

  test "symphony issue symlink keeps release configuration without registering a new global command" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    project_dir = Path.join(System.tmp_dir!(), "symphony-script-issue-project-#{System.unique_integer([:positive])}")
    issue_link = Path.join(bin_dir, "symphony-PRO-351")

    on_exit(fn ->
      File.rm_rf(home_dir)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(project_dir)
    end)

    File.mkdir_p!(project_dir)
    File.write!(Path.join(project_dir, "WORKFLOW.md"), "---\n---\n")
    File.ln_s!(Path.join(repo_dir, "symphony"), issue_link)

    assert {output, 0} = run_script_path(issue_link, home_dir, bin_dir, [], cd: project_dir)

    codex_issue_link = Path.join(home_dir, ".local/bin/sym-codex-PRO-351")
    refute File.exists?(codex_issue_link)
    assert output =~ "symphony-stub cwd=#{project_dir}"
    assert output =~ "symphony-stub codex_command=\n"
    assert output =~ "symphony-stub project_root=\n"
    assert output =~ "symphony-stub workflow_file=#{Path.join(repo_dir, "WORKFLOW.md")}"
    assert output =~ "symphony-stub workflow_interactive_file=#{Path.join(repo_dir, "WORKFLOW_INTERACTIVE.md")}"
    assert output =~ "symphony-stub workflow_dialog_file=#{Path.join(repo_dir, "WORKFLOW_DIALOG.md")}"
  end

  test "symphony issue symlink binds workflow files to its own checkout from another Symphony cwd" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    other_repo_dir = Path.join(System.tmp_dir!(), "symphony-script-other-#{System.unique_integer([:positive])}")
    issue_link = Path.join(bin_dir, "symphony-PRO-456")

    on_exit(fn ->
      File.rm_rf(home_dir)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(other_repo_dir)
    end)

    File.mkdir_p!(other_repo_dir)
    File.write!(Path.join(other_repo_dir, "WORKFLOW.md"), "---\n---\n")
    File.write!(Path.join(other_repo_dir, "mix.exs"), "defmodule SymphonyElixir.MixProject do\nend\n")
    File.ln_s!(Path.join(repo_dir, "symphony"), issue_link)

    assert {output, 0} = run_script_path(issue_link, home_dir, bin_dir, [], cd: other_repo_dir)

    assert output =~ "symphony-stub cwd=#{other_repo_dir}"
    assert output =~ "symphony-stub workflow_file=#{Path.join(repo_dir, "WORKFLOW.md")}"
    assert output =~ "symphony-stub workflow_interactive_file=#{Path.join(repo_dir, "WORKFLOW_INTERACTIVE.md")}"
    assert output =~ "symphony-stub workflow_dialog_file=#{Path.join(repo_dir, "WORKFLOW_DIALOG.md")}"
    refute output =~ "symphony-stub workflow_file=#{Path.join(other_repo_dir, "WORKFLOW.md")}"
  end

  test "symphony runs autoupdate before helper setup and launching escript" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()

    File.write!(Path.join(repo_dir, "autoupdate"), """
    #!/usr/bin/env bash
    printf 'autoupdate project=%s\\n' "$1"
    """)

    File.chmod!(Path.join(repo_dir, "autoupdate"), 0o755)

    on_exit(fn ->
      File.rm_rf(home_dir)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {output, 0} = run_script(repo_dir, home_dir, bin_dir, ["--port", "4001"])

    assert String.starts_with?(output, "autoupdate project=#{repo_dir}\n")
    assert output =~ "symphony-stub args=--port 4001"
    refute File.exists?(Path.join(home_dir, ".local/bin/sym-codex"))
    refute File.exists?(Path.join(home_dir, ".local/bin/sym-watch"))
  end

  test "an isolated release preserves an unmanaged sym-watch entry" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    user_bin_dir = Path.join(home_dir, ".local/bin")

    File.mkdir_p!(user_bin_dir)
    File.write!(Path.join(user_bin_dir, "sym-watch"), "not managed by symphony\n")

    on_exit(fn ->
      File.rm_rf(home_dir)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {output, 0} = run_script(repo_dir, home_dir, bin_dir, [])
    assert File.read!(Path.join(user_bin_dir, "sym-watch")) == "not managed by symphony\n"
    assert output =~ "symphony-stub"
  end

  test "startup fails before any mutations when a required tool is missing" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    isolated = Path.join(bin_dir, "isolated")
    File.mkdir_p!(isolated)

    for tool <- ["basename", "dirname", "python3", "git", "make", "codex", "mise"] do
      source = if tool in ["codex", "mise"], do: Path.join(bin_dir, tool), else: System.find_executable(tool)
      File.ln_s!(source, Path.join(isolated, tool))
    end

    for tool <- ["python3", "git", "make", "codex", "mise"] do
      path = Path.join(isolated, tool)
      target = File.read_link!(path)
      File.rm!(path)
      {output, status} = run_script(repo_dir, home_dir, bin_dir, [], env: [{"PATH", isolated}])
      assert status != 0
      assert output =~ "#{tool} not found in PATH"
      refute File.exists?(Path.join(repo_dir, ".mix-calls"))
      refute File.exists?(Path.join(repo_dir, "_build"))
      refute File.exists?(Path.join(home_dir, ".local/bin"))
      File.ln_s!(target, path)
      await_service_unlock(home_dir)
    end
  end

  test "failed mise lookup, missing runtime and failed activation cannot reach autoupdate" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    autoupdate = Path.join(repo_dir, "autoupdate")
    File.write!(autoupdate, "#!/bin/bash\necho MUTATED\n")
    File.chmod!(autoupdate, 0o755)

    for {variable, message} <- [
          {"SYMPHONY_TEST_MISE_LS_STATUS", "konnte die konfigurierte"},
          {"SYMPHONY_TEST_RUNTIME_MISSING", "Konfigurierte erlang-Laufzeit fehlt"},
          {"SYMPHONY_TEST_MISE_ENV_STATUS", "konnte die Laufzeit nicht aktivieren"}
        ] do
      assert {output, 1} = run_script(repo_dir, home_dir, bin_dir, [], env: [{variable, "1"}])
      assert output =~ message
      refute output =~ "MUTATED"
      refute File.exists?(Path.join(repo_dir, ".mix-calls"))
      refute File.exists?(Path.join(home_dir, ".local/bin"))
      await_service_unlock(home_dir)
    end

    File.rm!(Path.join(bin_dir, "runtime/escript"))
    assert {output, 1} = run_script(repo_dir, home_dir, bin_dir, [])
    assert output =~ "escript fehlt nach mise-Aktivierung"
    refute output =~ "MUTATED"
    refute File.exists?(Path.join(home_dir, ".local/bin"))
  end

  test "activation makes escript available only to the launched process" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    env = SymphonyElixir.TestSupport.script_env(bin_dir)
    assert {"", 1} = System.cmd("/bin/bash", ["-c", "command -v escript"], env: env)
    File.write!(Path.join(repo_dir, "bin/symphony"), "#!/bin/bash\ncommand -v escript\n")
    assert {output, 0} = run_script(repo_dir, home_dir, bin_dir, [])
    assert String.trim(output) == Path.join(bin_dir, "runtime/escript")
    assert {"", 1} = System.cmd("/bin/bash", ["-c", "command -v escript"], env: env)
  end

  test "relative multihop links and BSD directory links preserve the checkout and project cwd" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    link = Path.join(bin_dir, "symphony-PRO-678")
    File.ln_s!(Path.relative_to(Path.join(repo_dir, "symphony"), bin_dir, force: true), Path.join(bin_dir, "hop"))
    File.ln_s!("hop", link)
    user_bin = Path.join(home_dir, ".local/bin")
    File.mkdir_p!(user_bin)
    File.ln_s!("missing-target", Path.join(user_bin, "sym-codex"))
    File.ln_s!(repo_dir, Path.join(user_bin, "sym-watch"))
    skill = Path.join(home_dir, ".codex/skills/symphony-test")
    File.mkdir_p!(Path.dirname(skill))
    File.ln_s!(repo_dir, skill)

    assert {output, 0} =
             System.cmd("/bin/bash", ["-c", "symphony-PRO-678"],
               cd: bin_dir,
               env: [{"HOME", home_dir} | SymphonyElixir.TestSupport.script_env(bin_dir)],
               stderr_to_stdout: true
             )

    assert output =~ "symphony-stub cwd=#{bin_dir}"
    assert output =~ "symphony-stub workflow_file=#{repo_dir}/WORKFLOW.md"
    assert File.read_link!(Path.join(user_bin, "sym-watch")) == repo_dir
    assert File.read_link!(skill) == repo_dir
    assert File.read_link!(Path.join(user_bin, "sym-codex")) == "missing-target"
    refute File.exists?(Path.join(repo_dir, "sym-codex-PRO-678"))
  end

  @tag timeout: 120_000
  test "a lock is released after each update and build failure" do
    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()

    for {env, expected_status} <- [
          {[{"SYMPHONY_TEST_COMPILE_STATUS", "9"}], 9},
          {[{"SYMPHONY_TEST_DEPS_LOADPATHS_STATUS", "1"}, {"SYMPHONY_TEST_DEPS_GET_STATUS", "7"}], 7},
          {[{"SYMPHONY_TEST_ESCRIPT_STATUS", "6"}], 6}
        ] do
      assert {_output, ^expected_status} = run_script(repo_dir, home_dir, bin_dir, [], env: env)
      await_service_unlock(home_dir)
      assert {_output, 0} = run_script(repo_dir, home_dir, bin_dir, [])
      await_service_unlock(home_dir)
    end

    autoupdate = Path.join(repo_dir, "autoupdate")
    File.write!(autoupdate, "#!/bin/bash\nexit 13\n")
    File.chmod!(autoupdate, 0o755)
    assert {_output, 13} = run_script(repo_dir, home_dir, bin_dir, [])
    await_service_unlock(home_dir)
    File.rm!(autoupdate)
    assert {_output, 0} = run_script(repo_dir, home_dir, bin_dir, [])
    await_service_unlock(home_dir)
  end

  test "a toolchain removed by autoupdate fails before build and registration" do
    fixture = build_script_fixture!()
    autoupdate = Path.join(fixture.repo_dir, "autoupdate")
    File.write!(autoupdate, "#!/bin/bash\nrm \"#{fixture.bin_dir}/runtime/escript\"\n")
    File.chmod!(autoupdate, 0o755)
    assert {output, 1} = run_script(fixture.repo_dir, fixture.home_dir, fixture.bin_dir, [])
    assert output =~ "escript fehlt nach mise-Aktivierung"
    refute File.exists?(Path.join(fixture.repo_dir, ".mix-calls"))
    refute File.exists?(Path.join(fixture.home_dir, ".local/bin"))
  end

  @tag timeout: 120_000
  test "the running service retains the service mutex after the build lock is released" do
    fixture = build_script_fixture!()
    assert {output, 0} = run_lock_probe(fixture, "service", 0, fixture.repo_dir)
    assert output =~ "lock probe passed"
  end

  for mode <- ["holder", "waiter"], signum <- [2, 15] do
    @tag timeout: 120_000
    test "#{mode} interruption with signal #{signum} releases the lock and stops build children" do
      fixture = build_script_fixture!()
      assert {output, 0} = run_lock_probe(fixture, unquote(mode), unquote(signum), fixture.repo_dir)
      assert output =~ "lock probe passed"
    end
  end

  @tag timeout: 120_000
  test "linked worktrees share the per-user service mutex" do
    fixture = build_script_fixture!()
    repo = fixture.repo_dir
    other = Path.join(fixture.bin_dir, "other checkout")

    for args <- [
          ["init", "-b", "main"],
          ["add", "."],
          ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "fixture"],
          ["worktree", "add", "-b", "second", other]
        ] do
      assert {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    end

    assert {output, 0} = run_lock_probe(fixture, "independent", 0, other)
    assert output =~ "lock probe passed"
  end

  defp run_lock_probe(fixture, mode, signum, other) do
    System.cmd(
      System.find_executable("python3"),
      [Path.expand("support/start_lock_probe.py", __DIR__), fixture.repo_dir, mode, to_string(signum), other],
      env: [{"HOME", fixture.home_dir} | SymphonyElixir.TestSupport.script_env(fixture.bin_dir)],
      stderr_to_stdout: true
    )
  end

  defp build_script_fixture! do
    repo_dir = Path.join(System.tmp_dir!(), "symphony script-#{System.unique_integer([:positive])}")
    home_dir = Path.join(System.tmp_dir!(), "symphony-home-#{System.unique_integer([:positive])}")
    bin_dir = Path.join(System.tmp_dir!(), "symphony-bin-#{System.unique_integer([:positive])}")

    File.mkdir_p!(repo_dir)
    File.mkdir_p!(Path.join(repo_dir, "bin"))
    File.mkdir_p!(Path.join(repo_dir, "scripts"))
    File.mkdir_p!(Path.join(repo_dir, ".codex/skills/symphony-test"))
    File.mkdir_p!(bin_dir)

    File.cp!(@script_source, Path.join(repo_dir, "symphony"))
    File.cp!(@mix_runtime_source, Path.join(repo_dir, "scripts/mix-runtime"))
    File.cp!(Path.expand("../scripts/service-lock.py", __DIR__), Path.join(repo_dir, "scripts/service-lock.py"))
    # These tests exercise preflight, build locking and launch inside an
    # isolated release. The real snapshot copier has separate process tests.
    File.write!(Path.join(repo_dir, "scripts/installation-release.py"), """
    import os, pathlib, re, sys
    action, root, *args = sys.argv[1:]
    if action == "app-workflow":
        workflow = pathlib.Path(root) / "WORKFLOW.md"
        sys.exit(0 if workflow.is_file() and re.search(r'auth_mode["\\x27]?\\s*:\\s*["\\x27]?app\\b', workflow.read_text()) else 1)
    if action == "start":
        os.environ["SYMPHONY_RELEASE_ROOT"] = root
        os.environ["SYMPHONY_ROOT_DIR"] = root
        target = os.path.join(root, "scripts/mix-runtime")
        os.execv(target, [target, "start", root, *args])
    """)

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

    on_exit(fn ->
      Enum.each([home_dir, repo_dir, bin_dir], &File.rm_rf/1)
    end)

    %{home_dir: home_dir, repo_dir: repo_dir, bin_dir: bin_dir}
  end

  defp run_script(repo_dir, home_dir, bin_dir, args, opts \\ []) do
    run_script_path(Path.join(repo_dir, "symphony"), home_dir, bin_dir, args, opts)
  end

  defp run_script_path(script_path, home_dir, bin_dir, args, opts) do
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

  defp await_service_unlock(home_dir) do
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

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
