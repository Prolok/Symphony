defmodule SymphonyElixir.Yolo.Delivery do
  @moduledoc "Durable per-member dispatch receipts, independent of group membership and model completion."
  alias SymphonyElixir.Linear.IssueLease
  alias SymphonyElixir.Yolo.{Observation, Store}
  alias SymphonyElixir.Yolo.OpenClaw.Journal

  @doc "Carry forward provably unchanged completed observations from the earlier group journal."
  @spec migrate(map(), map()) :: map()
  def migrate(record, observations) do
    previous = record["observations"] || %{}

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

  @spec reconcile(String.t()) :: :ok | {:error, term()}
  def reconcile(group) do
    case Journal.read(group) do
      {:ok, %{"state" => "rejected", "id" => id}} ->
        rejected(group, id)

      {:ok, %{"state" => "retired", "retirement" => %{"kind" => "fenced_interruption"} = proof}} ->
        interrupted(group, proof)

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

  defp interrupted(group, proof) do
    update(group, fn record ->
      completed = proof["attempt"]["completed"] || %{}

      # Keep completed decisions suppressed; only the unfinished deliveries of
      # this exact generation can be scheduled again. Newer receipts survive.
      deliveries =
        Map.reject(record["deliveries"] || %{}, fn {id, receipt} ->
          receipt == proof["deliveries"][id] and not is_binary(completed[id])
        end)

      record
      |> Map.put("deliveries", deliveries)
      |> Map.update("delivery_ends", %{proof["attempt"]["id"] => true}, &Map.put(&1, proof["attempt"]["id"], true))
    end)
  end

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
    semantic = observations[issue.id]["semantic"]
    source = observations[issue.id]["source"]
    receipt = get_in(record, ["deliveries", issue.id])
    is_map(receipt) and receipt["semantic"] == semantic and not decided?(record, issue.id, semantic, source)
  end

  defp skip_member?(issue, observations, record) do
    semantic = observations[issue.id]["semantic"]
    source = observations[issue.id]["source"]
    receipt = get_in(record, ["deliveries", issue.id])

    decided?(record, issue.id, semantic, source) or
      (is_map(receipt) and (receipt["semantic"] == semantic or not ended?(record, receipt["run_id"])))
  end

  defp decided?(record, id, semantic, source) do
    previous = get_in(record, ["observations", id])
    decided = get_in(record, ["decisions", id])

    decided == semantic or same_source_decided?(record, id, source, previous, decided)
  end

  defp same_source_decided?(_record, _id, source, _previous, _decided) when not is_binary(source), do: false

  defp same_source_decided?(record, id, source, previous, decided) do
    get_in(record, ["decision_sources", id]) == source or
      get_in(record, ["completed_sources", id]) == source or
      (is_map(previous) and previous["source"] == source and
         (is_binary(get_in(record, ["attempt", "completed", id])) or decided == previous["semantic"]))
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
