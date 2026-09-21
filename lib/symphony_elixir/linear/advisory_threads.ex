defmodule SymphonyElixir.Linear.AdvisoryThreads do
  @moduledoc "Durable, text-free thread eligibility before coding input and baseline delivery."

  alias SymphonyElixir.Linear.CommentVersion

  @spec observe(map(), [map()], keyword()) :: map()
  def observe(state, comments, opts) do
    agents = Keyword.get(opts, :advisory_agent_ids, [])

    if agents == [] do
      state
    else
      issue = state["binding"]["issue_id"]
      previous = Map.get(state, "advisory_threads", %{})
      # Old sources are inspected on activation, without changing source keys or acknowledgements.
      old = state["versions"] |> Map.values() |> Enum.map(& &1["source"]) |> Enum.reject(&Map.has_key?(previous, &1["id"]))
      records = ingest(previous, old ++ Enum.map(comments, &CommentVersion.raw/1), agents, issue)
      records = resolve(records, agents, issue, opts)
      decisions = Map.new(records, fn {id, _} -> {id, decision(id, records, MapSet.new())} end)

      records = Map.new(records, fn {id, record} -> {id, Map.put(record, "decision", decisions[id])} end)
      Map.put(state, "advisory_threads", records)
    end
  end

  @spec eligible?(map(), map()) :: boolean()
  def eligible?(state, source), do: get_in(state, ["advisory_threads", source["id"], "decision"]) in [nil, "regular"]

  @spec valid_state?(map()) :: boolean()
  def valid_state?(state) do
    records = Map.get(state, "advisory_threads", %{})
    is_map(records) and Enum.all?(records, &valid_record?/1)
  end

  defp valid_record?({id, %{"parents" => parents, "decision" => decision} = record}) do
    is_binary(id) and is_list(parents) and Enum.all?(parents, &is_binary/1) and
      decision in ["regular", "held", "excluded"] and (is_nil(record["retry_at"]) or is_integer(record["retry_at"]))
  end

  defp valid_record?(_), do: false

  @spec unresolved?(map()) :: boolean()
  def unresolved?(state), do: Enum.any?(Map.get(state, "advisory_threads", %{}), fn {_, record} -> record["decision"] == "held" end)

  @spec diagnostics(map()) :: [map()]
  def diagnostics(state) do
    state
    |> Map.get("advisory_threads", %{})
    |> Enum.reject(fn {_, record} -> record["decision"] == "regular" end)
    |> Enum.map(fn {id, record} -> %{"comment_id" => id, "status" => record["decision"], "previously_delivered" => previously_delivered?(state, id)} end)
    |> Enum.sort_by(& &1["comment_id"])
  end

  defp previously_delivered?(state, id) do
    baseline = state["baseline"] || %{}
    baseline_ids = Map.get(baseline, "delivered_source_ids", Enum.map(baseline["sources"] || [], & &1["id"]))

    (baseline["status"] in ["delivered", "processed"] and id in baseline_ids) or
      Enum.any?(state["versions"], fn {_, version} -> version["source"]["id"] == id and version["status"] in ["delivered", "processed"] end)
  end

  defp ingest(records, sources, agents, issue) do
    records = Enum.reduce(sources, records, &link_parents/2)

    Enum.reduce(sources, records, fn source, acc ->
      id = source["id"]
      previous = Map.get(acc, id, %{})
      sessions = sessions(source)
      valid = Enum.filter(sessions, &bound_session?(&1, source, issue, records))
      candidate = previous["candidate"] == true or candidate?(source, agents)
      excluded = Enum.any?(valid, &(get_in(&1, ["appUser", "id"]) in agents))
      proven = valid != [] and length(valid) == length(sessions) and source["advisoryIncomplete"] != true

      record = %{
        "parents" => Enum.uniq(List.wrap(previous["parents"]) ++ List.wrap(source["parentId"])),
        "candidate" => candidate,
        "targeted" => previous["targeted"] == true or targeted?(source, agents),
        "excluded" => previous["excluded"] == true or previous["decision"] == "excluded" or excluded,
        "unclear" => not complete?(source, issue) or length(valid) != length(sessions) or source["advisoryIncomplete"] == true,
        "proven" => proven,
        "retry_at" => previous["retry_at"]
      }

      acc = Map.put(acc, id, record)
      Enum.reduce(valid, acc, &bind_session(&1, &2, agents))
    end)
  end

  defp link_parents(source, records) do
    previous = records[source["id"]] || %{}
    parents = Enum.uniq(List.wrap(previous["parents"]) ++ List.wrap(source["parentId"]))
    Map.put(records, source["id"], Map.put(previous, "parents", parents))
  end

  defp bind_session(session, records, agents) do
    if get_in(session, ["appUser", "id"]) in agents do
      Enum.reduce([get_in(session, ["comment", "id"]), get_in(session, ["sourceComment", "id"])], records, fn
        nil, acc -> acc
        id, acc -> Map.update(acc, id, %{"excluded" => true, "parents" => []}, &Map.put(&1, "excluded", true))
      end)
    else
      records
    end
  end

  defp sessions(source) do
    List.wrap(source["agentSession"]) ++
      List.wrap(get_in(source, ["agentSessions", "nodes"])) ++
      List.wrap(get_in(source, ["spawnedAgentSessions", "nodes"]))
  end

  defp bound_session?(session, source, issue, records) when is_map(session) do
    root = get_in(session, ["comment", "id"])
    trigger = get_in(session, ["sourceComment", "id"])

    is_binary(session["id"]) and is_binary(get_in(session, ["appUser", "id"])) and
      get_in(session, ["issue", "id"]) == issue and is_binary(root) and
      (source["id"] == trigger or connected?(source["id"], root, records, MapSet.new())) and
      get_in(source, ["issue", "id"]) == issue and
      reference_in_issue?(session["comment"], issue) and reference_in_issue?(session["sourceComment"], issue)
  end

  defp bound_session?(_, _, _, _), do: false

  defp connected?(id, id, _records, _seen), do: true

  defp connected?(id, root, records, seen) do
    if MapSet.member?(seen, id) or MapSet.size(seen) >= 128 do
      false
    else
      Enum.any?(get_in(records, [id, "parents"]) || [], &connected?(&1, root, records, MapSet.put(seen, id)))
    end
  end

  defp reference_in_issue?(nil, _), do: true
  defp reference_in_issue?(reference, issue), do: get_in(reference, ["issue", "id"]) == issue

  defp complete?(source, issue) do
    Map.has_key?(source, "agentSession") and is_boolean(source["isArtificialAgentSessionRoot"]) and
      Map.has_key?(source, "bodyData") and get_in(source, ["issue", "id"]) == issue and valid_body_data?(source["bodyData"])
  end

  defp valid_body_data?(value) when is_binary(value), do: match?({:ok, _}, Jason.decode(value))
  defp valid_body_data?(value), do: is_nil(value) or is_map(value) or is_list(value)

  defp candidate?(source, agents) do
    source["isArtificialAgentSessionRoot"] == true or sessions(source) != [] or targeted?(source, agents)
  end

  defp targeted?(source, agents) do
    mentioned?(decode(source["bodyData"]), agents) or
      Enum.any?(sessions(source), fn session -> is_map(session) and get_in(session, ["appUser", "id"]) in agents end)
  end

  defp decode(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  defp decode(value), do: value

  defp mentioned?(value, agents) when is_map(value) do
    attrs = if is_map(value["attrs"]), do: value["attrs"], else: %{}
    mention = value["type"] in ["mention", "userMention"] and (attrs["id"] in agents or attrs["userId"] in agents)
    mention or Enum.any?(Map.values(value), &mentioned?(&1, agents))
  end

  defp mentioned?(value, agents) when is_list(value), do: Enum.any?(value, &mentioned?(&1, agents))
  defp mentioned?(_, _), do: false

  defp decision(id, records, visited) do
    record = records[id]

    cond do
      is_nil(record) -> "held"
      record["excluded"] == true -> "excluded"
      MapSet.member?(visited, id) -> "held"
      MapSet.size(visited) >= 128 -> "held"
      true -> inherited(record, records, MapSet.put(visited, id))
    end
  end

  defp inherited(record, records, visited) do
    parents = Enum.map(record["parents"] || [], &decision(&1, records, visited))

    cond do
      "excluded" in parents -> "excluded"
      "held" in parents or record["unclear"] == true -> "held"
      record["targeted"] == true or (record["candidate"] == true and record["proven"] != true) -> "held"
      true -> "regular"
    end
  end

  defp resolve(records, agents, issue, opts) do
    fetch = Keyword.get(opts, :resolve_advisory, fn _ -> {:error, :advisory_resolution_unavailable} end)
    now = Keyword.get(opts, :advisory_now, System.system_time(:millisecond))
    resolve(records, agents, issue, fetch, now, MapSet.new(), 8)
  end

  defp resolve(records, _agents, _issue, _fetch, _now, _seen, 0), do: records

  defp resolve(records, agents, issue, fetch, now, seen, budget) do
    ids = Map.keys(records) ++ Enum.flat_map(Map.values(records), &(&1["parents"] || []))
    id = ids |> Enum.uniq() |> Enum.sort() |> Enum.find(&resolution_due?(&1, records, seen, now))

    if id do
      records = Map.update(records, id, %{"parents" => [], "unclear" => true, "retry_at" => now + 30_000}, &Map.put(&1, "retry_at", now + 30_000))

      case fetch.(id) do
        {:ok, %{"id" => ^id} = source} -> resolve(ingest(records, [source], agents, issue), agents, issue, fetch, now, MapSet.put(seen, id), budget - 1)
        _ -> resolve(records, agents, issue, fetch, now, MapSet.put(seen, id), budget - 1)
      end
    else
      records
    end
  end

  defp resolution_due?(id, records, seen, now) do
    record = records[id] || %{}

    not MapSet.member?(seen, id) and (record["retry_at"] || 0) <= now and
      decision(id, records, MapSet.new()) == "held" and
      (is_nil(records[id]) or record["candidate"] == true or record["unclear"] == true)
  end
end
