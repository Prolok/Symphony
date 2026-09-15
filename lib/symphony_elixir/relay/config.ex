defmodule SymphonyElixir.Relay.Config do
  @moduledoc "Public, restart-bound configuration for a workspace relay consumer."

  alias SymphonyElixir.{Config, EnvFile}

  @spec validate(map() | nil) :: :ok | {:error, atom()}
  def validate(nil), do: :ok

  def validate(relay) when is_map(relay) do
    cond do
      not endpoint?(relay["endpoint"]) -> {:error, :invalid_relay_endpoint}
      not env_name?(relay["key_env"]) -> {:error, :invalid_relay_key_reference}
      relay["consumer_id"] != nil and not id?(relay["consumer_id"]) -> {:error, :invalid_relay_consumer_id}
      not is_map(relay["owners"]) -> {:error, :invalid_relay_owners}
      true -> validate_storage(relay)
    end
  end

  defp validate_storage(relay) do
    cond do
      not is_integer(relay["reconcile_ms"]) or relay["reconcile_ms"] < 300_000 -> {:error, :invalid_relay_reconcile_interval}
      not is_binary(relay["state_root"]) or Path.type(relay["state_root"]) != :absolute -> {:error, :invalid_relay_state_root}
      true -> :ok
    end
  end

  @spec endpoint?(term()) :: boolean()
  def endpoint?(value) when is_binary(value) do
    uri = URI.parse(value)

    uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
      uri.userinfo == nil and uri.query == nil and uri.fragment == nil
  end

  def endpoint?(_), do: false

  @spec id?(term()) :: boolean()
  def id?(value), do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,80}\z/, value)

  @spec env_name?(term()) :: boolean()
  def env_name?(value), do: is_binary(value) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, value)

  @spec key(map(), map()) :: {:ok, String.t()} | {:error, atom()}
  def key(relay, app) do
    case EnvFile.linear_secret(relay["key_env"], app["env_dir"]) do
      {:ok, key} -> {:ok, key}
      _ -> {:error, :relay_key_unavailable}
    end
  end

  @spec shared([SymphonyElixir.ProjectContext.t()]) :: :ok | {:error, atom()}
  def shared(contexts) do
    configs = Enum.map(contexts, & &1.settings.tracker.relay) |> Enum.uniq()

    case configs do
      [nil] -> :ok
      [relay] -> shared_keys(contexts, relay)
      _ -> {:error, :conflicting_workspace_relay_binding}
    end
  end

  defp shared_keys(contexts, relay) do
    with :ok <- validate(relay),
         {:ok, hashes} <- Enum.reduce_while(contexts, {:ok, MapSet.new()}, &collect_key(&1, &2, relay)) do
      if MapSet.size(hashes) == 1, do: :ok, else: {:error, :conflicting_workspace_relay_keys}
    end
  end

  defp collect_key(context, {:ok, hashes}, relay) do
    case key(relay, context.settings.tracker.app) do
      {:ok, key} -> {:cont, {:ok, MapSet.put(hashes, :crypto.hash(:sha256, key))}}
      error -> {:halt, error}
    end
  end

  @spec current() :: map() | nil
  def current, do: Config.settings!().tracker.relay
end
