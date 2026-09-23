defmodule SymphonyElixir.Yolo.OpenClaw.LinearBridge.Delivery do
  @moduledoc "Bounded delivery from the existing coordinator; receipts never mutate execution journals."
  require Logger
  alias SymphonyElixir.{Config, ProjectContext, TaskSupervisor}
  alias SymphonyElixir.Linear.{DurableState, IssueLease}
  alias SymphonyElixir.Relay.Store, as: Digest
  alias SymphonyElixir.Yolo.OpenClaw
  alias SymphonyElixir.Yolo.OpenClaw.{Gateway, Journal, LinearBridge}

  @spec tick(keyword()) :: :ok
  def tick(opts \\ []) do
    if enabled?() do
      context = ProjectContext.current()
      callback = fn -> report_flush(flush(opts), context) end
      Task.Supervisor.start_child(TaskSupervisor, fn -> ProjectContext.with_context(context, callback) end)
    end

    :ok
  end

  defp report_flush(:ok, _context), do: :ok
  defp report_flush({:error, :issue_already_owned}, _context), do: :ok
  defp report_flush(_, context), do: Logger.warning("OpenClaw LinearBridge delivery=pending project_root=#{context.id} reason=outbox_unavailable")

  @spec flush(keyword()) :: :ok | {:error, term()}
  def flush(opts \\ []) do
    if enabled?() do
      IssueLease.with_lock("symphony-linear-bridge", ProjectContext.current().id, fn -> deliver_pending(opts) end)
    else
      :ok
    end
  end

  defp enabled?, do: is_map(Config.openclaw_linear_bridge()) and is_binary(Config.openclaw_yolo_agent())

  defp deliver_pending(opts) do
    with {:ok, orders} <- Journal.bridge_orders() do
      orders
      |> Enum.flat_map(&pending(&1, opts))
      |> Enum.sort_by(fn {_, _, receipt} -> receipt["retry_at"] || 0 end)
      |> Enum.take(4)
      |> Enum.each(fn {order, snapshot, receipt} -> deliver(order, snapshot, receipt, opts) end)

      :ok
    end
  end

  defp pending(order, opts) do
    case read_receipt(order) do
      {:ok, receipt} ->
        snapshot = Enum.find(order["linear_bridge"]["snapshots"], &(&1["sequence"] > receipt["ack_sequence"]))
        if snapshot && (receipt["retry_at"] || 0) <= now(opts), do: [{order, snapshot, receipt}], else: []

      {:error, _} ->
        log(order, :openclaw_bridge_receipt_unavailable)
        []
    end
  end

  @spec receipt_path(map()) :: Path.t()
  def receipt_path(order), do: Path.join(Journal.path(order["group"]) <> ".bridge", Digest.digest(order["id"]) <> ".json")

  defp read_receipt(order) do
    id = order["id"]

    case DurableState.read(receipt_path(order)) do
      {:error, :enoent} -> {:ok, %{"order_id" => order["id"], "ack_sequence" => 0}}
      {:ok, %{"order_id" => ^id, "ack_sequence" => sequence} = receipt} when is_integer(sequence) and sequence >= 0 -> {:ok, receipt}
      _ -> {:error, :openclaw_bridge_receipt_invalid}
    end
  end

  defp deliver(order, snapshot, receipt, opts) do
    # Persist the retry bound before RPC. A lost response replays the same bytes
    # after restart; no receipt can acknowledge a snapshot other than this one.
    attempted = Map.put(receipt, "retry_at", now(opts) + 30_000)

    result =
      with :ok <- DurableState.write(receipt_path(order), attempted),
           :ok <- same_config(order),
           {:ok, key} <- Keyword.get(opts, :bridge_key, &Config.openclaw_bridge_key/1).(order["linear_bridge"]["config"]),
           {:ok, raw} <- snapshot_bytes(snapshot),
           {:ok, wire} <- LinearBridge.sign(raw, order["linear_bridge"]["config"]["key_id"], key),
           {:ok, reply} <- Gateway.lifecycle(wire, Keyword.put(opts, :bridge_gateway_port, Map.get(order["linear_bridge"]["config"], "gateway_port", 18_789))),
           :ok <- LinearBridge.acknowledge(reply, order, snapshot) do
        confirmed = Map.merge(attempted, %{"ack_sequence" => snapshot["sequence"], "payload_sha256" => snapshot["payload_sha256"], "disposition" => reply["disposition"], "retry_at" => 0})
        DurableState.write(receipt_path(order), confirmed)
      end

    case result do
      :ok -> :ok
      {:error, reason} when is_atom(reason) -> log(order, reason)
      _ -> log(order, :openclaw_bridge_delivery_unconfirmed)
    end
  rescue
    _ -> log(order, :openclaw_bridge_delivery_unconfirmed)
  end

  defp snapshot_bytes(snapshot) do
    with {:ok, raw} <- Base.decode64(snapshot["payload_b64"]),
         true <- OpenClaw.digest(raw) == snapshot["payload_sha256"],
         {:ok, payload} <- Jason.decode(raw),
         true <- payload === Map.put(snapshot["projection"], "sequence", snapshot["sequence"]) do
      {:ok, raw}
    else
      _ -> {:error, :openclaw_bridge_snapshot_corrupt}
    end
  end

  defp same_config(order) do
    config = Config.openclaw_linear_bridge()
    original = order["linear_bridge"]["config"]

    if LinearBridge.valid_config?(config) and LinearBridge.valid_config?(original) and
         LinearBridge.config_with_defaults(original) == LinearBridge.config_with_defaults(config),
       do: :ok,
       else: {:error, :openclaw_bridge_binding_changed}
  end

  defp now(opts), do: Keyword.get(opts, :bridge_now, &System.system_time/1).(:millisecond)

  defp log(order, reason) do
    Enum.each(order["members"], fn member ->
      Logger.warning(
        "OpenClaw LinearBridge delivery=pending project_root=#{order["project_id"]} issue_id=#{member["id"]} issue_identifier=#{member["identifier"]} run_id=#{order["id"]} session_id=#{order["session_id"]} reason=#{reason}"
      )
    end)
  end
end
