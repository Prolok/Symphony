defmodule SymphonyElixir.MaintenanceTest do
  use SymphonyElixir.TestSupport
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias SymphonyElixir.Linear.DurableState
  alias SymphonyElixir.Linear.WriteContext
  alias SymphonyElixir.Maintenance
  alias SymphonyElixir.MaintenanceRecovery
  alias SymphonyElixir.ProjectContext
  alias SymphonyElixir.WorkerCapacity
  alias SymphonyElixir.Yolo.Coordinator
  alias SymphonyElixir.Yolo.OpenClaw.Journal
  @endpoint SymphonyElixirWeb.Endpoint

  defmodule DeadlineClient do
    def fetch_issue_states_by_ids(ids) do
      send(Application.fetch_env!(:symphony_elixir, :maintenance_tracker_recipient), {:deadline_read, self(), ids})

      receive do
        {:deadline_result, result} -> result
      after
        1_000 -> raise "deadline tracker fixture timed out"
      end
    end
  end

  setup do
    SymphonyElixir.TestSupport.isolate_application_orchestrator()
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", poll_interval_ms: 3_600_000)
    :ok
  end

  test "an unavailable start arbiter blocks maintenance changes and a false idle signal" do
    start_worker_capacity!([])
    stop_supervised!(WorkerCapacity)
    assert Maintenance.enabled?()
    assert Maintenance.status().reason == "Startarbiter nicht verfügbar"
    assert {:error, :maintenance_unavailable} = Maintenance.update(%{"enabled" => false})
    assert {:error, :maintenance_unavailable} = Maintenance.register()
    refute Maintenance.project(%{running: []}, true).idle
    refute Maintenance.aggregate([%{maintenance: %{idle: true, generation: nil}}], true).idle
  end

  test "deadline subscribers receive the current generation once and ignore obsolete timer messages" do
    start_worker_capacity!([])
    assert :ok = Maintenance.register()
    assert :ok = Maintenance.register()
    assert {:ok, old} = Maintenance.update(%{"enabled" => true, "reason" => "First", "deadline_seconds" => 300})
    assert_receive {:maintenance_changed, %{generation: old_generation}}
    assert old_generation == old.generation
    assert {:ok, _} = Maintenance.update(%{"enabled" => false})
    assert_receive {:maintenance_changed, %{enabled: false}}
    assert {:ok, current} = Maintenance.update(%{"enabled" => true, "reason" => "Second", "deadline_seconds" => 300})
    assert_receive {:maintenance_changed, %{generation: current_generation}}
    assert current_generation == current.generation
    timer = :sys.get_state(WorkerCapacity).deadline_timer
    send(WorkerCapacity, {:maintenance_deadline, old_generation})
    assert :sys.get_state(WorkerCapacity).deadline_timer == timer
    assert is_integer(Process.read_timer(timer))
    refute_receive {:maintenance_deadline, _}, 10
    expire_deadline()
    send(WorkerCapacity, {:maintenance_deadline, current_generation})
    assert_receive {:maintenance_deadline, ^current_generation}
    assert :sys.get_state(WorkerCapacity).deadline_timer == nil
    assert Maintenance.status().generation == current_generation
    refute_receive {:maintenance_deadline, _}, 10
  end

  test "real loopback HTTP command is idempotent, validates input and appears in API and dashboards" do
    orchestrator = start_supervised!({Orchestrator, name: :maintenance_http, initial_poll?: false})
    start_supervised!({HttpServer, port: 0, orchestrator: orchestrator})
    assert {:ok, occupied} = WorkerCapacity.start_child(nil, "In Arbeit (AI)", &wait/0)
    port = HttpServer.bound_port()
    url = "http://127.0.0.1:#{port}/api/v1/maintenance"

    assert {:ok, %{status: 200, body: %{"maintenance" => first}}} =
             Req.post(url, json: %{"enabled" => true, "reason" => "Update", "deadline_seconds" => 300})

    assert {:ok, %{body: %{"maintenance" => ^first}}} =
             Req.post(url, json: %{"enabled" => true, "reason" => "Update", "deadline_seconds" => 300})

    assert first["requested_at"] && first["deadline_at"]

    for request <- [
          %{},
          %{"enabled" => "true"},
          %{"enabled" => true, "reason" => " "},
          %{"enabled" => true, "reason" => "x", "deadline_seconds" => 0},
          %{"enabled" => true, "reason" => "x", "deadline_seconds" => 1.5},
          %{"enabled" => true, "reason" => "x", "deadline_seconds" => 86_401},
          %{"enabled" => false, "extra" => true}
        ] do
      assert {:ok, %{status: 400}} = Req.post(url, json: request)
      assert Maintenance.status().generation == first["generation"]
    end

    foreign = %{build_conn() | remote_ip: {192, 0, 2, 3}}
    foreign = Plug.Conn.put_req_header(foreign, "x-forwarded-for", "127.0.0.1")
    assert json_response(post(foreign, "/api/v1/maintenance", %{"enabled" => false}), 403)
    ipv6 = %{build_conn() | remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}
    assert json_response(post(ipv6, "/api/v1/maintenance", %{"enabled" => true, "reason" => "Update"}), 200)
    assert json_response(get(build_conn(), "/api/v1/maintenance"), 405)
    assert terminal(Orchestrator.snapshot(orchestrator, 1_000)) =~ "Laufende Arbeit wird beendet"
    {:ok, _view, draining_html} = live(build_conn(), "/")
    assert draining_html =~ "Laufende Arbeit wird beendet"
    send(occupied, :stop)
    eventually(fn -> Maintenance.status().drained end)
    payload = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert payload["maintenance"]["idle"]
    assert payload["counts"]["running"] == 0
    assert payload["counts"]["reserved"] == 0
    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Wartungsmodus" and html =~ "Leer und bereit für Neustart" and html =~ "Update"
    assert terminal(Orchestrator.snapshot(orchestrator, 1_000)) =~ "Leer und bereit für Neustart"
    assert {:ok, _} = Maintenance.update(%{"enabled" => false})
    assert terminal(Orchestrator.snapshot(orchestrator, 1_000)) =~ "Normalbetrieb"
  end

  test "activation serializes competing project starts and protects every new run category" do
    parent = self()

    owners =
      for _ <- 1..12 do
        spawn(fn ->
          receive do
            :start -> send(parent, {:started, self(), WorkerCapacity.start_child(nil, "In Arbeit (AI)", &wait/0)})
          end

          wait()
        end)
      end

    on_exit(fn -> Enum.each(owners, &Process.exit(&1, :kill)) end)
    Enum.each(owners, &send(&1, :start))
    assert {:ok, _} = Maintenance.update(%{"enabled" => true, "reason" => "Race"})

    results =
      for _ <- owners do
        receive do
          {:started, owner, result} -> {owner, result}
        after
          1_000 -> flunk("missing start response")
        end
      end

    for {_owner, result} <- results, do: assert(match?({:ok, _}, result) or result == {:error, :maintenance})

    for phase <- [
          "Todo (AI)",
          "Planung (AI)",
          "In Arbeit (AI)",
          "PreReview (AI)",
          "Review (AI)",
          "Test (AI)",
          "Merge (AI)",
          "Todo (Dialog-AI)",
          "In Arbeit",
          "YOLO incoming",
          "YOLO review",
          "YOLO blocker"
        ] do
      assert {:error, :maintenance} = WorkerCapacity.start_child(nil, phase, fn -> flunk("new run started") end)
    end

    for {_owner, {:ok, pid}} <- results, do: send(pid, :stop)
    eventually(fn -> Maintenance.status().drained end)
    assert Maintenance.project(%{running: []}, true).idle
  end

  test "already accepted external observers drain normally and keep idle false" do
    assert {:ok, _} = Maintenance.update(%{"enabled" => true, "reason" => "Update"})
    assert {:ok, pid} = WorkerCapacity.recover_child("YOLO review", &wait/0)
    refute Maintenance.project(%{running: []}, true).idle
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    eventually(fn -> Maintenance.project(%{running: []}, true).idle end)
  end

  test "new and replacement project loops inherit the service maintenance lock" do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("In Arbeit (AI)")])
    assert {:ok, _} = Maintenance.update(%{"enabled" => true, "reason" => "Update"})

    for name <- [:maintenance_new, :maintenance_replacement] do
      pid = start_supervised!({Orchestrator, name: name, initial_poll?: false}, id: name)
      send(pid, :tick)
      assert Orchestrator.snapshot(pid, 1_000).running == []
      assert Orchestrator.snapshot(pid, 1_000).maintenance.enabled
      stop_supervised!(name)
    end
  end

  test "dispatch rejected at the arbiter retains an initial attempt without a failure backoff" do
    current = issue("In Arbeit (AI)")
    assert {:ok, _} = Maintenance.update(%{"enabled" => true, "reason" => "Update"})
    state = Orchestrator.spawn_issue_on_worker_host_for_test(%Orchestrator.State{}, current)
    assert state.running == %{}
    assert state.retry_attempts[current.id].attempt == 0
    assert state.retry_attempts[current.id].error == nil
    assert state.retry_attempts[current.id].maintenance_paused
    assert {:ok, hints} = MaintenanceRecovery.load()
    assert hints[current.id].attempt == 0
  end

  test "aggregate requires complete fresh snapshots of the current maintenance generation" do
    assert {:ok, _} = Maintenance.update(%{"enabled" => true, "reason" => "Update"})
    fresh = %{maintenance: Maintenance.project(%{running: []}, true)}
    assert Maintenance.aggregate([fresh, fresh], true).idle
    refute Maintenance.aggregate([fresh], false).idle
    refute Maintenance.aggregate([], true).idle
    refute Maintenance.aggregate([%{maintenance: %{fresh.maintenance | generation: "old"}}], true).idle
    refute Maintenance.aggregate([fresh, %{maintenance: %{fresh.maintenance | idle: false}}], true).idle
    refute Maintenance.project(%{running: [%{external: %{reserved: true}}]}, true).idle
    refute Maintenance.project(%{running: []}, false).idle
    assert {:ok, _} = Maintenance.update(%{"enabled" => false})
    refute Maintenance.aggregate([fresh], true).idle
  end

  test "unattached external reservations and unreadable journals prevent the restart signal" do
    root = Path.dirname(Workflow.workflow_file_path())
    context = %ProjectContext{id: "maintenance-project", root: root, settings: Config.settings!()}
    assert :ok = WorkerCapacity.configure([context])
    assert {:ok, _} = Maintenance.update(%{"enabled" => true, "reason" => "Update"})

    ProjectContext.with_context(context, fn ->
      path = Journal.path("review")
      order = %{"id" => "accepted", "group" => "review", "members" => [], "state" => "accepted"}
      assert :ok = DurableState.write(path, order)
      refute Maintenance.project(%{running: []}, true).idle
      File.write!(path, "unreadable")
      refute Maintenance.project(%{running: []}, true).idle
      File.rm!(path)
      assert Maintenance.project(%{running: []}, true).idle
    end)
  end

  test "terminal maintenance lines fit the width and sanitize a multiline reason" do
    assert {:ok, _} = Maintenance.update(%{"enabled" => true, "reason" => "Update\n\e[2J" <> String.duplicate("lang ", 60)})
    snapshot = %{running: [], retrying: [], codex_totals: %{}, maintenance: Maintenance.project(%{running: []}, true)}

    for columns <- [115, 50] do
      rendered = StatusDashboard.format_snapshot_content_for_test({:ok, snapshot}, 0.0, columns)
      refute rendered =~ "\e[2J"
      lines = rendered |> String.split("\n") |> Enum.filter(&String.contains?(&1, ["Wartungsmodus", "Grund:", "seit:"]))
      assert Enum.all?(lines, &(String.length(&1) <= columns))
      assert Enum.any?(lines, &String.contains?(&1, "Grund: Update"))
    end
  end

  test "due retries retain metadata, cancel old timers and resume with a new token" do
    id = "retry"
    token = make_ref()
    timer = Process.send_after(self(), {:retry_issue, id, token}, 60_000)

    retry = %{
      attempt: 3,
      identifier: "PRO-1",
      error: "existing failure",
      worker_host: "host",
      delegate_id: "agent",
      review_stay: true,
      recovered_turn_context: %{thread_id: "thread"},
      timer_ref: timer,
      retry_token: token,
      due_at_ms: System.monotonic_time(:millisecond) + 60_000
    }

    state = %Orchestrator.State{retry_attempts: %{id => retry}}
    assert {:ok, control} = Maintenance.update(%{"enabled" => true, "reason" => "Update"})
    assert {:noreply, paused} = Orchestrator.handle_info({:retry_issue, id, token}, state)
    assert paused.retry_attempts[id].attempt == 3
    assert paused.retry_attempts[id].retry_token == nil
    assert Process.read_timer(timer) == false
    assert {:ok, %{^id => hint}} = MaintenanceRecovery.load()
    assert hint.error == retry.error and hint.review_stay and hint.worker_host == "host"
    assert {:noreply, ^paused} = Orchestrator.handle_info({:retry_issue, id, token}, paused)
    assert {:ok, _} = Maintenance.update(%{"enabled" => false})
    assert {:noreply, resumed} = Orchestrator.handle_info({:maintenance_changed, %{control | enabled: false}}, paused)
    assert resumed.retry_attempts[id].attempt == 3
    refute resumed.retry_attempts[id].retry_token == token
    assert {:noreply, ^resumed} = Orchestrator.handle_info({:retry_issue, id, token}, resumed)
    Process.cancel_timer(resumed.retry_attempts[id].timer_ref)
  end

  test "storage failure preserves pending retry and blocks a false idle result" do
    path = MaintenanceRecovery.path()
    File.mkdir_p!(path)
    retry = %{attempt: 1, timer_ref: nil, retry_token: make_ref(), identifier: "PRO-1"}
    state = %Orchestrator.State{retry_attempts: %{"retry" => retry}}
    assert {:ok, control} = Maintenance.update(%{"enabled" => true, "reason" => "Update"})
    assert {:noreply, failed} = Orchestrator.handle_info({:maintenance_changed, control}, state)
    assert failed.maintenance_error
    assert failed.retry_attempts["retry"] == retry
    refute Maintenance.project(%{running: []}, is_nil(failed.maintenance_error)).idle
  end

  test "corrupt encoded continuation hints cannot be consumed or overwritten" do
    assert :ok = MaintenanceRecovery.put("wake", %{attempt: 2, identifier: "PRO-1"})
    path = MaintenanceRecovery.path()
    assert {:ok, record} = DurableState.read(path)
    corrupt = %{record | "hints" => %{"wake" => "invalid-base64"}}
    assert :ok = DurableState.write(path, corrupt)
    assert {:error, :maintenance_recovery_corrupt} = MaintenanceRecovery.load()
    assert {:error, :maintenance_recovery_corrupt} = MaintenanceRecovery.put("new", %{attempt: 0})
    assert {:error, :maintenance_recovery_corrupt} = MaintenanceRecovery.delete("wake")
    assert {:ok, ^corrupt} = DurableState.read(path)
  end

  test "PO maintenance does not consume impulses or record start failures" do
    root = Path.dirname(Workflow.workflow_file_path())
    context = %ProjectContext{id: "po-maintenance", root: root, settings: Config.settings!(), yolo_agent_id: "agent"}

    ProjectContext.with_context(context, fn ->
      assert {:ok, _} = Maintenance.update(%{"enabled" => true, "reason" => "Update"})
      state = %Orchestrator.State{}
      state = put_in(state.yolo_retries[:agent_hops], %{})
      issues = for phase <- ["Todo (AI)", "Yolo Review", "BLOCKER"], do: %{issue(phase) | delegate_id: "agent"}
      assert Coordinator.tick(state, issues, start: fn _, _ -> flunk("PO started") end) == state
    end)
  end

  for phase <- ["Todo (AI)", "Planung (AI)", "In Arbeit (AI)", "PreReview (AI)", "Review (AI)", "Test (AI)"] do
    @tag phase: phase
    test "deadline records continuation and interrupts only the unchanged #{phase}", %{phase: phase} do
      current = issue(phase)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [current])
      assert {:ok, control} = Maintenance.update(%{"enabled" => true, "reason" => "Update", "deadline_seconds" => 300})
      expire_deadline()

      entry = %{
        issue: current,
        dispatch_issue: current,
        pid: self(),
        run_mode: :regular,
        identifier: current.identifier,
        codex_app_server_pid: "synthetic",
        retry_attempt: 2,
        workspace_path: "preserved-workspace",
        recovered_turn_context: %{thread_id: "same-thread"},
        review_subagent_call_ids: MapSet.new(["call"]),
        review_subagent_ids: MapSet.new(["child"])
      }

      state = %Orchestrator.State{running: %{current.id => entry}}
      assert {:noreply, stopped} = Orchestrator.handle_info({:maintenance_deadline, control.generation}, state)
      assert_receive {:maintenance_interrupt, generation}
      assert generation == control.generation
      assert stopped.running[current.id].maintenance_interrupt_requested
      assert {:ok, hints} = MaintenanceRecovery.load()
      assert hints[current.id].interrupted_state == phase
      assert hints[current.id].attempt == 2
      assert hints[current.id].workspace_path == "preserved-workspace"
      assert hints[current.id].recovered_turn_context == %{thread_id: "same-thread"}
      assert hints[current.id].review_stay == (phase == "Review (AI)")
      assert {:noreply, ^stopped} = Orchestrator.handle_info({:maintenance_deadline, generation}, stopped)
      refute_receive {:maintenance_interrupt, _}, 10
    end
  end

  for phase <- ["Merge (AI)", "Yolo Review", "BLOCKER", "Todo (Dialog-AI)", "In Arbeit"] do
    @tag phase: phase
    test "deadline never interrupts protected #{phase}", %{phase: phase} do
      current = issue(phase)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [current])
      assert {:ok, control} = Maintenance.update(%{"enabled" => true, "reason" => "Update", "deadline_seconds" => 300})
      expire_deadline()
      state = %Orchestrator.State{running: %{current.id => %{issue: current, pid: self(), run_mode: :regular}}}
      assert {:noreply, ^state} = Orchestrator.handle_info({:maintenance_deadline, control.generation}, state)
      refute_receive {:maintenance_interrupt, _}, 10
    end
  end

  test "changed or unknown tracker status and obsolete generations prevent an interruption" do
    current = issue("In Arbeit (AI)")
    state = %Orchestrator.State{running: %{current.id => %{issue: current, pid: self(), run_mode: :regular, codex_app_server_pid: "synthetic"}}}
    assert {:ok, control} = Maintenance.update(%{"enabled" => true, "reason" => "Update", "deadline_seconds" => 300})
    expire_deadline()

    for issues <- [[%{current | state: "Merge (AI)"}], []] do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
      assert {:noreply, deferred} = Orchestrator.handle_info({:maintenance_deadline, control.generation}, state)
      refute deferred.running[current.id][:maintenance_interrupt_requested]
    end

    assert {:ok, _} = Maintenance.update(%{"enabled" => false})
    assert {:ok, _} = Maintenance.update(%{"enabled" => true, "reason" => "New request", "deadline_seconds" => 300})
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [current])
    expire_deadline()
    assert {:noreply, ^state} = Orchestrator.handle_info({:maintenance_deadline, control.generation}, state)
    refute_receive {:maintenance_interrupt, _}, 10
  end

  test "a rejected old interruption does not suppress the deadline of a new generation" do
    current = issue("In Arbeit (AI)")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [current])
    assert {:ok, old} = Maintenance.update(%{"enabled" => true, "reason" => "First", "deadline_seconds" => 300})

    entry = %{
      issue: current,
      pid: self(),
      identifier: current.identifier,
      run_mode: :regular,
      codex_app_server_pid: "synthetic",
      maintenance_interrupt_requested: old.generation
    }

    state = %Orchestrator.State{running: %{current.id => entry}}
    assert {:ok, _} = Maintenance.update(%{"enabled" => false})
    assert {:ok, fresh} = Maintenance.update(%{"enabled" => true, "reason" => "Second", "deadline_seconds" => 300})
    expire_deadline()
    assert {:noreply, changed} = Orchestrator.handle_info({:maintenance_deadline, fresh.generation}, state)
    assert_receive {:maintenance_interrupt, generation}
    assert generation == fresh.generation
    assert changed.running[current.id].maintenance_interrupt_requested == generation
  end

  test "a disable during the worker's fresh status read cancels the interruption" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    Application.put_env(:symphony_elixir, :linear_client_module, DeadlineClient)
    Application.put_env(:symphony_elixir, :maintenance_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :linear_client_module)
      Application.delete_env(:symphony_elixir, :maintenance_tracker_recipient)
    end)

    current = issue("In Arbeit (AI)")
    assert {:ok, control} = Maintenance.update(%{"enabled" => true, "reason" => "Update", "deadline_seconds" => 300})
    expire_deadline()
    parent = self()

    reader =
      spawn(fn ->
        result = WriteContext.with_context(%{issue_id: current.id, phase: current.state}, fn -> Maintenance.interrupt_current?(control.generation) end)
        send(parent, {:interrupt_allowed, result})
      end)

    assert_receive {:deadline_read, ^reader, [id]}
    assert id == current.id
    assert {:ok, _} = Maintenance.update(%{"enabled" => false})
    send(reader, {:deadline_result, {:ok, [current]}})
    assert_receive {:interrupt_allowed, false}
  end

  test "a worker rejection makes the same deadline generation eligible for a later retry" do
    current = issue("In Arbeit (AI)")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [current])
    assert {:ok, control} = Maintenance.update(%{"enabled" => true, "reason" => "Update", "deadline_seconds" => 300})
    expire_deadline()
    entry = %{issue: current, pid: self(), run_mode: :regular, codex_app_server_pid: "synthetic", identifier: current.identifier}
    state = %Orchestrator.State{running: %{current.id => entry}, codex_totals: %{}}
    assert {:noreply, requested} = Orchestrator.handle_info({:maintenance_deadline, control.generation}, state)
    assert_receive {:maintenance_interrupt, generation}
    rejection = %{event: :maintenance_interrupt_rejected, generation: generation, timestamp: DateTime.utc_now()}
    assert {:noreply, rejected} = Orchestrator.handle_info({:codex_worker_update, current.id, rejection}, requested)
    refute rejected.running[current.id][:maintenance_interrupt_requested]
    assert {:noreply, throttled} = Orchestrator.handle_info({:maintenance_deadline, generation}, rejected)
    refute_receive {:maintenance_interrupt, _}, 10
    due = put_in(throttled.running[current.id].maintenance_deadline_check.next_at_ms, System.monotonic_time(:millisecond) - 1)
    assert {:noreply, retried} = Orchestrator.handle_info({:maintenance_deadline, generation}, due)
    assert_receive {:maintenance_interrupt, ^generation}
    assert retried.running[current.id].maintenance_interrupt_requested == generation
    stale = %{rejection | generation: "obsolete"}
    assert {:noreply, retained} = Orchestrator.handle_info({:codex_worker_update, current.id, stale}, retried)
    assert retained.running[current.id].maintenance_interrupt_requested == generation
  end

  test "a pending interruption stays running even after the normal stall limit" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", codex_stall_timeout_ms: 1_000)
    current = issue("In Arbeit (AI)")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [current])
    orchestrator = start_supervised!({Orchestrator, name: :maintenance_pending, initial_poll?: false})
    assert {:ok, worker} = WorkerCapacity.start_child(nil, current.state, &wait/0)
    stale = DateTime.add(DateTime.utc_now(), -5, :second)

    entry = %{
      issue: current,
      pid: worker,
      ref: Process.monitor(worker),
      run_mode: :regular,
      identifier: current.identifier,
      codex_app_server_pid: "synthetic",
      last_codex_timestamp: stale,
      started_at: stale
    }

    :sys.replace_state(orchestrator, fn state -> %{state | running: %{current.id => entry}, claimed: MapSet.new([current.id])} end)
    assert {:ok, control} = Maintenance.update(%{"enabled" => true, "reason" => "Update"})
    send(orchestrator, {:codex_worker_update, current.id, %{event: :maintenance_interrupt_pending, generation: control.generation, timestamp: stale}})
    send(orchestrator, :tick)
    state = :sys.get_state(orchestrator)
    assert state.running[current.id].maintenance_interrupt_pending
    assert state.retry_attempts == %{}
    assert Process.alive?(worker)
    refute Orchestrator.snapshot(orchestrator, 1_000).maintenance.idle
    send(worker, :stop)
  end

  test "an unresolved deadline status is read once across ten ticks and a changed source wakes it" do
    current = issue("In Arbeit (AI)")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    assert {:ok, control} = Maintenance.update(%{"enabled" => true, "reason" => "Update", "deadline_seconds" => 300})
    expire_deadline()
    entry = %{issue: current, pid: self(), run_mode: :regular, codex_app_server_pid: "synthetic", identifier: current.identifier}
    state = %Orchestrator.State{running: %{current.id => entry}}

    deferred =
      Enum.reduce(1..10, state, fn _, acc ->
        {:noreply, next} = Orchestrator.handle_info({:maintenance_deadline, control.generation}, acc)
        next
      end)

    assert_receive {:memory_tracker_fetch_issue_states, [id]}
    assert id == current.id
    refute_receive {:memory_tracker_fetch_issue_states, _}, 10
    refute_receive {:maintenance_interrupt, _}, 10
    changed = put_in(deferred.running[current.id].issue.updated_at, DateTime.utc_now())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [changed.running[current.id].issue])
    assert {:noreply, interrupted} = Orchestrator.handle_info({:maintenance_deadline, control.generation}, changed)
    assert_receive {:maintenance_interrupt, generation}
    assert generation == control.generation
    assert interrupted.running[current.id].maintenance_interrupt_requested == generation
  end

  for {host, disconnected?} <- [{nil, false}, {"synthetic-ssh", false}, {"synthetic-ssh", true}] do
    @tag host: host, disconnected?: disconnected?
    test "app-server waits for confirmed interruption on #{host || "local"} (disconnected: #{disconnected?})", %{host: host, disconnected?: disconnected?} do
      root = Path.dirname(Workflow.workflow_file_path())
      workspace = Path.join(root, "workspaces/PRO-1")
      File.mkdir_p!(workspace)
      dirty = Path.join(workspace, "pending.txt")
      File.write!(dirty, "uncommitted work")
      binary = Path.join(root, "fake-codex")
      trace = Path.join(root, "trace")
      interrupt_waiting = Path.join(root, "interrupt-waiting")
      release_interrupt = Path.join(root, "release-interrupt")
      on_exit(fn -> File.write(release_interrupt, "release") end)

      File.write!(binary, """
      #!/usr/bin/env python3
      import json, os, sys, time
      for line in sys.stdin:
          request = json.loads(line)
          with open(#{inspect(trace)}, 'a') as f:
              f.write(json.dumps(request) + '\\n')
          method = request.get('method')
          if method == 'initialize': result = {}
          elif method == 'thread/start': result = {'thread': {'id': 'thread'}}
          elif method == 'turn/start': result = {'turn': {'id': 'turn'}}
          elif method == 'turn/interrupt':
              open(#{inspect(interrupt_waiting)}, 'w').close()
              print(json.dumps({'id': request['id'], 'result': {}}), flush=True)
              print(json.dumps({'method': 'turn/completed', 'params': {'threadId': 'thread', 'turn': {'id': 'child', 'status': 'interrupted'}}}), flush=True)
              if #{if disconnected?, do: "True", else: "False"}: sys.exit(0)
              while not os.path.exists(#{inspect(release_interrupt)}): time.sleep(0.01)
              print(json.dumps({'method': 'turn/completed', 'params': {'threadId': 'thread', 'turn': {'id': 'turn', 'status': 'interrupted'}}}), flush=True)
              continue
          else: continue
          print(json.dumps({'id': request['id'], 'result': result}), flush=True)
      """)

      File.chmod!(binary, 0o755)

      options = [
        tracker_kind: "memory",
        workspace_root: Path.dirname(workspace),
        codex_command: "#{binary} app-server",
        codex_turn_timeout_ms: 500,
        poll_interval_ms: 3_600_000
      ]

      write_workflow_file!(Workflow.workflow_file_path(), options)
      current = issue("In Arbeit (AI)")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [current])

      if host do
        fake_ssh = Path.join(root, "ssh")
        File.write!(fake_ssh, "#!/bin/sh\nfor arg do command=\"$arg\"; done\nexec /bin/bash -c \"$command\"\n")
        File.chmod!(fake_ssh, 0o755)
        previous_path = System.get_env("PATH")
        System.put_env("PATH", root <> ":" <> previous_path)
        on_exit(fn -> restore_env("PATH", previous_path) end)
      end

      parent = self()

      {:ok, pid} =
        WorkerCapacity.start_child(nil, current.state, fn ->
          WriteContext.with_context(%{issue_id: current.id, phase: current.state}, fn ->
            {:ok, session} = AppServer.start_session(workspace, worker_host: host)
            send(parent, {:session, session.metadata.codex_app_server_pid})
            AppServer.run_turn(session, "synthetic", current, on_message: fn event -> send(parent, {:event, event}) end)
          end)
        end)

      ref = Process.monitor(pid)
      assert_receive {:session, os_pid}, 3_000
      assert_receive {:event, %{event: :session_started}}, 3_000
      assert {:ok, control} = Maintenance.update(%{"enabled" => true, "reason" => "Update", "deadline_seconds" => 300})
      expire_deadline()
      Application.put_env(:symphony_elixir, :memory_tracker_state_error, :transient_unavailable)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_state_error) end)
      send(pid, {:maintenance_interrupt, control.generation})
      assert_receive {:event, %{event: :maintenance_interrupt_rejected, generation: generation}}, 1_000
      assert generation == control.generation
      refute File.exists?(interrupt_waiting)
      Application.delete_env(:symphony_elixir, :memory_tracker_state_error)
      send(pid, {:maintenance_interrupt, control.generation})
      eventually(fn -> File.exists?(interrupt_waiting) end)
      assert_receive {:event, %{event: :maintenance_interrupt_pending}}, 1_000
      assert_receive {:event, %{event: :maintenance_interrupt_unconfirmed}}, 1_000
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 100
      refute Maintenance.project(%{running: []}, true).idle

      if disconnected? do
        eventually(fn -> elem(System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true), 1) != 0 end)
        assert Process.alive?(pid)
        refute Maintenance.project(%{running: []}, true).idle
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
      else
        File.write!(release_interrupt, "release")
        assert_receive {:DOWN, ^ref, :process, ^pid, :maintenance_interrupt}, 3_000
      end

      eventually(fn -> elem(System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true), 1) != 0 end)
      assert File.read!(trace) =~ "turn/interrupt"
      assert File.read!(dirty) == "uncommitted work"
      eventually(fn -> Maintenance.project(%{running: []}, true).idle end)
    end
  end

  @tag timeout: 30_000
  test "isolated complete application restart resumes persisted wake-ups exactly once" do
    workflow = Workflow.workflow_file_path()
    write_workflow_file!(workflow, tracker_kind: "memory", poll_interval_ms: 3_600_000, server_port: 0, observability_enabled: false, workspace_root: Path.join(Path.dirname(workflow), "workspaces"))
    paths = Path.wildcard(Path.join([File.cwd!(), "_build/test/lib/*/ebin"]))
    args = Enum.flat_map(paths, &["-pa", &1]) ++ ["test/support/maintenance_restart.exs", workflow]
    {output, status} = System.cmd(System.find_executable("elixir"), args, stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "maintenance-restart: complete, no loss, no duplicate"
  end

  defp issue(phase), do: %Issue{id: phase, identifier: "PRO-1", title: "Fixture", state: phase, assigned_to_worker: true}
  defp wait, do: receive(do: (:stop -> :ok))

  defp expire_deadline do
    :sys.replace_state(WorkerCapacity, fn state ->
      put_in(state.maintenance.deadline_ms, System.monotonic_time(:millisecond) - 1)
    end)
  end

  defp terminal(snapshot) do
    parent = self()
    {:ok, state} = StatusDashboard.init(enabled: true, refresh_ms: 100_000, snapshot_fun: fn -> {:ok, snapshot} end, render_fun: fn content -> send(parent, {:terminal, content}) end)
    {:noreply, _} = StatusDashboard.handle_info(:refresh, state)
    assert_receive {:terminal, content}
    content
  end

  defp eventually(fun, tries \\ 100)
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
