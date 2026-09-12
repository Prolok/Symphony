defmodule SymphonyElixir.ProjectFailuresTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{EnvFile, ProjectContext, ProjectPoller, Projects, ProjectSelection, ServiceMutex}
  alias SymphonyElixir.Linear.{Assignees, CommentJournal, LocalState}

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    previous_contexts = Application.get_env(:symphony_elixir, :project_contexts)
    previous_settings = Application.get_env(:symphony_elixir, :service_settings)
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_application(:project_contexts, previous_contexts)
      restore_application(:service_settings, previous_settings)
      restore_env("PATH", previous_path)
      System.delete_env("SYM_PROJECT_ROOT")
      System.delete_env("SYMPHONY_SERVICE_OWNER_PID")
      Application.delete_env(:symphony_elixir, :linear_client_request_fun)
    end)

    {:ok, root: root}
  end

  test "preparation rejects missing roots and invalid projects, then binds every valid project", %{root: root} do
    workflow = Workflow.workflow_file_path()
    System.put_env("SYM_PROJECT_ROOT", root)
    assert {:error, :no_symphony_projects_found} = Projects.prepare(root, workflow)
    project = Path.join(root, "Project")
    env_dir = Path.join(project, ".symphony")
    File.mkdir_p!(env_dir)
    File.mkdir_p!(Path.join(env_dir, ".env"))
    error = Projects.prepare(root, workflow)
    assert {:error, {:invalid_project, ^project, {:env_file_read_failed, _, :eisdir}}} = error
    File.rmdir!(Path.join(env_dir, ".env"))
    File.write!(Path.join(env_dir, ".env"), "LINEAR_ASSIGNEE=dev@example.com\n")
    assert :ok = Projects.prepare(root, workflow)
    [context] = Projects.configured()
    assert context.root == project
    assert :ok = SymphonyElixir.Application.startup_preflight()
    invalid = put_in(context.settings.tracker.app["client_id"], nil)
    Application.put_env(:symphony_elixir, :project_contexts, [invalid])
    assert {:error, _} = SymphonyElixir.Application.startup_preflight()

    SymphonyElixir.TestSupport.stub_linear_client(fn _payload, _headers ->
      node = %{"id" => "fixture", "identifier" => "PRO-1", "project" => %{"slugId" => context.settings.tracker.project_slug}}
      {:ok, %{status: 200, body: %{"data" => %{"issues" => %{"nodes" => [node]}}}}}
    end)

    selection = ProjectSelection.command_selection(root, workflow, "PRO-1", project)
    assert {:ok, %{project_root: ^project, identifier: "PRO-1"}} = selection
    assert {:error, {:issue_not_found_in_projects, "PRO-1"}} = ProjectSelection.resolve("PRO-1", [])
    System.put_env("SYM_PROJECT_ROOT", Path.join(root, "missing"))
    assert {:error, {:project_root_unavailable, _, :enoent}} = Projects.prepare(root, workflow)
  end

  test "preparation refuses colliding workspace roots before publishing contexts", %{root: root} do
    System.put_env("SYM_PROJECT_ROOT", root)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "$LINEAR_PROJECT_SLUG")

    for name <- ["One", "Two"] do
      File.mkdir_p!(Path.join([root, name, ".symphony"]))
      File.write!(Path.join([root, name, ".symphony/.env"]), "LINEAR_ASSIGNEE=dev@example.com\nLINEAR_PROJECT_SLUG=#{name}\n")
    end

    previous = Projects.configured()
    result = Projects.prepare(root, Workflow.workflow_file_path())
    assert {:error, {:overlapping_project_worktree_roots, _, _, _, _}} = result
    assert Projects.configured() == previous

    contexts =
      for name <- ["One", "Two"] do
        {:ok, context} = ProjectContext.load(Path.join(root, name), Workflow.workflow_file_path(), %{})
        context
      end

    assert :ok = Client.validate_workspace_bindings(contexts)
    [one, two] = contexts
    assert one.settings.workspace.root == two.settings.workspace.root
    shared = Path.join(root, "shared")
    File.mkdir_p!(shared)
    alias_path = Path.join(root, "shared-link")
    File.ln_s!(shared, alias_path)
    one = put_in(one.settings.workspace.root, shared)

    for other <- [shared, alias_path, Path.join(shared, "PRO-1"), root] do
      two = put_in(two.settings.workspace.root, other)
      assert {:error, {:overlapping_project_worktree_roots, _, _, _, _}} = Projects.validate_workspace_roots([one, two])
    end

    two = put_in(two.settings.workspace.root, shared <> "-other")
    assert :ok = Projects.validate_workspace_roots([one, two])
    cycle = Path.join(root, "cycle-root")
    File.ln_s!(cycle, cycle)
    two = put_in(two.settings.workspace.root, cycle)
    assert {:error, {:path_canonicalize_failed, _, :eloop}} = Projects.validate_workspace_roots([one, two])
  end

  test "discovery, public config and journals fail visibly without modifying bad state", %{root: root} do
    cycle = Path.join(root, "cycle")
    File.ln_s!(cycle, cycle)
    assert {:error, _} = ProjectContext.discover(cycle, root)
    workflow = Workflow.workflow_file_path()
    assert {:error, {:project_root_unavailable, _, :enotdir}} = ProjectContext.discover(workflow, root)
    env_root = Path.join(root, "env")
    File.mkdir_p!(env_root)
    File.write!(Path.join(env_root, ".env"), "SECRET_NAME=PRIVATE_TOKEN\nPRIVATE_TOKEN=unparsed='\nPUBLIC=visible\n")
    assert {:ok, %{"PUBLIC" => "visible"} = values} = EnvFile.read_public(env_root, "$SECRET_NAME")
    refute Map.has_key?(values, "PRIVATE_TOKEN")
    assert {:ok, _} = EnvFile.read_public(root)
    File.write!(Path.join(env_root, ".env"), "SECRET_NAME=\"unterminated\n")
    assert {:error, _} = EnvFile.read_public(env_root, "$SECRET_NAME")
    File.rm!(Path.join(env_root, ".env"))
    File.mkdir_p!(Path.join(env_root, ".env"))
    assert {:error, {:env_file_read_failed, _, :eisdir}} = EnvFile.read_public(env_root)

    binding = %{"state_root" => Path.join(root, "state"), "workspace_id" => "workspace", "installation_id" => "symphony"}
    File.mkdir_p!(binding["state_root"])
    codex = Path.join(binding["state_root"], "codex")
    File.write!(codex, "preserve")
    assert {:error, {:local_state_unavailable, ^codex, :enotdir}} = LocalState.validate(binding)
    File.rm!(codex)
    comments = Path.join(binding["state_root"], "comments")
    File.write!(comments, "preserve")
    assert {:error, {:local_state_unavailable, ^comments, :enotdir}} = LocalState.validate(binding)
    File.rm!(comments)
    File.mkdir_p!(comments)
    intent = Path.join(comments, "bad.intent.json")
    File.write!(intent, "not json")
    assert {:error, {:local_state_unavailable, ^intent, _}} = LocalState.validate(binding)
    File.write!(intent, Jason.encode!(%{"workspace_id" => "workspace", "installation_id" => "old"}))
    payload = %{"query" => "mutation { commentCreate(input:{issueId:\"fixture\",body:\"body\"}) { success } }"}
    request = fn _ -> flunk("write") end
    assert {:error, {:local_state_requires_handoff, _, _}} = CommentJournal.execute(binding, payload, request)
    assert File.read!(intent) =~ "old"

    assert Assignees.filter("b47fc057-4771-4e8e-8f9c-1633e4463068")["or"] == [
             %{"id" => %{"eq" => "b47fc057-4771-4e8e-8f9c-1633e4463068"}}
           ]
  end

  test "service mutex reuses launcher ownership and refuses concurrent direct starts", %{root: root} do
    System.put_env("SYMPHONY_SERVICE_OWNER_PID", System.pid())
    assert :ok = ServiceMutex.acquire()
    System.delete_env("SYMPHONY_SERVICE_OWNER_PID")
    python = System.find_executable("python3")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    shim = Path.join(bin, "python3")
    File.write!(shim, "#!/bin/sh\nHOME='#{root}' exec '#{python}' \"$@\"\n")
    File.chmod!(shim, 0o755)
    System.put_env("PATH", bin)
    assert :ok = ServiceMutex.acquire()
    port = Process.get({ServiceMutex, :port})
    assert {:error, "Symphony läuft bereits"} = Task.async(&ServiceMutex.acquire/0) |> Task.await()
    Port.close(port)
    File.write!(shim, "#!/bin/sh\nexit 7\n")
    assert {:error, "Symphony-Dienstlock konnte nicht erworben werden"} = ServiceMutex.acquire()
    File.write!(shim, "#!/bin/sh\nexec /bin/sleep 6\n")
    assert {:error, "Symphony-Dienstlock antwortet nicht"} = ServiceMutex.acquire()
  end

  test "missing poller and failed assignee verification remain visible", %{root: root} do
    assert %{checking?: true} = ProjectPoller.polling()
    project = Path.join(root, "Project")
    File.mkdir_p!(Path.join(project, ".symphony"))
    File.write!(Path.join(project, ".symphony/.env"), "LINEAR_ASSIGNEE=dev@example.com\n")
    {:ok, context} = ProjectContext.load(project, Workflow.workflow_file_path(), %{})
    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> {:error, :offline} end)
    assert {:stop, {:linear_api_request, :linear_app_request_unavailable}} = ProjectPoller.init(contexts: [context])
  end

  test "full service refreshes one cache, exposes failures and stops only when all projects are idle", %{root: root} do
    project = Path.join(root, "ServiceProject")
    File.mkdir_p!(Path.join(project, ".symphony"))
    File.write!(Path.join(project, ".symphony/.env"), "LINEAR_ASSIGNEE=dev@example.com\n")
    {:ok, context} = ProjectContext.load(project, Workflow.workflow_file_path(), %{})
    settings = context.settings

    settings = %{
      settings
      | polling: %{settings.polling | interval_ms: 60_000, idle_shutdown_ms: 0},
        tracker: %{settings.tracker | terminal_states: []},
        agent: %{settings.agent | max_concurrent_agents: 3}
    }

    context = %{context | settings: settings}
    mode = start_supervised!({Agent, fn -> :ok end})
    parent = self()

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _headers ->
      query = payload[:query] || payload["query"]

      if String.contains?(query, "SymphonyHumanAssignees") do
        user = %{"id" => "human", "email" => "dev@example.com", "app" => false}
        users = %{"nodes" => [user], "pageInfo" => %{"hasNextPage" => false}}
        {:ok, %{status: 200, body: %{"data" => %{"users" => users}}}}
      else
        send(parent, :candidate_poll)

        case Agent.get(mode, & &1) do
          :ok -> {:ok, %{status: 200, body: %{"data" => %{"issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}}}}}
          :offline -> {:error, :offline}
        end
      end
    end)

    :ok = Application.stop(:symphony_elixir)
    Application.put_env(:symphony_elixir, :project_contexts, [context])
    Application.put_env(:symphony_elixir, :service_settings, settings)

    on_exit(fn ->
      Application.stop(:symphony_elixir)
      Application.delete_env(:symphony_elixir, :project_contexts)
      Application.delete_env(:symphony_elixir, :service_settings)
      SymphonyElixir.TestSupport.ensure_application_started()
    end)

    assert {:ok, _} = Application.ensure_all_started(:symphony_elixir)
    assert_receive :candidate_poll, 2_000
    assert {:ok, []} = ProjectPoller.candidates(context)
    poll = :sys.get_state(ProjectPoller)
    send(ProjectPoller, {:poll, make_ref()})
    assert :sys.get_state(ProjectPoller).timer_token == poll.timer_token
    send(ProjectPoller, {:poll, poll.timer_token})
    assert_receive :candidate_poll, 2_000
    assert %{queued: true} = Orchestrator.request_refresh()
    assert_receive :candidate_poll, 2_000
    assert {:ok, []} = ProjectPoller.candidates(context)
    Agent.update(mode, fn _ -> :offline end)
    ProjectPoller.refresh()
    assert_receive :candidate_poll, 2_000
    assert {:error, _} = ProjectPoller.candidates(context)
    Agent.update(mode, fn _ -> :ok end)
    ProjectPoller.refresh()
    assert_receive :candidate_poll, 2_000
    assert {:ok, []} = ProjectPoller.candidates(context)
    assert {:reply, :unavailable, _} = Projects.handle_call(:snapshot, nil, [%{context | id: "missing"}])

    changed =
      context.workflow.config
      |> put_in(["polling", "interval_ms"], 61_000)
      |> put_in(["polling", "idle_shutdown_ms"], 0)
      |> put_in(["agent", "max_concurrent_agents"], 2)
      |> put_in(["observability"], %{"dashboard_enabled" => false, "refresh_ms" => 777, "render_interval_ms" => 888})

    File.write!(context.workflow_path, "---\n" <> Jason.encode!(changed) <> "\n---\nReloaded project prompt\n")
    assert :ok = WorkflowStore.force_reload()
    ProjectPoller.refresh()
    assert {:ok, []} = ProjectPoller.candidates(context)
    refreshed = :sys.get_state(Projects.server(context))
    assert refreshed.poll_interval_ms == 61_000
    assert refreshed.max_concurrent_agents == 2
    assert :sys.get_state(ProjectPoller).interval == 61_000
    [reloaded] = :sys.get_state(ProjectPoller).contexts
    assert reloaded.workflow.prompt == "Reloaded project prompt"
    assert Config.settings!().agent.max_concurrent_agents == 2
    assert Config.settings!().observability.refresh_ms == 777
    assert Config.settings!().observability.render_interval_ms == 888
    refute Config.settings!().observability.dashboard_enabled
    parent = self()

    :sys.replace_state(Projects.server(context), fn state ->
      send(parent, {:worker_context, ProjectContext.current()})
      state
    end)

    assert_receive {:worker_context, ^reloaded}
    assert reloaded.settings.tracker.app == context.settings.tracker.app
    assert context.workflow.prompt != reloaded.workflow.prompt
    invalid = put_in(changed, ["polling", "interval_ms"], -1)
    File.write!(context.workflow_path, "---\n" <> Jason.encode!(invalid) <> "\n---\nInvalid settings\n")
    assert :ok = WorkflowStore.force_reload()
    assert ProjectContext.refresh(reloaded) == reloaded
    File.write!(context.workflow_path, "---\n" <> Jason.encode!(changed) <> "\n---\nReloaded project prompt\n")
    assert :ok = WorkflowStore.force_reload()
    stale_binding = put_in(context.settings.tracker.app["client_id"], "another-client")
    assert ProjectContext.refresh(stale_binding) == stale_binding
    stale_root = put_in(context.settings.workspace.root, Path.join(root, "another-worktree-root"))
    assert ProjectContext.refresh(stale_root) == stale_root
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    File.rm!(context.workflow_path)
    assert ProjectContext.refresh(reloaded) == reloaded
    File.write!(context.workflow_path, "---\n" <> Jason.encode!(changed) <> "\n---\nReloaded project prompt\n")
    assert {:ok, _} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    send(Orchestrator, :check_idle)
    assert is_map(Orchestrator.snapshot())
    server = Projects.server(context)
    set_idle(server, 60_000, 0)
    send(Orchestrator, :check_idle)
    assert is_map(Orchestrator.snapshot())
    supervisor = Process.whereis(SymphonyElixir.Supervisor)
    monitor = Process.monitor(supervisor)
    set_idle(server, 1, 10)
    send(Orchestrator, :check_idle)
    assert_receive {:DOWN, ^monitor, :process, ^supervisor, :shutdown}, 3_000
    assert Process.whereis(SymphonyElixir.ProjectPoller) == nil
    assert ProjectPoller.service_settings() == nil
  end

  defp set_idle(server, timeout, elapsed) do
    :sys.replace_state(server, fn state ->
      last_activity = System.monotonic_time(:millisecond) - elapsed
      %{state | idle_shutdown_ms: timeout, idle_shutdown_ms_override: timeout, last_activity_at_ms: last_activity}
    end)
  end

  defp restore_application(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_application(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
