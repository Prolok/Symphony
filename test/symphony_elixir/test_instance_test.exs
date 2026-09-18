defmodule SymphonyElixir.TestInstanceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ProjectContext, ServiceMutex, TestInstance, TestInstanceGuard}
  alias SymphonyElixir.Relay.Store

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    keys = [:test_instance, :test_instance_owner, :test_instance_state_root, :project_contexts, :log_file]
    previous = Map.new(keys, &{&1, Application.get_env(:symphony_elixir, &1)})
    path = System.get_env("PATH")
    Application.put_env(:symphony_elixir, :test_instance_state_root, Path.join(root, "state"))

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value == nil,
          do: Application.delete_env(:symphony_elixir, key),
          else: Application.put_env(:symphony_elixir, key, value)
      end)

      System.delete_env("SYMPHONY_SERVICE_OWNER_PID")
      System.delete_env("SYMPHONY_SERVICE_LOCK_MODE")
      System.delete_env("SYMPHONY_TEST_RUN_STAGE")
      System.delete_env("SYMPHONY_TEST_RUN_PLAN")
      restore_env("PATH", path)
      Application.delete_env(:symphony_elixir, :linear_client_request_fun)
    end)

    source = %{
      "checkout" => Path.join(root, "code"),
      "sha" => String.duplicate("a", 40),
      "source_sha256" => String.duplicate("b", 64),
      "dirty" => false
    }

    instance = %{
      "name" => "dev",
      "source" => source,
      "manifest" => %{
        "project_root" => Path.join(root, "fixtures"),
        "workspace_root" => Path.join(root, "worktrees"),
        "projects" => %{}
      }
    }

    {:ok, root: root, instance: instance}
  end

  test "name is parsed before either service mutex and invalid forms fail closed" do
    assert {:ok, nil} = TestInstance.name(["--port", "4001"])
    assert {:ok, "dev"} = TestInstance.name(["--port", "4001", "--test-instance=dev"])

    for args <- [["--test-instance"], ["--test-instance", "../main"], ["--test-instance", "a", "--test-instance", "b"]] do
      assert {:error, _} = TestInstance.name(args)
    end

    assert :ok = TestInstance.configure([])
    assert {:error, _} = TestInstance.configure(["--test-instance"])
    assert {:error, _} = TestInstance.configure(["--test-instance", "a", "--test-instance", "b"])
    assert {:error, _} = TestInstance.configure(["--test-instance", "a", "--port", "4001"])

    for args <- [
          ["--test-instance", "../main"],
          ["--test-instance", "a"],
          ["--test-instance", "a", "--port", "0"],
          ["--test-instance", "a", "--logs-root", "/tmp", "--port", "4001"]
        ] do
      assert {:error, _} = TestInstance.configure(args)
    end
  end

  test "configured source must equal the executable and all output paths must be disjoint", %{
    instance: instance,
    root: root
  } do
    args = ["--test-instance", "dev", "--port", "4101"]
    deps = %{compiled_source: instance["source"], preflight: fn "dev", _ -> {Jason.encode!(instance), 0} end}
    assert :ok = TestInstance.configure(args, deps)
    assert Config.test_instance() == instance
    assert Application.fetch_env!(:symphony_elixir, :test_instance_owner) == self()
    assert Application.fetch_env!(:symphony_elixir, :log_file) == Path.join(root, "state/runs/dev/log/symphony.log")
    assert {:error, _} = TestInstance.configure(args, %{deps | compiled_source: %{}})
    assert {:error, _} = TestInstance.configure(args, %{deps | preflight: fn _, _ -> {"invalid-json", 0} end})
    assert {:error, _} = TestInstance.configure(args, %{deps | preflight: fn _, _ -> {"denied", 1} end})

    for target <- [
          "relative",
          instance["source"]["checkout"],
          instance["manifest"]["project_root"],
          Path.join(root, "state/workspaces")
        ] do
      rejected = put_in(instance["manifest"]["workspace_root"], target)

      assert {:error, _} =
               TestInstance.configure(args, %{deps | preflight: fn _, _ -> {Jason.encode!(rejected), 0} end})
    end

    rejected =
      put_in(instance["manifest"]["main_instance"], %{
        "projects" => [%{"root" => Path.join(root, "state/projects"), "workspace_root" => Path.join(root, "elsewhere")}]
      })

    assert {:error, _} = TestInstance.configure(args, %{deps | preflight: fn _, _ -> {Jason.encode!(rejected), 0} end})

    File.mkdir_p!(Path.join(root, "real"))
    File.ln_s!(Path.join(root, "real"), Path.join(root, "alias"))
    rejected = put_in(instance["manifest"]["workspace_root"], Path.join(root, "alias"))
    assert {:error, _} = TestInstance.configure(args, %{deps | preflight: fn _, _ -> {Jason.encode!(rejected), 0} end})
  end

  test "project context carries isolation into helpers while relay identity and production state stay separate", %{
    root: root,
    instance: instance
  } do
    config_dir = Path.join(root, "fixtures/symphony-test/.symphony")
    assert TestInstance.context_env(root) == %{}
    assert TestInstance.project_state_root(config_dir) == Path.join(config_dir, "state")
    assert :ok = TestInstance.validate_contexts([])
    production = Config.relay_state_root()
    relay = %{"state_root" => production, "consumer_id" => nil}
    assert {:ok, production_id} = Store.identity(relay, "test-workspace")
    before = snapshot(production)

    Application.put_env(:symphony_elixir, :test_instance, instance)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: "$SYMPHONY_PROJECT_WORKTREES_ROOT")
    File.mkdir_p!(config_dir)
    File.write!(Path.join(config_dir, ".env"), "LINEAR_ASSIGNEE=dev@example.com\n")
    assert {:ok, context} = ProjectContext.load(Path.dirname(config_dir), Workflow.workflow_file_path(), %{})
    assert context.settings.workspace.root == Path.join(root, "worktrees/symphony-test")
    assert context.settings.tracker.app["env_dir"] == config_dir
    assert context.settings.tracker.app["state_root"] == Path.join(root, "state/projects/symphony-test")
    rate_root = Config.linear_rate_limit_root()

    ProjectContext.with_context(context, fn ->
      assert Config.test_instance() == instance
      assert Config.relay_state_root() == Path.join(root, "state/relay")
      assert {:ok, test_id} = Store.identity(%{relay | "state_root" => Config.relay_state_root()}, "test-workspace")
      refute test_id == production_id
      assert {:ok, ^test_id} = Store.identity(%{relay | "state_root" => Config.relay_state_root()}, "test-workspace")
      assert Config.linear_rate_limit_root() == rate_root
      assert context.settings.tracker.app["installation_id"] == "symphony"
      encoded = ProjectContext.runtime_env()["SYMPHONY_PROJECT_CONTEXT"]
      previous = System.get_env("SYMPHONY_WORKFLOW_FILE")
      System.put_env("SYMPHONY_WORKFLOW_FILE", context.workflow_path)
      assert :ok = ProjectContext.restore(encoded, config_dir)
      assert Config.test_instance() == instance
      assert Config.settings!().tracker.app["state_root"] == context.settings.tracker.app["state_root"]
      restore_env("SYMPHONY_WORKFLOW_FILE", previous)
    end)

    assert snapshot(production) == before
  end

  test "authenticated binding, consumer overrides and foreign scopes are rejected before execution", %{
    root: root,
    instance: instance
  } do
    expected = %{
      "workspace_id" => "synthetic-workspace",
      "project_id" => "project-id",
      "slug_id" => "project",
      "workspace" => "prolok",
      "teams" => [%{"id" => "pro-id", "key" => "PRO"}]
    }

    instance = put_in(instance["manifest"]["projects"], %{"symphony-test" => expected})
    Application.put_env(:symphony_elixir, :test_instance, instance)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: "$SYMPHONY_PROJECT_WORKTREES_ROOT")
    project = Path.join(root, "fixtures/symphony-test")
    File.mkdir_p!(Path.join(project, ".symphony"))
    File.write!(Path.join(project, ".symphony/.env"), "LINEAR_ASSIGNEE=dev@example.com\n")
    {:ok, context} = ProjectContext.load(project, Workflow.workflow_file_path(), %{})

    context =
      put_in(context.settings.tracker.relay, %{"state_root" => Path.join(root, "state/relay"), "consumer_id" => nil})

    response = %{
      "project" => %{"id" => "project-id", "name" => "symphony-test", "slugId" => "project", "teams" => %{"nodes" => expected["teams"], "pageInfo" => %{"hasNextPage" => false}}},
      "viewer" => %{"organization" => %{"id" => "synthetic-workspace", "urlKey" => "prolok"}}
    }

    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> {:ok, %{status: 200, body: %{"data" => response}}} end)
    assert :ok = TestInstance.validate_contexts([context])
    assert {:error, :unexpected_test_projects} = TestInstance.validate_contexts([])

    for teams <- [
          nil,
          %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}},
          %{"nodes" => expected["teams"], "pageInfo" => %{"hasNextPage" => true}},
          %{"nodes" => [%{"id" => "qai-id", "key" => "QAI"}], "pageInfo" => %{"hasNextPage" => false}}
        ] do
      SymphonyElixir.TestSupport.stub_linear_client(fn _, _ ->
        {:ok, %{status: 200, body: %{"data" => put_in(response["project"]["teams"], teams)}}}
      end)

      assert {:error, _} = TestInstance.validate_contexts([context])
    end

    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> {:ok, %{status: 200, body: %{"data" => response}}} end)

    for rejected <- [
          put_in(context.settings.tracker.project_slug, "productive"),
          put_in(context.settings.tracker.team_key, "PRO"),
          put_in(context.settings.tracker.relay["consumer_id"], "production"),
          put_in(context.settings.tracker.relay["state_root"], "/production"),
          put_in(context.settings.workspace.root, "/outside")
        ] do
      assert {:error, {:test_project_binding_rejected, "symphony-test"}} = TestInstance.validate_contexts([rejected])
    end

    for path <- [
          context.settings.workspace.root,
          context.settings.tracker.app["state_root"],
          context.settings.tracker.relay["state_root"]
        ] do
      target = path <> "-original"
      File.mkdir_p!(path)
      File.rename!(path, target)
      File.ln_s!(target, path)
      assert {:error, {:test_project_binding_rejected, _}} = TestInstance.validate_contexts([context])
      File.rm!(path)
      File.rename!(target, path)
    end

    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ ->
      {:ok, %{status: 200, body: %{"data" => put_in(response["project"]["id"], "foreign")}}}
    end)

    assert {:error, {:test_project_binding_rejected, _}} = TestInstance.validate_contexts([context])
    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> {:error, :offline} end)
    assert {:error, _} = TestInstance.validate_contexts([context])
    Application.put_env(:symphony_elixir, :project_contexts, [context])
    assert [%{project_id: "project-id", state_root: state}] = TestInstance.public_info().bindings
    assert state == context.settings.tracker.app["state_root"]
  end

  test "full dummy project slugs match canonical manifest and API bindings", %{root: root, instance: instance} do
    for {name, slug, workspace, team} <- [
          {"symphony-test", "7d8cc05658e6", "prolok", "PRO"}
        ] do
      expected = %{
        "workspace_id" => "synthetic-workspace",
        "project_id" => "project-id",
        "slug_id" => slug,
        "workspace" => workspace,
        "teams" => [%{"id" => "team-id", "key" => team}]
      }

      instance = put_in(instance["manifest"]["projects"], %{name => expected})
      Application.put_env(:symphony_elixir, :test_instance, instance)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: name <> "-" <> slug,
        workspace_root: "$SYMPHONY_PROJECT_WORKTREES_ROOT"
      )

      project = Path.join(root, "fixtures/" <> name)
      File.mkdir_p!(Path.join(project, ".symphony"))
      File.write!(Path.join(project, ".symphony/.env"), "LINEAR_ASSIGNEE=dev@example.com\n")
      assert {:ok, context} = ProjectContext.load(project, Workflow.workflow_file_path(), %{})

      context =
        put_in(context.settings.tracker.relay, %{"state_root" => Path.join(root, "state/relay"), "consumer_id" => nil})

      response = %{
        "project" => %{
          "id" => expected["project_id"],
          "name" => name,
          "slugId" => slug,
          "teams" => %{"nodes" => expected["teams"], "pageInfo" => %{"hasNextPage" => false}}
        },
        "viewer" => %{"organization" => %{"id" => expected["workspace_id"], "urlKey" => workspace}}
      }

      SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> {:ok, %{status: 200, body: %{"data" => response}}} end)
      assert :ok = TestInstance.validate_contexts([context])
      assert :ok = TestInstance.validate_contexts([put_in(context.settings.tracker.project_slug, slug)])

      for rejected <- [
            put_in(context.settings.tracker.project_slug, name <> "-ffffffffffff"),
            put_in(context.settings.tracker.team_key, team),
            put_in(context.settings.tracker.relay["consumer_id"], "production")
          ] do
        assert {:error, _} = TestInstance.validate_contexts([rejected])
      end

      SymphonyElixir.TestSupport.stub_linear_client(fn _, _ ->
        {:ok, %{status: 200, body: %{"data" => put_in(response["project"]["slugId"], "ffffffffffff")}}}
      end)

      assert {:error, {:test_project_binding_rejected, ^name}} = TestInstance.validate_contexts([context])
    end
  end

  test "guard reports changed source or process evidence to its own CLI owner", %{root: root, instance: instance} do
    instance = put_in(instance["source"]["checkout"], root)
    File.mkdir_p!(Path.join(root, "scripts"))
    script = Path.join(root, "scripts/test-instance.py")
    File.write!(script, "print(" <> inspect(Jason.encode!(instance)) <> ")\n")
    Application.put_env(:symphony_elixir, :test_instance, instance)
    Application.put_env(:symphony_elixir, :test_instance_owner, self())
    guard = start_supervised!(TestInstanceGuard)
    send(guard, :verify)
    :sys.get_state(guard)
    refute_received :test_instance_invalid
    File.write!(script, "print('{}')\n")
    send(guard, :verify)
    assert_receive :test_instance_invalid, 2_000
    File.write!(script, "raise SystemExit(1)\n")
    send(guard, :verify)
    assert_receive :test_instance_invalid, 2_000
  end

  test "test ownership bypass requires the matching reservation mode" do
    System.put_env("SYMPHONY_SERVICE_OWNER_PID", System.pid())
    System.put_env("SYMPHONY_SERVICE_LOCK_MODE", "dev")
    assert :ok = ServiceMutex.acquire("dev")
  end

  test "project reservations propagate success, contention, dead helpers and timeout", %{root: root} do
    python = System.find_executable("python3")
    helper = Path.join([File.cwd!(), "scripts", "service-scopes.py"])
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    shim = Path.join(bin, "python3")

    File.write!(shim, """
    #!#{python}
    import importlib.util,pathlib,sys,json
    spec=importlib.util.spec_from_file_location('scopes',#{inspect(helper)})
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    try:
        handles=module.reserve(json.loads(sys.stdin.readline()),pathlib.Path(#{inspect(Path.join(root, "locks"))}))
        print('locked',flush=True);sys.stdin.read()
    except BlockingIOError:
        print('busy',flush=True);sys.exit(1)
    """)

    File.chmod!(shim, 0o755)
    project = Path.join(root, "Project")
    File.mkdir_p!(Path.join(project, ".symphony"))
    File.write!(Path.join(project, ".symphony/.env"), "LINEAR_ASSIGNEE=dev@example.com\n")
    {:ok, context} = ProjectContext.load(project, Workflow.workflow_file_path(), %{})

    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "viewer" => %{"organization" => %{"id" => context.settings.tracker.app["workspace_id"]}},
             "projects" => %{
               "nodes" => [
                 %{
                   "id" => "project-id",
                   "slugId" => context.settings.tracker.project_slug,
                   "teams" => %{"nodes" => [%{"id" => "pro-id", "key" => "PRO"}], "pageInfo" => %{"hasNextPage" => false}}
                 }
               ],
               "pageInfo" => %{"hasNextPage" => false}
             }
           }
         }
       }}
    end)

    System.put_env("PATH", bin)
    assert :ok = ServiceMutex.reserve_projects([context])
    port = Process.get({ServiceMutex, :scopes})
    assert {:error, _} = Task.async(fn -> ServiceMutex.reserve_projects([context]) end) |> Task.await()
    Port.close(port)
    File.write!(shim, "#!/bin/sh\nread line\nexit 7\n")
    assert {:error, "Projektreservierung fehlgeschlagen"} = ServiceMutex.reserve_projects([context])
    File.write!(shim, "#!/bin/sh\nread line\nexec /bin/sleep 6\n")
    assert {:error, "Projektreservierung antwortet nicht"} = ServiceMutex.reserve_projects([context])
    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> {:error, :offline} end)
    assert {:error, "Projekt-/Teambindung konnte nicht frisch und vollständig verifiziert werden"} = ServiceMutex.reserve_projects([context])
  end

  defp snapshot(root) do
    Path.wildcard(Path.join(root, "**/*")) |> Enum.filter(&File.regular?/1) |> Map.new(&{&1, File.read!(&1)})
  end
end
