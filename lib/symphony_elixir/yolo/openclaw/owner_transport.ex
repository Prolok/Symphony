defmodule SymphonyElixir.Yolo.OpenClaw.OwnerTransport do
  @moduledoc "One worker-owned process/connection; never recreate ownership after loss."
  alias SymphonyElixir.{Config, RuntimePaths}
  @key {__MODULE__, :connection}
  @test_build Application.compile_env(:symphony_elixir, :openclaw_test_build, false)

  @spec within((-> result)) :: result when result: var
  def within(callback) do
    previous = Process.put(@key, :unopened)

    try do
      callback.()
    after
      case Process.get(@key) do
        {port, ports} -> close(port, ports)
        _ -> :ok
      end

      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @spec active?() :: boolean()
  def active?, do: not is_nil(Process.get(@key))

  @spec lost?() :: boolean()
  def lost?, do: Process.get(@key) == :lost

  @spec command(String.t(), [String.t()], module(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def command(python, args, ports, opts) do
    if ports == Port and (@test_build or System.get_env("SYMPHONY_OPENCLAW_TEST_DENY") == "1") do
      raise "OpenClaw process access forbidden in standard tests; inject a transport"
    end

    request(python, args, ports, opts)
  end

  defp request(python, args, ports, opts) do
    with {:ok, port} <- connection(python, ports),
         true <- ports.command(port, Jason.encode!(args) <> "\n") do
      receive_reply(port, "", System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 15_000))
    else
      _ -> fail(:openclaw_owner_connection_lost)
    end
  rescue
    _ -> fail(:openclaw_owner_connection_lost)
  end

  defp connection(python, ports) do
    case Process.get(@key) do
      :unopened ->
        Process.put(@key, :lost)
        helper = Path.join(RuntimePaths.workflow_dir(), "scripts/openclaw-rpc.py")
        env = Config.without_linear_secret([]) |> Enum.map(fn {k, v} -> {String.to_charlist(k), if(v, do: String.to_charlist(v), else: false)} end)

        port = ports.open({:spawn_executable, python}, [:binary, :exit_status, :use_stdio, {:line, 2_000_000}, args: ["-I", helper, "--stream"], env: env])
        Process.put(@key, {port, ports})
        {:ok, port}

      {port, _} ->
        {:ok, port}

      _ ->
        {:error, :openclaw_owner_connection_lost}
    end
  end

  defp receive_reply(port, output, deadline) do
    receive do
      {^port, {:data, {:noeol, bytes}}} when byte_size(output) + byte_size(bytes) <= 2_000_000 ->
        receive_reply(port, output <> bytes, deadline)

      {^port, {:data, {:eol, bytes}}} when byte_size(output) + byte_size(bytes) <= 2_000_000 ->
        case Jason.decode(output <> bytes) do
          {:ok, %{"code" => 0, "output" => reply}} when is_binary(reply) -> {:ok, reply}
          {:ok, %{"code" => 124}} -> fail(:openclaw_owner_credentials_unavailable)
          {:ok, %{"code" => 123}} -> fail(:openclaw_owner_connection_lost)
          {:ok, %{"code" => 122}} -> fail(:openclaw_owner_access_rejected)
          _ -> fail(:openclaw_gateway_unavailable)
        end

      {^port, {:data, _}} ->
        fail(:openclaw_response_too_large)

      {^port, {:exit_status, 127}} ->
        fail(:openclaw_binary_missing)

      {^port, {:exit_status, _}} ->
        fail(:openclaw_owner_connection_lost)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> fail(:openclaw_owner_connection_lost)
    end
  end

  defp fail(reason) do
    case Process.put(@key, :lost) do
      {port, ports} -> close(port, ports)
      _ -> :ok
    end

    {:error, reason}
  end

  defp close(port, ports) do
    if ports.info(port), do: ports.close(port)
  rescue
    _ -> :ok
  end
end
