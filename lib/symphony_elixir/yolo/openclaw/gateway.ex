defmodule SymphonyElixir.Yolo.OpenClaw.Gateway do
  @moduledoc "Gateway RPC contract verified against OpenClaw 2026.9.4; no local fallback."
  @behaviour SymphonyElixir.Yolo.OpenClaw.Adapter
  alias SymphonyElixir.Yolo.OpenClaw.Transport

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
        "cwd" => order["workspace"],
        "timeout" => order["timeout_seconds"]
      },
      opts
    )
  end

  @impl true
  def status(order, opts), do: rpc("agent.wait", %{"runId" => order["id"], "timeoutMs" => 1000}, opts)

  @impl true
  def cancel(order, opts) do
    case rpc("sessions.abort", %{"key" => order["session_id"], "runId" => order["id"]}, opts) do
      {:ok, %{"ok" => true}} -> :ok
      {:error, _} = error -> error
      _ -> {:error, :openclaw_abort_unconfirmed}
    end
  end

  defp rpc(method, params, opts) do
    args = ["gateway", "call", method, "--params", Jason.encode!(params), "--json", "--timeout", "10000", "--port", "18789"]

    with {:ok, output} <- command(args, opts),
         {:ok, response} when is_map(response) <- Jason.decode(output) do
      {:ok, response}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :openclaw_invalid_response}
    end
  end

  defp command(args, opts), do: Keyword.get(opts, :transport, &Transport.command/1).(args)
end
