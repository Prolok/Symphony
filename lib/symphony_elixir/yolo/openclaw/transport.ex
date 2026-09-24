defmodule SymphonyElixir.Yolo.OpenClaw.Transport do
  @moduledoc "Bounded process boundary; compiled test builds cannot execute OpenClaw."
  alias SymphonyElixir.{Config, RuntimePaths}
  alias SymphonyElixir.Yolo.OpenClaw.OwnerTransport
  @test_build Application.compile_env(:symphony_elixir, :openclaw_test_build, false)

  @spec command([String.t()], keyword()) :: {:ok, String.t()} | {:error, atom()}
  def command(args, opts \\ []) do
    ports = Keyword.get(opts, :ports, Port)

    if ports == Port and (@test_build or System.get_env("SYMPHONY_OPENCLAW_TEST_DENY") == "1") do
      raise "OpenClaw process access forbidden in standard tests; inject a transport"
    end

    find = Keyword.get(opts, :find_executable, &System.find_executable/1)

    case find.("python3") do
      nil -> {:error, :openclaw_transport_python_missing}
      python -> dispatch(python, args, ports, opts)
    end
  end

  defp dispatch(python, ["gateway", "call", method | _] = args, ports, opts) when method in ~w(agents.list agent agent.wait sessions.abort) do
    # First lost-owner observation fences the journal. Later read-only polls may
    # still obtain a real terminal/inactivity proof through the existing CLI.
    if OwnerTransport.active?() and not (method == "agent.wait" and OwnerTransport.lost?()),
      do: OwnerTransport.command(python, args, ports, opts),
      else: invoke(python, args, ports, opts)
  end

  defp dispatch(python, args, ports, opts), do: invoke(python, args, ports, opts)

  defp invoke(python, args, ports, opts) do
    helper = Path.join(RuntimePaths.workflow_dir(), "scripts/openclaw-rpc.py")
    env = Config.without_linear_secret([]) |> Enum.map(fn {k, v} -> {String.to_charlist(k), if(v, do: String.to_charlist(v), else: false)} end)
    port = ports.open({:spawn_executable, python}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: ["-I", helper], env: env])

    try do
      true = ports.command(port, Jason.encode!(args) <> "\n")
      receive_output(port, "", System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 15_000))
    after
      if ports.info(port), do: ports.close(port)
    end
  rescue
    _ -> {:error, :openclaw_transport_failed}
  end

  defp receive_output(port, output, deadline) do
    receive do
      {^port, {:data, bytes}} when byte_size(output) + byte_size(bytes) <= 2_000_000 ->
        receive_output(port, output <> bytes, deadline)

      {^port, {:data, _}} ->
        {:error, :openclaw_response_too_large}

      {^port, {:exit_status, 0}} ->
        {:ok, output}

      {^port, {:exit_status, 124}} ->
        {:error, :openclaw_owner_credentials_unavailable}

      {^port, {:exit_status, 123}} ->
        {:error, :openclaw_owner_connection_lost}

      {^port, {:exit_status, 122}} ->
        {:error, :openclaw_owner_access_rejected}

      {^port, {:exit_status, 127}} ->
        {:error, :openclaw_binary_missing}

      {^port, {:exit_status, _}} ->
        {:error, :openclaw_gateway_unavailable}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :openclaw_transport_timeout}
    end
  end
end
