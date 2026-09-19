defmodule SymphonyElixir.OpenClawGatewayTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Yolo.OpenClaw
  alias SymphonyElixir.Yolo.OpenClaw.Gateway

  test "external submission passes the actual upstream cwd preflight without plugin identity" do
    probe = fn params ->
      {output, 0} = System.cmd("node", ["test/fixtures/openclaw/preflight.cjs", Jason.encode!(params)])
      Jason.decode!(output)
    end

    assert probe.(%{"cwd" => "/tmp/proof"}) == %{
             "allowed" => false,
             "error" => %{"code" => "INVALID_REQUEST", "message" => "cwd is reserved for plugin-owned subagent runs"}
           }

    order = %{"id" => "run", "agent" => "po", "session_id" => "session", "workspace" => "/tmp/proof", "timeout_seconds" => 3600}

    transport = fn ["gateway", "call", "agent", "--params", raw | _] ->
      params = Jason.decode!(raw)
      assert probe.(params) == %{"allowed" => true}
      assert Enum.sort(Map.keys(params)) == ~w(agentId deliver idempotencyKey message sessionKey timeout)
      {:ok, Jason.encode!(%{"runId" => "run", "status" => "accepted"})}
    end

    assert {:ok, %{"status" => "accepted"}} = Gateway.submit(order, "full workflow", transport: transport)
  end

  test "rejection envelopes require the exact request hash, method and allowlisted preflight reason" do
    order = %{"id" => "run", "agent" => "po", "session_id" => "session", "timeout_seconds" => 3600}

    for change <- [%{"symphony_openclaw_rejection" => 2}, %{"request_sha256" => "other"}, %{"method" => "agent.wait"}, %{"phase" => "final"}, %{"reason" => "SECRET"}] do
      transport = fn ["gateway", "call", "agent", "--params", raw | _] ->
        proof = %{
          "symphony_openclaw_rejection" => 1,
          "method" => "agent",
          "phase" => "pre_acceptance",
          "reason" => "cwd_reserved",
          "code" => "INVALID_REQUEST",
          "request_sha256" => OpenClaw.digest(raw)
        }

        {:ok, Jason.encode!(Map.merge(proof, change))}
      end

      assert {:error, :openclaw_invalid_response} = Gateway.submit(order, "workflow", transport: transport)
    end
  end
end
