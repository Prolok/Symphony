defmodule SymphonyElixir.TestExecutorTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.TestTool
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.DurableState
  alias SymphonyElixir.{ProjectContext, RoutineTest, TestExecutor}

  setup ctx do
    if ctx[:long_checkout] do
      original = File.cwd!()
      previous_tmpdir = System.get_env("TMPDIR")
      checkout = Path.join([original, "tmp", "executor-review-#{Ecto.UUID.generate()}", String.duplicate("long-checkout-", 8)])
      tmpdir = Path.join(checkout, "tmpdir")

      on_exit(fn ->
        File.cd!(original)
        restore_env("TMPDIR", previous_tmpdir)
        File.rm_rf!(Path.dirname(checkout))
      end)

      File.mkdir_p!(tmpdir)
      File.cd!(checkout)
      System.put_env("TMPDIR", tmpdir)
    end

    :ok
  end

  setup do
    root = Path.join(File.cwd!(), "tmp/ex-#{System.unique_integer([:positive])}")
    socket_root = SymphonyElixir.TestSupport.routine_socket_root()
    on_exit(fn -> File.rm_rf!(root) end)
    project = Path.join(root, "project")
    workspace = Path.join(root, "worktrees/PRO-769")
    File.mkdir_p!(project)
    git!(project, ["init", "-q"])
    git!(project, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "base"])
    git!(project, ["worktree", "add", "-qb", "symphony/PRO-769", workspace])

    config = %{
      "workspace_id" => "11111111-1111-4111-8111-111111111111",
      "project_id" => "22222222-2222-4222-8222-222222222222",
      "slug_id" => "dummy",
      "teams" => [%{"id" => "44444444-4444-4444-8444-444444444444", "key" => "PRO"}],
      "scenarios" => ["bootstrap", "workflow", "failure-probe"],
      "timeout" => 30,
      "result_root" => Path.join(root, "results")
    }

    settings = Config.settings!()
    settings = put_in(settings.worker.test_executor, config)
    settings = put_in(settings.worker.test_executor_socket, Path.join(socket_root, "e.sock"))
    settings = put_in(settings.workspace.root, Path.join(root, "worktrees"))
    context = %ProjectContext{id: project, root: project, name: "symphony-test", settings: settings}
    {json, 0} = System.cmd("python3", [Path.expand("../../scripts/test-instance.py", __DIR__), "source", workspace])
    source = Jason.decode!(json)

    request = %{
      "operation" => "start",
      "run_id" => "routine-1",
      "scenario" => "bootstrap",
      "head_sha" => source["sha"],
      "source_sha256" => source["source_sha256"],
      "issue_id" => "33333333-3333-4333-8333-333333333333",
      "identifier" => "PRO-769",
      "checkout" => workspace
    }

    %{root: root, context: context, config: config, request: request}
  end

  test "setup is explicit and rejects missing socket, arbitrary scenarios and incomplete bindings", ctx do
    assert TestExecutor.valid_config?(ctx.config)

    for bad <- [
          nil,
          %{},
          Map.put(ctx.config, "scenarios", ["shell"]),
          Map.put(ctx.config, "timeout", 0),
          Map.put(ctx.config, "result_root", "relative"),
          Map.put(ctx.config, "workspace_id", "private"),
          Map.put(ctx.config, "shell", "anything")
        ] do
      refute TestExecutor.valid_config?(bad)
    end

    assert {:error, _} = Schema.parse(%{"worker" => %{"test_executor" => ctx.config}})
    assert {:ok, _} = Schema.parse(%{"worker" => %{"test_executor" => ctx.config, "test_executor_socket" => ctx.context.settings.worker.test_executor_socket}})
    assert :ok = TestExecutor.validate_contexts([])
    assert {:error, :routine_test_setup_invalid} = TestExecutor.validate_contexts([%{ctx.context | name: "foreign"}])
  end

  test "normal supervisor owns a real executor process from socket readiness through result and shutdown", ctx do
    parent = self()

    runner = fn job, contexts, config, _runtime, _owner ->
      send(parent, {:started, self(), job})
      assert contexts == [ctx.context]
      assert config == ctx.config

      receive do
        :finish -> :ok
      end

      RoutineTest.failed(job, "fixture") |> Map.merge(%{"evidence" => "fixture", "status" => "passed", "cleanup" => true, "main_preserved" => true, "originals_preserved" => true})
    end

    pid = start_supervised!({TestExecutor, contexts: [ctx.context], name: __MODULE__.Executor, runner: runner})
    socket = ctx.context.settings.worker.test_executor_socket
    assert {:ok, %{"running" => true}} = TestTool.request(socket, ctx.request)
    assert_receive {:started, task, job}, 5_000
    assert job["request"]["issue_id"] == ctx.request["issue_id"]
    assert {:ok, %{"running" => true}} = TestTool.request(socket, ctx.request)
    refute_receive {:started, _, _}, 100
    send(task, :finish)
    read_result = fn -> TestTool.request(socket, %{ctx.request | "operation" => "result"}) end
    assert eventually(fn -> match?({:ok, %{"status" => "passed", "evidence" => "fixture"}}, read_result.()) end)
    assert Process.alive?(pid)
    :ok = stop_supervised(TestExecutor)
    assert eventually(fn -> not File.exists?(socket) end)
  end

  test "regular setup verifies workspace and complete target binding before executor startup", ctx do
    context = put_in(ctx.context.settings.tracker.app["workspace_id"], ctx.config["workspace_id"]).context
    context = put_in(context.settings.tracker.project_slug, ctx.config["slug_id"])
    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> flunk("unexpected request") end)

    response = %{
      "project" => %{
        "id" => ctx.config["project_id"],
        "slugId" => ctx.config["slug_id"],
        "name" => "symphony-test",
        "teams" => %{"nodes" => ctx.config["teams"], "pageInfo" => %{"hasNextPage" => false}}
      },
      "viewer" => %{"id" => "synthetic-app", "app" => true, "organization" => %{"id" => ctx.config["workspace_id"], "urlKey" => "prolok"}}
    }

    request_fun = fn _, _ -> {:ok, %{status: 200, body: %{"data" => response}}} end
    Application.put_env(:symphony_elixir, :linear_client_request_fun, request_fun)
    assert :ok = TestExecutor.validate_contexts([context])
    other_settings = %{context.settings | worker: %{context.settings.worker | test_executor: nil, test_executor_socket: nil}}
    other = %{context | id: context.id <> "-tilor", root: context.root <> "-tilor", name: "tilor-project", settings: other_settings}
    assert :ok = TestExecutor.validate_contexts([other, context])
    wrong = put_in(context.settings.tracker.project_slug, "foreign")
    assert {:error, :routine_test_project_binding_rejected} = TestExecutor.validate_contexts([wrong])
    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn _, _ -> {:error, :offline} end)
    assert {:error, _} = TestExecutor.validate_contexts([context])
  end

  test "runtime loss preserves intent, suspends dispatch and allows cleanup without another start", ctx do
    parent = self()

    runner = fn job, _, _, _, _ ->
      send(parent, {:started, job})
      exit(:fixture_crash)
    end

    start_supervised!({TestExecutor, contexts: [ctx.context], name: __MODULE__.Executor, runner: runner})
    socket = ctx.context.settings.worker.test_executor_socket
    assert {:ok, _} = TestTool.request(socket, ctx.request)
    assert_receive {:started, _}, 5_000
    assert eventually(fn -> match?({:ok, %{"status" => "failed", "cleanup" => false}}, TestTool.request(socket, ctx.request)) end)
    refute_receive {:started, _}, 100
    assert {:error, {:test_executor_rejected, "test_environment_needs_cleanup"}} = TestTool.request(socket, %{ctx.request | "run_id" => "another"})
  end

  @tag :long_checkout
  test "supervisor recovers its socket process and retains interrupted run identity", ctx do
    checkout = File.cwd!()
    assert byte_size(checkout) > 104
    assert byte_size(System.fetch_env!("TMPDIR")) > 104
    assert String.starts_with?(ctx.root, checkout <> "/")
    socket = ctx.context.settings.worker.test_executor_socket
    socket_root = Path.dirname(socket)
    assert {:ok, ^socket} = SymphonyElixir.PathSafety.canonicalize(socket)
    assert byte_size(socket) < 104
    assert Bitwise.band(File.stat!(socket_root).mode, 0o777) == 0o700

    other_root = SymphonyElixir.TestSupport.routine_socket_root()
    refute other_root == socket_root
    markers = [Path.join(other_root, "parallel-fixture"), Path.join(checkout, "foreign-fixture")]
    for marker <- markers, do: File.write!(marker, "preserve")
    parent = self()

    runner = fn job, _, _, _, _ ->
      send(parent, {:started, job})
      unless job["cleanup"], do: receive(do: (:cancel_test -> :ok))
      RoutineTest.failed(job, "cancelled") |> Map.put("cleanup", true)
    end

    pid = start_supervised!({TestExecutor, contexts: [ctx.context], name: __MODULE__.Executor, runner: runner})
    assert {:ok, _} = TestTool.request(socket, ctx.request)
    assert_receive {:started, job}, 5_000
    assert TestExecutor.active?(job["directory"])
    {:os_pid, os_pid} = Port.info(:sys.get_state(pid).port, :os_pid)
    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
    assert eventually(fn -> (next = Process.whereis(__MODULE__.Executor)) != nil and next != pid end)
    assert eventually(fn -> match?({:ok, %{"status" => "failed", "cleanup" => false}}, TestTool.request(socket, ctx.request)) end)
    refute TestExecutor.active?(job["directory"])
    refute_receive {:started, _}, 100
    assert {:ok, _} = TestTool.request(socket, %{ctx.request | "operation" => "cleanup"})
    assert_receive {:started, %{"cleanup" => true} = cleanup_job}, 5_000
    assert cleanup_job["request"] == job["request"]
    assert cleanup_job["directory"] == job["directory"]
    assert eventually(fn -> match?({:ok, %{"status" => "failed", "cleanup" => true}}, TestTool.request(socket, ctx.request)) end)
    assert {:ok, result} = TestTool.request(socket, %{ctx.request | "operation" => "result"})
    assert result["failure"] == "cancelled"
    assert Map.take(result, ~w(run_id head_sha source_sha256 scenario)) == Map.take(ctx.request, ~w(run_id head_sha source_sha256 scenario))

    :ok = stop_supervised(TestExecutor)
    assert eventually(fn -> not File.exists?(socket) end)
    File.rm_rf!(socket_root)
    refute File.exists?(socket_root)
    for marker <- markers, do: assert(File.read!(marker) == "preserve")
    assert File.cwd!() == checkout
    assert git!(ctx.context.root, ["status", "--porcelain"]) == ""
    assert git!(ctx.request["checkout"], ["status", "--porcelain"]) == ""
    assert String.trim(git!(ctx.request["checkout"], ["rev-parse", "HEAD"])) == ctx.request["head_sha"]
  end

  test "disabled setup opens no socket and denied workers cannot provision it", ctx do
    disabled = put_in(ctx.context.settings.worker.test_executor, nil).context
    start_supervised!({TestExecutor, contexts: [disabled], name: __MODULE__.Executor})
    refute File.exists?(ctx.context.settings.worker.test_executor_socket)
    :ok = stop_supervised(TestExecutor)
    System.put_env("SYMPHONY_LINEAR_SECRET_ACCESS", "denied")
    on_exit(fn -> System.delete_env("SYMPHONY_LINEAR_SECRET_ACCESS") end)
    assert {:error, _} = start_supervised({TestExecutor, contexts: [ctx.context], name: __MODULE__.Executor})
    refute File.exists?(ctx.config["result_root"])
  end

  test "executor startup rejects early exit, invalid readiness and silent processes", ctx do
    for {code, expected} <- [
          {"import sys; sys.stdin.readline(); sys.exit(1)", :test_executor_start_failed},
          {"import sys,time; sys.stdin.readline(); print('{}',flush=True); time.sleep(30)", :test_executor_not_ready},
          {"import sys,time; sys.stdin.readline(); time.sleep(30)", :test_executor_not_ready}
        ] do
      command = [System.find_executable("python3"), "-c", code]
      opts = [contexts: [ctx.context], name: __MODULE__.Executor, command: command]
      assert {:error, {{:error, ^expected}, _}} = start_supervised({TestExecutor, opts})

      refute File.exists?(ctx.context.settings.worker.test_executor_socket)
    end
  end

  test "invalid events stop the executor and late task notifications cannot create results", ctx do
    pid = start_supervised!({TestExecutor, contexts: [ctx.context], name: __MODULE__.Executor})
    state = :sys.get_state(pid)
    assert {:stop, :invalid_executor_event, ^state} = TestExecutor.handle_info({state.port, {:data, {:eol, "{}"}}}, state)
    assert {:noreply, ^state} = TestExecutor.handle_info({make_ref(), %{"status" => "passed"}}, state)
    assert {:noreply, ^state} = TestExecutor.handle_info({:DOWN, make_ref(), :process, self(), :normal}, state)
    assert {:stop, :test_executor_exited, ^state} = TestExecutor.handle_info({:EXIT, state.port, :closed}, state)
    refute File.exists?(Path.join(ctx.config["result_root"], "result.json"))

    task = Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn -> exit(:fixture_failure) end)
    assert :ok = TestExecutor.terminate(:shutdown, %{state | port: nil, tasks: %{task.ref => {task, %{}}}})
    refute Process.alive?(task.pid)
  end

  test "terminal reconciliation and startup preserve reserved worktrees before executor recovery", ctx do
    context = put_in(ctx.context.settings.tracker.kind, "memory").context
    context = put_in(context.settings.tracker.terminal_states, ["Review"])
    issue = %Issue{id: ctx.request["issue_id"], identifier: "PRO-769", state: "Review"}
    file = Path.join(ctx.request["checkout"], "external.txt")
    File.write!(file, "external change")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :run_terminal_workspace_cleanup_on_start, true)
    on_exit(fn -> Application.put_env(:symphony_elixir, :run_terminal_workspace_cleanup_on_start, false) end)

    # Startup cleanup runs before the executor/ETS table exists, including
    # when its journal is damaged or an interrupted fixture is terminal.
    start_supervised!({Orchestrator, context: context, name: __MODULE__.Cleanup, initial_poll?: false})
    assert File.read!(file) == "external change"

    worker = spawn(fn -> receive do: (:stop -> :ok) end)

    state = %Orchestrator.State{
      running: %{issue.id => %{pid: worker, ref: nil, identifier: issue.identifier, issue: issue, started_at: DateTime.utc_now()}},
      claimed: MapSet.new([issue.id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    next = ProjectContext.with_context(context, fn -> Orchestrator.reconcile_issue_states_for_test([issue], state) end)
    refute Map.has_key?(next.running, issue.id)
    refute Process.alive?(worker)
    assert File.read!(file) == "external change"
  end

  test "routine dispatch only releases its own active fixture and restart suspends it", ctx do
    directory = Path.join([ctx.config["result_root"], ctx.request["issue_id"], "routine-1"])
    issue = %Issue{id: "fixture", identifier: "PRO-1", state: "Todo (AI)"}
    plan = %{"scenario" => "bootstrap", "run_id" => "routine-1", "instance" => "routine", "source" => %{}}
    {:ok, journal} = SymphonyElixir.TestRun.routine_journal(ctx.context, plan, directory)
    DurableState.write(Path.join(directory, "fixtures.json"), %{journal | "fixtures" => [%{"id" => issue.id, "deleted" => false}]})
    DurableState.write(Path.join(directory, "plan.json"), plan)
    DurableState.write(Path.join(directory, "control.json"), %{"active" => true})
    :ets.new(TestExecutor, [:named_table])
    :ets.insert(TestExecutor, {directory, true})

    ProjectContext.with_context(ctx.context, fn ->
      assert RoutineTest.start_allowed?(issue)
      refute RoutineTest.start_allowed?(%{issue | id: "foreign"})
      refute RoutineTest.start_allowed?(%{issue | state: "Planung (AI)"})
      assert RoutineTest.owns?(issue.id)
      :ok = RoutineTest.record_session(issue.id, "thread-turn")
      assert {:ok, %{"session_id" => "thread-turn"}} = DurableState.read(Path.join(directory, "sessions/fixture.json"))
      retry_state = %Orchestrator.State{retry_attempts: %{issue.id => %{attempt: 1}}, codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}}
      update = %{event: :session_started, session_id: "retry-thread-turn", thread_id: "retry-thread", timestamp: DateTime.utc_now()}
      assert {:noreply, _} = Orchestrator.handle_info({:codex_worker_update, issue.id, update}, retry_state)
      assert {:ok, %{"session_id" => "retry-thread-turn"}} = DurableState.read(Path.join(directory, "sessions/fixture.json"))
      :ok = RoutineTest.record_session("foreign", "foreign-session")
      refute File.exists?(Path.join(directory, "sessions/foreign.json"))
      :ets.delete(TestExecutor)
      refute RoutineTest.start_allowed?(issue)
      refute RoutineTest.owns?("foreign")
      DurableState.write(Path.join(directory, "fixtures.json"), Map.put(journal, "binding", %{}))
      refute RoutineTest.owns?(issue.id)
    end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(20)
          eventually(fun, attempts - 1)
        )
  end

  defp git!(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    output
  end
end
