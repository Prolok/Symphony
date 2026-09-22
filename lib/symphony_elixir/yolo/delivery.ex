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
      {:ok, %{"state" => "rejected", "id" => id}} -> rejected(group, id)
      {:ok, _} -> :ok
      error -> error
    end
  end

  @spec pending([map()], map(), map()) :: [map()]
  def pending(members, observations, record) do
    if record["processed"] == Observation.fingerprint(observations) do
      []
    else
      Enum.reject(members, fn issue ->
        semantic = observations[issue.id]["semantic"]

        get_in(record, ["deliveries", issue.id, "semantic"]) == semantic or
          get_in(record, ["decisions", issue.id]) == semantic
      end)
    end
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
