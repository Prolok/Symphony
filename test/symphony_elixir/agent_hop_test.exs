defmodule SymphonyElixir.AgentHopTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Relay.Store, as: Digest
  alias SymphonyElixir.Yolo.AgentHop

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
    assert {:ok, _, blocked} = AgentHop.gate_durable(%{}, %{"shared" => held}, opts)
    assert MapSet.member?(blocked, "shared")
    assert {:ok, _, blocked} = AgentHop.gate_durable(%{}, %{"shared" => held}, opts)
    assert MapSet.member?(blocked, "shared")
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

  defp observation(key, agents, humans), do: %{"source" => key, "member_semantic" => key, "agent_sources" => agents, "human_sources" => humans}
end
