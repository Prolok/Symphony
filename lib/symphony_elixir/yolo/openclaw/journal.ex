defmodule SymphonyElixir.Yolo.OpenClaw.Journal do
  @moduledoc "External reservations survive agent changes and restarts, independent of YOLO selection."
  alias SymphonyElixir.{Config, ProjectContext}
  alias SymphonyElixir.Linear.{DurableState, IssueLease}
  alias SymphonyElixir.Relay.Store, as: Digest
  @groups ~w(incoming planning in_progress blocker review)
  @terminal ~w(completed failed cancelled rejected)

  @spec path(String.t()) :: Path.t()
  def path(group) do
    key = Digest.digest({ProjectContext.current().id, group})
    Path.join([Config.settings!().tracker.app["state_root"], "openclaw", key <> ".json"])
  end

  @spec read(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def read(group) do
    if ProjectContext.current(), do: read_bound(group), else: {:ok, nil}
  end

  defp read_bound(group) do
    case DurableState.read(path(group)) do
      {:error, :enoent} ->
        {:ok, nil}

      {:ok, %{"group" => ^group, "id" => id, "members" => members, "state" => state} = order}
      when is_binary(id) and is_list(members) and is_binary(state) ->
        {:ok, order}

      _ ->
        {:error, :openclaw_journal_corrupt}
    end
  end

  @spec member_available(String.t()) :: :ok | {:error, term()}
  def member_available(id) do
    with {:ok, orders} <- pending() do
      if Enum.any?(orders, &member?(&1, id)), do: {:error, :openclaw_member_reserved}, else: :ok
    end
  end

  defp member?(order, id), do: Enum.any?(order["members"], &(&1["id"] == id))

  @spec write(map()) :: :ok | {:error, term()}
  def write(order), do: DurableState.write(path(order["group"]), order)

  @spec update(map(), map()) :: {:ok, map()} | {:error, term()}
  def update(order, changes) do
    IssueLease.with_journal_lock(path(order["group"]) <> ".update", fn -> update_locked(order, changes) end)
  end

  defp update_locked(order, changes) do
    with {:ok, %{"id" => id} = current} <- read(order["group"]),
         true <- id == order["id"],
         updated = Map.merge(current, changes),
         :ok <- persist_change(current, updated) do
      {:ok, updated}
    else
      {:error, _} = error -> error
      _ -> {:error, :openclaw_generation_changed}
    end
  end

  defp persist_change(current, current), do: :ok
  defp persist_change(_current, updated), do: write(updated)

  @spec pending?(map() | nil) :: boolean()
  def pending?(nil), do: false
  def pending?(order), do: order["state"] not in @terminal

  @spec available(String.t()) :: :ok | {:error, term()}
  def available(group) do
    with {:ok, order} <- read(group) do
      if pending?(order), do: {:error, :openclaw_unresolved_order}, else: :ok
    end
  end

  @spec pending() :: {:ok, [map()]} | {:error, term()}
  def pending do
    Enum.reduce_while(@groups, {:ok, []}, fn group, {:ok, orders} ->
      case read(group) do
        {:ok, order} -> {:cont, {:ok, if(pending?(order), do: [order | orders], else: orders)}}
        error -> {:halt, error}
      end
    end)
  end

  @spec writable?(String.t(), String.t()) :: boolean()
  def writable?(group, run_id) do
    case read(group) do
      {:ok, %{"id" => ^run_id, "writable" => true, "state" => state}} -> state in ~w(intent accepted running)
      _ -> false
    end
  end

  @spec receipt(String.t(), String.t()) :: map() | nil
  def receipt(group, session) do
    case read(group) do
      {:ok, %{"session_id" => ^session, "state" => "completed"} = order} ->
        Map.take(order, ~w(id agent session_id state payload_sha256 sha terminal))

      _ ->
        nil
    end
  end
end
