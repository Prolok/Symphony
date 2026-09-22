defmodule SymphonyElixir.OpenClawGatewayTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Yolo.OpenClaw
  alias SymphonyElixir.Yolo.OpenClaw.Gateway

  test "an explicit existing normal-channel session stays bound to the configured agent" do
    alias SymphonyElixir.ProjectContext
    key = "agent:po:slack:channel:normal"
    route = %{"channel" => "slack", "to" => "channel:normal", "accountId" => "po"}

    transport = fn
      ["--version"] ->
        {:ok, "2026.9.4"}

      ["gateway", "call", "agents.list" | _] ->
        {:ok, ~s({"agents":[{"id":"po"}]})}

      ["gateway", "call", "sessions.list", "--params", raw | _] ->
        assert Jason.decode!(raw)["search"] == key
        {:ok, Jason.encode!(%{"sessions" => [%{"key" => key, "deliveryContext" => route}]})}
    end

    ProjectContext.with_context(%ProjectContext{env: %{"OPENCLAW_YOLO_NOTIFY_SESSION" => key}}, fn ->
      assert {:ok, destination} = Gateway.destination("po", transport: transport)
      assert destination == Map.put(route, "sessionKey", key)
    end)

    for foreign <- ["agent:other:main", "agent:po-other:main"] do
      ProjectContext.with_context(%ProjectContext{env: %{"OPENCLAW_YOLO_NOTIFY_SESSION" => foreign}}, fn ->
        assert {:error, :openclaw_normal_channel_unavailable} = Gateway.destination("po", transport: fn _ -> flunk("foreign session must not be queried") end)
      end)
    end
  end

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

  test "operator history countercheck is bounded and reads the current original agent session" do
    order = %{"agent" => "po", "session_id" => "agent:po:symphony:project:incoming:run"}

    transport = fn ["gateway", "call", method, "--params", raw, "--json", "--timeout", "10000", "--port", "18789"] ->
      assert method == "chat.history"

      assert Jason.decode!(raw) == %{
               "agentId" => "po",
               "sessionKey" => order["session_id"],
               "offset" => 0,
               "limit" => 200,
               "maxBytes" => 1_048_576
             }

      {:ok, "{}"}
    end

    assert {:ok, %{}} = Gateway.history(order, transport: transport)
  end

  test "escalations resolve only the bound normal session and send with a stable key" do
    route = %{"channel" => "signal", "to" => "human", "accountId" => "account"}

    transport = fn
      ["--version"] ->
        {:ok, "OpenClaw 2026.9.4"}

      ["gateway", "call", "agents.list" | _] ->
        {:ok, Jason.encode!(%{"agents" => [%{"id" => "po"}]})}

      ["gateway", "call", "sessions.list", "--params", raw | _] ->
        assert Jason.decode!(raw)["agentId"] == "po"
        {:ok, Jason.encode!(%{"sessions" => [%{"key" => "agent:po:main", "deliveryContext" => route}, %{"key" => "agent:other:main", "deliveryContext" => %{"to" => "foreign"}}]})}

      ["gateway", "call", "send", "--params", raw | _] ->
        params = Jason.decode!(raw)
        assert params["to"] == "human"
        assert params["idempotencyKey"] == "proposal-id"
        assert params["message"] == "concrete proposal"
        refute Map.has_key?(params, "deliver")
        {:ok, Jason.encode!(%{"messageId" => "message", "channel" => "signal"})}
    end

    assert {:ok, destination} = Gateway.destination("po", transport: transport)
    assert destination == Map.put(route, "sessionKey", "agent:po:main")
    assert {:ok, %{"messageId" => "message"}} = Gateway.notify(Map.put(destination, "idempotencyKey", "proposal-id"), "concrete proposal", transport: transport)

    missing = fn
      ["gateway", "call", "sessions.list" | _] -> {:ok, Jason.encode!(%{"sessions" => []})}
      args -> transport.(args)
    end

    assert {:error, :openclaw_normal_channel_unavailable} = Gateway.destination("po", transport: missing)

    offline = fn
      ["gateway", "call", "sessions.list" | _] -> {:error, :openclaw_unavailable}
      args -> transport.(args)
    end

    assert {:error, :openclaw_unavailable} = Gateway.destination("po", transport: offline)
  end
end
