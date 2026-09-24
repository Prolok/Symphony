defmodule SymphonyElixir.Yolo.OpenClaw.Journal do
  @moduledoc "External reservations survive agent changes and restarts, independent of YOLO selection."
  alias SymphonyElixir.{Config, ProjectContext}
  alias SymphonyElixir.Linear.{DurableState, IssueLease}
  alias SymphonyElixir.Relay.Store, as: Digest
  @groups ~w(incoming planning in_progress blocker review)
  @terminal ~w(completed failed cancelled rejected retired)
  @mutable ~w(state writable error cancel_requested abort_acknowledged abort_error terminal acceptance_observed execution_observed checkout_proof rejection recovery before_recovery resumed retirement)

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
  def write(order) do
    locked(order["group"], fn ->
      with {:ok, previous} <- read(order["group"]),
           false <- pending?(previous),
           true <- is_nil(previous) or previous["id"] != order["id"],
           {:error, :enoent} <- history(order["group"], order["id"]),
           :ok <- archive(previous),
           :ok <- DurableState.write(path(order["group"]), order) do
        :ok
      else
        true -> {:error, :openclaw_unresolved_order}
        false -> {:error, :openclaw_generation_reused}
        {:ok, _} -> {:error, :openclaw_generation_reused}
        error -> error
      end
    end)
  end

  @spec history(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def history(group, id), do: DurableState.read(archive_path(group, id))

  defp archive_path(group, id), do: Path.join(path(group) <> ".history", Digest.digest(id) <> ".json")
  defp archive(nil), do: :ok

  defp archive(order) do
    target = archive_path(order["group"], order["id"])

    case DurableState.read(target) do
      {:ok, ^order} -> :ok
      {:error, :enoent} -> DurableState.write(target, order)
      _ -> {:error, :openclaw_history_conflict}
    end
  end

  defp locked(group, fun), do: IssueLease.with_journal_lock(path(group) <> ".update", fun)

  @spec update(map(), map()) :: {:ok, map()} | {:error, term()}
  def update(order, changes) do
    transition(order, fn _ -> {:ok, changes} end)
  end

  @spec transition(map(), (map() -> {:ok, map()} | {:error, term()}), boolean()) :: {:ok, map()} | {:error, term()}
  def transition(order, callback, apply? \\ true) do
    locked(order["group"], fn -> update_locked(order, callback, apply?) end)
  end

  @doc "Drain authorized tool calls before revocation or retirement can acquire the same journal lock."
  @spec dispatch(map(), (map() -> {:ok, map()} | {:error, term()}), (-> term())) :: term()
  def dispatch(order, authorize, callback) do
    locked(order["group"], fn ->
      with {:ok, _} <- update_locked(order, authorize, true), do: callback.()
    end)
  end

  defp update_locked(order, callback, apply?) do
    with {:ok, %{"id" => id} = current} <- read(order["group"]),
         true <- id == order["id"],
         {:ok, changes} <- callback.(current),
         :ok <- validate_changes(changes),
         {:ok, updated} <- change(current, changes),
         :ok <- if(apply?, do: persist_change(current, updated), else: :ok) do
      {:ok, updated}
    else
      {:error, _} = error -> error
      _ -> {:error, :openclaw_generation_changed}
    end
  end

  defp validate_changes(changes) do
    if Enum.all?(Map.keys(changes), &(&1 in @mutable)), do: :ok, else: {:error, :openclaw_immutable_order}
  end

  # A late poll/cancel/acceptance cannot reopen a terminal generation. Once
  # execution was observed, no later preflight claim can prove non-execution.
  defp change(%{"state" => state} = current, _) when state in @terminal, do: {:ok, current}

  defp change(current, %{"state" => "rejected"} = changes) do
    if current["acceptance_observed"] == true or current["execution_observed"] == true or
         current["state"] in ~w(accepted running) or not is_map(changes["rejection"]) do
      {:error, :openclaw_rejection_conflicts_with_execution}
    else
      {:ok, Map.merge(current, changes)}
    end
  end

  defp change(current, changes) do
    updated = Map.merge(current, changes)
    updated = if get_in(current, ["abort_error", "retryable"]) == false, do: Map.put(updated, "abort_error", current["abort_error"]), else: updated
    updated = if current["interruption_contract"] == 1 and current["writable"] == false, do: Map.put(updated, "writable", false), else: updated

    updated =
      Enum.reduce(~w(acceptance_observed execution_observed), updated, fn key, acc ->
        if current[key] == true, do: Map.put(acc, key, true), else: acc
      end)

    {:ok, updated}
  end

  defp persist_change(current, current), do: :ok
  defp persist_change(_current, updated), do: DurableState.write(path(updated["group"]), updated)

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
        Map.take(order, ~w(id project_id agent session_id state payload_sha256 workspace sha terminal checkout_proof))

      _ ->
        nil
    end
  end
end
