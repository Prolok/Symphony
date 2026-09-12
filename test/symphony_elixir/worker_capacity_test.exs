defmodule SymphonyElixir.WorkerCapacityTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{ProjectContext, WorkerCapacity}

  test "concurrent project owners share host limits and release workers on owner exit" do
    settings = Config.settings!()
    worker = %{settings.worker | ssh_hosts: ["shared", "other"], max_concurrent_agents_per_host: 1}
    context = %ProjectContext{settings: %{settings | worker: worker}}
    start_supervised!({WorkerCapacity, contexts: [context, context]})
    parent = self()

    owners =
      for _ <- 1..8 do
        spawn(fn ->
          receive do
            :start -> send(parent, {:result, self(), WorkerCapacity.start_child("shared", "Review (AI)", &wait/0)})
          end

          wait()
        end)
      end

    on_exit(fn -> Enum.each(owners, &Process.exit(&1, :kill)) end)
    Enum.each(owners, &send(&1, :start))
    results = for _ <- owners, do: receive(do: ({:result, owner, result} -> {owner, result}))
    assert [{owner, {:ok, pid}}] = Enum.filter(results, fn {_, result} -> match?({:ok, _}, result) end)
    assert Enum.count(results, fn {_, result} -> result == {:error, :worker_capacity} end) == 7
    assert WorkerCapacity.count("shared") == 1

    ProjectContext.with_context(context, fn ->
      assert Orchestrator.select_worker_host_for_test(%Orchestrator.State{external_poll: true}, "shared") == "other"
    end)

    assert {:ok, other} = WorkerCapacity.start_child("other", "Review (AI)", &wait/0)
    ref = Process.monitor(pid)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    assert WorkerCapacity.count("shared") == 0
    assert WorkerCapacity.count("other") == 1
    assert {:ok, replacement} = WorkerCapacity.start_child("shared", "Review (AI)", &wait/0)
    ref = Process.monitor(replacement)
    send(replacement, :stop)
    assert_receive {:DOWN, ^ref, :process, ^replacement, :normal}, 1_000
    assert WorkerCapacity.count("shared") == 0
    assert Process.alive?(other)
    stop_supervised!(WorkerCapacity)
    refute Process.alive?(other)
  end

  test "global limits reload, local workers share capacity and task-start failures do not reserve slots" do
    settings = Config.settings!()
    context = %ProjectContext{settings: %{settings | agent: %{settings.agent | max_concurrent_agents: 1}}}
    tasks = start_supervised!({Task.Supervisor, max_children: 1})
    start_supervised!({WorkerCapacity, contexts: [context], task_supervisor: tasks})
    assert {:ok, pid} = WorkerCapacity.start_child(nil, "Review (AI)", &wait/0)
    assert {:error, :worker_capacity} = WorkerCapacity.start_child("another", "Review (AI)", &wait/0)
    updated = put_in(context.settings.agent.max_concurrent_agents, 2)
    assert :ok = WorkerCapacity.configure([updated])
    assert {:error, :max_children} = WorkerCapacity.start_child("another", "Review (AI)", &wait/0)
    assert WorkerCapacity.count("another") == 0
    ref = Process.monitor(pid)
    Task.Supervisor.terminate_child(tasks, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    assert {:ok, _} = WorkerCapacity.start_child("another", "Review (AI)", &wait/0)
  end

  test "status capacity is shared by projects" do
    settings = Config.settings!()
    agent = %{settings.agent | max_concurrent_agents_by_state: %{"review (ai)" => 1}}
    context = %ProjectContext{settings: %{settings | agent: agent}}
    start_supervised!({WorkerCapacity, contexts: [context, context]})
    assert {:ok, pid} = WorkerCapacity.start_child(nil, "Review (AI)", &wait/0)
    assert {:error, :worker_capacity} = WorkerCapacity.start_child("other-host", "review (ai)", &wait/0)
    assert WorkerCapacity.count_state("REVIEW (AI)") == 1
    assert {:ok, _} = WorkerCapacity.start_child(nil, "Test (AI)", &wait/0)
    issue = %Issue{id: "fixture", identifier: "PRO-1", title: "Fixture", state: "Review (AI)", assigned_to_worker: true}

    ProjectContext.with_context(context, fn ->
      refute Orchestrator.should_dispatch_issue_for_test(issue, %Orchestrator.State{external_poll: true})
      entry = %{pid: pid, issue: issue, run_mode: :regular}
      state = %Orchestrator.State{external_poll: true, running: %{issue.id => entry}}
      changed = %{issue | state: "Test (AI)"}
      assert %{running: %{"fixture" => %{issue: ^changed}}} = Orchestrator.reconcile_issue_states_for_test([changed], state)
    end)

    assert WorkerCapacity.count_state("Review (AI)") == 0
    assert WorkerCapacity.count_state("Test (AI)") == 2
    assert {:ok, replacement} = WorkerCapacity.start_child(nil, "Review (AI)", &wait/0)
    ref = Process.monitor(replacement)
    Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, replacement)
    assert_receive {:DOWN, ^ref, :process, ^replacement, _}
    assert :ok = WorkerCapacity.update_state(replacement, "Test (AI)")
    assert WorkerCapacity.count_state("Review (AI)") == 0

    updated = put_in(context.settings.agent.max_concurrent_agents_by_state, %{"review (ai)" => 2})
    assert :ok = WorkerCapacity.configure([updated, context])
    assert {:ok, _} = WorkerCapacity.start_child(nil, "Review (AI)", &wait/0)
    assert {:error, :worker_capacity} = WorkerCapacity.start_child(nil, "Review (AI)", &wait/0)
  end

  defp wait do
    receive do
      :stop -> :ok
    end
  end
end
