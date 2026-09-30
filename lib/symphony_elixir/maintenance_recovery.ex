defmodule SymphonyElixir.MaintenanceRecovery do
  @moduledoc "Durable, project-bound continuation hints for a drain and service restart."
  alias SymphonyElixir.{Config, ProjectContext, Workflow}
  alias SymphonyElixir.Linear.DurableState
  alias SymphonyElixir.Relay.Store

  @keys ~w(attempt identifier error worker_host workspace_path delegate_id recovered_turn_context review_subagent_call_ids review_subagent_ids codex_token_checkpoint review_stay completion_pending access_blocked interrupted_state maintenance_deferred due_at_unix_ms)a

  @spec load() :: {:ok, map()} | {:error, term()}
  def load do
    case DurableState.read(path()) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:ok, %{"version" => 1, "binding" => binding, "hints" => hints}} when is_map(hints) ->
        if binding == project_binding(), do: decode_hints(hints), else: {:error, :maintenance_recovery_binding}

      _ ->
        {:error, :maintenance_recovery_corrupt}
    end
  end

  @spec put(String.t(), map()) :: :ok | {:error, term()}
  def put(id, retry) do
    due_at =
      if is_integer(retry[:due_at_ms]),
        do: System.system_time(:millisecond) + max(retry.due_at_ms - System.monotonic_time(:millisecond), 0),
        else: retry[:due_at_unix_ms] || System.system_time(:millisecond)

    hint = retry |> Map.take(@keys) |> Map.put(:due_at_unix_ms, due_at)
    with {:ok, hints} <- load(), do: write(Map.put(hints, id, hint))
  end

  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(id) do
    with {:ok, hints} <- load() do
      if Map.has_key?(hints, id), do: write(Map.delete(hints, id)), else: :ok
    end
  end

  @spec path() :: Path.t()
  def path, do: Path.join([Config.settings!().tracker.app["state_root"], "maintenance", Store.digest(project_binding()) <> ".json"])

  defp project_binding do
    case ProjectContext.current() do
      %{id: id} -> id
      nil -> Path.dirname(Workflow.workflow_file_path())
    end
  end

  defp write(hints) do
    encoded = Map.new(hints, fn {id, hint} -> {id, hint |> :erlang.term_to_binary() |> Base.encode64()} end)
    DurableState.write(path(), %{"version" => 1, "binding" => project_binding(), "hints" => encoded})
  end

  defp decode_hints(hints) do
    decoded = Map.new(hints, fn {id, bytes} -> {id, bytes |> Base.decode64!() |> :erlang.binary_to_term([:safe])} end)

    if Enum.all?(decoded, fn {id, hint} ->
         is_binary(id) and is_map(hint) and is_integer(hint[:attempt]) and hint.attempt >= 0 and
           Enum.all?(Map.keys(hint), &(&1 in @keys))
       end), do: {:ok, decoded}, else: {:error, :maintenance_recovery_corrupt}
  rescue
    _ -> {:error, :maintenance_recovery_corrupt}
  end
end
