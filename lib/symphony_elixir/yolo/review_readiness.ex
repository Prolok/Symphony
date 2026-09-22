defmodule SymphonyElixir.Yolo.ReviewReadiness do
  @moduledoc "Durable per-member dependency releases, separate from a running group's frozen observations."
  alias SymphonyElixir.Yolo.{Admission, Dependencies, Group, Store}

  @key "review-readiness"

  @spec observe([map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def observe(issues) do
    Store.lock(@key, fn -> observe_locked(issues) end)
  end

  defp observe_locked(issues) do
    with {:ok, record} <- read() do
      members = observe_members(issues, Map.get(record, "members", %{}))
      update(record, Enum.any?(issues, &Group.expected?/1), members)
    end
  end

  defp observe_members(issues, previous) do
    ready = MapSet.new(Dependencies.review_members(issues), & &1.id)

    issues
    |> Enum.filter(&(not is_nil(member_key(&1)) and Admission.eligible?(&1)))
    |> Enum.reduce(previous, fn issue, members ->
      key = member_key(issue)
      old = Map.get(members, key, %{"ready" => true, "generation" => 0})
      available = if issue.state == "Yolo Review", do: MapSet.member?(ready, issue.id), else: issue.state != "Backlog" or Dependencies.unblocked?(issue)
      generation = old["generation"] + if(not old["ready"] and available, do: 1, else: 0)
      Map.put(members, key, %{"ready" => available, "generation" => generation})
    end)
  end

  defp member_key(%{state: "Yolo Review", id: id}), do: "review:" <> id
  defp member_key(%{state: state, id: id}) when state in ["Backlog", "Todo", "Definiert"], do: "incoming:" <> id
  defp member_key(_), do: nil

  @doc "Observed blocking/release cycles remain new work even if the final dependency snapshot repeats."
  @spec generations([map()]) :: {:ok, map()} | {:error, term()}
  def generations(issues) do
    with {:ok, record} <- read() do
      {:ok, Map.new(issues, &{&1.id, get_in(record, ["members", member_key(&1), "generation"]) || 0})}
    end
  end

  defp update(record, waiting, members) do
    epoch = Map.get(record, "epoch", 0)
    next_epoch = epoch + if(waiting == Map.get(record, "waiting", false), do: 0, else: 1)

    if next_epoch == epoch and members == Map.get(record, "members", %{}) do
      {:ok, epoch}
    else
      with :ok <- Store.write(@key, Map.merge(record, %{"waiting" => waiting, "epoch" => next_epoch, "members" => members})), do: {:ok, next_epoch}
    end
  end

  @spec epoch(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def epoch("review") do
    with {:ok, record} <- read(), do: {:ok, Map.get(record, "epoch", 0)}
  end

  def epoch(_), do: {:ok, 0}

  defp read do
    with {:ok, record} <- Store.read(@key),
         epoch = Map.get(record, "epoch", 0),
         true <- is_integer(epoch) and epoch >= 0 and is_boolean(Map.get(record, "waiting", false)),
         members = Map.get(record, "members", %{}),
         true <- is_map(members) and Enum.all?(members, &valid_member?/1) do
      {:ok, record}
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_readiness_corrupt}
    end
  end

  defp valid_member?({id, %{"ready" => ready, "generation" => generation}}), do: is_binary(id) and is_boolean(ready) and is_integer(generation) and generation >= 0
  defp valid_member?(_), do: false
end
