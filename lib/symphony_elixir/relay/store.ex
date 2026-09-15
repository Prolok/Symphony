defmodule SymphonyElixir.Relay.Store do
  @moduledoc "Durable consumer identity and recovery records, independent of release and project paths."
  alias SymphonyElixir.Linear.{DurableState, IssueLease}
  alias SymphonyElixir.Relay.Config

  @spec identity(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def identity(config, workspace) do
    path = Path.join(config["state_root"], digest(workspace) <> ".identity.json")

    case DurableState.read(path) do
      {:error, :enoent} -> IssueLease.with_journal_lock(path, fn -> identity_locked(path, config["consumer_id"]) end)
      _ -> identity_locked(path, config["consumer_id"])
    end
  end

  defp identity_locked(path, configured) do
    case DurableState.read(path) do
      {:error, :enoent} ->
        id = configured || Ecto.UUID.generate()

        with true <- Config.id?(id), :ok <- DurableState.write(path, %{"consumer_id" => id}) do
          {:ok, id}
        else
          false -> {:error, :invalid_relay_consumer_id}
          error -> error
        end

      {:ok, %{"consumer_id" => id}} ->
        if Config.id?(id) and configured in [nil, id], do: {:ok, id}, else: {:error, :relay_identity_change_requires_handoff}

      _ ->
        {:error, :relay_identity_unavailable}
    end
  end

  @spec path(map(), String.t(), String.t()) :: Path.t()
  def path(config, workspace, consumer), do: Path.join(config["state_root"], digest({workspace, consumer}) <> ".cache.json")

  @spec digest(term()) :: String.t()
  def digest(value), do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)
end
