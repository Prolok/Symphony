# Operator tool: all credentials stay behind the configured Linear client.
# Each invocation uses exactly one identity and one explicit workflow.
alias SymphonyElixir.{Config, EnvFile, Tracker, Workflow}
alias SymphonyElixir.Linear.{Client, IssueLease, WorkpadTransfer, WriteContext}

result = with :ok <- Workflow.set_workflow_file_path(System.fetch_env!("SYMPHONY_WORKFLOW_FILE")),
              :ok <- EnvFile.load_runtime(EnvFile.config_dir(System.fetch_env!("SYMPHONY_SOURCE_REPO"))),
              {:ok, _} <- Application.ensure_all_started(:req),
              :ok <- Config.validate_startup_requirements() do
  query = fn document, variables ->
    case Client.graphql(document, variables) do
      {:ok, %{"data" => data} = body} ->
        if Map.get(body, "errors", []) in [nil, []], do: {:ok, data}, else: {:error, :graphql_failed}
      error -> error
    end
  end

  api = fn
    :identity, _ ->
      with {:ok, %{"viewer" => viewer}} <- query.("{ viewer { id app organization { id } } }", %{}) do
        {:ok, %{"workspace_id" => viewer["organization"]["id"], "user_id" => viewer["id"], "app" => viewer["app"]}}
      end
    :list, %{"issue_id" => issue_id} ->
      with {:ok, comments} <- Tracker.fetch_issue_comments(issue_id) do
        {:ok, Enum.map(comments, fn c -> %{"id" => c.id, "body" => c.body, "user" => %{"id" => c.user_id}} end)}
      end
    :update, %{"id" => id, "body" => body} -> Tracker.update_comment(id, body)
    :create, input ->
      with {:ok, %{"commentCreate" => %{"success" => true}}} <- query.(
        "mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success comment { id } } }", %{"input" => input}) do
        :ok
      end
  end

  WriteContext.with_context(%{run_id: Ecto.UUID.generate(), phase: "Kontrollierte lokale Umstellung"}, fn ->
    case System.argv() do
      ["identity"] -> api.(:identity, %{})
      ["candidates" | expected] ->
        with {:ok, issues} <- Tracker.fetch_candidate_issues(),
             true <- Enum.all?(issues, &(&1.identifier in expected)) do
          {:ok, Enum.map(issues, &Map.take(&1, [:id, :identifier, :state, :assignee_id]))}
        else
          false -> {:error, :unexpected_candidate_do_not_start}
          error -> error
        end
      ["graphql", file] ->
        input = file |> File.read!() |> Jason.decode!()
        query.(input["query"], input["variables"] || %{})
      [stage, file] when stage in ["begin", "retire", "activate", "ready"] ->
        input = file |> File.read!() |> Jason.decode!()
        binding = Map.put(input["binding"], "state_root", Path.join(EnvFile.bound_config_dir(), "state"))
        issue_id = input["issue_id"]
        IssueLease.with_lock(binding["workspace_id"], issue_id, fn ->
          case stage do
            "begin" -> WorkpadTransfer.begin(binding, issue_id, input["target_user"], input["backup"], api)
            "retire" -> WorkpadTransfer.retire(binding, issue_id, api)
            "activate" -> WorkpadTransfer.activate(binding, issue_id, api)
            "ready" ->
              with {:ok, identity} <- api.(:identity, %{}),
                   {:ok, comments} <- api.(:list, %{"issue_id" => issue_id}) do
                WorkpadTransfer.ready(Map.put(binding, "user_id", identity["user_id"]), issue_id, comments)
              end
          end
        end)
      _ -> {:error, :usage_identity_candidates_graphql_begin_retire_activate_ready}
    end
  end)
end

case result do
  :ok -> IO.puts(Jason.encode!(%{ok: true}))
  {:ok, value} -> IO.puts(Jason.encode!(%{ok: value}))
  {:error, reason} ->
    IO.puts(:stderr, "linear-app: " <> inspect(reason))
    System.halt(1)
end
