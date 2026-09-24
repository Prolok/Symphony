defmodule SymphonyElixir.OpenClawGatewayTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Yolo.OpenClaw
  alias SymphonyElixir.Yolo.OpenClaw.Gateway

  test "lifecycle uses the selected local port" do
    parent = self()

    transport = fn args ->
      send(parent, {:lifecycle_args, args})
      {:ok, "{}"}
    end

    assert {:ok, %{}} = Gateway.lifecycle(%{}, transport: transport, bridge_gateway_port: 19_892)
    assert_received {:lifecycle_args, ["gateway", "call", "linearbridge.symphony.lifecycle.v1", "--params", "{}", "--json", "--timeout", "10000", "--port", "19892"]}
  end

  test "invalid lifecycle ports fail before transport and unavailable isolated targets have no fallback" do
    deny = fn _ -> flunk("invalid endpoint must not access transport") end

    for port <- [nil, false, 0, -1, 65_536, 19_892.0, "19892", "ws://remote:19892", "19892 --token secret"] do
      result = Gateway.lifecycle(%{}, bridge_gateway_port: port, transport: deny)
      assert {:error, :openclaw_bridge_gateway_port_invalid} = result
    end

    parent = self()

    offline = fn args ->
      send(parent, {:attempt, List.last(args)})
      {:error, :openclaw_gateway_unavailable}
    end

    result = Gateway.lifecycle(%{}, bridge_gateway_port: 19_892, transport: offline)
    assert {:error, :openclaw_gateway_unavailable} = result
    assert_received {:attempt, "19892"}
    refute_received {:attempt, _}
  end

  test "the bridge port cannot change agent, status, abort, history or notification targets" do
    parent = self()

    transport = fn ["gateway", "call", method, "--params", _raw, "--json", "--timeout", "10000", "--port", "18789"] ->
      send(parent, {:standard_target, method})

      if method == "sessions.abort",
        do: {:ok, ~s({"ok":true,"status":"aborted","abortedRunId":"run"})},
        else: {:ok, ~s({"ok":true})}
    end

    opts = [transport: transport, bridge_gateway_port: 19_892]
    order = %{"id" => "run", "agent" => "po", "session_id" => "session", "timeout_seconds" => 3600}
    assert {:ok, _} = Gateway.submit(order, "workflow", opts)
    assert {:ok, _} = Gateway.status(order, opts)
    assert :ok = Gateway.cancel(order, opts)
    assert {:ok, _} = Gateway.history(order, opts)
    assert {:ok, _} = Gateway.notify(%{}, "notification", opts)
    assert {:ok, _} = Gateway.lifecycle(%{}, transport: transport)

    for method <- ~w(agent agent.wait sessions.abort chat.history send linearbridge.symphony.lifecycle.v1),
        do: assert_received({:standard_target, ^method})
  end

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
        deny = fn _ -> flunk("foreign session must not be queried") end
        assert {:error, :openclaw_normal_channel_unavailable} = Gateway.destination("po", transport: deny)
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

  test "only an actual abort of the requested original acknowledges cancellation" do
    order = %{"id" => "original", "session_id" => "session"}
    confirmed = %{"ok" => true, "status" => "aborted", "abortedRunId" => "original"}

    assert :ok = Gateway.cancel(order, transport: fn _ -> {:ok, Jason.encode!(confirmed)} end)

    for reply <- [
          %{"ok" => true, "status" => "no-active-run", "abortedRunId" => nil},
          Map.put(confirmed, "abortedRunId", "newer-or-foreign"),
          Map.put(confirmed, "status", "no-active-run"),
          Map.put(confirmed, "ok", false),
          Map.delete(confirmed, "abortedRunId"),
          %{"ok" => true}
        ] do
      assert {:error, :openclaw_abort_unconfirmed} = Gateway.cancel(order, transport: fn _ -> {:ok, Jason.encode!(reply)} end)
    end
  end

  test "typed abort failures retain only correlated sanitized evidence" do
    order = %{"id" => "original", "session_id" => "session"}

    for retryable <- [true, false] do
      transport = fn ["gateway", "call", "sessions.abort", "--params", raw | _] ->
        {:ok,
         Jason.encode!(%{
           "symphony_openclaw_abort_error" => 1,
           "method" => "sessions.abort",
           "code" => "INVALID_REQUEST",
           "reason" => "unauthorized",
           "retryable" => retryable,
           "request_sha256" => OpenClaw.digest(raw),
           "details" => "SECRET"
         })}
      end

      assert {:error, {:openclaw_abort_failed, proof}} = Gateway.cancel(order, transport: transport)
      assert proof["retryable"] == retryable
      assert proof["reason"] == "unauthorized"
      refute inspect(proof) =~ "SECRET"
    end

    for changed <- [%{"symphony_openclaw_abort_error" => 2}, %{"request_sha256" => "foreign"}, %{"retryable" => nil}, %{"reason" => "SECRET"}, %{"method" => "agent"}] do
      transport = fn ["gateway", "call", "sessions.abort", "--params", raw | _] ->
        proof = %{
          "symphony_openclaw_abort_error" => 1,
          "method" => "sessions.abort",
          "code" => "INVALID_REQUEST",
          "reason" => "unauthorized",
          "retryable" => false,
          "request_sha256" => OpenClaw.digest(raw)
        }

        {:ok, Jason.encode!(Map.merge(proof, changed))}
      end

      assert {:error, :openclaw_invalid_response} = Gateway.cancel(order, transport: transport)
    end

    foreign_method = fn _ -> {:ok, Jason.encode!(%{"symphony_openclaw_abort_error" => 1})} end
    assert {:error, :openclaw_invalid_response} = Gateway.status(order, transport: foreign_method)
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

  test "operator history countercheck is bounded and reads the current original agent session" do
    order = %{"agent" => "po", "session_id" => "agent:po:symphony:project:incoming:run"}

    transport = fn ["gateway", "call", method, "--params", raw, "--json", "--timeout", "10000", "--port", "18789"] ->
      assert method == "chat.history"

      assert Jason.decode!(raw) == %{
               "agentId" => "po",
               "sessionKey" => order["session_id"],
               "offset" => 0,
               "limit" => 200,
               "maxBytes" => 1_048_576,
               "maxChars" => 500_000
             }

      {:ok, "{}"}
    end

    assert {:ok, %{}} = Gateway.history(order, transport: transport)
  end
end
