defmodule SymphonyElixir.TestExecutorTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.TestTool
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.DurableState
  alias SymphonyElixir.{ProjectContext, RoutineTest, TestExecutor}

  setup do
    root = Path.join(File.cwd!(), "tmp/ex-#{System.unique_integer([:positive])}")
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
    settings = put_in(settings.worker.test_executor_socket, Path.join(root, "socket/e.sock"))
    settings = put_in(settings.workspace.root, Path.join(root, "worktrees"))
    context = %ProjectContext{id: project, root: project, name: "symphony-test", settings: settings}
    {json, 0} = System.cmd("python3", ["scripts/test-instance.py", "source", workspace])
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

    on_exit(fn -> File.rm_rf!(root) end)
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

  test "supervisor recovers its socket process and retains interrupted run identity", ctx do
    parent = self()

    runner = fn job, _, _, _, _ ->
      send(parent, {:started, job})
      unless job["cleanup"], do: receive(do: (:cancel_test -> :ok))
      RoutineTest.failed(job, "cancelled") |> Map.put("cleanup", true)
    end

    pid = start_supervised!({TestExecutor, contexts: [ctx.context], name: __MODULE__.Executor, runner: runner})
    socket = ctx.context.settings.worker.test_executor_socket
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
    assert_receive {:started, %{"cleanup" => true}}, 5_000
    assert eventually(fn -> match?({:ok, %{"status" => "failed", "cleanup" => true}}, TestTool.request(socket, ctx.request)) end)
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
