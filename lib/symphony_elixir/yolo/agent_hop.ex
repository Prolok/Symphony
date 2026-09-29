defmodule SymphonyElixir.Yolo.AgentHop do
  @moduledoc "Durable rolling limit for agent-triggered PO wakeups."
  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.{DurableState, IssueLease}
  alias SymphonyElixir.Relay.Store, as: Digest

  @window_ms 86_400_000

  @doc "Apply the per-issue limit across PO groups with an atomic durable record."
  @spec gate_durable(map(), map(), keyword()) :: {:ok, map(), MapSet.t()} | {:error, term()}
  def gate_durable(record, observations, opts) do
    case Config.settings!().tracker.trusted_agent_ids do
      [] -> {:ok, record, MapSet.new()}
      _ -> Enum.reduce_while(observations, {:ok, record, MapSet.new()}, &gate_observation(&1, &2, opts))
    end
  end

  defp gate_observation({id, observation}, {:ok, current, blocked}, opts) do
    if gate_needed?(current, id, observation) do
      case gate_one(path(id, opts), id, observation, current, opts) do
        {:ok, entry, true} -> {:cont, {:ok, put_entry(current, id, entry), MapSet.put(blocked, id)}}
        {:ok, entry, false} -> {:cont, {:ok, put_entry(current, id, entry), blocked}}
        {:error, _} = error -> {:halt, error}
      end
    else
      {:cont, {:ok, current, blocked}}
    end
  end

  defp gate_needed?(record, id, observation) do
    previous = get_in(record, ["agent_hops", id])
    impulse = get_in(record, ["impulses", id]) || %{}
    agents = sources(observation, impulse, "agent")
    humans = sources(observation, impulse, "human")

    case previous do
      %{"held" => held} when is_binary(held) ->
        true

      %{"agent_sources" => old_agents, "human_sources" => old_humans} when is_list(old_agents) and is_list(old_humans) ->
        MapSet.new(agents) != MapSet.new(old_agents) or MapSet.new(humans) != MapSet.new(old_humans)

      _ ->
        agents != [] or humans != []
    end
  end

  defp gate_one(path, id, observation, current, opts) do
    IssueLease.with_journal_lock(path, fn ->
      with {:ok, previous} <- read(path, id, current),
           {next, held} <- gate(Map.put(current, "agent_hops", %{id => previous}), %{id => observation}, opts),
           entry = get_in(next, ["agent_hops", id]),
           :ok <- persist_entry(path, previous, entry) do
        {:ok, entry, MapSet.member?(held, id)}
      end
    end)
  end

  defp persist_entry(_path, entry, entry), do: :ok
  defp persist_entry(path, _previous, entry), do: DurableState.write(path, entry)

  defp put_entry(record, id, entry), do: Map.update(record, "agent_hops", %{id => entry}, &Map.put(&1, id, entry))

  defp read(path, id, record) do
    case DurableState.read(path) do
      {:ok, entry} -> {:ok, entry}
      {:error, :enoent} -> {:ok, get_in(record, ["agent_hops", id])}
      error -> error
    end
  end

  defp path(id, opts) do
    tracker = Config.settings!().tracker
    root = Keyword.get(opts, :agent_hop_state_root, tracker.app["state_root"])
    key = Digest.digest({tracker.app["workspace_id"], id})
    Path.join([root, "yolo", "agent-hops", key <> ".json"])
  end

  @spec gate(map(), map(), keyword()) :: {map(), MapSet.t()}
  def gate(record, observations, opts) do
    now = Keyword.get(opts, :agent_hop_now, fn -> System.system_time(:millisecond) end).()
    limit = Config.settings!().tracker.agent_hop_limit

    {states, blocked} =
      Enum.reduce(observations, {record["agent_hops"] || %{}, MapSet.new()}, fn {id, observation}, {states, blocked} ->
        impulse = get_in(record, ["impulses", id]) || %{}
        previous = states[id]
        {entry, stop?} = decide(previous, observation, impulse, now, limit)

        if stop? and (is_nil(previous) or previous["held"] != entry["held"]) do
          Logger.warning("PO agent wake held issue_id=#{id} reason=agent_hop_limit until_ms=#{entry["due_at"]}")
        end

        {Map.put(states, id, entry), if(stop?, do: MapSet.put(blocked, id), else: blocked)}
      end)

    {Map.put(record, "agent_hops", states), blocked}
  end

  defp decide(nil, observation, impulse, now, _limit) do
    key = observation["member_semantic"] || observation["source"]
    agent_only? = sources(observation, impulse, "agent") != [] and sources(observation, impulse, "human") == []
    events = if agent_only?, do: %{key => now}, else: %{}
    {cursor(observation, impulse, %{"events" => events, "seen" => events, "held" => nil, "due_at" => nil}), false}
  end

  defp decide(previous, observation, impulse, now, limit) do
    agents = sources(observation, impulse, "agent")
    humans = sources(observation, impulse, "human")
    agent_changed? = new_sources?(agents, previous["agent_sources"] || [])
    human_changed? = new_sources?(humans, previous["human_sources"] || [])
    key = observation["member_semantic"] || observation["source"]
    events = Map.filter(previous["events"] || %{}, fn {_key, at} -> is_integer(at) and at > now - @window_ms end)
    seen = previous["seen"] || %{}
    held? = is_binary(previous["held"])
    candidate? = not human_changed? and (agent_changed? or held?)
    {events, seen, held, due_at, stop?} = candidate_decision(candidate?, held?, events, seen, key, now, limit)

    entry = cursor(observation, impulse, previous)
    entry = %{entry | "events" => events, "seen" => seen, "held" => held, "due_at" => due_at}
    {limit_evidence(entry, previous, key, due_at, now, stop?), stop?}
  end

  defp limit_evidence(entry, _previous, _key, _due_at, _now, false), do: entry

  defp limit_evidence(entry, previous, key, due_at, now, true) do
    old = previous["last_limit"]
    evidence = if is_map(old) and old["key"] == key, do: old, else: %{"reason" => "agent_hop_limit", "key" => key, "at" => now, "due_at" => due_at}
    Map.put(entry, "last_limit", evidence)
  end

  defp candidate_decision(false, _held?, events, seen, _key, _now, _limit), do: {events, seen, nil, nil, false}

  defp candidate_decision(true, held?, events, seen, key, now, limit) do
    cond do
      Map.has_key?(seen, key) and not held? -> {events, seen, nil, nil, false}
      map_size(events) < limit -> {Map.put(events, key, now), Map.put(seen, key, now), nil, nil, false}
      true -> {events, seen, key, Enum.min(Map.values(events)) + @window_ms, true}
    end
  end

  defp cursor(observation, impulse, entry) do
    Map.merge(entry, %{
      "agent_sources" => sources(observation, impulse, "agent"),
      "human_sources" => sources(observation, impulse, "human")
    })
  end

  defp sources(observation, impulse, "agent"), do: Enum.uniq((observation["agent_sources"] || []) ++ (impulse["agent_input_ids"] || []))
  defp sources(observation, impulse, "human"), do: Enum.uniq((observation["human_sources"] || []) ++ (impulse["human_input_ids"] || []))
  defp new_sources?(current, previous), do: Enum.any?(current, &(&1 not in previous))
end
