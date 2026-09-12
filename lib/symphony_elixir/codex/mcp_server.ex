defmodule SymphonyElixir.Codex.MCPServer do
  @moduledoc """
  Minimal stdio MCP server exposing Symphony's `linear_graphql` tool.
  """

  alias SymphonyElixir.Codex.CommentTool
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Codex.LinearGraphqlTool
  alias SymphonyElixir.Codex.MergeTool
  alias SymphonyElixir.{EnvFile, Workflow}

  @protocol_version "2025-06-18"
  @server_name "symphony-linear"

  @type main_opt ::
          {:bootstrap_fun, (-> :ok | {:error, term()})}
          | {:run_fun, ([String.t()], keyword() -> :ok)}
          | {:halt_fun, (integer() -> no_return())}
          | {:stderr_device, atom() | pid()}
  @type request_handler_opt ::
          {:linear_client, (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()})}
  @type response :: map() | nil

  @spec main([String.t()], [main_opt() | request_handler_opt()]) :: :ok | no_return()
  def main(args \\ [], opts \\ []) when is_list(args) and is_list(opts) do
    bootstrap_fun = Keyword.get(opts, :bootstrap_fun, &bootstrap/0)
    run_fun = Keyword.get(opts, :run_fun, &run/2)
    halt_fun = Keyword.get(opts, :halt_fun, &System.halt/1)
    stderr_device = Keyword.get(opts, :stderr_device, :stderr)
    run_opts = Keyword.drop(opts, [:bootstrap_fun, :run_fun, :halt_fun, :stderr_device])

    case bootstrap_fun.() do
      :ok ->
        run_fun.(args, run_opts)

      {:error, reason} ->
        IO.puts(stderr_device, "sym-codex-mcp: #{format_bootstrap_error(reason)}")
        halt_fun.(1)
    end
  end

  @spec bootstrap(keyword()) :: :ok | {:error, term()}
  def bootstrap(opts \\ []) do
    env_loader = Keyword.get(opts, :env_loader, &load_project_env/1)
    logger_configurer = Keyword.get(opts, :logger_configurer, &silence_stdout_logger/0)
    workflow_setter = Keyword.get(opts, :workflow_setter, &Workflow.set_workflow_file_path/1)
    source_repo = env_value("SYMPHONY_SOURCE_REPO") || File.cwd!()
    env_files_root = env_value("SYMPHONY_PROJECT_ROOT") || source_repo
    workflow_file = env_value("SYMPHONY_WORKFLOW_FILE") || Workflow.default_workflow_file_path()

    with :ok <- logger_configurer.(),
         :ok <- workflow_setter.(workflow_file),
         :ok <- env_loader.(EnvFile.config_dir(env_files_root)),
         {:ok, _apps} <- Application.ensure_all_started(:req) do
      :ok
    end
  end

  defp env_value(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _empty_or_missing -> nil
    end
  end

  defp silence_stdout_logger do
    :logger.remove_handler(:default)
    :ok
  end

  defp load_project_env(config_dir), do: EnvFile.load_runtime(config_dir)

  @spec run([String.t()], keyword()) :: :ok
  def run(_args \\ [], opts \\ []) do
    input = Keyword.get(opts, :input, :stdio)
    output = Keyword.get(opts, :output, :stdio)

    # MCP carries UTF-8 JSON bytes. Elixir's Unicode stdio would transcode
    # binwrite's bytes as Latin-1, and a binary read needs the same raw mode.
    :ok = :io.setopts(io_device(input), encoding: :latin1)
    :ok = :io.setopts(io_device(output), encoding: :latin1)

    input
    |> IO.binstream(:line)
    |> Enum.each(fn line ->
      case handle_message(line, opts) do
        nil ->
          :ok

        response ->
          IO.binwrite(output, response_line(response))
      end
    end)

    :ok
  end

  defp io_device(:stdio), do: :standard_io
  defp io_device(:stderr), do: :standard_error
  defp io_device(device), do: device

  @spec handle_message(String.t(), keyword()) :: response()
  def handle_message(line, opts \\ []) when is_binary(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      nil
    else
      case Jason.decode(trimmed) do
        {:ok, request} when is_map(request) -> handle_request(request, opts)
        {:ok, _other} -> jsonrpc_error(nil, -32_600, "Invalid Request")
        {:error, _reason} -> jsonrpc_error(nil, -32_700, "Parse error")
      end
    end
  end

  @spec handle_request(map()) :: response()
  def handle_request(request), do: handle_request(request, [])

  @spec handle_request(map(), keyword()) :: response()
  def handle_request(%{"jsonrpc" => "2.0", "method" => method} = request, opts) do
    id = Map.get(request, "id")

    case {method, id} do
      {"initialize", request_id} when not is_nil(request_id) ->
        jsonrpc_result(request_id, %{
          "protocolVersion" => @protocol_version,
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{
            "name" => @server_name,
            "version" => to_string(Application.spec(:symphony_elixir, :vsn) || "0.1.0")
          }
        })

      {"notifications/initialized", nil} ->
        nil

      {"ping", request_id} when not is_nil(request_id) ->
        jsonrpc_result(request_id, %{})

      {"tools/list", request_id} when not is_nil(request_id) ->
        jsonrpc_result(request_id, %{"tools" => DynamicTool.tool_specs()})

      {"tools/call", request_id} when not is_nil(request_id) ->
        handle_tool_call(request_id, Map.get(request, "params"), opts)

      {_other, nil} ->
        nil

      {_other, request_id} ->
        jsonrpc_error(request_id, -32_601, "Method not found")
    end
  end

  def handle_request(%{"id" => id}, _opts), do: jsonrpc_error(id, -32_600, "Invalid Request")
  def handle_request(_request, _opts), do: jsonrpc_error(nil, -32_600, "Invalid Request")

  defp handle_tool_call(id, %{"name" => name, "arguments" => arguments}, opts)
       when name in ["symphony_merge", "symphony_linear.symphony_merge"] do
    jsonrpc_result(id, MergeTool.mcp_call(arguments, opts))
  end

  defp handle_tool_call(id, %{"name" => name, "arguments" => arguments}, opts)
       when name in ["symphony_comments", "symphony_linear.symphony_comments"] do
    jsonrpc_result(id, CommentTool.mcp_call(arguments, opts))
  end

  defp handle_tool_call(id, %{"name" => name, "arguments" => arguments}, opts)
       when is_binary(name) do
    if LinearGraphqlTool.canonical_tool_name(name) == LinearGraphqlTool.tool_name() do
      linear_client = Keyword.get(opts, :linear_client)
      tool_opts = if linear_client, do: [linear_client: linear_client], else: []
      jsonrpc_result(id, LinearGraphqlTool.mcp_call(arguments, tool_opts))
    else
      jsonrpc_error(id, -32_602, "Unknown tool: #{name}")
    end
  end

  defp handle_tool_call(id, _params, _opts), do: jsonrpc_error(id, -32_602, "Invalid tool call")

  defp jsonrpc_result(id, result) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => result
    }
  end

  defp jsonrpc_error(id, code, message) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => code,
        "message" => message
      }
    }
  end

  defp response_line(response) do
    Jason.encode!(response) <> "\n"
  end

  defp format_bootstrap_error({:invalid_env_file, path, line_number, reason}) do
    "#{path}:#{line_number}: #{inspect(reason)}"
  end

  defp format_bootstrap_error({:env_file_read_failed, path, reason}) do
    "#{path}: #{inspect(reason)}"
  end

  defp format_bootstrap_error(reason), do: inspect(reason)
end
