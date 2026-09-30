defmodule SymphonyElixir.ProjectSnapshotTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Projects

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
    send(pid, :check_idle)
    pending = receive_requests(contexts)
    advance(clock, 2_000)
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
    {pid, _clock, contexts} = start_aggregator()
    requests = receive_requests(contexts)
    Enum.each(requests, &reply/1)
    await_snapshot(pid, &(length(&1.running) == 2))
    send(pid, :check_idle)
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

  test "an unsuccessful reply is a visible project error while other projects remain available" do
    {pid, _clock, contexts} = start_aggregator()
    pending = receive_requests(contexts)
    {_id, from} = hd(pending)
    GenServer.reply(from, :unavailable)
    reply(List.last(pending))
    result = await_snapshot(pid, &(length(&1.running) == 1))
    assert result.partial
    assert hd(result.project_statuses).error == "snapshot_error"
    assert hd(result.project_statuses).observed_at == nil
    assert List.last(result.project_statuses).status == :fresh
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
    send(pid, :check_idle)
    Enum.each(receive_requests(contexts), &reply_idle/1)
    assert_receive :shutdown, 1_000
  end

  test "a poll in progress or an overdue full live check retains the service" do
    parent = self()
    {pid, clock, contexts} = start_aggregator(contexts(), shutdown_fun: fn -> send(parent, :shutdown) end)
    Enum.each(receive_requests(contexts), &reply_idle/1)
    await_snapshot(pid, &(not &1.partial))
    send(pid, :check_idle)
    pending = receive_requests(contexts)
    reply_idle(hd(pending))
    {id, from} = List.last(pending)
    GenServer.reply(from, put_in(idle_snapshot(id), [:polling, :checking?], true))
    await_idle_completion(pid)
    refute_receive :shutdown, 20
    send(pid, :check_idle)
    pending = receive_requests(contexts)
    advance(clock, 1_000)
    Enum.each(pending, &reply_idle/1)
    await_idle_completion(pid)
    refute_receive :shutdown, 20
  end

  test "a replacement during an idle check invalidates that check" do
    parent = self()
    {pid, _clock, contexts} = start_aggregator(contexts(), shutdown_fun: fn -> send(parent, :shutdown) end)
    Enum.each(receive_requests(contexts), &reply_idle/1)
    await_snapshot(pid, &(not &1.partial))
    send(pid, :check_idle)
    pending = receive_requests(contexts)
    reply_idle(hd(pending))
    stop_supervised!(hd(contexts).id)
    Orchestrator.snapshot(pid, 1_000)
    reply_idle(List.last(pending))
    await_idle_completion(pid)
    refute_receive :shutdown, 20
  end

  test "stopping the aggregator removes pending request aliases and monitors" do
    {pid, _clock, contexts} = start_aggregator()
    pending = receive_requests(contexts)
    assert {:monitors, monitors} = Process.info(pid, :monitors)
    assert length(monitors) == 4
    stop_supervised!(Projects)
    Enum.each(pending, &reply/1)
    refute Process.alive?(pid)

    for context <- contexts do
      assert {:monitored_by, []} = Process.info(GenServer.whereis(Projects.server(context)), :monitored_by)
    end
  end

  defp start_aggregator(contexts \\ contexts(), opts \\ []) do
    Enum.each(contexts, &start_server/1)
    clock = start_supervised!({Agent, fn -> System.monotonic_time(:millisecond) end})
    pid = start_supervised!({Projects, Keyword.merge([contexts: contexts, name: __MODULE__, clock_fun: fn -> Agent.get(clock, & &1) end], opts)})
    {pid, clock, contexts}
  end

  defp start_server(context), do: start_supervised!(Supervisor.child_spec({SnapshotServer, {context, self()}}, id: context.id))
  defp advance(clock, ms), do: Agent.update(clock, &(&1 + ms))

  defp receive_requests(contexts) do
    requests =
      for _ <- contexts do
        assert_receive {:snapshot_requested, id, from}, 1_000
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
