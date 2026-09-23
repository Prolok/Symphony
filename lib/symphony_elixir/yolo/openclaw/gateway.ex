defmodule SymphonyElixir.Yolo.OpenClaw.Gateway do
  @moduledoc "Gateway RPC contract verified against OpenClaw 2026.9.4; no local fallback."
  @behaviour SymphonyElixir.Yolo.OpenClaw.Adapter
  alias SymphonyElixir.ProjectContext
  alias SymphonyElixir.Yolo.OpenClaw
  alias SymphonyElixir.Yolo.OpenClaw.Transport
  @owner_unavailable [:openclaw_owner_connection_lost, :openclaw_owner_credentials_unavailable]

  @impl true
  def preflight(agent, opts) do
    with {:ok, version} <- command(["--version"], opts),
         :ok <- version_supported(version),
         {:ok, %{"agents" => agents}} when is_list(agents) <- rpc("agents.list", %{}, opts),
         true <- Enum.any?(agents, &(&1["id"] == agent)) do
      :ok
    else
      false -> {:error, :openclaw_agent_not_found}
      {:error, _} = error -> error
      _ -> {:error, :openclaw_protocol_mismatch}
    end
  end

  defp version_supported(version) do
    if Regex.match?(~r/^(?:OpenClaw )?2026\.9\.4(?:\s|$)/, version), do: :ok, else: {:error, :openclaw_version_unsupported}
  end

  @impl true
  def submit(order, prompt, opts) do
    rpc(
      "agent",
      %{
        "agentId" => order["agent"],
        "sessionKey" => order["session_id"],
        "idempotencyKey" => order["id"],
        "message" => prompt,
        "deliver" => false,
        "timeout" => order["timeout_seconds"]
      },
      opts
    )
  end

  @impl true
  def status(order, opts), do: rpc("agent.wait", %{"runId" => order["id"], "timeoutMs" => 1000}, opts)

  @impl true
  def history(order, opts) do
    rpc("chat.history", %{"agentId" => order["agent"], "sessionKey" => order["session_id"], "offset" => 0, "limit" => 200, "maxBytes" => 1_048_576, "maxChars" => 500_000}, opts)
  end

  @impl true
  def cancel(order, opts) do
    id = order["id"]

    case rpc("sessions.abort", %{"key" => order["session_id"], "runId" => order["id"]}, opts) do
      {:ok, %{"ok" => true, "status" => "aborted", "abortedRunId" => ^id}} when is_binary(id) and id != "" -> :ok
      {:error, _} = error -> error
      _ -> {:error, :openclaw_abort_unconfirmed}
    end
  end

  @spec destination(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def destination(agent, opts) do
    key = ProjectContext.env("OPENCLAW_YOLO_NOTIFY_SESSION") || "agent:#{agent}:main"

    with true <- String.starts_with?(key, "agent:#{agent}:") and byte_size(key) <= 256,
         :ok <- preflight(agent, opts),
         {:ok, %{"sessions" => sessions}} when is_list(sessions) <- rpc("sessions.list", %{"agentId" => agent, "search" => key, "limit" => 100}, opts),
         [session] <- Enum.filter(sessions, &(&1["key"] == key)),
         %{"channel" => channel, "to" => to} = route <- session["deliveryContext"],
         true <- is_binary(channel) and channel not in ["", "webchat", "internal"] and is_binary(to) and to != "" do
      {:ok, route |> Map.take(~w(channel to accountId threadId)) |> Map.put("sessionKey", key)}
    else
      {:error, _} = error -> error
      _ -> {:error, :openclaw_normal_channel_unavailable}
    end
  end

  @spec notify(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def notify(destination, message, opts), do: rpc("send", Map.put(destination, "message", message), opts)

  @spec lifecycle(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def lifecycle(envelope, opts), do: rpc("linearbridge.symphony.lifecycle.v1", envelope, opts)

  defp rpc(method, params, opts) do
    raw = Jason.encode!(params)
    args = ["gateway", "call", method, "--params", raw, "--json", "--timeout", "10000", "--port", "18789"]

    with {:ok, output} <- command(args, opts),
         {:ok, response} when is_map(response) <- Jason.decode(output) do
      decode_response(response, method, raw)
    else
      {:error, reason} when method == "sessions.abort" and reason in @owner_unavailable ->
        reason = if reason == :openclaw_owner_connection_lost, do: "owner_connection_lost", else: "credentials_unavailable"
        {:error, {:openclaw_abort_failed, %{"method" => method, "code" => "NOT_LINKED", "reason" => reason, "retryable" => false, "request_sha256" => OpenClaw.digest(raw)}}}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      _ ->
        {:error, :openclaw_invalid_response}
    end
  end

  defp decode_response(%{"symphony_openclaw_abort_error" => 1} = proof, "sessions.abort", raw) do
    if proof["method"] == "sessions.abort" and proof["code"] in ~w(INVALID_REQUEST UNAVAILABLE NOT_LINKED OTHER) and
         proof["reason"] in ~w(unauthorized request_rejected owner_connection_lost owner_mismatch credentials_unavailable) and is_boolean(proof["retryable"]) and
         proof["request_sha256"] == OpenClaw.digest(raw) do
      {:error, {:openclaw_abort_failed, Map.take(proof, ~w(method code reason retryable request_sha256))}}
    else
      {:error, :openclaw_invalid_response}
    end
  end

  defp decode_response(%{"symphony_openclaw_abort_error" => _}, _, _), do: {:error, :openclaw_invalid_response}

  defp decode_response(%{"symphony_openclaw_rejection" => 1} = proof, "agent", raw) do
    if proof["method"] == "agent" and proof["phase"] == "pre_acceptance" and
         proof["code"] == "INVALID_REQUEST" and proof["reason"] in ~w(cwd_reserved cwd_not_absolute) and
         proof["request_sha256"] == OpenClaw.digest(raw) do
      {:rejected, Map.take(proof, ~w(method phase code reason request_sha256))}
    else
      {:error, :openclaw_invalid_response}
    end
  end

  defp decode_response(%{"symphony_openclaw_rejection" => _}, _, _), do: {:error, :openclaw_invalid_response}
  defp decode_response(response, _, _), do: {:ok, response}

  defp command(args, opts), do: Keyword.get(opts, :transport, &Transport.command/1).(args)
end
