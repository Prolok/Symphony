defmodule SymphonyElixir.RootEnvTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.EnvFile
  alias SymphonyElixir.Linear.AppAuth

  setup do
    keys =
      EnvFile.root_config_names() ++
        ~w(LINEAR_APP_CLIENT_ID LINEAR_APP_WORKSPACE_ID LINEAR_APP_USER_ID LINEAR_APP_INSTALLATION_ID LINEAR_APP_STATE_ROOT LINEAR_APP_SECRET_ENV LINEAR_APP_SECRET LINEAR_ASSIGNEE SYMPHONY_ROOT_DIR SYMPHONY_LINEAR_ENV_DIR SYMPHONY_PROJECT_CONTEXT SYMPHONY_LINEAR_SECRET_ACCESS SECRET_SELECTOR SYNTHETIC_SECRET_DEFAULT SYNTHETIC_SECRET_LOCAL)

    previous = Map.new(keys, &{&1, System.get_env(&1)})
    Enum.each(keys, &System.delete_env/1)
    root = Path.join(System.tmp_dir!(), "root-env-#{System.unique_integer([:positive])}")
    source = Path.join(root, "symphony")
    project = Path.join(root, "project/.symphony")
    release = Path.join(root, "release")
    Enum.each([source, project, release], &File.mkdir_p!/1)
    System.put_env("SYMPHONY_ROOT_DIR", source)
    System.put_env("SYMPHONY_LINEAR_ENV_DIR", project)

    on_exit(fn ->
      SymphonyElixir.TestSupport.restore_env_snapshot(previous)
      File.rm_rf!(root)
    end)

    {:ok, root: root, source: source, project: project, release: release}
  end

  test "root defaults, local overrides and external precedence stay separate from project scope", ctx do
    File.write!(Path.join(ctx.source, ".env"), "LINEAR_APP_CLIENT_ID=default\nSYM_CODEX_MODEL=default-model\nLINEAR_APP_SECRET=default-secret\nLINEAR_ASSIGNEE=wrong-root\n")
    File.write!(Path.join(ctx.source, ".env.local"), "LINEAR_APP_CLIENT_ID=local\nSYM_CODEX_MODEL=local-model\nLINEAR_APP_SECRET='synthetic-secret $(touch forbidden)'\n")
    File.write!(Path.join(ctx.project, ".env"), "LINEAR_ASSIGNEE=default@example.invalid\nLINEAR_PROJECT_SLUG=default-project\n")

    File.write!(
      Path.join(ctx.project, ".env.local"),
      "LINEAR_ASSIGNEE=human@example.invalid\nLINEAR_PROJECT_SLUG=selected-project\nLINEAR_APP_CLIENT_ID=project-local\nLINEAR_APP_SECRET='synthetic-secret $(touch forbidden)'\n"
    )

    System.put_env("SYM_CODEX_MODEL", "external-model")
    System.put_env("LINEAR_ASSIGNEE", "inherited@example.invalid")

    assert :ok = EnvFile.load_runtime(ctx.project)
    assert System.get_env("LINEAR_APP_CLIENT_ID") == "project-local"
    assert System.get_env("SYM_CODEX_MODEL") == "external-model"
    assert System.get_env("LINEAR_ASSIGNEE") == "human@example.invalid"
    assert System.get_env("LINEAR_PROJECT_SLUG") == "selected-project"
    assert System.get_env("LINEAR_APP_SECRET") == nil
    assert {:ok, "synthetic-secret $(touch forbidden)"} = Config.linear_client_secret(%{"client_secret_env" => "LINEAR_APP_SECRET"})
    refute File.exists?(Path.join(ctx.source, "forbidden"))
    System.put_env("LINEAR_APP_CLIENT_ID", "external-client")
    assert :ok = EnvFile.load_runtime(ctx.project)
    assert System.get_env("LINEAR_APP_CLIENT_ID") == "project-local"
  end

  test "project secret overrides inherited values, including empty entries, with env only as fallback", ctx do
    File.write!(Path.join(ctx.project, ".env"), "LINEAR_APP_SECRET=default-secret\n")
    assert {:ok, "default-secret"} = EnvFile.linear_secret("LINEAR_APP_SECRET")
    File.write!(Path.join(ctx.project, ".env.local"), "LINEAR_APP_SECRET=local-secret\n")
    assert :ok = EnvFile.load(ctx.project, override_existing: true)
    assert System.get_env("LINEAR_APP_SECRET") == nil
    assert {:ok, "local-secret"} = EnvFile.linear_secret("LINEAR_APP_SECRET")
    System.put_env("LINEAR_APP_SECRET", "external-secret")
    assert {:ok, "local-secret"} = EnvFile.linear_secret("LINEAR_APP_SECRET")
    System.put_env("LINEAR_APP_SECRET", "")
    assert {:ok, "local-secret"} = EnvFile.linear_secret("LINEAR_APP_SECRET")
    System.put_env("LINEAR_APP_SECRET", "wrong-inherited-secret")
    File.write!(Path.join(ctx.project, ".env.local"), "LINEAR_APP_SECRET=\n")
    assert {:error, :missing_linear_client_secret} = EnvFile.linear_secret("LINEAR_APP_SECRET")
    File.rm!(Path.join(ctx.project, ".env"))
    File.rm!(Path.join(ctx.project, ".env.local"))
    assert {:ok, "wrong-inherited-secret"} = EnvFile.linear_secret("LINEAR_APP_SECRET")
    System.delete_env("LINEAR_APP_SECRET")
    File.write!(Path.join(ctx.source, ".env.local"), "LINEAR_APP_SECRET=wrong-root-secret\n")
    assert :ok = EnvFile.load_runtime(ctx.project)
    assert {:error, :missing_linear_client_secret} = EnvFile.linear_secret("LINEAR_APP_SECRET")
    System.delete_env("SYMPHONY_LINEAR_ENV_DIR")
    System.delete_env("SYMPHONY_ROOT_DIR")
    assert :ok = EnvFile.load_root()
    assert {:error, :missing_linear_client_secret} = EnvFile.linear_secret("LINEAR_APP_SECRET")
    System.put_env("SYMPHONY_ROOT_DIR", "")
    assert :ok = EnvFile.load_root()
  end

  test "project-selected secret names are excluded before either public env file loads", ctx do
    workflow = Path.join(ctx.root, "selected-workflow.md")
    File.write!(workflow, "---\ntracker:\n  auth_mode: app\n  app:\n    client_secret_env: $SECRET_SELECTOR\n---\nSynthetic\n")
    Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    Workflow.set_workflow_file_path(workflow)
    Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    for selector_first? <- [true, false] do
      System.delete_env("SECRET_SELECTOR")
      System.delete_env("SYNTHETIC_SECRET_DEFAULT")
      System.delete_env("SYNTHETIC_SECRET_LOCAL")

      for {file, name} <- [{".env", "SYNTHETIC_SECRET_DEFAULT"}, {".env.local", "SYNTHETIC_SECRET_LOCAL"}] do
        lines = ["SECRET_SELECTOR=#{name}", "#{name}=synthetic-never-export"]
        lines = if selector_first?, do: lines, else: Enum.reverse(lines)
        File.write!(Path.join(ctx.project, file), Enum.join(lines, "\n") <> "\n")
      end

      assert :ok = EnvFile.load_runtime(ctx.project)
      assert System.get_env("SECRET_SELECTOR") == "SYNTHETIC_SECRET_LOCAL"
      assert System.get_env("SYNTHETIC_SECRET_DEFAULT") == nil
      assert System.get_env("SYNTHETIC_SECRET_LOCAL") == nil
      assert {:ok, "synthetic-never-export"} = EnvFile.linear_secret("SYNTHETIC_SECRET_LOCAL")
    end

    File.write!(Path.join(ctx.project, ".env"), "SECRET_SELECTOR=\"unterminated\n")
    assert {:error, _} = EnvFile.load_runtime(ctx.project)
    assert System.get_env("SYNTHETIC_SECRET_DEFAULT") == nil
    assert System.get_env("SYNTHETIC_SECRET_LOCAL") == nil
  end

  test "fresh CLI MCP and script bootstraps select their workflow before loading secrets", ctx do
    project = Path.dirname(ctx.project)
    File.write!(Path.join(project, "WORKFLOW.md"), "---\ntracker:\n  auth_mode: legacy\n---\nSynthetic default\n")
    workflow = Path.join(project, "CUSTOM.md")
    helper = Path.expand("../support/linear_app/bootstrap_helper.exs", __DIR__)
    code_paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])

    results =
      for mode <- ~w(cli mcp script), indirect? <- [true, false] do
        reference = if indirect?, do: "$SECRET_SELECTOR", else: "SYNTHETIC_SECRET_LOCAL"
        default = if indirect?, do: "SYNTHETIC_SECRET_DEFAULT", else: "SYNTHETIC_SECRET_LOCAL"
        File.write!(workflow, "---\ntracker:\n  auth_mode: app\n  app:\n    client_secret_env: #{reference}\n---\nSynthetic selected\n")
        File.write!(Path.join(ctx.project, ".env"), "#{default}=synthetic-default-value\nSECRET_SELECTOR=#{default}\n")
        File.write!(Path.join(ctx.project, ".env.local"), "SYNTHETIC_SECRET_LOCAL=synthetic-local-value\nSECRET_SELECTOR=SYNTHETIC_SECRET_LOCAL\n")
        {output, status} = System.cmd(System.find_executable("elixir"), code_paths ++ [helper, mode, project, workflow], stderr_to_stdout: true)
        assert status == 0, "#{mode}: #{output}"
        refute output =~ "synthetic-local-value"
        result = output |> String.trim() |> Jason.decode!()
        {mode, indirect?, result["exported"]}
      end

    assert Enum.all?(results, fn {_mode, _indirect, exported} -> exported == false end), inspect(results)
  end

  test "root files are reread without snapshots or exporting private values", ctx do
    File.write!(Path.join(ctx.source, ".env"), "SYM_CODEX_MODEL=default-model\n")
    File.write!(Path.join(ctx.source, ".env.local"), "SYM_CODEX_MODEL=local-model\nLINEAR_APP_SECRET=synthetic-secret\n")
    assert {:ok, %{"SYM_CODEX_MODEL" => "local-model"}} = EnvFile.read_root(ctx.source)
    File.write!(Path.join(ctx.source, ".env.local"), "SYM_CODEX_MODEL=changed-model\n")
    assert {:ok, %{"SYM_CODEX_MODEL" => "changed-model"}} = EnvFile.read_root(ctx.source)
    File.rm!(Path.join(ctx.source, ".env.local"))
    assert {:ok, %{"SYM_CODEX_MODEL" => "default-model"}} = EnvFile.read_root(ctx.source)
    File.mkdir!(Path.join(ctx.source, ".env.local"))
    assert {:error, {:env_file_read_failed, _, :eisdir}} = EnvFile.read_root(ctx.source)
    File.rmdir!(Path.join(ctx.source, ".env.local"))
    File.write!(Path.join(ctx.source, ".env.local"), "SYM_CODEX_MODEL=\"unterminated\n")
    assert {:error, {:invalid_env_file, _, 1, :unterminated_quote}} = EnvFile.read_root(ctx.source)
    assert System.get_env("LINEAR_APP_SECRET") == nil
  end

  test "project discovery honors multiple base paths from the original env.local", ctx do
    previous = Application.get_env(:symphony_elixir, :project_contexts)
    settings = Application.get_env(:symphony_elixir, :service_settings)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :project_contexts, previous || [])

      if settings,
        do: Application.put_env(:symphony_elixir, :service_settings, settings),
        else: Application.delete_env(:symphony_elixir, :service_settings)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: "$SYMPHONY_PROJECT_WORKTREES_ROOT", tracker_project_slug: "$LINEAR_PROJECT_SLUG")
    bases = [Path.join(ctx.root, "QuantHub"), Path.join(ctx.root, "Project Hub")]
    projects = Enum.map(bases, &Path.join(&1, "Project"))

    for project <- projects do
      File.mkdir_p!(Path.join(project, ".symphony"))
      File.write!(Path.join(project, ".symphony/.env"), "LINEAR_ASSIGNEE=human@example.invalid\nLINEAR_PROJECT_SLUG=#{Path.basename(Path.dirname(project))}\n")
    end

    File.ln_s!(hd(bases), Path.join(ctx.root, "alias"))
    File.write!(Path.join(ctx.source, ".env"), "SYM_PROJECT_ROOT=/unused-default\nSYM_CODEX_MODEL=default-model\n")
    File.write!(Path.join(ctx.source, ".env.local"), "SYM_PROJECT_ROOT= ../QuantHub, ../Project Hub, ../alias \nSYM_MAXIMUM_REVIEW_ITERATIONS=7\n")
    before_env = System.get_env()
    assert :ok = SymphonyElixir.Projects.prepare(ctx.source, Workflow.workflow_file_path())
    contexts = SymphonyElixir.Projects.configured()
    assert Enum.map(contexts, & &1.root) == projects
    assert Enum.all?(contexts, &(&1.env["SYM_MAXIMUM_REVIEW_ITERATIONS"] == "7"))
    assert System.get_env() == before_env

    System.put_env("SYM_PROJECT_ROOT", hd(bases))
    assert :ok = SymphonyElixir.Projects.prepare(ctx.source, Workflow.workflow_file_path())
    assert Enum.map(SymphonyElixir.Projects.configured(), & &1.root) == [hd(projects)]
  end

  test "reload applies public settings to new workers and preserves the running worker context", ctx do
    alias SymphonyElixir.ProjectContext
    on_exit(fn -> ProjectContext.bind(nil) end)
    workflow = Workflow.workflow_file_path()
    write_workflow_file!(workflow, tracker_assignee: "$LINEAR_ASSIGNEE")
    project = Path.dirname(ctx.project)
    File.write!(Path.join(ctx.source, ".env"), "SYM_CODEX_MODEL=default-model\nSYM_MAXIMUM_REVIEW_ITERATIONS=3\n")
    File.write!(Path.join(ctx.source, ".env.local"), "SYM_CODEX_MODEL=old-model\n")
    File.write!(Path.join(ctx.project, ".env"), "LINEAR_ASSIGNEE=human@example.invalid\nPUBLIC_HOOK_VALUE=old\n")
    assert {:ok, root_env} = EnvFile.read_root(ctx.source)
    assert {:ok, old} = ProjectContext.load(project, workflow, root_env, ctx.source)
    accepted = ProjectContext.with_context(old, &Config.linear_runtime_env/0)
    File.write!(Path.join(ctx.source, ".env.local"), "SYM_CODEX_MODEL=new-model\nSYM_MAXIMUM_REVIEW_ITERATIONS=7\n")
    File.write!(Path.join(ctx.project, ".env.local"), "PUBLIC_HOOK_VALUE=new\nSYM_MAXIMUM_REVIEW_ITERATIONS=99\n")
    File.write!(workflow, "\nReloaded prompt.\n", [:append])
    updated = ProjectContext.refresh(old)
    assert updated.env["SYM_CODEX_MODEL"] == "new-model"
    assert updated.env["PUBLIC_HOOK_VALUE"] == "new"
    assert updated.workflow.prompt =~ "Reloaded prompt."
    assert ProjectContext.with_context(updated, fn -> Config.maximum_review_iterations!(ctx.source) end) == 7
    assert old.env["SYM_CODEX_MODEL"] == "old-model"
    refute old.workflow.prompt =~ "Reloaded prompt."

    File.rm!(Path.join(ctx.source, ".env.local"))
    File.rm!(Path.join(ctx.project, ".env.local"))
    reverted = ProjectContext.refresh(updated)
    assert reverted.env["SYM_CODEX_MODEL"] == "default-model"
    assert reverted.env["PUBLIC_HOOK_VALUE"] == "old"
    File.write!(Path.join(ctx.source, ".env.local"), "SYM_CODEX_MODEL=\"broken\n")
    assert ProjectContext.refresh(reverted) == reverted
    File.write!(Path.join(ctx.source, ".env.local"), "SYM_MAXIMUM_REVIEW_ITERATIONS=invalid\n")
    assert ProjectContext.refresh(reverted) == reverted
    File.rm!(Path.join(ctx.source, ".env.local"))
    File.write!(Path.join(ctx.project, ".env.local"), "LINEAR_ASSIGNEE=another@example.invalid\n")
    assert ProjectContext.refresh(reverted) == reverted

    # A helper launched after the edits still receives the worker's accepted
    # public configuration, including its workflow and identity.
    System.put_env(accepted)
    System.put_env("SYMPHONY_WORKFLOW_FILE", workflow)
    assert :ok = EnvFile.load_runtime(ctx.project)
    assert ProjectContext.current().workflow == old.workflow
    assert ProjectContext.current().env == old.env
    assert Config.settings!().tracker == old.settings.tracker
    ProjectContext.bind(nil)

    System.put_env("SYMPHONY_LINEAR_BINDING_HASH", "different-binding")
    assert {:error, :invalid_project_context} = EnvFile.load_runtime(ctx.project)
    assert ProjectContext.current() == nil

    for invalid <- ["bad", Base.url_encode64("invalid compressed data"), Base.url_encode64(:zlib.compress("{}"))] do
      System.put_env("SYMPHONY_PROJECT_CONTEXT", invalid)
      assert {:error, :invalid_project_context} = EnvFile.load_runtime(ctx.project)
      assert ProjectContext.current() == nil
    end
  end

  test "non-auth children cannot regain project secret access by reloading config", ctx do
    File.write!(Path.join(ctx.source, ".env.local"), "LINEAR_APP_SECRET=synthetic-secret\n")
    System.put_env("SYMPHONY_LINEAR_SECRET_ACCESS", "denied")
    assert {:error, :linear_secret_access_denied} = EnvFile.linear_secret("LINEAR_APP_SECRET")
    File.write!(Path.join(ctx.project, ".env.local"), "SYMPHONY_LINEAR_SECRET_ACCESS=allowed\nSYMPHONY_ROOT_DIR=#{ctx.project}\n")
    assert {:error, :linear_runtime_binding_changed} = EnvFile.load_runtime(ctx.project)
    assert System.get_env("SYMPHONY_ROOT_DIR") == ctx.source
    assert {:error, :linear_secret_access_denied} = EnvFile.linear_secret("LINEAR_APP_SECRET")
    assert :ok = SymphonyElixir.HookRunner.run_local(~s|test "$SYMPHONY_LINEAR_SECRET_ACCESS" = denied && test -z "${LINEAR_APP_SECRET+x}"|, ctx.source, "synthetic-root")
  end

  test "runtime boot preserves its project binding and public loaders do not parse secrets", ctx do
    File.write!(Path.join(ctx.project, ".env.local"), "LINEAR_APP_SECRET=\"unterminated\rLINEAR_PROJECT_SLUG=synthetic-project\r\n")
    assert :ok = EnvFile.load_runtime(ctx.project)
    assert System.get_env("LINEAR_PROJECT_SLUG") == "synthetic-project"
    assert {:error, :linear_secret_source_unavailable} = EnvFile.linear_secret("LINEAR_APP_SECRET")
    System.put_env("SYMPHONY_LINEAR_AUTH_MODE", "app")
    assert {:error, :linear_runtime_binding_changed} = EnvFile.load_runtime(Path.join(ctx.root, "other/.symphony"))
    assert EnvFile.bound_config_dir() == ctx.project
  end

  test "app worktree hooks preserve nonsecret test scope and assignee without copying secrets", ctx do
    project = Path.dirname(ctx.project)
    worker = Path.join(ctx.root, "worker")
    File.mkdir!(worker)
    project_config = "LINEAR_APP_SECRET=synthetic-never-copy\nLINEAR_TEST_PROJECT_SLUG=synthetic-test\nLINEAR_ASSIGNEE=human@example.invalid\n"
    File.write!(Path.join(ctx.project, ".env.local"), project_config)
    File.write!(Path.join(project, ".env.local"), "SYM_CODEX_MODEL=synthetic-model\nOTHER_SECRET=synthetic-never-copy\n")
    workflow = Path.join(ctx.root, "app.md")
    File.write!(workflow, "---\ntracker:\n  auth_mode: app\n---\nSynthetic workflow\n")
    Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    Workflow.set_workflow_file_path(workflow)
    Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
    script = Path.expand("../../.symphony/on_create_worktree.py", __DIR__)
    command = ~s|test "$SYMPHONY_LINEAR_AUTH_MODE" = app && "#{System.find_executable("python3")}" "#{script}" "#{project}" "#{worker}"|
    assert :ok = SymphonyElixir.HookRunner.run_local(command, worker, "synthetic-after-create")
    worker_config = File.read!(Path.join(worker, ".symphony/.env.local"))
    assert worker_config =~ ~s(LINEAR_PROJECT_SLUG="synthetic-test")
    assert worker_config =~ ~s(LINEAR_ASSIGNEE="human@example.invalid")
    refute worker_config =~ "synthetic-never-copy"
    refute worker_config =~ "LINEAR_APP_SECRET"
    assert File.read!(Path.join(worker, ".env.local")) == ~s(SYM_CODEX_MODEL="synthetic-model"\n)
    assert File.read!(Path.join(ctx.project, ".env.local")) == project_config

    File.write!(Path.join(worker, ".symphony/.env.local"), "operator-prepared-synthetic-file\n")
    File.write!(Path.join(worker, ".env.local"), "operator-prepared-model-config\n")
    assert :ok = SymphonyElixir.HookRunner.run_local(command, worker, "synthetic-after-create-repeat")
    assert File.read!(Path.join(worker, ".symphony/.env.local")) == "operator-prepared-synthetic-file\n"
    assert File.read!(Path.join(worker, ".env.local")) == "operator-prepared-model-config\n"
  end

  test "the shared workflow resolves every app binding and human assignee from the project", ctx do
    File.write!(
      Path.join(ctx.project, ".env"),
      "LINEAR_APP_CLIENT_ID=client\nLINEAR_APP_WORKSPACE_ID=workspace\nLINEAR_APP_USER_ID=app\nLINEAR_APP_INSTALLATION_ID=synthetic\nLINEAR_APP_SECRET=synthetic-secret\n"
    )

    {:ok, workflow} = Workflow.load(Path.expand("../../WORKFLOW.md", __DIR__))

    for assignee <- ["human@example.invalid", "00000000-0000-4000-8000-000000000001"] do
      File.write!(Path.join(ctx.project, ".env.local"), "LINEAR_PROJECT_SLUG=selected-project\nLINEAR_ASSIGNEE=#{assignee}\n")
      assert :ok = EnvFile.load_runtime(ctx.project)
      assert {:ok, settings} = Schema.parse(workflow.config)
      assert settings.tracker.auth_mode == "app"
      assert settings.tracker.app["client_id"] == "client"
      assert settings.tracker.app["client_secret_env"] == "LINEAR_APP_SECRET"
      assert settings.tracker.assignee == assignee
      assert settings.tracker.project_slug == "selected-project"
      assert :ok = AppAuth.validate(settings.tracker)
      refute inspect(settings) =~ "synthetic-secret"
    end

    assert {:error, _} = Schema.parse(%{"tracker" => %{"auth_mode" => "legacy"}})

    issue_ids = ["00000000-0000-4000-8000-000000000002"]
    scoped_workflow = put_in(workflow.config, ["tracker", "app", "allowed_issue_ids"], issue_ids)
    assert {:ok, scoped} = Schema.parse(scoped_workflow)
    assert scoped.tracker.app["allowed_issue_ids"] == issue_ids
    assert :ok = AppAuth.validate(scoped.tracker)
    assert scoped.tracker.app["state_root"] == Path.join(ctx.project, "state")

    System.put_env("LINEAR_APP_STATE_ROOT", "/synthetic-unwanted-override")
    configured = put_in(scoped_workflow, ["tracker", "app", "state_root"], "/synthetic-unwanted-override")
    assert {:ok, fixed} = Schema.parse(configured)
    assert fixed.tracker.app["state_root"] == Path.join(ctx.project, "state")
  end

  test "parallel project CWDs share a Symphony root but keep workspace, auth, journal and sessions separate", ctx do
    assert_parallel_projects(ctx, fn name -> name end)
  end

  test "two project copies use the same project installation ID with independent local state and tokens", ctx do
    assert_parallel_projects(ctx, fn _name -> "shared" end)
  end

  defp assert_parallel_projects(ctx, binding_name) do
    File.write!(Path.join(ctx.source, ".env.local"), "SYM_CODEX_MODEL=shared-model\nLINEAR_APP_CLIENT_ID=wrong-global\n")
    File.cp!(Path.expand("../../WORKFLOW.md", __DIR__), Path.join(ctx.source, "WORKFLOW.md"))
    File.mkdir_p!(Path.join(ctx.source, "priv/linear_app"))

    for helper <- ["issue_lease.py", "state_lock.py"] do
      File.cp!(Path.expand("../../priv/linear_app/#{helper}", __DIR__), Path.join(ctx.source, "priv/linear_app/#{helper}"))
    end

    File.mkdir_p!(Path.join(ctx.source, ".symphony"))
    File.write!(Path.join(ctx.source, ".symphony/.env.local"), "LINEAR_APP_SECRET=wrong-release\nLINEAR_APP_CLIENT_ID=wrong-release\n")
    code_paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])
    probe = Path.expand("../support/linear_app/parallel_project_helper.exs", __DIR__)
    barrier = Path.join(ctx.root, "barrier")
    File.mkdir!(barrier)

    tasks =
      for name <- ["one", "two"] do
        identity = binding_name.(name)
        project = Path.join(ctx.root, name)
        File.mkdir_p!(EnvFile.config_dir(project))

        File.write!(
          Path.join(EnvFile.config_dir(project), ".env.local"),
          "LINEAR_APP_CLIENT_ID=#{identity}\nLINEAR_APP_WORKSPACE_ID=workspace-#{identity}\nLINEAR_APP_USER_ID=app-#{identity}\nLINEAR_APP_INSTALLATION_ID=symphony\nLINEAR_APP_SECRET=synthetic-#{identity}\nLINEAR_ASSIGNEE=#{name}@example.invalid\nLINEAR_PROJECT_SLUG=project-#{identity}\nLINEAR_TEAM_KEY=\n"
        )

        env = [
          {"LINEAR_RELAY_URL", "https://relay.example"},
          {"SYMPHONY_ROOT_DIR", ctx.source},
          {"SYMPHONY_WORKFLOW_FILE", Path.join(ctx.source, "WORKFLOW.md")},
          {"PROBE_BARRIER", barrier},
          {"PROBE_INSTANCE", name},
          {"SYMPHONY_LINEAR_ENV_DIR", nil}
        ]

        Task.async(fn -> System.cmd(System.find_executable("elixir"), code_paths ++ [probe], cd: project, env: env, stderr_to_stdout: true) end)
      end

    assert :ok =
             Enum.reduce_while(1..400, nil, fn _, _ ->
               if Enum.all?(["one", "two"], &File.exists?(Path.join(barrier, &1))),
                 do: {:halt, :ok},
                 else:
                   (
                     Process.sleep(25)
                     {:cont, nil}
                   )
             end)

    assert Enum.all?(["one", "two"], &File.exists?(Path.join(barrier, &1)))
    File.write!(Path.join(barrier, "go"), "go")

    results =
      Enum.map(tasks, fn task ->
        assert {output, 0} = Task.await(task, 20_000)
        refute output =~ "synthetic-token"
        refute output =~ "synthetic-one"
        output |> String.trim() |> Jason.decode!()
      end)

    assert Enum.map(results, & &1["workspace"]) == Enum.map(["one", "two"], &("workspace-" <> binding_name.(&1)))
    assert Enum.map(results, & &1["project"]) == Enum.map(["one", "two"], &("project-" <> binding_name.(&1)))
    assert Enum.map(results, & &1["assignee"]) == ["one@example.invalid", "two@example.invalid"]
    assert length(Enum.uniq_by(results, & &1["hash"])) == 2
    assert Enum.map(results, & &1["session"]) == Enum.map(["one", "two"], &Path.join([ctx.root, &1, ".symphony/state/codex/symphony"]))

    for name <- ["one", "two"] do
      [intent] = Path.wildcard(Path.join([ctx.root, name, ".symphony/state/comments/*.intent.json"]))
      record = intent |> File.read!() |> Jason.decode!()
      assert record["workspace_id"] == "workspace-#{binding_name.(name)}"
      assert record["author_id"] == "app-#{binding_name.(name)}"
      assert record["installation_id"] == "symphony"
    end
  end
end
