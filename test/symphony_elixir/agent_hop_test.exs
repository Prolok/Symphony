defmodule SymphonyElixir.AgentHopTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Linear.DurableState
  alias SymphonyElixir.Linear.IssueLease
  alias SymphonyElixir.ProjectContext
  alias SymphonyElixir.Relay.Store, as: Digest
  alias SymphonyElixir.Yolo.AgentHop

  setup do
    settings = Config.settings!()
    tracker = %{settings.tracker | trusted_agent_ids: ["trusted-agent"]}
    ProjectContext.bind(%ProjectContext{settings: %{settings | tracker: tracker}})
    :ok
  end

  test "limits ten agent wakes per issue, holds the next, and releases on human input or window expiry" do
    baseline = observation("base", [], [])
    {record, blocked} = AgentHop.gate(%{}, %{"issue" => baseline}, agent_hop_now: fn -> 1_000 end)
    assert MapSet.size(blocked) == 0

    record =
      Enum.reduce(1..10, record, fn n, prior ->
        current = observation("agent-#{n}", Enum.map(1..n, &"input-#{&1}"), [])
        {next, blocked} = AgentHop.gate(prior, %{"issue" => current}, agent_hop_now: fn -> 1_000 + n end)
        assert MapSet.size(blocked) == 0
        next
      end)

    held = observation("agent-11", Enum.map(1..11, &"input-#{&1}"), [])
    {record, blocked} = AgentHop.gate(record, %{"issue" => held}, agent_hop_now: fn -> 2_000 end)
    assert MapSet.member?(blocked, "issue")
    assert get_in(record, ["agent_hops", "issue", "held"]) == "agent-11"
    assert get_in(record, ["agent_hops", "issue", "last_limit", "reason"]) == "agent_hop_limit"

    restarted = Jason.decode!(Jason.encode!(record))
    {replayed, blocked} = AgentHop.gate(restarted, %{"issue" => held}, agent_hop_now: fn -> 2_001 end)
    assert MapSet.member?(blocked, "issue")
    assert map_size(get_in(replayed, ["agent_hops", "issue", "events"])) == 10

    unrelated = observation("unrelated-field", held["agent_sources"], [])
    {replayed, blocked} = AgentHop.gate(replayed, %{"issue" => unrelated}, agent_hop_now: fn -> 2_001 end)
    assert MapSet.member?(blocked, "issue")

    human = observation("human-release", held["agent_sources"], ["human-1"])
    {released, blocked} = AgentHop.gate(replayed, %{"issue" => human}, agent_hop_now: fn -> 2_002 end)
    assert MapSet.size(blocked) == 0
    assert get_in(released, ["agent_hops", "issue", "held"]) == nil

    later = observation("agent-12", held["agent_sources"] ++ ["input-12"], ["human-1"])
    {held_again, blocked} = AgentHop.gate(released, %{"issue" => later}, agent_hop_now: fn -> 2_003 end)
    assert MapSet.member?(blocked, "issue")
    {after_window, blocked} = AgentHop.gate(held_again, %{"issue" => later}, agent_hop_now: fn -> 86_402_000 end)
    assert MapSet.size(blocked) == 0
    assert get_in(after_window, ["agent_hops", "issue", "held"]) == nil
    {replay, blocked} = AgentHop.gate(after_window, %{"issue" => later}, agent_hop_now: fn -> 86_402_001 end)
    assert MapSet.size(blocked) == 0
    assert map_size(get_in(replay, ["agent_hops", "issue", "seen"])) == 11
  end

  test "the same issue shares its durable counter across PO groups and process restarts" do
    root = Path.join(System.tmp_dir!(), "agent-hops-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    opts = [agent_hop_state_root: root, agent_hop_now: fn -> 10_000 end]
    assert {:ok, _, blocked} = AgentHop.gate_durable(%{}, %{"shared" => observation("base", [], [])}, opts)
    assert MapSet.size(blocked) == 0

    for n <- 1..10 do
      current = observation("wake-#{n}", Enum.map(1..n, &"input-#{&1}"), [])
      assert {:ok, _, blocked} = AgentHop.gate_durable(%{}, %{"shared" => current}, opts)
      assert MapSet.size(blocked) == 0
    end

    held = observation("wake-11", Enum.map(1..11, &"input-#{&1}"), [])
    assert {:ok, held_record, blocked} = AgentHop.gate_durable(%{}, %{"shared" => held}, opts)
    assert MapSet.member?(blocked, "shared")
    assert {:ok, _, blocked} = AgentHop.gate_durable(%{}, %{"shared" => held}, opts)
    assert MapSet.member?(blocked, "shared")
    assert {:ok, _, blocked} = AgentHop.gate_durable(held_record, %{"shared" => held}, opts)
    assert MapSet.member?(blocked, "shared")
    later = Keyword.put(opts, :agent_hop_now, fn -> 86_410_001 end)
    assert {:ok, released, blocked} = AgentHop.gate_durable(held_record, %{"shared" => held}, later)
    assert MapSet.size(blocked) == 0
    assert get_in(released, ["agent_hops", "shared", "held"]) == nil
  end

  test "corrupt counters stop agent wake processing" do
    root = Path.join(System.tmp_dir!(), "agent-hops-failure-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    workspace = Config.settings!().tracker.app["workspace_id"]
    key = Digest.digest({workspace, "shared"})
    state_path = Path.join([root, "yolo", "agent-hops", key <> ".json"])
    File.mkdir_p!(Path.dirname(state_path))
    File.write!(state_path, "invalid JSON")

    assert {:error, :runtime_state_corrupt} =
             AgentHop.gate_durable(%{}, %{"shared" => observation("wake", ["agent-input"], [])}, agent_hop_state_root: root)
  end

  test "unchanged source sets avoid locks while a new agent source counts once" do
    root = Path.join(System.tmp_dir!(), "agent-hops-idle-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    opts = [agent_hop_state_root: root, agent_hop_now: fn -> 10_000 end]
    initial = observation("base", ["agent-1"], [])
    assert {:ok, record, blocked} = AgentHop.gate_durable(%{}, %{"issue" => initial}, opts)
    assert MapSet.size(blocked) == 0
    assert map_size(get_in(record, ["agent_hops", "issue", "events"])) == 1

    {_, paths} =
      journal_lock_paths(fn ->
        for _ <- 1..3 do
          assert {:ok, ^record, blocked} = AgentHop.gate_durable(record, %{"issue" => %{initial | "agent_sources" => ["agent-1", "agent-1"]}}, opts)
          assert MapSet.size(blocked) == 0
        end
      end)

    assert paths == []

    next = observation("agent-2", ["agent-2", "agent-1"], [])
    {{:ok, updated, blocked}, paths} = journal_lock_paths(fn -> AgentHop.gate_durable(record, %{"issue" => next}, opts) end)
    assert length(paths) == 1
    assert MapSet.size(blocked) == 0
    assert map_size(get_in(updated, ["agent_hops", "issue", "events"])) == 2
    replay = fn -> AgentHop.gate_durable(updated, %{"issue" => next}, opts) end
    {{:ok, ^updated, blocked}, paths} = journal_lock_paths(replay)
    assert paths == []
    assert MapSet.size(blocked) == 0

    with_human = Map.put(updated, "impulses", %{"issue" => %{"human_input_ids" => ["human-1"]}})
    human_change = fn -> AgentHop.gate_durable(with_human, %{"issue" => next}, opts) end
    {{:ok, after_human, blocked}, paths} = journal_lock_paths(human_change)
    assert length(paths) == 1
    assert MapSet.size(blocked) == 0
    human_replay = fn -> AgentHop.gate_durable(after_human, %{"issue" => next}, opts) end
    {{:ok, ^after_human, _}, paths} = journal_lock_paths(human_replay)
    assert paths == []
  end

  test "empty trust list preserves an existing durable counter and cursor" do
    root = Path.join(System.tmp_dir!(), "agent-hops-disabled-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    opts = [agent_hop_state_root: root, agent_hop_now: fn -> 10_000 end]
    assert {:ok, record, _} = AgentHop.gate_durable(%{}, %{"issue" => observation("first", ["agent-1"], [])}, opts)
    [path] = Path.wildcard(Path.join([root, "yolo", "agent-hops", "*.json"]))
    original = File.read!(path)
    context = ProjectContext.current()
    tracker = %{context.settings.tracker | trusted_agent_ids: []}
    ProjectContext.bind(%{context | settings: %{context.settings | tracker: tracker}})

    {{:ok, ^record, blocked}, paths} =
      journal_lock_paths(
        fn ->
          AgentHop.gate_durable(record, %{"issue" => observation("second", ["agent-1", "agent-2"], [])}, opts)
        end,
        true
      )

    assert paths == []
    assert MapSet.size(blocked) == 0
    assert File.read!(path) == original
  end

  defp journal_lock_paths(fun, trace_state \\ false) do
    tracer = spawn(fn -> collect_lock_paths([]) end)
    :erlang.trace_pattern({IssueLease, :with_journal_lock, 2}, true, [:local])

    if trace_state do
      :erlang.trace_pattern({DurableState, :read, 1}, true, [:local])
      :erlang.trace_pattern({DurableState, :write, 2}, true, [:local])
    end

    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      result = fun.()
      send(tracer, {:flush, self()})

      paths =
        receive do
          {:journal_lock_paths, paths} -> paths
        after
          1_000 -> flunk("journal lock trace was not delivered")
        end

      {result, paths}
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({IssueLease, :with_journal_lock, 2}, false, [:local])

      if trace_state do
        :erlang.trace_pattern({DurableState, :read, 1}, false, [:local])
        :erlang.trace_pattern({DurableState, :write, 2}, false, [:local])
      end

      send(tracer, :stop)
    end
  end

  defp collect_lock_paths(paths) do
    receive do
      {:trace, _, :call, {IssueLease, :with_journal_lock, [path | _]}} ->
        collect_lock_paths([path | paths])

      {:trace, _, :call, {DurableState, operation, [path | _]}} when operation in [:read, :write] ->
        collect_lock_paths([path | paths])

      {:flush, parent} ->
        send(parent, {:journal_lock_paths, Enum.reverse(paths)})

      :stop ->
        :ok

      _ ->
        collect_lock_paths(paths)
    end
  end

  defp observation(key, agents, humans), do: %{"source" => key, "member_semantic" => key, "agent_sources" => agents, "human_sources" => humans}
end
