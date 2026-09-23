defmodule SymphonyElixir.Yolo.OpenClaw.LinearBridge do
  @moduledoc "Versioned, authenticated lifecycle snapshots; never executes or completes PO work."
  alias SymphonyElixir.Config
  alias SymphonyElixir.Yolo.OpenClaw
  alias SymphonyElixir.Yolo.OpenClaw.LinearBridge.Projection
  @method "linearbridge.symphony.lifecycle.v1"
  @config_keys ~w(producer_id consumer_account_id key_id secret_env)

  @spec valid_config?(term()) :: boolean()
  def valid_config?(nil), do: true

  def valid_config?(config) when is_map(config) do
    Enum.all?(Map.keys(config), &(&1 in @config_keys)) and
      Enum.all?(~w(producer_id consumer_account_id key_id), &slug?(config[&1])) and
      secret_name?(config["secret_env"] || "SYMPHONY_LINEAR_BRIDGE_KEY")
  end

  def valid_config?(_), do: false
  defp secret_name?(value), do: is_binary(value) and Regex.match?(~r/\ASYMPHONY_LINEAR_BRIDGE_[A-Z0-9_]+\z/, value)
  defp slug?(value), do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/, value)

  @doc "Bind only newly created orders; enabling the option does not reinterpret old journals."
  @spec bind(map()) :: {:ok, map()} | {:error, atom()}
  def bind(order) do
    case Config.openclaw_linear_bridge() do
      nil -> {:ok, order}
      config -> capture(Map.put(order, "linear_bridge", %{"config" => Map.put_new(config, "secret_env", "SYMPHONY_LINEAR_BRIDGE_KEY"), "snapshots" => []}))
    end
  end

  @doc "Called under the original journal lock and persisted in the same atomic write."
  @spec capture(map()) :: {:ok, map()} | {:error, atom()}
  def capture(%{"linear_bridge" => bridge} = order) do
    snapshots = bridge["snapshots"]
    previous = List.last(snapshots)
    sequence = if previous, do: previous["sequence"] + 1, else: 1

    with {:ok, payload} <- Projection.payload(order, bridge["config"], sequence) do
      if previous && previous["projection"] == Map.delete(payload, "sequence") do
        {:ok, order}
      else
        append(order, payload, snapshots)
      end
    end
  end

  def capture(order), do: {:ok, order}

  defp append(order, payload, snapshots) do
    raw = Jason.encode!(payload)
    sequence = payload["sequence"]

    if byte_size(raw) <= 262_144 and sequence <= 9_007_199_254_740_991 do
      snapshot = %{"sequence" => sequence, "payload_b64" => Base.encode64(raw), "payload_sha256" => OpenClaw.digest(raw), "projection" => Map.delete(payload, "sequence")}
      {:ok, put_in(order, ["linear_bridge", "snapshots"], snapshots ++ [snapshot])}
    else
      {:error, :openclaw_bridge_payload_too_large}
    end
  end

  @spec sign(binary(), String.t(), binary()) :: {:ok, map()} | {:error, atom()}
  def sign(raw, key_id, key) do
    if byte_size(raw) <= 262_144 and byte_size(key) >= 32 and slug?(key_id) do
      encoded = Base.encode64(raw)
      mac = :crypto.mac(:hmac, :sha256, key, @method <> "\n" <> key_id <> "\n" <> encoded) |> Base.encode16(case: :lower)
      {:ok, %{"version" => 1, "key_id" => key_id, "payload_b64" => encoded, "mac" => mac}}
    else
      {:error, :openclaw_bridge_signing_invalid}
    end
  end

  @spec acknowledge(term(), map(), map()) :: :ok | {:error, atom()}
  def acknowledge(reply, order, snapshot) when is_map(reply) do
    config = order["linear_bridge"]["config"]

    expected = %{
      "version" => 1,
      "producer_id" => config["producer_id"],
      "consumer_account_id" => config["consumer_account_id"],
      "order_id" => order["id"],
      "sequence" => snapshot["sequence"],
      "payload_sha256" => snapshot["payload_sha256"]
    }

    if Map.delete(reply, "disposition") === expected and reply["disposition"] in ~w(stored duplicate stale),
      do: :ok,
      else: {:error, :openclaw_bridge_ack_mismatch}
  end

  def acknowledge(_, _, _), do: {:error, :openclaw_bridge_ack_mismatch}
end
