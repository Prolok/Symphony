defmodule SymCodexScriptTest do
  use ExUnit.Case

  @script_source Path.expand("../sym-codex", __DIR__)
  @mcp_script_source Path.expand("../sym-codex-mcp", __DIR__)
  @mix_runtime_source Path.expand("../scripts/mix-runtime", __DIR__)
  @interactive_workflow_source Path.expand("../WORKFLOW_INTERACTIVE.md", __DIR__)

  test "sym-codex reaches codex when invoked directly from the script repository" do
    %{repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {output, 0} = run_script(Path.join(repo_dir, "sym-codex"), bin_dir)
    assert output =~ "codex-stub"
  end

  test "manual app configuration selects the bound launcher without inherited worker variables" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root, worktree: worktree} =
      build_script_worktree_fixture!("PRO-676")

    on_exit(fn -> Enum.each([repo_dir, bin_dir, workspace_root], &File.rm_rf!/1) end)

    File.write!(Path.join(worktree, "scripts/codex-app-context.py"), """
    import os
    print('bound-app=' + os.environ['SYMPHONY_LINEAR_BINDING_HASH'])
    print('state=' + os.environ['SYMPHONY_CODEX_STATE_ROOT'])
    """)

    runtime = %{
      "SYMPHONY_LINEAR_AUTH_MODE" => "app",
      "SYMPHONY_LINEAR_CLIENT_SECRET_ENV" => "SYMPHONY_TEST_SECRET",
      "SYMPHONY_LINEAR_BINDING_HASH" => "synthetic-binding",
      "SYMPHONY_CODEX_STATE_ROOT" => Path.join(repo_dir, "state"),
      "SYMPHONY_RUN_ID" => "synthetic-run",
      "SYMPHONY_PHASE" => "In Arbeit (AI)"
    }

    prompt = "SYM_CODEX_CONTEXT_V3\n#{Jason.encode!(runtime)}\nIn Arbeit (AI)\n\nSYM_CODEX_PROMPT_V1\nTest"

    assert {output, 0} =
             run_script(Path.join(worktree, "sym-codex"), bin_dir, [],
               cd: worktree,
               env: [{"SYMPHONY_TEST_MANUAL_PROMPT_OUTPUT", prompt}]
             )

    assert output =~ "bound-app=synthetic-binding"
    assert output =~ "state=#{repo_dir}/state"
    refute output =~ "codex-stub"
  end

  test "sym-codex derives the issue identifier from the current worktree path" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root, worktree: worktree} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    assert {output, 0} =
             run_script(Path.join(worktree, "sym-codex"), bin_dir, [],
               cd: worktree,
               env: [{"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root}]
             )

    assert output =~ "codex-stub"
    assert output =~ "pwd=#{worktree}"
  end

  test "sym-codex keeps Mix artifacts local to the invoking Symphony worktree" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root, worktree: worktree} =
      build_script_worktree_fixture!("PRO-608")

    foreign_deps = Path.join(repo_dir, "deps")
    foreign_build = Path.join(repo_dir, "_build")
    File.write!(Path.join(repo_dir, "mix.lock"), "newer lock version\n")
    File.mkdir_p!(foreign_deps)
    File.mkdir_p!(foreign_build)
    File.write!(Path.join(foreign_deps, "sentinel"), "newer lock deps\n")
    File.write!(Path.join(foreign_build, "sentinel"), "newer lock build\n")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    assert {output, 0} =
             run_script(Path.join(worktree, "sym-codex"), bin_dir, ["PRO-608"],
               cd: worktree,
               env: [
                 {"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root},
                 {"MIX_DEPS_PATH", foreign_deps},
                 {"MIX_BUILD_ROOT", foreign_build},
                 {"MIX_BUILD_PATH", foreign_build}
               ]
             )

    assert output =~ "mix_deps=unset mix_build_root=unset mix_build_path=unset"
    assert File.ls!(foreign_deps) == ["sentinel"]
    assert File.ls!(foreign_build) == ["sentinel"]
    assert File.exists?(Path.join(worktree, "deps/sym-codex-touch"))
    assert File.exists?(Path.join(worktree, "_build/sym-codex-touch"))
  end

  test "sym-codex follows a symlink back to the script repository" do
    %{repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    link_dir = Path.join(System.tmp_dir!(), "sym-codex-link-#{System.unique_integer([:positive])}")
    link_path = Path.join(link_dir, "sym-codex")

    File.mkdir_p!(link_dir)
    File.ln_s!(Path.join(repo_dir, "sym-codex"), link_path)

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(link_dir)
    end)

    assert {output, 0} = run_script(link_path, bin_dir)
    assert output =~ "codex-stub"
  end

  test "sym-codex help omits the sourced invocation line" do
    %{repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {output, 0} = run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["--help"])
    assert output =~ "Usage:"
    refute output =~ "source sym-codex"
  end

  test "sym-codex configures a repo-local MCP server for direct execution" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-49"], env: [{"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root}])

    assert output =~ ~s(mcp_servers.symphony_linear.command="#{repo_dir}/sym-codex-mcp")
    assert output =~ ~s(SYMPHONY_SOURCE_REPO="#{repo_dir}")
    assert output =~ ~s(SYMPHONY_WORKFLOW_FILE="#{repo_dir}/WORKFLOW.md")
    assert output =~ "runtime_workflow_dir=#{repo_dir}"
    assert output =~ "runtime_issue_identifier=PRO-49"
    assert output =~ "manual-prompt-for-PRO-49"
  end

  test "sym-codex clears inherited Symphony runtime env while preserving explicit test env" do
    previous_env =
      Map.new(SymphonyElixir.TestSupport.symphony_runtime_env_keys(), fn key ->
        {key, System.get_env(key)}
      end)

    Enum.each(SymphonyElixir.TestSupport.symphony_runtime_env_keys(), fn key ->
      System.put_env(key, "/tmp/wrong/#{key}")
    end)

    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      SymphonyElixir.TestSupport.restore_env_snapshot(previous_env)
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-49"], env: [{"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root}])

    assert output =~ ~s(SYMPHONY_SOURCE_REPO="#{repo_dir}")
    assert output =~ ~s(SYMPHONY_WORKFLOW_FILE="#{repo_dir}/WORKFLOW.md")
    assert output =~ "runtime_workflow_dir=#{repo_dir}"
    refute output =~ "/tmp/wrong"
  end

  test "sym-codex resumes dialog sessions in the project root" do
    %{repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    workspace_root = Path.join(System.tmp_dir!(), "sym-codex-dialog-worktrees-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    prompt_output = manual_prompt_context_v2("Todo (Dialog-AI)", "thread-dialog", "follow-up-prompt")

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-351"],
               cd: repo_dir,
               env: [
                 {"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root},
                 {"SYMPHONY_TEST_WORKFLOW_STEP_OUTPUT", "Todo (Dialog-AI)"},
                 {"SYMPHONY_TEST_MANUAL_PROMPT_OUTPUT", prompt_output}
               ]
             )

    assert output =~ "codex-stub"
    assert output =~ "pwd=#{repo_dir}"
    refute output =~ "--sandbox read-only"
    refute output =~ "--ask-for-approval never"
    assert output =~ "resume thread-dialog follow-up-prompt"
    refute output =~ "no existing worktree"
    refute File.exists?(Path.join(workspace_root, ".dialog"))
  end

  test "sym-codex inferred from an implementation worktree still runs dialog sessions in the project root" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root, worktree: worktree} =
      build_script_worktree_fixture!("PRO-351")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    prompt_output = manual_prompt_context_v2("Todo (Dialog-AI)", "thread-dialog", "follow-up-prompt")

    assert {output, 0} =
             run_script(Path.join(worktree, "sym-codex"), bin_dir, [],
               cd: worktree,
               env: [
                 {"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root},
                 {"SYMPHONY_TEST_WORKFLOW_STEP_OUTPUT", "Todo (Dialog-AI)"},
                 {"SYMPHONY_TEST_MANUAL_PROMPT_OUTPUT", prompt_output}
               ]
             )

    assert output =~ "codex-stub"
    assert output =~ "pwd=#{repo_dir}"
    refute output =~ "pwd=#{worktree}"
    refute output =~ "--sandbox read-only"
    refute output =~ "--ask-for-approval never"
    assert output =~ "resume thread-dialog follow-up-prompt"
    refute File.exists?(Path.join(workspace_root, ".dialog"))
  end

  test "sym-codex resumes already answered dialog sessions without a new prompt" do
    %{repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    workspace_root = Path.join(System.tmp_dir!(), "sym-codex-dialog-noop-worktrees-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    prompt_output = manual_prompt_context_v2("Todo (Dialog-AI)", "thread-dialog", "")

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-351"],
               cd: repo_dir,
               env: [
                 {"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root},
                 {"SYMPHONY_TEST_WORKFLOW_STEP_OUTPUT", "Todo (Dialog-AI)"},
                 {"SYMPHONY_TEST_MANUAL_PROMPT_OUTPUT", prompt_output}
               ]
             )

    assert output =~ "codex-stub"
    assert output =~ "pwd=#{repo_dir}"
    refute output =~ "--sandbox read-only"
    refute output =~ "--ask-for-approval never"
    assert output =~ "resume thread-dialog"
    refute output =~ "SYM_CODEX_PROMPT_V1"
    refute output =~ "dialog="
    refute File.exists?(Path.join(workspace_root, ".dialog"))
  end

  test "sym-codex prefers the current Symphony worktree for MCP server wiring" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root, worktree: worktree} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    assert {output, 0} =
             run_script(Path.join(worktree, "sym-codex"), bin_dir, [],
               cd: worktree,
               env: [{"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root}]
             )

    assert output =~ ~s(mcp_servers.symphony_linear.command="#{worktree}/sym-codex-mcp")
    assert output =~ ~s(SYMPHONY_SOURCE_REPO="#{worktree}")
    assert output =~ ~s(SYMPHONY_WORKFLOW_FILE="#{worktree}/WORKFLOW.md")
    assert output =~ "manual-prompt-for-PRO-49"
  end

  test "sym-codex keeps the built-in launch profile when root env files are absent" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    prompt_output = manual_prompt_context("In Arbeit (AI)", "manual-prompt-for-PRO-49")

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-49"],
               env: [
                 {"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root},
                 {"SYMPHONY_TEST_MANUAL_PROMPT_OUTPUT", prompt_output}
               ]
             )

    assert output =~ "--model gpt-5.6-sol"
    assert output =~ "--config service_tier=priority"
    assert output =~ "--config model_reasoning_effort=high"
  end

  test "sym-codex passes the new reasoning effort values through unchanged" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    for reasoning_effort <- ["max", "ultra"] do
      File.write!(
        Path.join(repo_dir, ".env"),
        "SYM_CODEX_REASONING_EFFORT=#{reasoning_effort}\n"
      )

      assert {output, 0} =
               run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-49"], env: [{"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root}])

      assert output =~ "--config model_reasoning_effort=#{reasoning_effort}"
    end
  end

  test "sym-codex uses the same root env launch profile for every workflow step" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    File.write!(Path.join(repo_dir, ".env"), """
    SYM_CODEX_MODEL=gpt-5.4-mini
    SYM_CODEX_REASONING_EFFORT=medium
    SYM_CODEX_SERVICE_TIER=flex
    SYM_CODEX_HUMAN_SERVICE_TIER=priority
    """)

    for workflow_step <- ["In Arbeit (AI)", "Review (AI)"] do
      prompt_output = manual_prompt_context(workflow_step, "manual-prompt-for-PRO-49")

      assert {output, 0} =
               run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-49"],
                 cd: repo_dir,
                 env: [
                   {"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root},
                   {"SYMPHONY_TEST_MANUAL_PROMPT_OUTPUT", prompt_output}
                 ]
               )

      assert output =~ "--model gpt-5.4-mini"
      assert output =~ "--config model_reasoning_effort=medium"
    end
  end

  test "sym-codex lets root .env.local override root .env service tiers" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    File.write!(Path.join(repo_dir, ".env"), """
    SYM_CODEX_MODEL=gpt-5.5
    SYM_CODEX_REASONING_EFFORT=high
    SYM_CODEX_SERVICE_TIER=flex
    SYM_CODEX_HUMAN_SERVICE_TIER=priority
    """)

    File.write!(Path.join(repo_dir, ".env.local"), """
    SYM_CODEX_MODEL=gpt-5.4-mini
    SYM_CODEX_REASONING_EFFORT=low
    SYM_CODEX_SERVICE_TIER=standard
    SYM_CODEX_HUMAN_SERVICE_TIER=priority-plus
    """)

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-49"],
               cd: repo_dir,
               env: [{"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root}]
             )

    assert output =~ "--model gpt-5.4-mini"
    assert output =~ "--config service_tier=priority-plus"
    assert output =~ "--config model_reasoning_effort=low"
    refute output =~ "--config model_reasoning_effort=minimal"

    assert {observer_output, 0} =
             run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["--observer"], cd: repo_dir)

    assert observer_output =~ "--config service_tier=standard"
  end

  test "sym-codex uses the human service tier for manual starts" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    File.write!(Path.join(repo_dir, ".env"), """
    SYM_CODEX_SERVICE_TIER=flex
    SYM_CODEX_HUMAN_SERVICE_TIER=priority
    """)

    File.write!(Path.join(repo_dir, ".env.local"), """
    SYM_CODEX_SERVICE_TIER=standard
    SYM_CODEX_HUMAN_SERVICE_TIER=priority-plus
    """)

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-49"],
               cd: repo_dir,
               env: [{"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root}]
             )

    assert output =~ "--config service_tier=priority-plus"
    refute output =~ "--config service_tier=standard"
  end

  test "sym-codex reads launch overrides from the active Symphony worktree" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root, worktree: worktree} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    File.write!(Path.join(worktree, ".env"), """
    SYM_CODEX_MODEL=gpt-5.5
    SYM_CODEX_REASONING_EFFORT=high
    SYM_CODEX_SERVICE_TIER=flex
    """)

    File.write!(Path.join(worktree, ".env.local"), """
    SYM_CODEX_REASONING_EFFORT=xhigh
    """)

    assert {output, 0} =
             run_script(Path.join(worktree, "sym-codex"), bin_dir, ["--observer"], cd: worktree)

    assert output =~ "--model gpt-5.5"
    assert output =~ "--config service_tier=flex"
    assert output =~ "--config model_reasoning_effort=xhigh"
    refute output =~ "--config model_reasoning_effort=high"
  end

  test "sym-codex preserves explicit shell profile while manual starts use the human service tier" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    File.write!(Path.join(repo_dir, ".env"), """
    SYM_CODEX_MODEL=gpt-5.5
    SYM_CODEX_REASONING_EFFORT=high
    SYM_CODEX_SERVICE_TIER=flex
    SYM_CODEX_HUMAN_SERVICE_TIER=priority
    """)

    File.write!(Path.join(repo_dir, ".env.local"), """
    SYM_CODEX_MODEL=gpt-5.4-mini
    SYM_CODEX_REASONING_EFFORT=low
    SYM_CODEX_SERVICE_TIER=standard
    SYM_CODEX_HUMAN_SERVICE_TIER=priority-plus
    """)

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-49"],
               cd: repo_dir,
               env: [
                 {"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root},
                 {"SYM_CODEX_MODEL", "gpt-5.2"},
                 {"SYM_CODEX_REASONING_EFFORT", "xhigh"},
                 {"SYM_CODEX_SERVICE_TIER", "shell-standard"},
                 {"SYM_CODEX_HUMAN_SERVICE_TIER", "shell-priority"}
               ]
             )

    assert output =~ "--model gpt-5.2"
    assert output =~ "--config model_reasoning_effort=xhigh"
    assert output =~ "--config service_tier=shell-priority"
    refute output =~ "--config service_tier=shell-standard"
  end

  test "sym-codex accepts service tier strings from env files" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    File.write!(Path.join(repo_dir, ".env"), "SYM_CODEX_HUMAN_SERVICE_TIER=priority-plus\n")

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-49"],
               cd: repo_dir,
               env: [{"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root}]
             )

    assert output =~ "--config service_tier=priority-plus"
  end

  test "sym-codex ignores .symphony env files for launch profile values" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    File.mkdir_p!(Path.join(repo_dir, ".symphony"))
    File.write!(Path.join(repo_dir, ".symphony/.env"), "SYM_CODEX_MODEL=gpt-5.4-mini\n")
    File.write!(Path.join(repo_dir, ".symphony/.env.local"), "SYM_CODEX_REASONING_EFFORT=low\n")

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-49"],
               cd: repo_dir,
               env: [{"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root}]
             )

    assert output =~ "--model gpt-5.6-sol"
    assert output =~ "--config model_reasoning_effort=high"
    refute output =~ "--model gpt-5.4-mini"
    refute output =~ "--config model_reasoning_effort=low"
  end

  test "sym-codex exports the active worktree while building the manual prompt" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root, worktree: worktree} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-49"],
               env: [
                 {"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root},
                 {"SYMPHONY_TEST_MANUAL_PROMPT_OUTPUT_FROM_ENV", "1"}
               ]
             )

    assert output =~ "active=#{worktree}"
    assert output =~ "source=#{repo_dir}"
    assert output =~ "workflow=#{Path.join(repo_dir, "WORKFLOW.md")}"
  end

  test "sym-codex resolves worktrees from the local project root when launched from another repo" do
    %{
      repo_dir: repo_dir,
      bin_dir: bin_dir,
      project_root: project_root,
      worktree: worktree
    } = build_external_project_fixture!("PRO-28")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(Path.dirname(project_root))
    end)

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-28"], cd: project_root)

    assert output =~ "codex-stub"
    assert output =~ "pwd=#{worktree}"
    assert output =~ ~s(SYMPHONY_SOURCE_REPO="#{repo_dir}")
    assert output =~ ~s(SYMPHONY_PROJECT_ROOT="#{project_root}")
    assert output =~ ~s(SYMPHONY_WORKFLOW_FILE="#{repo_dir}/WORKFLOW.md")
    assert output =~ "runtime_workflow_dir=#{repo_dir}"
    assert output =~ "runtime_source_repo=#{project_root}"
    assert output =~ "runtime_issue_identifier=PRO-28"
  end

  test "sym-codex infers the issue identifier from an external project worktree" do
    %{
      repo_dir: repo_dir,
      bin_dir: bin_dir,
      project_root: project_root,
      worktree: worktree
    } = build_external_project_fixture!("PRO-28")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(Path.dirname(project_root))
    end)

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-codex"), bin_dir, [], cd: worktree)

    assert output =~ "codex-stub"
    assert output =~ "pwd=#{worktree}"
  end

  test "sym-codex observer start from a worktree avoids mix for branch-based inference" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root, worktree: worktree} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    File.write!(Path.join(bin_dir, "mix"), """
    #!/usr/bin/env bash
    printf 'mix should not run\\n' >&2
    exit 99
    """)

    File.chmod!(Path.join(bin_dir, "mix"), 0o755)

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["--observer"], cd: worktree)

    assert output =~ "codex-stub"
    assert output =~ "pwd=#{worktree}"
    refute output =~ "mix should not run"
  end

  test "sourced app launcher returns the selected worktree and venv through the release child" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root, worktree: worktree} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    File.cp!(Path.expand("../scripts/installation-release.py", __DIR__), Path.join(repo_dir, "scripts/installation-release.py"))
    File.write!(Path.join(repo_dir, "WORKFLOW.md"), "---\ntracker:\n  auth_mode: app\n---\n")
    File.write!(Path.join(repo_dir, ".gitignore"), ".symphony/\n")
    File.rename!(Path.join(repo_dir, "scripts/mix-runtime"), Path.join(repo_dir, "scripts/mix-runtime-fixture"))

    # Keep real snapshotting, argument forwarding and both sym-codex processes;
    # stand in only for the external build/Linear peers in this shell contract.
    File.write!(Path.join(repo_dir, "scripts/mix-runtime"), """
    #!/bin/bash
    if [[ "$1" == start ]]; then
      release="$2"
      shift 3
      printf '{"files":{}}' > "$release/.symphony-release.json"
      exec "$release/sym-codex" "$@"
    fi
    exec "$(dirname "${BASH_SOURCE[0]}")/mix-runtime-fixture" "$@"
    """)

    File.chmod!(Path.join(repo_dir, "scripts/mix-runtime"), 0o755)
    File.write!(Path.join(repo_dir, ".venv/bin/codex"), "\nexit 7\n", [:append])

    command =
      ~s|. "#{Path.join(repo_dir, "sym-codex")}" PRO-49; status=$?; printf 'after status=%s pwd=%s venv=%s\\n' "$status" "$PWD" "${VIRTUAL_ENV:-}"|

    assert {output, 0} =
             System.cmd("/bin/bash", ["--noprofile", "--norc", "-c", command],
               cd: repo_dir,
               env:
                 SymphonyElixir.TestSupport.cleared_symphony_runtime_env() ++
                   [
                     {"PATH", SymphonyElixir.TestSupport.script_path(bin_dir)},
                     {"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root},
                     {"SYMPHONY_SOURCE_REPO", repo_dir}
                   ],
               stderr_to_stdout: true
             )

    assert output =~ "Eigener Laufzeitstand"
    assert output =~ "codex-stub pwd=#{worktree}"
    assert output =~ "after status=7 pwd=#{worktree} venv=#{Path.join(repo_dir, ".venv")}"
    assert Path.wildcard(Path.join(repo_dir, ".symphony/installations/sourced-*")) == []
  end

  test "sourced sym-codex activates the repo venv in the current shell" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root, worktree: worktree} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    command =
      ~s|. "#{Path.join(repo_dir, "sym-codex")}" PRO-49; printf 'after pwd=%s venv=%s codex=%s\\n' "$PWD" "${VIRTUAL_ENV:-}" "$(command -v codex)"|

    {output, 0} =
      System.cmd("/bin/bash", ["--noprofile", "--norc", "-c", command],
        cd: repo_dir,
        env:
          SymphonyElixir.TestSupport.cleared_symphony_runtime_env() ++
            [
              {"PATH", SymphonyElixir.TestSupport.script_path(bin_dir)},
              {"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root}
            ],
        stderr_to_stdout: true
      )

    assert output =~ "codex-stub"
    assert output =~ "pwd=#{worktree}"
    assert output =~ "venv=#{Path.join(repo_dir, ".venv")}"
    assert output =~ "codex=#{Path.join(repo_dir, ".venv/bin/codex")}"
  end

  test "sourced sym-codex keeps repo python ahead in login shells spawned afterwards" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root, worktree: _worktree} =
      build_script_worktree_fixture!("PRO-49")

    fake_home =
      Path.join(System.tmp_dir!(), "sym-codex-home-#{System.unique_integer([:positive])}")

    fake_user_bin = Path.join(fake_home, ".local/bin")
    fake_user_python = Path.join(fake_user_bin, "python")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
      File.rm_rf(fake_home)
    end)

    File.mkdir_p!(fake_user_bin)

    File.write!(Path.join(fake_home, ".profile"), """
    PATH="$HOME/.local/bin:$PATH"
    export PATH
    """)

    File.write!(fake_user_python, """
    #!/usr/bin/env bash
    printf 'user-python\\n'
    """)

    File.chmod!(fake_user_python, 0o755)

    command =
      ~s|. "#{Path.join(repo_dir, "sym-codex")}" PRO-49; HOME="#{fake_home}" bash -lc 'printf "python=%s\\nvenv=%s\\nbash_env=%s\\n" "$(command -v python)" "${VIRTUAL_ENV:-}" "${BASH_ENV:-}"'|

    {output, 0} =
      System.cmd("/bin/bash", ["--noprofile", "--norc", "-c", command],
        cd: repo_dir,
        env:
          SymphonyElixir.TestSupport.cleared_symphony_runtime_env() ++
            [
              {"PATH", SymphonyElixir.TestSupport.script_path(bin_dir)},
              {"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root}
            ],
        stderr_to_stdout: true
      )

    assert output =~ "python=#{Path.join(repo_dir, ".venv/bin/python")}"
    assert output =~ "venv=#{Path.join(repo_dir, ".venv")}"
    assert output =~ "bash_env=#{Path.join(repo_dir, ".venv/bin/activate")}"
  end

  test "sym-codex prefers a worktree-local venv over the script-repo venv" do
    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root, worktree: worktree} =
      build_script_worktree_fixture!("PRO-49")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(workspace_root)
    end)

    create_venv_fixture!(worktree, "workspace")

    {output, 0} =
      run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-49"], env: [{"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root}])

    assert output =~ "venv=#{Path.join(worktree, ".venv")}"
  end

  test "sym-codex prefers the project-root venv over worktree and script-repo venvs" do
    %{
      repo_dir: repo_dir,
      bin_dir: bin_dir,
      project_root: project_root,
      workspace_root: _workspace_root,
      worktree: worktree
    } = build_external_project_fixture!("PRO-28")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(Path.dirname(project_root))
    end)

    create_venv_fixture!(project_root, "project")
    create_venv_fixture!(worktree, "workspace")

    {output, 0} =
      run_script(Path.join(repo_dir, "sym-codex"), bin_dir, ["PRO-28"], cd: worktree)

    assert output =~ "venv=#{Path.join(project_root, ".venv")}"
  end

  test "worktree hooks create executable issue commands for bash and zsh and clean only matching links" do
    %{repo_dir: repo, bin_dir: bin, worktree: worktree, workspace_root: workspace_root} =
      build_script_worktree_fixture!("PRO-678")

    home = Path.join(bin, "home with spaces")
    user_bin = Path.join(home, ".local/bin")
    File.mkdir_p!(user_bin)

    env =
      SymphonyElixir.TestSupport.cleared_symphony_runtime_env() ++
        SymphonyElixir.TestSupport.script_env(bin) ++
        [{"HOME", home}, {"SYMPHONY_PROJECT_WORKTREES_ROOT", workspace_root}]

    on_exit(fn -> Enum.each([repo, bin, workspace_root], &File.rm_rf/1) end)
    create = Path.expand("../.symphony/on_create_worktree.py", __DIR__)
    remove = Path.expand("../.symphony/on_remove_worktree.py", __DIR__)

    for _ <- 1..2 do
      assert {_, 0} = System.cmd(System.find_executable("python3"), [create, repo, worktree], env: env)
    end

    link = Path.join(user_bin, "sym-codex-PRO-678")
    assert File.read_link!(link) == Path.join(worktree, "sym-codex")
    # A generic, relative multi-hop helper link must also choose the worktree.
    File.ln_s!("sym-codex-PRO-678", Path.join(user_bin, "hop"))
    File.ln_s!("hop", Path.join(user_bin, "sym-codex"))

    for shell <- ["/bin/bash", System.find_executable("zsh") || flunk("zsh required for platform proof")],
        command <- ["sym-codex-PRO-678 --observer PRO-678", "sym-codex --observer PRO-678", "sym-codex PRO-678"] do
      assert {output, 0} =
               System.cmd(shell, ["-f", "-c", command],
                 cd: repo,
                 env: env ++ [{"PATH", "#{user_bin}:#{SymphonyElixir.TestSupport.script_path(bin)}"}],
                 stderr_to_stdout: true
               )

      assert output =~ "pwd=#{worktree}"
    end

    symphony_link = Path.join(user_bin, "symphony-PRO-678")
    File.rm!(symphony_link)
    File.ln_s!("foreign-target", symphony_link)
    assert {_, 0} = System.cmd(System.find_executable("python3"), [remove, repo, worktree], env: env)
    assert {:error, :enoent} = File.lstat(link)
    assert File.read_link!(symphony_link) == "foreign-target"
    assert File.read_link!(Path.join(user_bin, "sym-codex")) == "hop"
  end

  defp build_script_fixture! do
    repo_dir =
      Path.join(System.tmp_dir!(), "sym-codex-script-#{System.unique_integer([:positive])}")

    bin_dir = Path.join(System.tmp_dir!(), "sym-codex-bin-#{System.unique_integer([:positive])}")
    codex_path = Path.join(bin_dir, "codex")
    mix_path = Path.join(bin_dir, "mix")
    mise_path = Path.join(bin_dir, "mise")

    File.mkdir_p!(repo_dir)
    File.mkdir_p!(Path.join(repo_dir, "scripts"))
    File.mkdir_p!(bin_dir)
    File.cp!(@script_source, Path.join(repo_dir, "sym-codex"))
    File.cp!(@mcp_script_source, Path.join(repo_dir, "sym-codex-mcp"))
    File.cp!(@mix_runtime_source, Path.join(repo_dir, "scripts/mix-runtime"))

    File.write!(codex_path, """
    #!/usr/bin/env bash
    printf 'codex-stub pwd=%s args=%s runtime_workflow_dir=%s runtime_source_repo=%s runtime_issue_identifier=%s mix_deps=%s mix_build_root=%s mix_build_path=%s\\n' \
      "$PWD" \
      "$*" \
      "${SYMPHONY_WORKFLOW_DIR:-}" \
      "${SYMPHONY_SOURCE_REPO:-}" \
      "${SYMPHONY_ISSUE_IDENTIFIER:-}" \
      "${MIX_DEPS_PATH-unset}" \
      "${MIX_BUILD_ROOT-unset}" \
      "${MIX_BUILD_PATH-unset}"
    """)

    create_venv_fixture!(repo_dir, "repo")

    File.write!(mix_path, """
    #!/usr/bin/env bash
    deps_path="${MIX_DEPS_PATH:-$PWD/deps}"
    build_path="${MIX_BUILD_PATH:-${MIX_BUILD_ROOT:-$PWD/_build}}"
    mkdir -p "$deps_path" "$build_path"
    printf '%s\\n' "$1" >> "$deps_path/sym-codex-touch"
    printf '%s\\n' "$1" >> "$build_path/sym-codex-touch"

    if [ "$1" = "deps.loadpaths" ]; then
      exit 0
    fi

    if [ "$1" = "compile" ]; then
      exit 0
    fi

    if [ "$1" = "run" ]; then
      shift
      mix_expr=""

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --no-start|--no-compile)
            shift
            ;;
          -e)
            mix_expr="$2"
            shift 2
            break
            ;;
          *)
            printf 'unexpected mix args=%s\\n' "run $*" >&2
            exit 1
            ;;
        esac
      done

      if [ "$1" = "--" ]; then
        shift
      fi

      case "$#" in
        1)
          printf '%s' "${SYMPHONY_PROJECT_WORKTREES_ROOT:-}"
          exit 0
          ;;
        2)
          case "$mix_expr" in
            *dialog_workspace*)
              dialog_workspace="${SYMPHONY_TEST_DIALOG_WORKSPACE:-${SYMPHONY_PROJECT_ROOT:-$(pwd -P)}}"
              printf '%s' "$dialog_workspace"
              ;;
            *)
              printf '%s' "${SYMPHONY_TEST_WORKFLOW_STEP_OUTPUT:-In Arbeit (AI)}"
              ;;
          esac
          exit 0
          ;;
        3|4)
          issue_identifier="$#"
          if [ -n "${SYMPHONY_TEST_MANUAL_PROMPT_OUTPUT_FROM_ENV:-}" ]; then
            printf 'SYM_CODEX_CONTEXT_V1\nIn Arbeit (AI)\nSYM_CODEX_PROMPT_V1\nactive=%s source=%s workflow=%s' \
              "${SYMPHONY_ACTIVE_REPO_ROOT:-}" \
              "${SYMPHONY_SOURCE_REPO:-}" \
              "${SYMPHONY_WORKFLOW_FILE:-}"
          elif [ -n "${SYMPHONY_TEST_MANUAL_PROMPT_OUTPUT:-}" ]; then
            printf '%s' "$SYMPHONY_TEST_MANUAL_PROMPT_OUTPUT"
          else
            eval "resolved_issue_identifier=\\${$issue_identifier}"
            printf 'manual-prompt-for-%s' "$resolved_issue_identifier"
          fi
          exit 0
          ;;
      esac
    fi

    printf 'unexpected mix args=%s\\n' "$*" >&2
    exit 1
    """)

    File.write!(mise_path, "#!/usr/bin/env bash\nif [ \"$1\" = \"exec\" ] && [ \"$2\" = \"--\" ]; then\n  shift 2\n  exec \"$@\"\nfi\nprintf 'unexpected mise args=%s\\n' \"$*\" >&2\nexit 1\n")
    File.chmod!(codex_path, 0o755)
    File.chmod!(mix_path, 0o755)
    File.chmod!(mise_path, 0o755)
    File.chmod!(Path.join(repo_dir, "scripts/mix-runtime"), 0o755)
    File.write!(Path.join(repo_dir, "WORKFLOW.md"), "")
    File.cp!(@interactive_workflow_source, Path.join(repo_dir, "WORKFLOW_INTERACTIVE.md"))
    File.write!(Path.join(repo_dir, "WORKFLOW_DIALOG.md"), "---\n---\ndialog={{ issue.identifier }}\n")
    File.write!(Path.join(repo_dir, "mix.exs"), "")
    File.write!(Path.join(repo_dir, "mix.lock"), "old lock version\n")

    %{repo_dir: repo_dir, bin_dir: bin_dir}
  end

  defp build_script_worktree_fixture!(issue_identifier) do
    %{repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    workspace_root = Path.join(System.tmp_dir!(), "sym-codex-worktrees-#{System.unique_integer([:positive])}")
    worktree = Path.join(workspace_root, issue_identifier)

    File.mkdir_p!(workspace_root)

    git_cmd!(repo_dir, ["init", "-b", "main"])
    git_cmd!(repo_dir, ["config", "user.name", "SymCodex Script Test"])
    git_cmd!(repo_dir, ["config", "user.email", "sym-codex-script-test@example.com"])
    git_cmd!(repo_dir, ["add", "."])
    git_cmd!(repo_dir, ["commit", "-m", "Initial commit"])
    git_cmd!(repo_dir, ["worktree", "add", "-b", "symphony/#{issue_identifier}", worktree, "HEAD"])

    %{repo_dir: repo_dir, bin_dir: bin_dir, workspace_root: workspace_root, worktree: worktree}
  end

  defp build_external_project_fixture!(issue_identifier) do
    %{repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()

    test_root =
      Path.join(System.tmp_dir!(), "sym-codex-project-#{System.unique_integer([:positive])}")

    project_root = Path.join(test_root, "project")
    workspace_root = project_root <> "-worktrees"
    worktree = Path.join(workspace_root, issue_identifier)

    File.mkdir_p!(project_root)
    File.mkdir_p!(workspace_root)

    git_cmd!(project_root, ["init", "-b", "main"])
    git_cmd!(project_root, ["config", "user.name", "SymCodex External Project Test"])
    git_cmd!(project_root, ["config", "user.email", "sym-codex-external-project-test@example.com"])
    File.write!(Path.join(project_root, "README.md"), "project\n")
    git_cmd!(project_root, ["add", "README.md"])
    git_cmd!(project_root, ["commit", "-m", "Initial commit"])
    git_cmd!(project_root, ["worktree", "add", "-b", "symphony/#{issue_identifier}", worktree, "HEAD"])

    %{
      repo_dir: repo_dir,
      bin_dir: bin_dir,
      project_root: project_root,
      workspace_root: workspace_root,
      worktree: worktree
    }
  end

  defp run_script(script_path, bin_dir, args \\ ["--observer"], opts \\ []) do
    env =
      SymphonyElixir.TestSupport.cleared_symphony_runtime_env() ++
        [
          {"PATH", SymphonyElixir.TestSupport.script_path(bin_dir)},
          {"SYM_CODEX_MODEL", nil},
          {"SYM_CODEX_REASONING_EFFORT", nil},
          {"SYM_CODEX_SERVICE_TIER", nil},
          {"SYM_CODEX_HUMAN_SERVICE_TIER", nil}
        ] ++ Keyword.get(opts, :env, [])

    system_opts = [env: env, stderr_to_stdout: true]
    system_opts = maybe_put_cd(system_opts, Keyword.get(opts, :cd))

    System.cmd(
      "/bin/bash",
      [script_path | args],
      system_opts
    )
  end

  defp git_cmd!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {_, 0} = success -> success
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end

  defp maybe_put_cd(opts, nil), do: opts
  defp maybe_put_cd(opts, cd), do: Keyword.put(opts, :cd, cd)

  defp create_venv_fixture!(root, label) do
    venv_bin_dir = Path.join(root, ".venv/bin")
    venv_activate_path = Path.join(venv_bin_dir, "activate")
    venv_codex_path = Path.join(venv_bin_dir, "codex")
    venv_python_path = Path.join(venv_bin_dir, "python")

    File.mkdir_p!(venv_bin_dir)

    File.write!(venv_activate_path, """
    _sym_codex_venv_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
    export VIRTUAL_ENV="$_sym_codex_venv_dir"
    export PATH="$VIRTUAL_ENV/bin:$PATH"
    """)

    File.write!(venv_codex_path, """
    #!/usr/bin/env bash
    printf 'codex-stub pwd=%s args=%s venv=%s label=#{label} runtime_workflow_dir=%s runtime_source_repo=%s runtime_issue_identifier=%s mix_deps=%s mix_build_root=%s mix_build_path=%s\\n' \\
      "$PWD" \\
      "$*" \\
      "${VIRTUAL_ENV:-}" \\
      "${SYMPHONY_WORKFLOW_DIR:-}" \\
      "${SYMPHONY_SOURCE_REPO:-}" \\
      "${SYMPHONY_ISSUE_IDENTIFIER:-}" \\
      "${MIX_DEPS_PATH-unset}" \\
      "${MIX_BUILD_ROOT-unset}" \\
      "${MIX_BUILD_PATH-unset}"
    """)

    File.write!(venv_python_path, """
    #!/usr/bin/env bash
    printf '#{label}-python\\n'
    """)

    File.chmod!(venv_codex_path, 0o755)
    File.chmod!(venv_python_path, 0o755)
  end

  defp manual_prompt_context(workflow_step, prompt) do
    "SYM_CODEX_CONTEXT_V1\n#{workflow_step}\nSYM_CODEX_PROMPT_V1\n#{prompt}"
  end

  defp manual_prompt_context_v2(workflow_step, session_id, prompt) do
    "SYM_CODEX_CONTEXT_V2\n#{workflow_step}\n#{session_id}\nSYM_CODEX_PROMPT_V1\n#{prompt}"
  end
end
