defmodule SymphonyElixir.Yolo.OpenClaw.Transport do
  @moduledoc "Bounded process boundary; compiled test builds cannot execute OpenClaw."
  alias SymphonyElixir.{Config, RuntimePaths}
  @test_build Application.compile_env(:symphony_elixir, :openclaw_test_build, false)

  @spec command([String.t()]) :: {:ok, String.t()} | {:error, atom()}
  def command(args) do
    if @test_build or System.get_env("SYMPHONY_OPENCLAW_TEST_DENY") == "1" do
      raise "OpenClaw process access forbidden in standard tests; inject a transport"
    end

    case System.find_executable("python3") do
      nil -> {:error, :openclaw_transport_python_missing}
      python -> invoke(python, args)
    end
  end

  defp invoke(python, args) do
    helper = Path.join(RuntimePaths.workflow_dir(), "scripts/openclaw-rpc.py")
    env = Config.without_linear_secret([]) |> Enum.map(fn {k, v} -> {String.to_charlist(k), if(v, do: String.to_charlist(v), else: false)} end)
    port = Port.open({:spawn_executable, python}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: ["-I", helper], env: env])

    try do
      true = Port.command(port, Jason.encode!(args) <> "\n")
      receive_output(port, "", System.monotonic_time(:millisecond) + 15_000)
    after
      if Port.info(port), do: Port.close(port)
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

      {^port, {:exit_status, 127}} ->
        {:error, :openclaw_binary_missing}

      {^port, {:exit_status, _}} ->
        {:error, :openclaw_gateway_unavailable}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :openclaw_transport_timeout}
    end
  end
end
