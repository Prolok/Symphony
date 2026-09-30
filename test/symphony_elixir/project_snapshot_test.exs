defmodule SymphonyElixir.ProjectSnapshotTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Projects
  alias SymphonyElixir.TestSupport.Snapshot
  alias SymphonyElixirWeb.Presenter

  setup do
    unless Process.whereis(SymphonyElixir.ProjectRegistry) do
      start_supervised!({Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry})
    end

    :ok
  end

  defmodule SnapshotServer do
    use GenServer
    def start_link({context, parent}), do: GenServer.start_link(__MODULE__, {context.id, parent}, name: Projects.server(context))
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call(:snapshot, from, {id, parent} = state) do
      send(parent, {:snapshot_requested, id, from})
      {:noreply, state}
    end
  end

  test "background requests all projects and publishes each answer independently" do
    {pid, _clock, contexts} = start_aggregator()
    requests = receive_requests(contexts)
    initial = Orchestrator.snapshot(pid, 1_000)
    assert initial.partial
    assert Enum.all?(initial.project_statuses, &(&1.error == "snapshot_pending"))
    assert initial.running == []
    reply(hd(requests))
    first = await_snapshot(pid, &(length(&1.running) == 1))
    assert first.projects == ["One", "Two"]
    assert first.partial
    reply(List.last(requests))
    result = await_snapshot(pid, &(length(&1.running) == 2))
    refute result.partial
    assert Enum.map(result.running, & &1.project) == ["One", "Two"]
    assert result.codex_totals.input_tokens == 3
    assert Enum.all?(result.project_statuses, &(&1.status == :fresh and &1.age_ms == 0 and is_binary(&1.observed_at)))
  end

  test "stale and expired boundaries exclude old data and recovery resets the observation" do
    {pid, clock, contexts} = start_aggregator()
    Enum.each(receive_requests(contexts), &reply/1)
    fresh = await_snapshot(pid, &(length(&1.running) == 2))
    begin_idle_check(pid, clock)
    pending = receive_requests(contexts)
    advance(clock, 1_000)
    assert Enum.all?(Orchestrator.snapshot(pid, 1_000).project_statuses, &(&1.status == :fresh))
    advance(clock, 1)
    stale = Orchestrator.snapshot(pid, 1_000)
    assert Enum.all?(stale.project_statuses, &(&1.status == :stale and &1.age_ms == 2_001))
    assert Enum.map(stale.project_statuses, & &1.observed_at) == Enum.map(fresh.project_statuses, & &1.observed_at)
    refute stale.partial
    assert length(stale.running) == 2
    advance(clock, 297_998)
    assert Enum.all?(Orchestrator.snapshot(pid, 1_000).project_statuses, &(&1.status == :stale and &1.age_ms == 299_999))
    advance(clock, 1)
    expired = Orchestrator.snapshot(pid, 1_000)
    assert expired.partial
    assert Enum.all?(expired.project_statuses, &(&1.status == :unavailable and &1.error == "snapshot_expired" and &1.age_ms == 300_000))
    assert expired.running == []
    assert expired.retrying == []
    assert expired.waiting == []
    assert expired.codex_totals.total_tokens == 0
    assert expired.codex_totals.input_tokens == 0
    Enum.each(pending, &reply/1)
    recovered = await_snapshot(pid, &(length(&1.running) == 2))
    assert Enum.all?(recovered.project_statuses, &(&1.status == :fresh and &1.age_ms == 0))
    refute recovered.partial
  end

  test "many readers enqueue no further requests while a project is blocked" do
    {pid, _clock, contexts} = start_aggregator()
    requests = receive_requests(contexts)
    reply(hd(requests))
    await_snapshot(pid, &(length(&1.running) == 1))
    tasks = for _ <- 1..20, do: Task.async(fn -> Orchestrator.snapshot(pid, 2_000) end)
    assert Enum.all?(tasks, &Task.await(&1, 2_000).partial)
    assert {:message_queue_len, 0} = Process.info(GenServer.whereis(Projects.server(List.last(contexts))), :message_queue_len)
    refute_receive {:snapshot_requested, "snapshot-two", _}, 1_100
    assert_receive {:snapshot_requested, "snapshot-one", healthy}, 1_000
    GenServer.reply(healthy, snapshot("snapshot-one", 10))
    assert await_snapshot(pid, &(&1.codex_totals.input_tokens == 10)).partial
  end

  test "process death and replacement discard cache and ignore the old reply" do
    {pid, clock, contexts} = start_aggregator()
    requests = receive_requests(contexts)
    Enum.each(requests, &reply/1)
    await_snapshot(pid, &(length(&1.running) == 2))
    begin_idle_check(pid, clock)
    pending = receive_requests(contexts)
    first = hd(contexts)
    stop_supervised!(first.id)
    missing = await_snapshot(pid, & &1.partial)
    assert hd(missing.project_statuses).error == "process_unavailable"
    assert hd(missing.project_statuses).age_ms == nil
    start_server(first)
    replaced = Orchestrator.snapshot(pid, 1_000)
    assert hd(replaced.project_statuses).error == "snapshot_pending"
    assert_receive {:snapshot_requested, "snapshot-one", new_from}, 1_000
    reply(hd(pending), 999)
    assert hd(Orchestrator.snapshot(pid, 1_000).project_statuses).error == "snapshot_pending"
    GenServer.reply(new_from, snapshot(first.id, 10))
    assert await_snapshot(pid, &(not &1.partial)).codex_totals.input_tokens == 12
  end

  test "all absent projects give an immediate explicit partial snapshot" do
    contexts = contexts()
    pid = start_supervised!({Projects, contexts: contexts, name: __MODULE__})
    result = Orchestrator.snapshot(pid, 100)
    assert result.projects == ["One", "Two"]
    assert result.partial
    assert Enum.all?(result.project_statuses, &(&1.error == "process_unavailable"))
    assert result.running == []
    assert result.codex_totals.total_tokens == 0
  end

  test "background retries discover projects that start after an absent observation" do
    contexts = contexts()
    pid = start_supervised!({Projects, contexts: contexts, name: __MODULE__})
    initial_timer = :sys.get_state(pid).projects[hd(contexts).id].timer

    await_snapshot(
      pid,
      fn result ->
        assert result.partial
        :sys.get_state(pid).projects[hd(contexts).id].timer != initial_timer
      end,
      150
    )

    Enum.each(contexts, &start_server/1)
    Enum.each(receive_requests(contexts), &reply/1)
    assert length(await_snapshot(pid, &(not &1.partial)).running) == 2
  end

  test "an unsuccessful reply is a visible project error while other projects remain available" do
    parent = self()
    {pid, _clock, contexts} = start_aggregator(contexts(), shutdown_fun: fn -> send(parent, :shutdown) end)
    pending = receive_requests(contexts)
    {_id, from} = hd(pending)
    GenServer.reply(from, :unavailable)
    reply(List.last(pending))
    result = await_snapshot(pid, &(length(&1.running) == 1))
    assert result.partial
    assert hd(result.project_statuses).error == "snapshot_error"
    assert hd(result.project_statuses).observed_at == nil
    assert List.last(result.project_statuses).status == :fresh

    send(pid, :check_idle)
    Orchestrator.snapshot(pid, 1_000)
    refute_receive {:snapshot_requested, _, _}, 20
    [{_id, failed}, healthy] = receive_requests(contexts)
    GenServer.reply(failed, :unavailable)
    reply_idle(healthy)
    await_idle_completion(pid)
    assert Orchestrator.snapshot(pid, 1_000).partial
    refute_receive :shutdown, 20
  end

  test "qualification remains based on every configured project in a partial snapshot" do
    contexts = Enum.map(contexts(), &%{&1 | name: "Shared"})
    {pid, _clock, contexts} = start_aggregator(contexts)
    requests = receive_requests(contexts)
    reply(hd(requests))
    result = await_snapshot(pid, &(length(&1.running) == 1))
    assert hd(result.running).project_qualifier == hd(contexts).root
    assert result.partial
  end

  test "cached idle is insufficient, a fresh complete idle check permits shutdown" do
    parent = self()
    {pid, clock, contexts} = start_aggregator(contexts(), shutdown_fun: fn -> send(parent, :shutdown) end)
    initial = receive_requests(contexts)
    Enum.each(initial, &reply_idle/1)
    await_snapshot(pid, &(not &1.partial))
    advance(clock, 3_000)
    assert Enum.all?(Orchestrator.snapshot(pid, 1_000).project_statuses, &(&1.status == :stale))
    refute_receive :shutdown, 20
    send(pid, :check_idle)
    pending = receive_requests(contexts)
    reply_idle(hd(pending))
    check = :sys.get_state(pid).idle_check
    send(pid, {:idle_deadline, check.token})
    Orchestrator.snapshot(pid, 1_000)
    refute_receive :shutdown, 20
    # A late reply updates the cache, but cannot complete the expired idle check.
    reply_idle(List.last(pending))
    await_snapshot(pid, &(not &1.partial))
    refute_receive :shutdown, 20
    begin_idle_check(pid, clock)
    Enum.each(receive_requests(contexts), &reply_idle/1)
    assert_receive :shutdown, 1_000
  end

  test "cached retries count down while both API views retain the original deadline" do
    {pid, clock, contexts} = start_aggregator()
    retry = %{issue_id: "retry-one", identifier: "PRO-3", attempt: 1, due_in_ms: 30_000, error: "blocked"}

    for {id, from} <- receive_requests(contexts) do
      retries = if id == hd(contexts).id, do: [retry], else: []
      GenServer.reply(from, %{snapshot(id) | running: [], retrying: retries})
    end

    await_snapshot(pid, &(length(&1.retrying) == 1))
    first = Presenter.state_payload(pid, 1_000)
    deadline = hd(first.retrying).due_at
    advance(clock, 20_000)
    stale = Orchestrator.snapshot(pid, 1_000)
    assert hd(stale.retrying).due_in_ms == 10_000
    rendered = StatusDashboard.format_snapshot_content_for_test({:ok, stale}, 0.0, 115)
    assert Snapshot.strip_ansi(rendered) =~ "in 10.000s"
    assert hd(Presenter.state_payload(pid, 1_000).retrying).due_at == deadline
    {:ok, issue} = Presenter.issue_payload("One:PRO-3", pid, 1_000)
    assert issue.retry.due_at == deadline
    advance(clock, 40_000)
    overdue = Orchestrator.snapshot(pid, 1_000)
    assert hd(overdue.retrying).due_in_ms == 0
    assert hd(Presenter.state_payload(pid, 1_000).retrying).due_at == deadline
    {:ok, issue} = Presenter.issue_payload("One:PRO-3", pid, 1_000)
    assert issue.retry.due_at == deadline
  end

  test "retries without a countdown preserve their explicit deadline as the cache ages" do
    {pid, clock, contexts} = start_aggregator()
    retry = %{issue_id: "retry-one", identifier: "PRO-3", due_at: ~U[2026-09-30 10:00:00Z]}

    for {id, from} <- receive_requests(contexts) do
      retries = if id == hd(contexts).id, do: [retry], else: []
      GenServer.reply(from, %{snapshot(id) | running: [], retrying: retries})
    end

    initial = hd(await_snapshot(pid, &(length(&1.retrying) == 1)).retrying)
    advance(clock, 20_000)
    assert hd(Orchestrator.snapshot(pid, 1_000).retrying) == initial
    assert initial.due_at == retry.due_at
    refute Map.has_key?(initial, :due_in_ms)
  end

  test "idle requests respect the interval since a delayed reply and still confirm shutdown" do
    parent = self()
    {pid, clock, contexts} = start_aggregator(contexts(), shutdown_fun: fn -> send(parent, :shutdown) end)
    initial = receive_requests(contexts)
    advance(clock, 900)
    Enum.each(initial, &reply_idle/1)
    await_snapshot(pid, &(not &1.partial))
    advance(clock, 100)
    send(pid, :check_idle)
    Orchestrator.snapshot(pid, 1_000)
    refute_receive {:snapshot_requested, _, _}, 20
    refute_receive :shutdown, 20
    advance(clock, 900)
    check = :sys.get_state(pid).idle_check
    send(pid, {:start_idle_check, check.token})
    Enum.each(receive_requests(contexts), &reply_idle/1)
    assert_receive :shutdown, 1_000
  end

  test "a poll in progress or an overdue full live check retains the service" do
    parent = self()
    {pid, clock, contexts} = start_aggregator(contexts(), shutdown_fun: fn -> send(parent, :shutdown) end)
    Enum.each(receive_requests(contexts), &reply_idle/1)
    await_snapshot(pid, &(not &1.partial))
    begin_idle_check(pid, clock)
    pending = receive_requests(contexts)
    reply_idle(hd(pending))
    {id, from} = List.last(pending)
    GenServer.reply(from, put_in(idle_snapshot(id), [:polling, :checking?], true))
    await_idle_completion(pid)
    refute_receive :shutdown, 20
    begin_idle_check(pid, clock)
    pending = receive_requests(contexts)
    advance(clock, 1_000)
    Enum.each(pending, &reply_idle/1)
    await_idle_completion(pid)
    refute_receive :shutdown, 20
  end

  test "a replacement during an idle check invalidates that check" do
    parent = self()
    {pid, clock, contexts} = start_aggregator(contexts(), shutdown_fun: fn -> send(parent, :shutdown) end)
    Enum.each(receive_requests(contexts), &reply_idle/1)
    await_snapshot(pid, &(not &1.partial))
    begin_idle_check(pid, clock)
    pending = receive_requests(contexts)
    reply_idle(hd(pending))
    stop_supervised!(hd(contexts).id)
    Orchestrator.snapshot(pid, 1_000)
    reply_idle(List.last(pending))
    await_idle_completion(pid)
    refute_receive :shutdown, 20
  end

  test "a replacement during idle preparation restores independent refreshes" do
    parent = self()
    {pid, _clock, contexts} = start_aggregator(contexts(), shutdown_fun: fn -> send(parent, :shutdown) end)
    Enum.each(receive_requests(contexts), &reply_idle/1)
    await_snapshot(pid, &(not &1.partial))
    send(pid, :check_idle)
    Orchestrator.snapshot(pid, 1_000)
    check = :sys.get_state(pid).idle_check
    assert check.started_at == nil
    :sys.suspend(pid)
    send(pid, {:start_idle_check, check.token})
    stop_supervised!(hd(contexts).id)
    start_server(hd(contexts))
    :sys.resume(pid)
    assert Orchestrator.snapshot(pid, 1_000).partial
    assert :sys.get_state(pid).idle_check == nil
    send(pid, {:start_idle_check, check.token})
    assert_receive {:snapshot_requested, "snapshot-one", replacement}, 1_000
    assert_receive {:snapshot_requested, "snapshot-two", healthy}, 1_500
    GenServer.reply(healthy, snapshot("snapshot-two", 10))
    assert await_snapshot(pid, &(&1.codex_totals.input_tokens == 10)).partial
    refute_receive :shutdown, 20
    GenServer.reply(replacement, idle_snapshot("snapshot-one"))
    assert await_snapshot(pid, &(not &1.partial)).codex_totals.input_tokens == 11
  end

  test "foreign monitor messages and obsolete deadlines cannot finish a live idle check" do
    parent = self()
    {pid, clock, contexts} = start_aggregator(contexts(), shutdown_fun: fn -> send(parent, :shutdown) end)
    Enum.each(receive_requests(contexts), &reply_idle/1)
    await_snapshot(pid, &(not &1.partial))
    begin_idle_check(pid, clock)
    pending = receive_requests(contexts)
    check = :sys.get_state(pid).idle_check
    send(pid, {:DOWN, make_ref(), :process, self(), :normal})
    send(pid, {:idle_deadline, make_ref()})
    Orchestrator.snapshot(pid, 1_000)
    assert :sys.get_state(pid).idle_check == check
    refute_receive :shutdown, 20
    Enum.each(pending, &reply_idle/1)
    assert_receive :shutdown, 1_000
  end

  test "normal timers coordinate staggered replies into a full live idle check" do
    parent = self()
    shutdown = fn -> send(parent, :shutdown) end

    {pid, _clock, contexts} =
      start_aggregator(contexts(), clock_fun: fn -> System.monotonic_time(:millisecond) end, shutdown_fun: shutdown)

    initial = receive_requests(contexts)

    observations =
      Map.new(initial, fn {id, _from} = request ->
        Process.sleep(20)
        reply_idle(request)
        await_snapshot(pid, &Enum.any?(&1.project_statuses, fn status -> status.id == id and status.status == :fresh end))
        {id, :sys.get_state(pid).projects[id].observed_at_ms}
      end)

    for {id, _from} = request <- receive_requests(contexts) do
      assert System.monotonic_time(:millisecond) - observations[id] >= 1_000
      reply_idle(request)
    end

    assert_receive :shutdown, 1_000
  end

  test "stopping the aggregator removes pending request aliases and monitors" do
    {pid, _clock, contexts} = start_aggregator()
    pending = receive_requests(contexts)
    assert {:monitors, monitors} = Process.info(pid, :monitors)
    assert length(monitors) == 4
    GenServer.stop(pid)
    Enum.each(pending, &reply/1)
    refute Process.alive?(pid)

    for context <- contexts do
      assert {:monitored_by, []} = Process.info(GenServer.whereis(Projects.server(context)), :monitored_by)
    end
  end

  test "graceful shutdown cancels a live idle deadline and abandons its late replies" do
    parent = self()
    {pid, clock, contexts} = start_aggregator(contexts(), shutdown_fun: fn -> send(parent, :shutdown) end)
    Enum.each(receive_requests(contexts), &reply_idle/1)
    await_snapshot(pid, &(not &1.partial))
    begin_idle_check(pid, clock)
    pending = receive_requests(contexts)
    timer = :sys.get_state(pid).idle_check.timer
    assert is_integer(Process.read_timer(timer))
    GenServer.stop(pid)
    assert Process.read_timer(timer) == false
    Enum.each(pending, &reply_idle/1)
    refute_receive :shutdown, 20
  end

  defp start_aggregator(contexts \\ contexts(), opts \\ []) do
    Enum.each(contexts, &start_server/1)
    clock = start_supervised!({Agent, fn -> System.monotonic_time(:millisecond) end})

    pid =
      start_supervised!(
        {Projects, Keyword.merge([contexts: contexts, name: __MODULE__, clock_fun: fn -> Agent.get(clock, & &1) end], opts)},
        restart: :temporary
      )

    {pid, clock, contexts}
  end

  defp start_server(context), do: start_supervised!(Supervisor.child_spec({SnapshotServer, {context, self()}}, id: context.id))
  defp advance(clock, ms), do: Agent.update(clock, &(&1 + ms))

  defp begin_idle_check(pid, clock) do
    advance(clock, 1_000)
    send(pid, :check_idle)
  end

  defp receive_requests(contexts) do
    requests =
      for _ <- contexts do
        assert_receive {:snapshot_requested, id, from}, 2_000
        {id, from}
      end

    Enum.map(contexts, fn context -> Enum.find(requests, &(elem(&1, 0) == context.id)) || flunk("missing #{context.id}") end)
  end

  defp reply({id, from}, number \\ nil), do: GenServer.reply(from, snapshot(id, number))
  defp reply_idle({id, from}), do: GenServer.reply(from, idle_snapshot(id))

  defp await_snapshot(pid, predicate, attempts \\ 50)
  defp await_snapshot(_pid, _predicate, 0), do: flunk("snapshot did not converge")

  defp await_snapshot(pid, predicate, attempts) do
    result = Orchestrator.snapshot(pid, 1_000)

    if predicate.(result),
      do: result,
      else:
        (
          Process.sleep(10)
          await_snapshot(pid, predicate, attempts - 1)
        )
  end

  defp await_idle_completion(pid, attempts \\ 50)
  defp await_idle_completion(_pid, 0), do: flunk("idle check did not finish")

  defp await_idle_completion(pid, attempts) do
    if :sys.get_state(pid).idle_check == nil,
      do: :ok,
      else:
        (
          Process.sleep(10)
          await_idle_completion(pid, attempts - 1)
        )
  end

  defp contexts do
    for {id, name} <- [{"snapshot-one", "One"}, {"snapshot-two", "Two"}] do
      %{id: id, name: name, root: "/tmp/#{id}", settings: %{workspace: %{root: "/tmp/#{id}-worktrees"}, tracker: %{app: %{"workspace_id" => "test"}}}}
    end
  end

  defp snapshot(id, number \\ nil) do
    number = number || if(id == "snapshot-one", do: 1, else: 2)

    %{
      running: [%{identifier: "PRO-#{number}", workspace_path: "/tmp/workspace-#{number}"}],
      retrying: [],
      waiting: [],
      idle_shutdown_ms: 0,
      last_activity_at_ms: System.monotonic_time(:millisecond),
      codex_totals: %{input_tokens: number},
      rate_limits: nil,
      polling: %{checking?: false}
    }
  end

  defp idle_snapshot(id) do
    activity_at_ms = System.monotonic_time(:millisecond) - 1_000
    %{snapshot(id) | running: [], idle_shutdown_ms: 100, last_activity_at_ms: activity_at_ms}
  end
end
