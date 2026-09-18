defmodule MixGateScriptTest do
  use ExUnit.Case

  @script_path Path.expand("../scripts/mix-gate", __DIR__)
  @repo_root Path.expand("..", __DIR__)

  test "make check invokes only the small gate while all retains one complete test pass" do
    root = Path.join(System.tmp_dir!(), "make-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    File.cp!(Path.join(@repo_root, "Makefile"), Path.join(root, "Makefile"))
    fixture = Path.join(root, "mix-fixture")
    File.write!(fixture, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> calls\n")
    File.chmod!(fixture, 0o755)
    assert {_, 0} = System.cmd("make", ["check", "MIX=./mix-fixture"], cd: root, stderr_to_stdout: true)
    assert File.read!(Path.join(root, "calls")) == "setup\nbuild\nformat --check-formatted\nlint\n"
    assert {commands, 0} = System.cmd("make", ["-n", "all"], cd: root, stderr_to_stdout: true)
    assert length(Regex.scan(~r/python3 -m unittest discover/, commands)) == 1
    assert length(Regex.scan(~r/mix-gate test --cover/, commands)) == 1
    assert commands =~ "mix-gate dialyzer"
  end

  test "mix-gate clears Symphony runtime env and trusts mise.toml for the process" do
    bin_dir =
      Path.join(System.tmp_dir!(), "mix-gate-bin-#{System.unique_integer([:positive])}")

    File.mkdir_p!(bin_dir)

    File.write!(Path.join(bin_dir, "mise"), """
    #!/usr/bin/env bash
    printf 'args=%s\\n' "$*"
    printf 'trusted=%s\\n' "${MISE_TRUSTED_CONFIG_PATHS:-}"
    printf 'workflow=%s\\n' "${SYMPHONY_WORKFLOW_FILE-unset}"
    printf 'workflow_dir=%s\\n' "${SYMPHONY_WORKFLOW_DIR-unset}"
    printf 'source=%s\\n' "${SYMPHONY_SOURCE_REPO-unset}"
    printf 'issue_id=%s\\n' "${SYMPHONY_ISSUE_ID-unset}"
    printf 'issue_identifier=%s\\n' "${SYMPHONY_ISSUE_IDENTIFIER-unset}"
    printf 'labels=%s\\n' "${SYMPHONY_ISSUE_LABELS_JSON-unset}"
    printf 'project=%s\\n' "${SYMPHONY_PROJECT_ROOT-unset}"
    printf 'python=%s\\n' "${SYMPHONY_PYTHON-unset}"
    printf 'codex_command=%s\\n' "${SYMPHONY_CODEX_COMMAND-unset}"
    printf 'secret_access=%s\\n' "${SYMPHONY_LINEAR_SECRET_ACCESS-unset}"
    printf 'mix_deps=%s\\n' "${MIX_DEPS_PATH-unset}"
    printf 'mix_build_root=%s\\n' "${MIX_BUILD_ROOT-unset}"
    printf 'mix_build_path=%s\\n' "${MIX_BUILD_PATH-unset}"
    """)

    File.chmod!(Path.join(bin_dir, "mise"), 0o755)

    on_exit(fn -> File.rm_rf(bin_dir) end)

    env =
      [
        {"PATH", SymphonyElixir.TestSupport.script_path(bin_dir)},
        {"MISE_TRUSTED_CONFIG_PATHS", "/tmp/existing-trust"},
        {"SYMPHONY_WORKFLOW_FILE", "/tmp/wrong/WORKFLOW.md"},
        {"SYMPHONY_WORKFLOW_DIR", "/tmp/wrong"},
        {"SYMPHONY_SOURCE_REPO", "/tmp/wrong-source"},
        {"SYMPHONY_ISSUE_ID", "issue-wrong"},
        {"SYMPHONY_ISSUE_IDENTIFIER", "MT-WRONG"},
        {"SYMPHONY_ISSUE_LABELS_JSON", ~s([{"name":"Requires Manual Review"}])},
        {"SYMPHONY_PROJECT_ROOT", "/tmp/wrong-project"},
        {"SYMPHONY_PYTHON", "/tmp/wrong-python"},
        {"SYMPHONY_CODEX_COMMAND", "false"},
        {"SYMPHONY_LINEAR_SECRET_ACCESS", "denied"},
        {"MIX_DEPS_PATH", "/tmp/wrong-deps"},
        {"MIX_BUILD_ROOT", "/tmp/wrong-build"},
        {"MIX_BUILD_PATH", "/tmp/wrong-build-path"}
      ]

    # Resolve a relative link chain from another cwd, using system Bash.
    link = Path.join(bin_dir, "gate")
    File.ln_s!(@script_path, Path.join(bin_dir, "hop"))
    File.ln_s!("hop", link)
    assert {output, 0} = System.cmd("/bin/bash", [link, "format", "--check-formatted"], cd: bin_dir, env: env, stderr_to_stdout: true)

    assert output =~ "args=x -- mix format --check-formatted"
    assert output =~ "trusted=#{Path.join(@repo_root, "mise.toml")}:/tmp/existing-trust"
    assert output =~ "workflow=unset"
    assert output =~ "workflow_dir=unset"
    assert output =~ "source=unset"
    assert output =~ "issue_id=unset"
    assert output =~ "issue_identifier=unset"
    assert output =~ "labels=unset"
    assert output =~ "project=unset"
    assert output =~ "python=unset"
    assert output =~ "codex_command=unset"
    assert output =~ "secret_access=denied"
    assert output =~ "mix_deps=unset"
    assert output =~ "mix_build_root=unset"
    assert output =~ "mix_build_path=unset"
  end
end
