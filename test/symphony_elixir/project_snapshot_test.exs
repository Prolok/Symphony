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

    def start_link({context, parent}) do
      GenServer.start_link(__MODULE__, {context.id, parent}, name: Projects.server(context))
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:snapshot, from, {id, parent} = state) do
      send(parent, {:snapshot_requested, id, from})
      {:noreply, state}
    end
  end

  test "aggregate snapshot requests every project before awaiting a response" do
    contexts = contexts()
    start_servers(contexts)

    result = assert_parallel_requests(contexts, fn -> Projects.handle_call(:snapshot, nil, contexts) end)
    {:reply, snapshot, ^contexts} = result

    assert snapshot.projects == ["One", "Two"]
    assert Enum.map(snapshot.running, & &1.project) == ["One", "Two"]
    assert snapshot.codex_totals == %{input_tokens: 3}
  end

  test "idle check requests every project before awaiting a response" do
    contexts = contexts()
    start_servers(contexts)

    result = assert_parallel_requests(contexts, fn -> Projects.handle_info(:check_idle, contexts) end)
    assert {:noreply, ^contexts} = result
  end

  test "aggregate snapshot remains unavailable when one project times out" do
    contexts = contexts()
    start_servers(contexts)
    task = Task.async(fn -> Projects.handle_call(:snapshot, nil, contexts) end)

    try do
      requests = receive_requests(contexts)
      {_id, from} = hd(requests)
      GenServer.reply(from, snapshot(hd(contexts).id))

      assert {:reply, :unavailable, ^contexts} = Task.await(task, 12_000)
    after
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end
  end

  test "idle check retains the service when one project times out" do
    contexts = contexts()
    start_servers(contexts)
    task = Task.async(fn -> Projects.handle_info(:check_idle, contexts) end)

    try do
      requests = receive_requests(contexts)
      {_id, from} = hd(requests)
      GenServer.reply(from, snapshot(hd(contexts).id))

      assert {:noreply, ^contexts} = Task.await(task, 2_000)
    after
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end
  end

  defp assert_parallel_requests(contexts, fun) do
    task = Task.async(fun)

    try do
      requests = receive_requests(contexts)

      for {id, from} <- requests do
        GenServer.reply(from, snapshot(id))
      end

      Task.await(task, 1_000)
    after
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end
  end

  defp receive_requests(contexts) do
    requests =
      for _ <- contexts do
        assert_receive {:snapshot_requested, id, from}, 1_000
        {id, from}
      end

    assert Enum.sort(Enum.map(requests, &elem(&1, 0))) == Enum.sort(Enum.map(contexts, & &1.id))
    requests
  end

  defp start_servers(contexts) do
    for context <- contexts do
      {:ok, pid} = SnapshotServer.start_link({context, self()})
      on_exit(fn -> stop_server(pid) end)
    end
  end

  defp stop_server(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  end

  defp contexts do
    for {id, name} <- [{"snapshot-one", "One"}, {"snapshot-two", "Two"}] do
      %{
        id: id,
        name: name,
        root: "/tmp/#{id}",
        settings: %{workspace: %{root: "/tmp/#{id}-worktrees"}, tracker: %{app: %{"workspace_id" => "test"}}}
      }
    end
  end

  defp snapshot(id) do
    number = if id == "snapshot-one", do: 1, else: 2

    %{
      running: [%{identifier: "PRO-#{number}", workspace_path: "/tmp/workspace-#{number}"}],
      retrying: [],
      idle_shutdown_ms: 0,
      last_activity_at_ms: System.monotonic_time(:millisecond),
      codex_totals: %{input_tokens: number},
      rate_limits: nil
    }
  end
end
