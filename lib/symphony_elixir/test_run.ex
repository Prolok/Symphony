defmodule SymphonyElixir.TestRun do
  @moduledoc "Bound runtime operations for the operator's limited bootstrap scenario."

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, ProjectContext, Projects, TestInstance, Workspace}
  alias SymphonyElixir.Linear.{Client, DurableState}
  alias SymphonyElixir.Relay.Session

  @spec stage() :: String.t() | nil
  def stage, do: Config.test_run_stage()

  @spec execute(String.t()) :: {:ok, map()} | {:error, term()}
  def execute(stage) when stage in ["prepare", "probe", "cleanup"] do
    with %{} = instance <- Config.test_instance(),
         {:ok, plan} <- plan(),
         true <- plan["source"] == instance["source"],
         {:ok, journal} <- journal(plan),
         {:ok, result} <- execute_stage(stage, plan, journal) do
      {:ok, result}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_test_run}
    end
  end

  @spec bind_contexts([ProjectContext.t()]) :: {:ok, [ProjectContext.t()]} | {:error, term()}
  def bind_contexts(contexts) do
    with :ok <- environment_available() do
      bind_run_contexts(contexts)
    end
  end

  defp environment_available do
    if Config.test_instance() do
      active_run =
        case plan() do
          {:ok, plan} -> plan["run_id"]
          _ -> nil
        end

      Path.wildcard(Path.join([TestInstance.state_root(), "runs", "*", "fixtures.json"]))
      |> Enum.reduce_while(:ok, &check_pending_run(&1, &2, active_run))
    else
      :ok
    end
  end

  defp check_pending_run(path, :ok, active_run) do
    case DurableState.read(path) do
      {:ok, %{"run_id" => id, "fixtures" => fixtures}} when is_list(fixtures) ->
        if id == active_run or Enum.all?(fixtures, &(&1["deleted"] == true)), do: {:cont, :ok}, else: {:halt, {:error, :test_environment_needs_cleanup}}

      _ ->
        {:halt, {:error, :test_environment_journal_corrupt}}
    end
  end

  defp bind_run_contexts(contexts) do
    if stage() == "run" do
      with {:ok, plan} <- plan(),
           {:ok, journal} <- journal(plan, contexts),
           true <- length(journal["fixtures"]) == 2 and Enum.all?(journal["fixtures"], &(&1["created"] and not &1["deleted"])) do
        {:ok, Enum.map(contexts, &bind_fixture(&1, journal))}
      else
        _ -> {:error, :test_fixtures_not_prepared}
      end
    else
      {:ok, contexts}
    end
  end

  defp bind_fixture(context, journal) do
    fixture = Enum.find(journal["fixtures"], &(&1["project"] == context.name))
    settings = context.settings
    tracker = %{settings.tracker | active_states: ["Todo (AI)"], app: Map.put(settings.tracker.app, "allowed_issue_ids", [fixture["id"]])}
    # Only the normal Todo bootstrap is exercised. Its phase transition makes
    # the ticket ineligible for another worker in this bounded scenario.
    config = put_in(context.workflow.config, ["tracker", "active_states"], ["Todo (AI)"])
    config = put_in(config, ["tracker", "app", "allowed_issue_ids"], [fixture["id"]])
    workflow = %{context.workflow | config: config}
    %{context | settings: %{settings | tracker: tracker}, workflow: workflow, code_root: nil}
  end

  defp plan do
    with path when is_binary(path) <- Config.test_run_plan(),
         {:ok, plan} <- DurableState.read(path),
         true <- plan["evidence"] == "live" and is_binary(plan["run_id"]) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,47}\z/, plan["run_id"]),
         true <- plan["instance"] == Config.test_instance()["name"] do
      {:ok, plan}
    else
      _ -> {:error, :invalid_public_test_plan}
    end
  end

  defp journal_path(plan), do: Path.join([SymphonyElixir.TestInstance.state_root(), "runs", plan["run_id"], "fixtures.json"])

  defp journal(plan, contexts \\ Projects.configured()) do
    id = plan["run_id"]
    source = plan["source"]
    binding = binding_identity(contexts)

    case DurableState.read(journal_path(plan)) do
      {:error, :enoent} -> {:ok, %{"run_id" => plan["run_id"], "source" => plan["source"], "binding" => binding, "fixtures" => []}}
      {:ok, %{"run_id" => ^id, "source" => ^source, "binding" => ^binding} = journal} -> {:ok, journal}
      _ -> {:error, :test_journal_identity_mismatch}
    end
  end

  defp binding_identity(contexts) do
    Map.new(contexts, fn context ->
      {context.name,
       %{
         "root" => context.root,
         "workspace_root" => context.settings.workspace.root,
         "app" => Map.take(context.settings.tracker.app, ~w(workspace_id client_id user_id)),
         "project" => Config.test_instance()["manifest"]["projects"][context.name]
       }}
    end)
  end

  defp execute_stage("prepare", plan, journal) do
    with :ok <- preflight_access(Projects.configured()) do
      Enum.reduce_while(Projects.configured(), {:ok, journal}, &prepare_context(&1, &2, plan))
    end
  end

  defp execute_stage(stage, plan, journal) do
    Enum.reduce_while(journal["fixtures"], {:ok, journal}, fn fixture, {:ok, current} ->
      context = Enum.find(Projects.configured(), &(&1.name == fixture["project"]))
      result = ProjectContext.with_context(context, fn -> inspect_fixture(stage, context, fixture, plan, current) end)
      if match?({:ok, _}, result), do: {:cont, result}, else: {:halt, result}
    end)
  end

  defp prepare_context(context, {:ok, current}, plan) do
    result = ProjectContext.with_context(context, fn -> prepare_fixture(context, plan, current) end)
    if match?({:ok, _}, result), do: {:cont, result}, else: {:halt, result}
  end

  defp preflight_access(contexts) do
    Enum.reduce_while(contexts, :ok, &preflight_context/2)
  end

  defp preflight_context(context, :ok) do
    result =
      ProjectContext.with_context(context, fn ->
        with {:ok, relay} <- SymphonyElixir.Relay.open([context]),
             %{status: :ready} <- Session.tick(relay),
             {:ok, session} <- AppServer.start_session(context.root, allow_source_repo_cwd: true) do
          AppServer.stop_session(session)
        end
      end)

    case result do
      :ok -> {:cont, :ok}
      {:error, _} = error -> {:halt, error}
      _ -> {:halt, {:error, :test_relay_preflight_failed}}
    end
  end

  defp prepare_fixture(context, plan, journal) do
    case Enum.find(journal["fixtures"], &(&1["project"] == context.name)) do
      nil -> create_fixture(context, plan, journal)
      %{"created" => true, "deleted" => false} -> {:ok, journal}
      _ -> {:error, :test_creation_requires_reconciliation}
    end
  end

  defp create_fixture(context, plan, journal) do
    binding = Config.test_instance()["manifest"]["projects"][context.name]

    with {:ok, [verified]} <- Client.resolve_relay_contexts([context]),
         [assignee | _] <- verified.assignee_ids,
         {:ok, data} <-
           query("query TestFixtureSchema($id: String!) { __type(name: \"IssueCreateInput\") { inputFields { name } } project(id: $id) { teams { nodes { id states { nodes { id name } } } } } }", %{
             id: binding["project_id"]
           }),
         true <- Enum.all?(~w(id title description teamId projectId assigneeId stateId), fn field -> Enum.any?(data["__type"]["inputFields"], &(&1["name"] == field)) end),
         [team] <- data["project"]["teams"]["nodes"],
         [initial] <- Enum.filter(team["states"]["nodes"], &(&1["name"] == "Todo (AI)")),
         {head, 0} <- System.cmd("git", ["rev-parse", "origin/main"], cd: context.root, env: Config.without_linear_secret([])) do
      fixture = %{
        "id" => Ecto.UUID.generate(),
        "project" => context.name,
        "project_id" => binding["project_id"],
        "team_id" => team["id"],
        "assignee_id" => assignee,
        "title" => "Symphony-Test #{plan["run_id"]}: #{context.name}",
        "description" => "Begrenzter Symphony-Infrastrukturtest #{plan["run_id"]}. Der reguläre Todo-Bootstrap mit Workpad und Übergabe nach Planung (AI) ist das Erfolgskriterium.",
        "project_head" => String.trim(head),
        "created" => false,
        "deleted" => false,
        "complete" => false
      }

      id = fixture["id"]

      with {:ok, journal} <- save_fixture(plan, journal, fixture),
           {:ok, data} <-
             query("mutation CreateTestFixture($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier } } }", %{
               input: %{
                 id: fixture["id"],
                 title: fixture["title"],
                 teamId: fixture["team_id"],
                 projectId: fixture["project_id"],
                 assigneeId: assignee,
                 stateId: initial["id"],
                 description: fixture["description"]
               }
             }),
           %{"success" => true, "issue" => %{"id" => ^id, "identifier" => identifier}} <- data["issueCreate"],
           false <- File.exists?(Path.join(context.settings.workspace.root, identifier)),
           {_, 1} <- System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/heads/symphony/" <> identifier], cd: context.root),
           {_, 1} <- System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/remotes/origin/symphony/" <> identifier], cd: context.root) do
        save_fixture(plan, journal, Map.merge(fixture, %{"created" => true, "identifier" => identifier}))
      else
        {:error, _} = error -> error
        _ -> {:error, :test_fixture_creation_unconfirmed}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :test_fixture_schema_or_binding_unsupported}
    end
  end

  defp inspect_fixture("cleanup", _context, %{"deleted" => true}, _plan, journal), do: {:ok, journal}

  defp inspect_fixture(stage, context, fixture, plan, journal) do
    with {:ok, data} <- query("query TestFixture($id: String!) { issue(id: $id) { id identifier title description project { id } team { id } assignee { id } state { name } } }", %{id: fixture["id"]}) do
      inspect_observed(stage, data["issue"], context, fixture, plan, journal)
    end
  end

  defp inspect_observed("cleanup", nil, context, %{"created" => true} = fixture, plan, journal) do
    with :ok <- remove_workspace(context, fixture["identifier"], fixture) do
      save_fixture(plan, journal, Map.put(fixture, "deleted", true))
    end
  end

  defp inspect_observed(stage, issue, context, fixture, plan, journal) when is_map(issue) do
    owned =
      issue["id"] == fixture["id"] and issue["title"] == fixture["title"] and issue["description"] == fixture["description"] and
        get_in(issue, ["project", "id"]) == fixture["project_id"] and get_in(issue, ["team", "id"]) == fixture["team_id"] and
        get_in(issue, ["assignee", "id"]) == fixture["assignee_id"]

    if owned do
      inspect_owned(stage, issue, context, fixture, plan, journal)
    else
      {:error, :test_fixture_changed_externally}
    end
  end

  defp inspect_observed(_, _, _, _, _, _), do: {:error, :test_fixture_missing}

  defp inspect_owned("probe", issue, _context, fixture, plan, journal) do
    with {:ok, comments} <- Client.fetch_issue_comments(fixture["id"]) do
      complete =
        get_in(issue, ["state", "name"]) == "Planung (AI)" and
          Enum.any?(comments, &(&1.user_id == Config.settings!().tracker.app["user_id"] and SymphonyElixir.Workpad.comment_matches?(&1.body)))

      save_fixture(plan, journal, Map.put(fixture, "complete", complete))
    end
  end

  defp inspect_owned("cleanup", issue, context, fixture, plan, journal) do
    with :ok <- remove_workspace(context, issue["identifier"], fixture),
         {:ok, journal} <- save_fixture(plan, journal, Map.merge(fixture, %{"created" => true, "identifier" => issue["identifier"]})),
         {:ok, data} <- query("mutation DeleteTestFixture($id: String!) { issueDelete(id: $id) { success } }", %{id: fixture["id"]}),
         true <- data["issueDelete"]["success"] == true do
      save_fixture(plan, journal, Map.put(fixture, "deleted", true))
    else
      {:error, _} = error -> error
      _ -> {:error, :test_cleanup_unconfirmed}
    end
  end

  defp remove_workspace(context, identifier, fixture) do
    path = Path.join(context.settings.workspace.root, identifier)

    if File.exists?(path) do
      with true <- fixture["created"] == true and fixture["identifier"] == identifier,
           {"", 0} <- System.cmd("git", ["status", "--porcelain"], cd: path, env: Config.without_linear_secret([]), stderr_to_stdout: true),
           {head, 0} <- System.cmd("git", ["rev-parse", "HEAD"], cd: path, env: Config.without_linear_secret([])),
           true <- String.trim(head) == fixture["project_head"],
           {:ok, _} <- Workspace.remove(path),
           {worktrees, 0} <- System.cmd("git", ["worktree", "list", "--porcelain"], cd: context.root),
           false <- String.contains?(worktrees, "worktree " <> path <> "\n"),
           {_, 1} <- System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/heads/symphony/" <> identifier], cd: context.root) do
        :ok
      else
        _ -> {:error, :test_workspace_changed_or_cleanup_failed}
      end
    else
      :ok
    end
  end

  defp save_fixture(plan, journal, fixture) do
    fixtures = Enum.reject(journal["fixtures"], &(&1["id"] == fixture["id"])) ++ [fixture]
    updated = Map.put(journal, "fixtures", fixtures)
    with :ok <- DurableState.write(journal_path(plan), updated), do: {:ok, updated}
  end

  defp query(document, variables) do
    with {:ok, %{"data" => data} = response} <- Client.graphql(document, variables),
         true <- response["errors"] in [nil, []] do
      {:ok, data}
    else
      {:error, _} = error -> error
      _ -> {:error, :test_runtime_query_failed}
    end
  end
end
