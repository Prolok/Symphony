defmodule SymphonyElixir.Codex.MergeTool do
  @moduledoc "Bound execution of the existing land helper, with a fresh comment check at the actual merge request."
  alias SymphonyElixir.{CommentCheckpoint, Config, PathSafety, RoutineTest, RuntimePaths, SSH}
  alias SymphonyElixir.Linear.{Client, WriteContext}

  @spec tool_spec() :: map()
  def tool_spec do
    %{
      "name" => "symphony_merge",
      "description" => "Run the existing GitHub land gates and merge the bound issue PR only after a fresh Linear comment checkpoint. Requires a clean, tested worktree and expected PR head.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["head_sha"],
        "properties" => %{
          "head_sha" => %{"type" => "string"},
          "issue_id" => %{"type" => "string"}
        }
      }
    }
  end

  @spec invoke(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def invoke(arguments, opts \\ []) do
    with %{"head_sha" => head} when is_binary(head) <- arguments,
         true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, head),
         {:ok, issue} <- fresh_bound_issue(arguments["issue_id"] || WriteContext.current()["issue_id"], opts),
         true <- issue.state == "Merge (AI)",
         {:ok, workspace} <- workspace(issue, WriteContext.current()["worker_host"]),
         {:ok, port} <- start_port(workspace, issue, head, WriteContext.current()["worker_host"]) do
      result = run(port, issue, opts)
      RoutineTest.record_architecture_failure(issue.id, issue.identifier, head, result)
      result
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_bound_merge_context}
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

  defp workspace(issue, nil) do
    with {:ok, root} <- PathSafety.canonicalize(Config.settings!().workspace.root),
         {:ok, workspace} <- PathSafety.canonicalize(Path.join(root, issue.identifier)),
         true <- String.starts_with?(workspace <> "/", root <> "/") and File.dir?(workspace) do
      {:ok, workspace}
    else
      _ -> {:error, :merge_workspace_unverified}
    end
  end

  defp workspace(issue, worker_host) when is_binary(worker_host) do
    workspace = WriteContext.current()["workspace_path"]

    if is_binary(workspace) and Path.type(workspace) == :absolute and Path.basename(workspace) == issue.identifier and not String.contains?(workspace, ["\n", "\r", <<0>>]),
      do: {:ok, workspace},
      else: {:error, :merge_workspace_unverified}
  end

  defp start_port(workspace, issue, head, worker_host) when is_binary(worker_host) do
    script = Path.join(RuntimePaths.workflow_dir(), ".codex/skills/symphony-land/land_watch.py")

    environment =
      process_env(issue, workspace)
      |> Enum.map_join(" && ", fn
        {name, nil} -> "unset #{name}"
        {name, value} -> "export #{name}=#{shell_escape(value)}"
      end)

    command =
      "cd #{shell_escape(workspace)} && #{environment} && exec python3 -u #{shell_escape(script)} --bound-merge #{shell_escape(head)} #{shell_escape("#{issue.identifier}: #{issue.title}")}"

    SSH.start_port(worker_host, command, line: 1_048_576)
  end

  defp start_port(workspace, issue, head, nil) do
    case System.find_executable("python3") do
      nil -> {:error, :python_not_found}
      python -> {:ok, local_port(python, workspace, issue, head)}
    end
  end

  defp local_port(python, workspace, issue, head) do
    script = Path.join(RuntimePaths.workflow_dir(), ".codex/skills/symphony-land/land_watch.py")

    env =
      process_env(issue, workspace)
      |> Enum.map(fn {key, value} -> {String.to_charlist(key), if(is_nil(value), do: false, else: String.to_charlist(value))} end)

    Port.open({:spawn_executable, python}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:line, 1_048_576},
      {:cd, workspace},
      {:env, env},
      {:args, ["-u", script, "--bound-merge", head, "#{issue.identifier}: #{issue.title}"]}
    ])
  end

  defp run(port, issue, opts) do
    receive_result(port, issue, opts, nil, "")
  after
    if Port.info(port), do: Port.close(port)
  end

  defp process_env(issue, workspace) do
    RuntimePaths.cleaned_builtin_system_env(%{"SYMPHONY_ISSUE_IDENTIFIER" => issue.identifier, "SYMPHONY_ACTIVE_REPO_ROOT" => workspace})
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp receive_result(port, issue, opts, result, output) do
    receive do
      {^port, {:data, {:eol, "SYMPHONY_BOUND_REQUEST " <> json}}} ->
        reply = handle_checkpoint(Jason.decode(json), issue, opts)
        Port.command(port, Jason.encode!(reply) <> "\n")
        receive_result(port, issue, opts, result, output <> (reply["error"] || ""))

      {^port, {:data, {:eol, "SYMPHONY_MERGE_RESULT " <> json}}} ->
        receive_result(port, issue, opts, Jason.decode(json), output)

      {^port, {:data, {_type, line}}} ->
        receive_result(port, issue, opts, result, String.slice(output <> line <> "\n", -8_192, 8_192))

      {^port, {:exit_status, 0}} when not is_nil(result) ->
        result

      {^port, {:exit_status, status}} ->
        {:error, {:bound_merge_incomplete, status, output}}
    after
      Keyword.get(opts, :timeout_ms, 600_000) -> {:error, :bound_merge_timeout}
    end
  end

  @doc false
  @spec handle_checkpoint(term(), map(), keyword()) :: map()
  def handle_checkpoint({:ok, %{"operation" => operation}}, issue, opts) when operation in ["labels", "merge"] do
    fetch_labels = Keyword.get(opts, :labels, &labels/1)
    guard = Keyword.get(opts, :guard, &CommentCheckpoint.before_action/1)
    fetch_issue = Keyword.get(opts, :bound_issue, &fresh_bound_issue/1)

    with {:ok, %{state: "Merge (AI)"}} <- fetch_issue.(issue.id),
         {:ok, labels} <- fetch_labels.(issue.id),
         :ok <- if(operation == "merge", do: guard.(issue), else: :ok) do
      %{"ok" => true, "labels" => Enum.sort(labels)}
    else
      error -> %{"ok" => false, "error" => inspect(error)}
    end
  end

  def handle_checkpoint({:ok, %{"operation" => "architecture"} = request}, issue, opts) do
    fetch_issue = Keyword.get(opts, :bound_issue, &fresh_bound_issue/1)

    with :ok <- valid_architecture_request(request),
         {:ok, %{state: "Merge (AI)"}} <- fetch_issue.(issue.id),
         :ok <- mark_architecture_workpad(issue, request),
         :ok <- add_architecture_label(issue) do
      %{"ok" => true}
    else
      error -> %{"ok" => false, "error" => inspect(error)}
    end
  end

  def handle_checkpoint(_request, _issue, _opts), do: %{"ok" => false, "error" => "Invalid bound request"}

  defp fresh_bound_issue(id, opts \\ []) do
    CommentCheckpoint.bound_issue(id, Keyword.put_new(opts, :fetch_issue, &Client.fetch_issue_states_by_ids/1))
  end

  defp valid_architecture_request(%{"paths" => paths, "justification" => reason, "base" => base, "head" => head, "url" => url}) do
    if valid_paths?(paths) and short_text?(reason) and is_binary(url) and
         String.starts_with?(url, "https://") and sha?(base) and sha?(head),
       do: :ok,
       else: {:error, :invalid_architecture_request}
  end

  defp valid_architecture_request(_), do: {:error, :invalid_architecture_request}
  defp valid_paths?(paths), do: is_list(paths) and paths != [] and Enum.all?(paths, &short_path?/1)
  defp short_path?(path), do: short_text?(path) and not String.contains?(path, ["\n", "\r"])
  defp short_text?(text), do: is_binary(text) and byte_size(text) > 0 and byte_size(text) < 512
  defp sha?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40}\z/, value)

  defp mark_architecture_workpad(issue, request) do
    with {:ok, comments} <- Client.fetch_issue_comments(issue.id),
         [workpad] <- Enum.filter(comments, &String.starts_with?(&1.body, "## Symphony Workpad")) do
      workpad_id = workpad.id
      payload = Map.take(request, ["paths", "justification", "base", "head", "url"])
      section = "### Architekturänderung\n\n```json\n" <> Jason.encode!(payload) <> "\n```"

      body =
        if String.contains?(workpad.body, "\n### Architekturänderung\n") do
          Regex.replace(~r/\n### Architekturänderung\n[\s\S]*?(?=\n### [^\n]+\n|\z)/, workpad.body, "\n" <> section <> "\n")
        else
          String.trim_trailing(workpad.body) <> "\n\n" <> section <> "\n"
        end

      if body == workpad.body, do: :ok, else: update_architecture_workpad(workpad_id, body)
    else
      error -> {:error, {:architecture_workpad_unavailable, error}}
    end
  end

  defp update_architecture_workpad(workpad_id, body) do
    query = "mutation SymphonyArchitectureWorkpad($id: String!, $body: String!) { commentUpdate(id: $id, input: {body: $body}) { success comment { id } } }"

    with {:ok, response} <- Client.graphql(query, %{id: workpad_id, body: body}),
         true <- get_in(response, ["data", "commentUpdate", "success"]) == true,
         ^workpad_id <- get_in(response, ["data", "commentUpdate", "comment", "id"]) do
      :ok
    else
      error -> {:error, {:architecture_workpad_update_failed, error}}
    end
  end

  defp add_architecture_label(issue) do
    with {:ok, existing} <- labels(issue.id) do
      if "Architekturänderung" in existing, do: :ok, else: find_architecture_label(issue)
    end
  end

  defp find_architecture_label(issue) do
    with {:ok, nodes} <- architecture_labels(nil, %{}, []) do
      nodes
      |> Enum.filter(&(&1["name"] == "Architekturänderung" and get_in(&1, ["team", "id"]) in [nil, issue.team_id]))
      |> apply_matching_architecture_label(issue.id)
    end
  end

  defp apply_matching_architecture_label([], _issue_id), do: :ok
  defp apply_matching_architecture_label([%{"id" => id}], issue_id), do: apply_architecture_label(issue_id, id)
  defp apply_matching_architecture_label(_, _issue_id), do: {:error, :architecture_label_ambiguous}

  defp architecture_labels(cursor, seen, acc) do
    query =
      "query SymphonyArchitectureLabel($name: String!, $after: String) { issueLabels(filter: {name: {eqIgnoreCase: $name}}, first: 100, after: $after) { nodes { id name team { id } } pageInfo { hasNextPage endCursor } } }"

    with {:ok, response} <- Client.graphql(query, %{name: "Architekturänderung", after: cursor}),
         %{"nodes" => nodes, "pageInfo" => page} <- get_in(response, ["data", "issueLabels"]),
         true <- is_list(nodes) and Enum.all?(nodes, &is_binary(&1["id"])) do
      next = page["endCursor"]

      cond do
        page["hasNextPage"] == false -> {:ok, acc ++ nodes}
        page["hasNextPage"] == true and is_binary(next) and next != "" and not Map.has_key?(seen, next) -> architecture_labels(next, Map.put(seen, next, true), acc ++ nodes)
        true -> {:error, :architecture_label_lookup_incomplete}
      end
    else
      error -> {:error, {:architecture_label_lookup_failed, error}}
    end
  end

  defp apply_architecture_label(issue_id, label_id) do
    query = "mutation SymphonyArchitectureLabelAdd($id: String!, $label: String!) { issueUpdate(id: $id, input: {addedLabelIds: [$label]}) { success issue { id } } }"

    with {:ok, response} <- Client.graphql(query, %{id: issue_id, label: label_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true,
         ^issue_id <- get_in(response, ["data", "issueUpdate", "issue", "id"]) do
      :ok
    else
      error -> {:error, {:architecture_label_update_failed, error}}
    end
  end

  defp labels(id), do: labels(id, nil, %{}, [])

  defp labels(id, cursor, seen, acc) do
    query = "query($id: String!, $after: String) { issue(id: $id) { labels(first: 100, after: $after) { nodes { name } pageInfo { hasNextPage endCursor } } } }"

    with {:ok, body} <- Client.graphql(query, %{id: id, after: cursor}),
         true <- Map.get(body, "errors", []) in [nil, []],
         %{"nodes" => nodes, "pageInfo" => page} <- get_in(body, ["data", "issue", "labels"]),
         true <- is_list(nodes) and Enum.all?(nodes, &is_binary(&1["name"])) do
      names = acc ++ Enum.map(nodes, & &1["name"])
      next = page["endCursor"]

      cond do
        page["hasNextPage"] == false -> {:ok, names}
        page["hasNextPage"] == true and is_binary(next) and next != "" and not Map.has_key?(seen, next) -> labels(id, next, Map.put(seen, next, true), names)
        true -> {:error, :merge_labels_incomplete}
      end
    else
      _ -> {:error, :merge_labels_incomplete}
    end
  end

  defp response({:ok, result}), do: {true, Jason.encode!(result)}
  defp response({:error, reason}), do: {false, Jason.encode!(%{"error" => inspect(reason)})}
end
