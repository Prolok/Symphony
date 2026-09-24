defmodule SymphonyElixir.OpenClawTransportTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Yolo.OpenClaw.{Gateway, OwnerTransport, Transport}

  defmodule SyntheticPorts do
    def open(executable, options) do
      send(self(), {:opened, executable, options})
      if Process.get(:open_failure), do: raise("synthetic open failure"), else: make_ref()
    end

    def command(port, input) do
      send(self(), {:input, input})
      Enum.each(Process.get(:replies, []), &send(self(), {port, &1}))
      true
    end

    def info(_port), do: Process.get(:port_info, [])

    def close(port) do
      send(self(), {:closed, port})
      if Process.get(:close_failure), do: raise(ArgumentError, "synthetic port already closed")
    end
  end

  defp options do
    [ports: SyntheticPorts, find_executable: fn "python3" -> "/synthetic/python3" end, timeout_ms: 0]
  end

  test "default process access remains denied even with timing or lookup overrides" do
    for opts <- [[], [timeout_ms: 0], [find_executable: fn _ -> flunk("lookup before denial") end]] do
      assert_raise RuntimeError, ~r/forbidden in standard tests/, fn -> Transport.command(["--version"], opts) end
    end

    OwnerTransport.within(fn ->
      assert_raise RuntimeError, ~r/forbidden in standard tests/, fn -> OwnerTransport.command("python3", [], Port, []) end
    end)
  end

  test "synthetic process boundary preserves framing, secret removal and successful output" do
    Process.put(:replies, [{:data, "first"}, {:data, "second"}, {:exit_status, 0}])
    assert {:ok, "firstsecond"} = Transport.command(["gateway", "call", "agents.list"], options())
    assert_receive {:opened, {:spawn_executable, "/synthetic/python3"}, flags}
    assert "-I" == hd(Keyword.fetch!(flags, :args))
    assert List.last(Keyword.fetch!(flags, :args)) =~ "/scripts/openclaw-rpc.py"
    assert {~c"LINEAR_APP_SECRET", false} in Keyword.fetch!(flags, :env)
    assert_receive {:input, "[\"gateway\",\"call\",\"agents.list\"]\n"}
    assert_receive {:closed, _}
  end

  test "bounded output, missing binary, gateway failure and timeout remain distinct" do
    for {replies, expected} <- [
          {[{:exit_status, 124}], :openclaw_owner_credentials_unavailable},
          {[{:exit_status, 123}], :openclaw_owner_connection_lost},
          {[{:exit_status, 122}], :openclaw_owner_access_rejected},
          {[{:exit_status, 127}], :openclaw_binary_missing},
          {[{:exit_status, 1}], :openclaw_gateway_unavailable},
          {[{:data, String.duplicate("x", 2_000_001)}], :openclaw_response_too_large},
          {[], :openclaw_transport_timeout}
        ] do
      Process.put(:replies, replies)
      assert {:error, ^expected} = Transport.command(["--version"], options())
      assert_receive {:closed, _}
    end
  end

  test "closed ports, missing Python and launch exceptions have safe results" do
    Process.put(:port_info, nil)
    Process.put(:replies, [{:exit_status, 0}])
    assert {:ok, ""} = Transport.command([], options())
    refute_receive {:closed, _}
    assert {:error, :openclaw_transport_python_missing} = Transport.command([], Keyword.put(options(), :find_executable, fn _ -> nil end))
    Process.put(:open_failure, true)
    assert {:error, :openclaw_transport_failed} = Transport.command([], options())
  end

  test "one worker keeps one process across preflight, submit and abort and closes it on exit" do
    OwnerTransport.within(fn ->
      for method <- ~w(agents.list agent sessions.abort) do
        Process.put(:replies, [{:data, {:eol, Jason.encode!(%{code: 0, output: "{}"})}}])
        assert {:ok, "{}"} = Transport.command(["gateway", "call", method], options())
      end

      assert_receive {:opened, _, flags}
      assert List.last(Keyword.fetch!(flags, :args)) == "--stream"
      refute_receive {:opened, _, _}
      refute_receive {:closed, _}
    end)

    assert_receive {:closed, _}
    refute OwnerTransport.active?()
  end

  test "lost connection cannot reopen or abort but later read-only status can prove original end" do
    OwnerTransport.within(fn ->
      Process.put(:replies, [{:exit_status, 1}])
      assert {:error, :openclaw_owner_connection_lost} = Transport.command(["gateway", "call", "agent.wait"], options())
      assert_receive {:opened, _, _}
      assert_receive {:closed, _}
      transport = &Transport.command(&1, options())
      assert {:error, {:openclaw_abort_failed, proof}} = Gateway.cancel(%{"id" => "original", "session_id" => "own"}, transport: transport)
      assert proof["reason"] == "owner_connection_lost"
      refute proof["retryable"]
      refute_receive {:opened, _, _}
      Process.put(:replies, [{:data, ~s({"status":"ok","runId":"original","endedAt":123})}, {:exit_status, 0}])
      assert {:ok, %{"endedAt" => 123}} = Gateway.status(%{"id" => "original"}, transport: transport)
      assert_receive {:opened, _, flags}
      refute "--stream" in Keyword.fetch!(flags, :args)
      assert OwnerTransport.lost?()
    end)
  end

  test "port exit during owner cleanup preserves callback results and exceptions" do
    Process.put(:close_failure, true)
    Process.put(:replies, [{:data, {:eol, Jason.encode!(%{code: 0, output: "{}"})}}])

    assert :completed ==
             OwnerTransport.within(fn ->
               assert {:ok, "{}"} = Transport.command(["gateway", "call", "agents.list"], options())
               :completed
             end)

    assert_receive {:closed, _}
    refute OwnerTransport.active?()

    assert_raise RuntimeError, "callback failed", fn ->
      OwnerTransport.within(fn ->
        assert {:ok, "{}"} = Transport.command(["gateway", "call", "agents.list"], options())
        raise "callback failed"
      end)
    end

    assert_receive {:closed, _}
    refute OwnerTransport.active?()
  end

  test "port exit during failure cleanup keeps the lost owner fenced" do
    Process.put(:close_failure, true)
    Process.put(:replies, [{:exit_status, 1}])

    OwnerTransport.within(fn ->
      assert {:error, :openclaw_owner_connection_lost} = Transport.command(["gateway", "call", "agent.wait"], options())
      assert_receive {:opened, _, _}
      assert_receive {:closed, _}
      assert OwnerTransport.lost?()
      assert {:error, :openclaw_owner_connection_lost} = Transport.command(["gateway", "call", "sessions.abort"], options())
      refute_receive {:opened, _, _}
      refute_receive {:closed, _}
    end)

    refute OwnerTransport.active?()
  end

  test "bounded persistent framing and all failed process paths permanently fence this owner" do
    for {replies, expected} <- [
          {[{:data, {:eol, ~s({"code":124})}}], :openclaw_owner_credentials_unavailable},
          {[{:data, {:eol, ~s({"code":123})}}], :openclaw_owner_connection_lost},
          {[{:data, {:eol, ~s({"code":122})}}], :openclaw_owner_access_rejected},
          {[{:data, {:eol, "invalid"}}], :openclaw_gateway_unavailable},
          {[{:exit_status, 127}], :openclaw_binary_missing},
          {[{:data, {:noeol, String.duplicate("x", 2_000_001)}}], :openclaw_response_too_large},
          {[], :openclaw_owner_connection_lost}
        ] do
      OwnerTransport.within(fn ->
        Process.put(:replies, replies)
        assert {:error, ^expected} = Transport.command(["gateway", "call", "agent"], options())
        assert OwnerTransport.lost?()
      end)
    end

    OwnerTransport.within(fn ->
      Process.put(:replies, [{:data, {:noeol, "{\"code\":0,"}}, {:data, {:eol, "\"output\":\"ok\"}"}}])
      assert {:ok, "ok"} = Transport.command(["gateway", "call", "agents.list"], options())
    end)

    Process.put(:open_failure, true)

    OwnerTransport.within(fn ->
      assert {:error, :openclaw_owner_connection_lost} = Transport.command(["gateway", "call", "agent"], options())
      assert OwnerTransport.lost?()
    end)
  end
end
