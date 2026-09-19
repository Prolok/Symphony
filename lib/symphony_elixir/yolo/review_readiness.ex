defmodule SymphonyElixir.Yolo.ReviewReadiness do
  @moduledoc "Durable changes in expected work, separate from a running review's frozen observations."
  alias SymphonyElixir.Yolo.{Group, Store}

  @key "review-readiness"

  @spec observe([map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def observe(issues) do
    Store.lock(@key, fn -> observe_locked(issues) end)
  end

  defp observe_locked(issues) do
    with {:ok, record} <- read() do
      update(record, Enum.any?(issues, &Group.expected?/1))
    end
  end

  defp update(record, waiting) do
    epoch = Map.get(record, "epoch", 0)

    if waiting == Map.get(record, "waiting", false) do
      {:ok, epoch}
    else
      with :ok <- Store.write(@key, Map.merge(record, %{"waiting" => waiting, "epoch" => epoch + 1})), do: {:ok, epoch + 1}
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
         true <- is_integer(epoch) and epoch >= 0 and is_boolean(Map.get(record, "waiting", false)) do
      {:ok, record}
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_readiness_corrupt}
    end
  end
end
