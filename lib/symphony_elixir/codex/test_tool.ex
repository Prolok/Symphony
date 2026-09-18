defmodule SymphonyElixir.Codex.TestTool do
  @moduledoc "Bound, secret-free requests to an operator-provisioned isolated test executor."

  alias SymphonyElixir.{CommentCheckpoint, Config, PathSafety}
  alias SymphonyElixir.Linear.WriteContext

  @operations ~w(start result cancel cleanup)
  @fields ~w(operation run_id head_sha source_sha256 scenario)
  @phases ["In Arbeit (AI)", "PreReview (AI)", "Review (AI)", "Test (AI)"]
  @socket_options [:binary, active: false, packet: :line, packet_size: 65_536]

  @spec tool_spec() :: map()
  def tool_spec do
    %{
      "name" => "symphony_test",
      "description" =>
        "Run or inspect an isolated, source-bound development test after operator provisioning. Reuse run_id after an uncertain response; cleanup never upgrades a failed test. No credentials or arbitrary paths accepted.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => @fields,
        "properties" => %{
          "operation" => %{"type" => "string", "enum" => @operations},
          "run_id" => %{"type" => "string", "pattern" => "^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$"},
          "head_sha" => %{"type" => "string", "pattern" => "^[0-9a-f]{40}$"},
          "source_sha256" => %{"type" => "string", "pattern" => "^[0-9a-f]{64}$"},
          "scenario" => %{"type" => "string", "enum" => ["bootstrap", "failure-probe"]}
        }
      }
    }
  end

  @spec invoke(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def invoke(arguments, opts \\ []) do
    context = WriteContext.current()
    request = Keyword.get(opts, :test_request, &request/2)

    with true <- valid_arguments?(arguments),
         owner when is_binary(owner) <- context["issue_id"],
         nil <- context["worker_host"],
         {:ok, issue} <- CommentCheckpoint.bound_issue(owner, opts),
         true <- issue.state in @phases,
         {:ok, workspace} <- workspace(issue.identifier),
         socket when is_binary(socket) <- Config.test_executor_socket() do
      request.(socket, Map.merge(arguments, %{"issue_id" => owner, "identifier" => issue.identifier, "checkout" => workspace}))
    else
      {:error, _} = error -> error
      nil -> {:error, :test_executor_not_provisioned_or_unbound}
      _ -> {:error, :invalid_bound_test_context}
    end
  end

  defp valid_arguments?(arguments) when is_map(arguments) do
    Enum.sort(Map.keys(arguments)) == Enum.sort(@fields) and
      arguments["operation"] in @operations and arguments["scenario"] in ["bootstrap", "failure-probe"] and
      matches?(arguments["run_id"], ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,47}\z/) and
      matches?(arguments["head_sha"], ~r/\A[0-9a-f]{40}\z/) and
      matches?(arguments["source_sha256"], ~r/\A[0-9a-f]{64}\z/)
  end

  defp valid_arguments?(_arguments), do: false
  defp matches?(value, pattern), do: is_binary(value) and Regex.match?(pattern, value)

  defp workspace(identifier) do
    with {:ok, root} <- PathSafety.canonicalize(Config.settings!().workspace.root),
         {:ok, path} <- PathSafety.canonicalize(Path.join(root, identifier)),
         true <- String.starts_with?(path <> "/", root <> "/") and File.dir?(path) do
      {:ok, path}
    else
      _ -> {:error, :test_workspace_unverified}
    end
  end

  @doc false
  @spec request(Path.t(), map()) :: {:ok, map()} | {:error, term()}
  def request(path, payload) do
    case :gen_tcp.connect({:local, String.to_charlist(path)}, 0, @socket_options, 5_000) do
      {:ok, socket} ->
        try do
          with :ok <- :gen_tcp.send(socket, Jason.encode!(payload) <> "\n"),
               {:ok, response} <- :gen_tcp.recv(socket, 0, 5_000),
               {:ok, %{} = result} <- Jason.decode(response) do
            if Map.has_key?(result, "error"), do: {:error, {:test_executor_rejected, result["error"]}}, else: {:ok, result}
          else
            _ -> {:error, :test_executor_response_uncertain_query_same_run}
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, _} ->
        {:error, :test_executor_unavailable}
    end
  end

  @spec execute(term(), keyword()) :: map()
  def execute(arguments, opts \\ []) do
    {success, output} = response(invoke(arguments, opts))
    %{"success" => success, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end

  @spec mcp_call(term(), keyword()) :: map()
  def mcp_call(arguments, opts \\ []) do
    {success, output} = response(invoke(arguments, opts))
    %{"isError" => not success, "content" => [%{"type" => "text", "text" => output}]}
  end

  defp response({:ok, result}), do: {true, Jason.encode!(result)}
  defp response({:error, reason}), do: {false, Jason.encode!(%{"error" => inspect(reason)})}
end
