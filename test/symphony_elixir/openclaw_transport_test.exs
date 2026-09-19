defmodule SymphonyElixir.OpenClawTransportTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Yolo.OpenClaw.Transport

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
    def close(port), do: send(self(), {:closed, port})
  end

  defp options do
    [ports: SyntheticPorts, find_executable: fn "python3" -> "/synthetic/python3" end, timeout_ms: 0]
  end

  test "default process access remains denied even with timing or lookup overrides" do
    for opts <- [[], [timeout_ms: 0], [find_executable: fn _ -> flunk("lookup before denial") end]] do
      assert_raise RuntimeError, ~r/forbidden in standard tests/, fn -> Transport.command(["--version"], opts) end
    end
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
end
