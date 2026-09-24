defmodule SymphonyElixir.Yolo.Delivery do
  @moduledoc "Durable per-member dispatch receipts, independent of group membership and model completion."
  alias SymphonyElixir.Linear.IssueLease
  alias SymphonyElixir.Yolo.{BlockerBrake, Observation, Store}
  alias SymphonyElixir.Yolo.OpenClaw.Journal

  @doc "Carry forward provably unchanged completed observations from the earlier group journal."
  @spec migrate(map(), map()) :: map()
  def migrate(record, observations) do
    previous = record["observations"] || %{}
    record = preserve_source_versions(record, previous)

    if record["processed"] == Observation.fingerprint(previous) do
      decisions =
        for {id, old} <- previous,
            is_nil(old["source"]),
            current = observations[id],
            is_map(current) and current["legacy_semantic"] == old["semantic"],
            into: record["decisions"] || %{},
            do: {id, current["semantic"]}

      Map.put(record, "decisions", decisions)
    else
      record
    end
  end

  defp preserve_source_versions(record, previous) do
    record
    |> Map.put("completed_versions", source_versions(record, previous, "completed_sources", "completed_versions"))
    |> Map.put("decision_versions", source_versions(record, previous, "decision_sources", "decision_versions"))
  end

  defp source_versions(record, previous, sources_key, versions_key) do
    Enum.reduce(record[sources_key] || %{}, record[versions_key] || %{}, fn {id, source}, versions ->
      case previous[id] do
        %{"source" => ^source, "member_semantic" => version} when is_binary(version) -> Map.put_new(versions, id, version)
        _ -> versions
      end
    end)
  end

  @spec reconcile(String.t()) :: :ok | {:error, term()}
  def reconcile(group) do
    case Journal.read(group) do
      {:ok, %{"state" => "rejected", "id" => id} = order} ->
        reconcile_rejected(group, id, order)

      {:ok, %{"state" => "retired", "id" => id, "retirement" => %{"kind" => "fenced_interruption"} = proof}} ->
        interrupted(group, id, proof)

      {:ok, %{"state" => "completed", "id" => id}} ->
        completed_session(group, id)

      {:ok, %{"state" => state, "id" => id, "terminal" => terminal, "execution_observed" => true}}
      when state in ["failed", "cancelled"] and is_map(terminal) ->
        completed_session(group, id)

      {:ok, _} ->
        :ok

      error ->
        error
    end
  end

  defp reconcile_rejected("blocker" = group, run_id, order) do
    members = order["members"]

    if is_list(members) and Enum.all?(members, &(is_map(&1) and is_binary(&1["id"]))) do
      issues = Enum.map(members, &%{id: &1["id"]})

      with :ok <- BlockerBrake.release(issues, run_id), do: rejected(group, run_id)
    else
      {:error, :openclaw_journal_corrupt}
    end
  end

  defp reconcile_rejected(group, run_id, _order), do: rejected(group, run_id)

  defp completed_session(group, id) do
    update(group, fn record ->
      case record["attempt"] do
        %{"id" => ^id} = attempt ->
          record
          |> Map.put("attempt", Map.put(attempt, "session_end", true))
          |> Map.update("delivery_ends", %{id => true}, &Map.put(&1, id, true))

        _ ->
          record
      end
    end)
  end

  defp interrupted("blocker" = group, run_id, %{"attempt" => %{"id" => run_id} = attempt, "deliveries" => original})
       when is_map(original) do
    reconcile_interrupted(group, run_id, attempt, original)
  end

  defp interrupted("blocker", _run_id, _proof), do: {:error, :openclaw_journal_corrupt}

  defp interrupted(group, run_id, %{"attempt" => %{"id" => attempt_id} = attempt, "deliveries" => original})
       when is_binary(attempt_id) and is_map(original) do
    reconcile_interrupted(group, run_id, attempt, original)
  end

  defp interrupted(_group, _run_id, _proof), do: {:error, :openclaw_journal_corrupt}

  defp reconcile_interrupted(group, run_id, attempt, original) do
    IssueLease.with_journal_lock(Store.path(group) <> ".completion", fn ->
      with {:ok, record} <- Store.read(group), do: release_interrupted(group, run_id, attempt, original, record)
    end)
  end

  defp release_interrupted(group, run_id, attempt, original, record) do
    completed = attempt["completed"] || %{}

    # Keep completed decisions suppressed; only unfinished deliveries of this
    # generation can be scheduled again. Newer receipts survive.
    {released, deliveries} =
      Enum.split_with(record["deliveries"] || %{}, fn {id, receipt} ->
        matching_generation?(group, receipt, original, id, run_id) and not is_binary(completed[id])
      end)

    issues = if group == "blocker", do: Enum.map(released, fn {id, _} -> %{id: id} end), else: []

    with :ok <- BlockerBrake.release(issues, run_id) do
      updated =
        record
        |> Map.put("deliveries", Map.new(deliveries))
        |> Map.update("delivery_ends", %{attempt["id"] => true}, &Map.put(&1, attempt["id"], true))

      Store.write(group, updated)
    end
  end

  defp matching_generation?("blocker", receipt, original, id, run_id), do: receipt["run_id"] == run_id and receipt == original[id]
  defp matching_generation?(_group, receipt, original, id, _run_id), do: receipt == original[id]

  @spec pending([map()], map(), map()) :: [map()]
  def pending(members, observations, record) do
    if record["processed"] == Observation.fingerprint(observations) or unresolved_delivery?(members, record) do
      []
    else
      Enum.reject(members, &skip_member?(&1, observations, record))
    end
  end

  @spec waiting_reason([map()], map(), map()) :: String.t()
  def waiting_reason(members, observations, record) do
    cond do
      unresolved_delivery?(members, record) -> "delivery_end_unconfirmed"
      record["processed"] == Observation.fingerprint(observations) -> "already_processed"
      Enum.any?(members, &same_open_delivery?(&1, observations, record)) -> "awaiting_new_impulse"
      true -> "already_decided"
    end
  end

  defp unresolved_delivery?(members, record) do
    Enum.any?(members, fn issue ->
      case get_in(record, ["deliveries", issue.id]) do
        %{"run_id" => run_id} -> not ended?(record, run_id)
        _ -> false
      end
    end)
  end

  defp same_open_delivery?(issue, observations, record) do
    observation = observations[issue.id]
    semantic = observation["semantic"]
    receipt = get_in(record, ["deliveries", issue.id])
    is_map(receipt) and receipt["semantic"] == semantic and not decided?(record, issue.id, observation)
  end

  defp skip_member?(issue, observations, record) do
    observation = observations[issue.id]
    semantic = observation["semantic"]
    receipt = get_in(record, ["deliveries", issue.id])

    decided?(record, issue.id, observation) or
      (is_map(receipt) and (receipt["semantic"] == semantic or not ended?(record, receipt["run_id"])))
  end

  defp decided?(record, id, observation) do
    previous = get_in(record, ["observations", id])
    decided = get_in(record, ["decisions", id])

    decided == observation["semantic"] or same_source_decided?(record, id, observation, previous, decided)
  end

  defp same_source_decided?(record, id, observation, previous, decided) do
    source = observation["source"]
    version = observation["member_semantic"]

    source_receipt?(record, id, source, version, previous, "decision") or
      source_receipt?(record, id, source, version, previous, "completed") or
      prior_attempt_decided?(record, id, source, version, previous, decided)
  end

  defp source_receipt?(record, id, source, version, previous, kind) do
    stored_version = get_in(record, ["#{kind}_versions", id]) || (previous && previous["member_semantic"])
    is_binary(source) and stored_version == version and get_in(record, ["#{kind}_sources", id]) == source
  end

  defp prior_attempt_decided?(record, id, source, version, previous, decided) do
    is_binary(source) and is_map(previous) and previous["member_semantic"] == version and previous["source"] == source and
      (is_binary(get_in(record, ["attempt", "completed", id])) or decided == previous["semantic"])
  end

  defp ended?(record, run_id) do
    get_in(record, ["delivery_ends", run_id]) == true or
      (get_in(record, ["attempt", "id"]) == run_id and get_in(record, ["attempt", "session_end"]) == true)
  end

  @spec reserve(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def reserve(group, run_id, observations) do
    update(group, fn record ->
      receipts = Map.new(observations, fn {id, observation} -> {id, %{"semantic" => observation["semantic"], "run_id" => run_id}} end)
      Map.put(record, "deliveries", Map.merge(record["deliveries"] || %{}, receipts))
    end)
  end

  @spec rejected(String.t(), String.t()) :: :ok | {:error, term()}
  def rejected(group, run_id) do
    update(group, fn record ->
      Map.update(record, "deliveries", %{}, &Map.reject(&1, fn {_, receipt} -> receipt["run_id"] == run_id end))
    end)
  end

  defp update(group, fun) do
    IssueLease.with_journal_lock(Store.path(group) <> ".completion", fn ->
      with {:ok, record} <- Store.read(group), do: Store.write(group, fun.(record))
    end)
  end
end
