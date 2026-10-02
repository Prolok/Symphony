defmodule SymphonyElixir.MaintenanceTurnTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Maintenance, MaintenanceRecovery}

  setup do
    SymphonyElixir.TestSupport.isolate_application_orchestrator()
    root = Path.dirname(Workflow.workflow_file_path())
    binary = Path.join(root, "fake-codex")
    trace = Path.join(root, "turns")
    release = Path.join(root, "release")

    File.write!(binary, """
    #!/usr/bin/env python3
    import json, os, sys, time
    count = 0
    for line in sys.stdin:
        request = json.loads(line)
        method = request.get('method')
        if method == 'initialize': result = {}
        elif method == 'thread/start': result = {'thread': {'id': 'maintenance-thread'}}
        elif method == 'turn/start':
            count += 1
            with open(#{inspect(trace)}, 'a') as f: f.write(str(count) + '\\n')
            result = {'turn': {'id': 'turn-' + str(count)}}
            print(json.dumps({'id': request['id'], 'result': result}), flush=True)
            if count > 1 and os.path.exists(#{inspect(Path.join(root, "hold-next"))}): continue
            while not os.path.exists(#{inspect(release)}): time.sleep(0.01)
            print(json.dumps({'method': 'turn/completed', 'params': {'threadId': 'maintenance-thread', 'turn': {'id': 'turn-' + str(count), 'status': 'completed'}}}), flush=True)
            continue
        elif method == 'turn/interrupt':
            if not os.path.exists(#{inspect(Path.join(root, "hold-next"))}): raise Exception('normal completion must not interrupt')
            print(json.dumps({'id': request['id'], 'result': {}}), flush=True)
            print(json.dumps({'method': 'turn/completed', 'params': {'threadId': 'maintenance-thread', 'turn': {'id': 'turn-' + str(count), 'status': 'completed'}}}), flush=True)
            continue
        else: continue
        print(json.dumps({'id': request['id'], 'result': result}), flush=True)
    """)

    File.chmod!(binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(root, "workspaces"),
      codex_command: "#{binary} app-server",
      max_turns: 3,
      poll_interval_ms: 3_600_000,
      hook_after_create: "git init -b main && git config user.name Fixture && git config user.email fixture@example.com && touch README && git add README && git commit -m fixture"
    )

    %{root: root, trace: trace, release: release}
  end

  for {phase, target} <- [{"In Arbeit (AI)", "In Arbeit (AI)"}, {"In Arbeit (AI)", "PreReview (AI)"}, {"PreReview (AI)", "PreReview (AI)"}, {"Review (AI)", "Review (AI)"}] do
    @tag phase: phase, target: target
    test "maintenance saves a completed turn from #{phase} to #{target}", fixture do
      {server, worker, current} = start_turn(fixture, fixture.phase)
      dirty = Path.join([fixture.root, "workspaces", "PRO-1", "pending.txt"])
      File.write!(dirty, "open work")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{current | state: fixture.target}])
      assert {:ok, _} = Maintenance.update(%{"enabled" => true, "reason" => "Update"})
      ref = Process.monitor(worker)
      refute_receive {:DOWN, ^ref, :process, ^worker, _}, 30
      File.write!(fixture.release, "finish")
      assert_receive {:DOWN, ^ref, :process, ^worker, :maintenance_interrupt}, 5_000
      assert File.read!(fixture.trace) == "1\n"
      assert {:ok, hints} = MaintenanceRecovery.load()
      hint = hints[current.id]
      assert hint.interrupted_state == fixture.target
      assert hint.workspace_path == Path.dirname(dirty)
      if fixture.phase == fixture.target, do: assert(is_binary(hint.codex_token_checkpoint.thread_id))
      assert hint.attempt == 0
      assert File.read!(dirty) == "open work"
      eventually(fn -> Orchestrator.snapshot(server, 1_000).maintenance.idle end)
      assert :sys.get_state(server).retry_attempts[current.id].maintenance_paused
    end
  end

  test "maintenance off preserves continuation until max_turns", fixture do
    {server, worker, _} = start_turn(fixture, "In Arbeit (AI)")
    ref = Process.monitor(worker)
    File.write!(fixture.release, "finish")
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 5_000
    assert File.read!(fixture.trace) == "1\n2\n3\n"
    assert MaintenanceRecovery.load() == {:ok, %{}}
    assert is_pid(server)
  end

  test "failed hint storage keeps the completed worker reserved until persistence succeeds", fixture do
    {server, worker, current} = start_turn(fixture, "In Arbeit (AI)")
    assert {:ok, _} = Maintenance.update(%{"enabled" => true, "reason" => "Update"})
    path = MaintenanceRecovery.path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "corrupt")
    ref = Process.monitor(worker)
    File.write!(fixture.release, "finish")
    eventually(fn -> :sys.get_state(server).running[current.id][:maintenance_interrupt_pending] end)
    refute Orchestrator.snapshot(server, 1_000).maintenance.idle
    assert File.read!(fixture.trace) == "1\n"
    refute_receive {:DOWN, ^ref, :process, ^worker, _}, 30
    File.rm!(path)
    assert_receive {:DOWN, ^ref, :process, ^worker, :maintenance_interrupt}, 3_000
    assert {:ok, hints} = MaintenanceRecovery.load()
    assert hints[current.id]
    eventually(fn -> Orchestrator.snapshot(server, 1_000).maintenance.idle end)
  end

  test "Merge continues its turns during maintenance", fixture do
    {_server, worker, _} = start_turn(fixture, "Merge (AI)")
    assert {:ok, _} = Maintenance.update(%{"enabled" => true, "reason" => "Update"})
    ref = Process.monitor(worker)
    File.write!(fixture.release, "finish")
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 5_000
    assert File.read!(fixture.trace) == "1\n2\n3\n"
    assert MaintenanceRecovery.load() == {:ok, %{}}
  end

  test "disabling maintenance after a storage failure restores deadline protection for the next turn", fixture do
    {server, worker, current} = start_turn(fixture, "In Arbeit (AI)")
    File.write!(Path.join(fixture.root, "hold-next"), "hold")
    assert {:ok, _} = Maintenance.update(%{"enabled" => true, "reason" => "First"})
    path = MaintenanceRecovery.path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "corrupt")
    ref = Process.monitor(worker)
    File.write!(fixture.release, "finish")
    eventually(fn -> :sys.get_state(server).running[current.id][:maintenance_interrupt_pending] end)
    assert {:ok, _} = Maintenance.update(%{"enabled" => false})
    File.rm!(path)
    eventually(fn -> File.read!(fixture.trace) == "1\n2\n" end)
    assert {:ok, control} = Maintenance.update(%{"enabled" => true, "reason" => "Second", "deadline_seconds" => 60})

    :sys.replace_state(SymphonyElixir.WorkerCapacity, fn state ->
      put_in(state.maintenance.deadline_ms, System.monotonic_time(:millisecond) - 1)
    end)

    send(server, {:maintenance_deadline, control.generation})
    assert_receive {:DOWN, ^ref, :process, ^worker, :maintenance_interrupt}, 3_000
    assert File.read!(fixture.trace) == "1\n2\n"
    assert {:ok, hints} = MaintenanceRecovery.load()
    assert hints[current.id].interrupted_state == current.state
  end

  test "a new maintenance generation at the safe point still prevents a follow-up turn", fixture do
    {server, worker, _} = start_turn(fixture, "In Arbeit (AI)")
    assert {:ok, old} = Maintenance.update(%{"enabled" => true, "reason" => "First"})
    ref = Process.monitor(worker)
    :sys.suspend(server)

    try do
      File.write!(fixture.release, "finish")

      eventually(fn ->
        {:messages, messages} = Process.info(server, :messages)

        Enum.any?(messages, fn
          {:"$gen_call", _, {:maintenance_turn_completed, _, generation}} -> generation == old.generation
          _ -> false
        end)
      end)

      assert {:ok, _} = Maintenance.update(%{"enabled" => false})
      assert {:ok, _} = Maintenance.update(%{"enabled" => true, "reason" => "Second"})
    after
      :sys.resume(server)
    end

    assert_receive {:DOWN, ^ref, :process, ^worker, :maintenance_interrupt}, 3_000
    assert File.read!(fixture.trace) == "1\n"
    assert {:ok, hints} = MaintenanceRecovery.load()
    assert hints["maintenance-turn"].maintenance_deferred
  end

  defp start_turn(fixture, phase) do
    current = %Issue{id: "maintenance-turn", identifier: "PRO-1", title: "Fixture", state: phase, assigned_to_worker: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [current])
    server = start_supervised!({Orchestrator, name: :maintenance_turn, initial_poll?: false})
    send(server, :tick)
    eventually(fn -> File.exists?(fixture.trace) end)
    worker = :sys.get_state(server).running[current.id].pid
    on_exit(fn -> if Process.alive?(worker), do: Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker) end)
    {server, worker, current}
  end

  defp eventually(fun, tries \\ 300)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, tries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, tries - 1)
        )
  end
end
