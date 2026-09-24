defmodule SymphonyElixir.Codex.TestTool do
  @moduledoc "Bound, secret-free requests to a managed test executor."

  alias SymphonyElixir.{CommentCheckpoint, Config, PathSafety, ProjectContext, ProjectPoller, Projects}
  alias SymphonyElixir.Linear.{Client, WriteContext}

  @operations ~w(start result cancel cleanup)
  @fields ~w(operation run_id head_sha source_sha256 scenario)
  @phases ["In Arbeit (AI)", "PreReview (AI)", "Review (AI)", "Test (AI)"]
  @socket_options [:binary, active: false, packet: :line, packet_size: 65_536]

  @spec tool_spec() :: map()
  def tool_spec do
    %{
      "name" => "symphony_test",
      "description" =>
        "Run or inspect an isolated, source-bound development test using the configured test executor. Reuse run_id after an uncertain response; cleanup never upgrades a failed test. No credentials or arbitrary paths accepted.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => @fields,
        "properties" => %{
          "operation" => %{"type" => "string", "enum" => @operations},
          "run_id" => %{"type" => "string", "pattern" => "^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$"},
          "head_sha" => %{"type" => "string", "pattern" => "^[0-9a-f]{40}$"},
          "source_sha256" => %{"type" => "string", "pattern" => "^[0-9a-f]{64}$"},
          "scenario" => %{"type" => "string", "enum" => ~w(bootstrap workflow failure-probe po_handoff po_followup)}
        }
      }
    }
  end

  @spec invoke(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def invoke(arguments, opts \\ []) do
    context = WriteContext.current()
    request = Keyword.get(opts, :test_request, &request/2)

    with :ok <- validate_arguments(arguments),
         {:ok, owner} <- owner(context),
         :ok <- local_worker(context),
         {:ok, socket} <- bound_socket(opts),
         {:ok, issue} <- bound_issue(owner, opts),
         {:ok, workspace} <- workspace(issue.identifier),
         :ok <- configured_scenario(arguments["scenario"], opts) do
      request.(socket, Map.merge(arguments, %{"issue_id" => owner, "identifier" => issue.identifier, "checkout" => workspace}))
    end
  end

  defp validate_arguments(arguments), do: if(valid_arguments?(arguments), do: :ok, else: {:error, :invalid_test_request})
  defp owner(%{"issue_id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp owner(_), do: {:error, :test_worker_issue_missing}
  defp local_worker(%{"worker_host" => host}) when is_binary(host), do: {:error, :test_remote_worker_not_supported}
  defp local_worker(_), do: :ok

  defp bound_socket(opts) do
    contexts = Keyword.get(opts, :contexts, Projects.configured())
    current = ProjectContext.current()
    poller = Keyword.get(opts, :poller_context, &ProjectPoller.context/1)

    cond do
      is_nil(current) or not Enum.any?(contexts, &(&1.id == current.id and &1.root == current.root)) ->
        {:error, :test_project_not_bound}

      not same_project_binding?(poller.(current), current) ->
        {:error, :test_poller_context_changed}

      true ->
        case Enum.filter(contexts, &(&1.name == "symphony-test" and is_map(&1.settings.worker.test_executor))) do
          [target] when is_binary(target.settings.worker.test_executor_socket) -> {:ok, target.settings.worker.test_executor_socket}
          _ -> {:error, :test_executor_not_configured}
        end
    end
  catch
    :exit, _ -> {:error, :test_poller_context_unavailable}
  end

  defp same_project_binding?(%ProjectContext{} = active, %ProjectContext{} = current) do
    active.id == current.id and active.root == current.root and
      active.settings.workspace.root == current.settings.workspace.root and
      active.settings.tracker.app["workspace_id"] == current.settings.tracker.app["workspace_id"] and
      active.assignee_ids == current.assignee_ids
  end

  defp same_project_binding?(_, _), do: false

  defp bound_issue(owner, opts) do
    fetch = Keyword.get(opts, :fetch_issue, &Client.fetch_issue_states_by_ids/1)

    with {:ok, [issue]} <- fetch.([owner]),
         true <- issue.id == owner,
         true <- issue.assigned_to_worker,
         :ok <- allowed_phase(issue),
         {:ok, bound} <- CommentCheckpoint.bound_issue(owner, Keyword.put(opts, :fetch_issue, fn _ -> {:ok, [issue]} end)) do
      {:ok, bound}
    else
      {:ok, [_]} -> {:error, :test_assignee_not_bound}
      false -> {:error, :test_assignee_not_bound}
      {:error, _} = error -> error
      _ -> {:error, :test_issue_lookup_incomplete}
    end
  end

  defp allowed_phase(%{state: state}), do: if(state in @phases, do: :ok, else: {:error, :test_phase_not_allowed})

  defp configured_scenario(scenario, opts) do
    target = Enum.find(Keyword.get(opts, :contexts, Projects.configured()), &(&1.name == "symphony-test"))
    if target && scenario in List.wrap((target.settings.worker.test_executor || %{})["scenarios"]), do: :ok, else: {:error, :test_scenario_not_configured}
  end

  defp valid_arguments?(arguments) when is_map(arguments) do
    Enum.sort(Map.keys(arguments)) == Enum.sort(@fields) and
      arguments["operation"] in @operations and arguments["scenario"] in ~w(bootstrap workflow failure-probe po_handoff po_followup) and
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
