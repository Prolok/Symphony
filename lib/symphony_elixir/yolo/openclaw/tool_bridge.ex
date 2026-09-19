defmodule SymphonyElixir.Yolo.OpenClaw.ToolBridge do
  @moduledoc "Ephemeral loopback MCP bridge with a frozen server-owned project and PO scope."
  alias SymphonyElixir.Codex.MCPServer
  alias SymphonyElixir.Linear.WriteContext
  alias SymphonyElixir.{ProjectContext, RuntimePaths}
  alias SymphonyElixir.Yolo.OpenClaw.Journal
  @allowed ~w(linear_graphql symphony_comments symphony_yolo_action symphony_yolo_complete symphony_test)

  @spec start(map(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start(order, directory, opts \\ []) do
    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         {:ok, socket} <- listen(),
         {:ok, port} <- :inet.port(socket) do
      token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      descriptor = Path.join(directory, "tools.json")
      File.write!(descriptor, Jason.encode!(%{port: port, token: token}))
      File.chmod!(descriptor, 0o600)
      parent = self()
      context = ProjectContext.current()
      writes = WriteContext.current()

      pid = spawn_link(fn -> serve_bound(context, writes, socket, parent, order, token, opts) end)

      {:ok, %{pid: pid, socket: socket, descriptor: descriptor, helper: Path.join(RuntimePaths.workflow_dir(), "scripts/sym-yolo-tool.py")}}
    end
  end

  defp listen do
    :gen_tcp.listen(0, [:binary, packet: :line, packet_size: 1_048_576, active: false, ip: {127, 0, 0, 1}, send_timeout: 5000, send_timeout_close: true])
  end

  @spec stop(map()) :: :ok
  def stop(bridge) do
    :gen_tcp.close(bridge.socket)
    Process.unlink(bridge.pid)
    Process.exit(bridge.pid, :shutdown)
    File.rm(bridge.descriptor)
    :ok
  end

  defp serve_bound(context, writes, socket, parent, order, token, opts) do
    Process.monitor(parent)
    callback = fn -> serve(socket, parent, order, token, opts) end
    ProjectContext.with_context(context, fn -> WriteContext.with_context(writes, callback) end)
  end

  defp serve(socket, parent, order, token, opts) do
    if Process.alive?(parent) do
      case :gen_tcp.accept(socket, 500) do
        {:ok, client} ->
          respond(client, order, token, opts)
          :gen_tcp.close(client)
          serve(socket, parent, order, token, opts)

        {:error, :timeout} ->
          serve(socket, parent, order, token, opts)

        _ ->
          :ok
      end
    end
  end

  defp respond(client, order, token, opts) do
    result =
      with {:ok, line} <- :gen_tcp.recv(client, 0, 5000),
           {:ok, %{"token" => ^token, "request" => %{"jsonrpc" => "2.0", "id" => id} = request}} <- Jason.decode(line),
           false <- is_nil(id),
           true <- Journal.writable?(order["group"], order["id"]) do
        dispatch(request, opts)
      else
        _ -> %{"error" => %{"code" => -32_603, "message" => "Expired or invalid Symphony run binding"}}
      end

    :gen_tcp.send(client, Jason.encode!(result) <> "\n")
  end

  defp dispatch(%{"method" => "tools/list"} = request, opts) do
    response = MCPServer.handle_request(request, opts)
    update_in(response, ["result", "tools"], &Enum.filter(&1, fn tool -> tool["name"] in @allowed end))
  end

  defp dispatch(%{"method" => "tools/call", "params" => %{"name" => name}} = request, opts) when name in @allowed,
    do: MCPServer.handle_request(request, opts)

  defp dispatch(%{"method" => method} = request, opts) when method in ["initialize", "ping"], do: MCPServer.handle_request(request, opts)
  defp dispatch(_request, _opts), do: %{"error" => %{"code" => -32_601, "message" => "Tool not available in this PO run"}}
end
