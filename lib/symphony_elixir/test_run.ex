defmodule SymphonyElixir.TestRun do
  @moduledoc "Bound fixture operations shared by managed routines and explicit isolated tests."
  require Logger

  alias SymphonyElixir.TestRun.PoIncoming, as: PoIncoming

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, PathSafety, ProjectContext, Projects, TestInstance, Workspace}
  alias SymphonyElixir.Linear.{Client, DurableState}
  alias SymphonyElixir.TestRun.{Delegation, Derived, OpenClawInterruption, PoActions, PoHandoff, Readiness, Scenario}
  alias SymphonyElixir.Yolo.Operations, as: YoloOperations

  @spec stage() :: String.t() | nil
  def stage, do: if(routine(), do: routine().stage, else: Config.test_run_stage())

  @spec start_allowed?(map()) :: boolean()
  def start_allowed?(issue) do
    SymphonyElixir.RoutineTest.start_allowed?(issue) and instance_start_allowed?(issue)
  end

  @doc false
  @spec with_routine(ProjectContext.t(), map(), Path.t(), String.t(), (-> result)) :: result when result: var
  def with_routine(context, plan, directory, stage, callback) do
    previous = routine()
    Process.put({__MODULE__, :routine}, %{context: context, plan: plan, directory: directory, stage: stage})

    try do
      ProjectContext.with_context(context, callback)
    after
      Process.put({__MODULE__, :routine}, previous)
    end
  end

  defp routine, do: Process.get({__MODULE__, :routine})

  @doc false
  @spec routine_journal(ProjectContext.t(), map(), Path.t()) :: {:ok, map()} | {:error, term()}
  def routine_journal(context, plan, directory) do
    with_routine(context, plan, directory, "probe", fn -> journal(plan) end)
  end

  defp contexts, do: if(routine(), do: [routine().context], else: Projects.configured())

  defp instance do
    if routine() do
      context = routine().context
      %{"name" => "routine", "source" => routine().plan["source"], "manifest" => %{"projects" => %{context.name => Config.test_executor()}}}
    else
      Config.test_instance()
    end
  end

  defp instance_start_allowed?(issue) do
    if stage() == "run" do
      with {:ok, plan} <- plan(),
           {:ok, journal} <- journal(plan) do
        state_allowed =
          issue.state == "Todo (AI)" or
            (plan["scenario"] in ["po_incoming", "po_aggregation"] and issue.state in ["Backlog", "Todo", "Definiert"]) or
            (plan["scenario"] == "po_aggregation" and YoloOperations.recovering_origin?(issue)) or
            (plan["scenario"] in ["po_handoff", "po_followup"] and issue.state in ["BLOCKER", "Yolo Review"])

        state_allowed and Delegation.start_allowed?(issue, plan, journal)
      else
        _ -> false
      end
    else
      true
    end
  end

  @spec record_workspace(Path.t(), map(), boolean()) :: :ok | {:error, term()}
  def record_workspace(path, issue, created?) do
    if stage() == "run" and created? do
      with {:ok, plan} <- plan(),
           {:ok, journal} <- journal(plan),
           %{"created" => true} = fixture <- Enum.find(journal["fixtures"], &(&1["id"] == issue.issue_id)),
           true <- fixture["identifier"] == issue.issue_identifier,
           {head, 0} <- System.cmd("git", ["rev-parse", "HEAD"], cd: path, env: Config.without_linear_secret([])) do
        # Each fixture owns a separate receipt: simultaneous workers and the
        # probe process must never overwrite one another's journal updates.
        DurableState.write(workspace_receipt_path(plan, fixture), %{"path" => path, "head" => String.trim(head), "source" => plan["source"]})
      else
        _ -> {:error, :test_workspace_base_unconfirmed}
      end
    else
      SymphonyElixir.RoutineTest.record_workspace(path, issue, created?)
    end
  end

  @spec execute(String.t()) :: {:ok, map()} | {:error, term()}
  def execute(stage) when stage in ["prepare", "probe", "cleanup", "delegate", "withdraw", "interrupt"] do
    with %{} = instance <- instance(),
         {:ok, plan} <- plan(),
         true <- valid_source?(stage, plan, instance),
         {:ok, journal} <- journal(plan),
         {:ok, result} <- execute_stage(stage, plan, journal) do
      {:ok, result}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_test_run}
    end
  end

  defp valid_source?(stage, plan, %{"cleanup_recovery" => recovery}) do
    with "cleanup" <- stage,
         "cleanup" <- Config.test_run_stage(),
         true <- recovery["plan_path"] == Path.expand(Config.test_run_plan()),
         true <- recovery["source"] == plan["source"],
         true <- Map.get(plan, "yolo", false) == Config.yolo?(),
         true <- File.regular?(journal_path(plan)),
         {:ok, raw} <- File.read(Config.test_run_plan()) do
      Base.encode16(:crypto.hash(:sha256, raw), case: :lower) == recovery["plan_sha256"]
    else
      _ -> false
    end
  end

  defp valid_source?(_stage, plan, instance), do: plan["source"] == instance["source"]

  @spec bind_contexts([ProjectContext.t()]) :: {:ok, [ProjectContext.t()]} | {:error, term()}
  def bind_contexts(contexts) do
    with :ok <- environment_available() do
      bind_run_contexts(contexts)
    end
  end

  defp environment_available do
    if instance() do
      active_run =
        case plan() do
          {:ok, plan} -> {plan["run_id"], plan_owner(plan)}
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
      {:ok, %{"run_id" => id, "fixtures" => fixtures} = journal} when is_list(fixtures) ->
        if {id, journal["owner"]} == active_run or Enum.all?(fixtures, &(&1["deleted"] == true)), do: {:cont, :ok}, else: {:halt, {:error, :test_environment_needs_cleanup}}

      _ ->
        {:halt, {:error, :test_environment_journal_corrupt}}
    end
  end

  defp bind_run_contexts(contexts) do
    if stage() == "run" do
      with {:ok, plan} <- plan(),
           {:ok, journal} <- journal(plan, contexts),
           true <- prepared_fixtures?(journal["fixtures"], contexts, plan) do
        {:ok, Enum.map(contexts, &bind_fixture(&1, journal))}
      else
        _ -> {:error, :test_fixtures_not_prepared}
      end
    else
      {:ok, contexts}
    end
  end

  defp prepared_fixtures?(fixtures, contexts, plan) when is_list(fixtures) and contexts != [] do
    names = Enum.map(contexts, & &1.name) |> Enum.sort()
    expected = instance()["manifest"]["projects"] |> Map.keys() |> Enum.sort()
    members = for name <- names, state <- Scenario.states(plan), do: {name, state}

    names == expected and Enum.all?(fixtures, &is_map/1) and
      Enum.sort(Enum.map(fixtures, &{&1["project"], Map.get(&1, "initial_state", "Todo (AI)")})) == Enum.sort(members) and
      length(Enum.uniq_by(fixtures, & &1["id"])) == length(fixtures) and
      Enum.all?(fixtures, &prepared_fixture?/1)
  end

  defp prepared_fixtures?(_, _, _), do: false

  defp prepared_fixture?(fixture), do: is_binary(fixture["id"]) and fixture["id"] != "" and fixture["created"] == true and fixture["deleted"] == false

  defp bind_fixture(context, journal) do
    ids = journal["fixtures"] |> Enum.filter(&(&1["project"] == context.name)) |> Enum.map(& &1["id"])
    settings = context.settings
    tracker = %{settings.tracker | app: Map.put(settings.tracker.app, "allowed_issue_ids", ids)}
    # Keep reconciliation active through the bootstrap's phase transition.
    # start_allowed?/1 independently excludes a subsequent planning worker.
    config = put_in(context.workflow.config, ["tracker", "app", "allowed_issue_ids"], ids)
    workflow = %{context.workflow | config: config}
    %{context | settings: %{settings | tracker: tracker}, workflow: workflow, code_root: nil}
  end

  defp plan do
    if routine(), do: {:ok, routine().plan}, else: instance_plan()
  end

  defp instance_plan do
    with path when is_binary(path) <- Config.test_run_plan(),
         {:ok, plan} <- DurableState.read(path),
         true <- plan["evidence"] == "live" and is_binary(plan["run_id"]) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,47}\z/, plan["run_id"]),
         true <- plan["instance"] == instance()["name"] do
      if Map.get(plan, "scenario", "bootstrap") in ["bootstrap", "failure-probe", "delegation", "po_incoming", "po_handoff", "po_aggregation", "po_followup"],
        do: {:ok, plan},
        else: {:error, :invalid_public_test_plan}
    else
      _ -> {:error, :invalid_public_test_plan}
    end
  end

  defp journal_path(plan) do
    if routine(), do: Path.join(routine().directory, "fixtures.json"), else: Path.join([SymphonyElixir.TestInstance.state_root(), "runs", plan["run_id"], "fixtures.json"])
  end

  defp journal(plan, contexts \\ contexts()) do
    id = plan["run_id"]
    source = plan["source"]
    binding = binding_identity(contexts)
    owner = plan_owner(plan)

    case DurableState.read(journal_path(plan)) do
      {:error, :enoent} ->
        {:ok, %{"run_id" => plan["run_id"], "source" => plan["source"], "binding" => binding, "owner" => owner, "scenario" => Map.get(plan, "scenario", "bootstrap"), "fixtures" => []}}

      {:ok, %{"run_id" => ^id, "source" => ^source, "binding" => ^binding, "owner" => ^owner} = journal} ->
        if Map.get(journal, "scenario", "bootstrap") == Map.get(plan, "scenario", "bootstrap"), do: {:ok, journal}, else: {:error, :test_journal_identity_mismatch}

      _ ->
        {:error, :test_journal_identity_mismatch}
    end
  end

  defp plan_owner(plan) do
    path = if routine(), do: Path.join(routine().directory, "plan.json"), else: Path.expand(Config.test_run_plan())
    %{"instance" => plan["instance"], "plan_path" => path}
  end

  defp binding_identity(contexts) do
    Map.new(contexts, fn context ->
      {context.name,
       %{
         "root" => context.root,
         "workspace_root" => context.settings.workspace.root,
         "app" => Map.take(context.settings.tracker.app, ~w(workspace_id client_id user_id)),
         "project" => instance()["manifest"]["projects"][context.name]
       }}
    end)
  end

  defp execute_stage("prepare", plan, journal) do
    with :ok <- Delegation.preflight(contexts(), plan),
         :ok <- scenario_preflight(plan),
         :ok <- preflight_access(contexts()) do
      Enum.reduce_while(contexts(), {:ok, journal}, &prepare_context(&1, &2, plan))
    end
  end

  defp execute_stage("interrupt", plan, journal), do: OpenClawInterruption.execute(contexts(), plan, journal)

  defp execute_stage(stage, plan, journal) do
    with {:ok, derived} <- inspect_derived(stage, plan),
         {:ok, result} <- inspect_fixtures(stage, plan, journal) do
      {:ok, if(derived == [], do: result, else: Map.put(result, "derived", derived))}
    end
  end

  defp inspect_derived(stage, plan) do
    if routine(), do: {:ok, []}, else: Derived.inspect_fixtures(stage, plan)
  end

  defp scenario_preflight(plan) do
    if routine(), do: :ok, else: Scenario.preflight(contexts(), plan)
  end

  defp inspect_fixtures(stage, plan, journal) do
    with {:ok, contexts} <- inspection_contexts(stage, journal) do
      inspect_fixtures(stage, plan, journal, contexts)
    end
  end

  defp inspection_contexts("probe", journal) do
    po_projects = for fixture <- journal["fixtures"], fixture["po_incoming"] == true or fixture["po_handoff"] == true, do: fixture["project"]

    # The CLI loads fresh contexts for every probe. Reuse a verified context only
    # within this invocation, as workers already do; never cache observations.
    Enum.reduce_while(contexts(), {:ok, []}, fn context, {:ok, contexts} ->
      result = if context.name in po_projects, do: Client.resolve_relay_contexts([context]), else: {:ok, [context]}

      case result do
        {:ok, [verified]} -> {:cont, {:ok, contexts ++ [verified]}}
        error -> {:halt, error}
      end
    end)
  end

  defp inspection_contexts(_, _), do: {:ok, contexts()}

  defp inspect_fixtures(stage, plan, journal, contexts) do
    Enum.reduce_while(journal["fixtures"], {:ok, journal}, fn fixture, {:ok, current} ->
      context = Enum.find(contexts, &(&1.name == fixture["project"]))
      result = ProjectContext.with_context(context, fn -> inspect_fixture(stage, context, fixture, plan, current) end)

      if match?({:ok, _}, result) do
        {:cont, result}
      else
        Logger.warning(
          "Test fixture operation failed stage=#{stage} run_id=#{plan["run_id"]} " <>
            "issue_id=#{fixture["id"]} issue_identifier=#{fixture["identifier"]} " <>
            "project=#{fixture["project"]} failure=#{Jason.encode!(Readiness.public_error(result))}"
        )

        {:halt, result}
      end
    end)
  end

  defp prepare_context(context, {:ok, current}, plan) do
    states = Scenario.states(plan)

    result =
      ProjectContext.with_context(context, fn ->
        Enum.reduce_while(states, {:ok, current}, &prepare_state(&1, &2, context, plan))
      end)

    if match?({:ok, _}, result), do: {:cont, result}, else: {:halt, result}
  end

  defp prepare_state(state, {:ok, journal}, context, plan) do
    case prepare_fixture(context, Map.put(plan, "fixture_state", state), journal) do
      {:ok, updated} -> {:cont, {:ok, updated}}
      error -> {:halt, error}
    end
  end

  defp preflight_access(contexts) do
    if routine() do
      with {:ok, _} <- SymphonyElixir.ProjectPoller.relay_issues(hd(contexts), []), do: :ok
    else
      Enum.reduce_while(contexts, :ok, &preflight_context/2)
    end
  end

  defp preflight_context(context, :ok) do
    result =
      ProjectContext.with_context(context, fn ->
        with {:ok, relay} <- SymphonyElixir.Relay.open([context]),
             :ok <- Readiness.await(relay),
             {:ok, session} <- AppServer.start_session(context.root, allow_source_repo_cwd: true) do
          AppServer.stop_session(session)
        end
      end)

    case result do
      :ok -> {:cont, :ok}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp prepare_fixture(context, plan, journal) do
    case Enum.find(journal["fixtures"], &(&1["project"] == context.name and Map.get(&1, "initial_state", "Todo (AI)") == plan["fixture_state"])) do
      nil -> create_fixture(context, plan, journal)
      %{"created" => true, "deleted" => false} -> {:ok, journal}
      _ -> {:error, :test_creation_requires_reconciliation}
    end
  end

  defp create_fixture(context, plan, journal) do
    binding = instance()["manifest"]["projects"][context.name]

    with {:ok, [verified]} <- Client.resolve_relay_contexts([context]),
         assignee when is_binary(assignee) <- verified.human_handoff_id || List.first(verified.assignee_ids),
         {:ok, data} <-
           query("query TestFixtureSchema($id: String!) { __type(name: \"IssueCreateInput\") { inputFields { name } } project(id: $id) { teams { nodes { id states { nodes { id name } } } } } }", %{
             id: binding["project_id"]
           }),
         true <- Enum.all?(~w(id title description teamId projectId assigneeId stateId), fn field -> Enum.any?(data["__type"]["inputFields"], &(&1["name"] == field)) end),
         [team] <- data["project"]["teams"]["nodes"],
         [initial] <- Enum.filter(team["states"]["nodes"], &(&1["name"] == plan["fixture_state"])),
         {head, 0} <- System.cmd("git", ["rev-parse", "origin/main"], cd: context.root, env: Config.without_linear_secret([])) do
      fixture = %{
        "id" => Ecto.UUID.generate(),
        "project" => context.name,
        "initial_state" => plan["fixture_state"],
        "project_id" => binding["project_id"],
        "team_id" => team["id"],
        "assignee_id" => assignee,
        "title" => "Symphony-Test #{plan["run_id"]}: #{context.name}",
        "description" => fixture_description(plan),
        "project_head" => String.trim(head),
        "created" => false,
        "deleted" => false,
        "complete" => false
      }

      fixture = Map.merge(fixture, Delegation.fixture(verified, plan))
      po? = plan["scenario"] in ["po_incoming", "po_aggregation"] and plan["fixture_state"] in ["Backlog", "Todo", "Definiert"]

      fixture =
        if po?,
          do:
            Map.merge(fixture, %{
              "po_incoming" => true,
              "description" =>
                "Isolierte PO-Prüfanforderung #{plan["run_id"]} / #{plan["fixture_state"]}: Die Anforderung, dass Symphony einen dokumentierten Todo-Bootstrap hat, ist nachweislich bereits erfüllt. Es besteht kein Änderungsbedarf. Fachlich prüfen und mit Begründung nach Verworfen abschließen; kein neues Ticket, keine Aggregation, kein Code. Vorhandenen menschlichen Verantwortlichen erhalten bzw. konfigurierte Erstzuweisung verwenden."
            }),
          else: fixture

      fixture = fixture |> PoHandoff.fixture(plan) |> PoActions.fixture(plan)
      id = fixture["id"]

      with {:ok, journal} <- save_fixture(plan, journal, fixture),
           {:ok, data} <-
             query("mutation CreateTestFixture($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier } } }", %{
               input: %{
                 id: fixture["id"],
                 title: fixture["title"],
                 teamId: fixture["team_id"],
                 projectId: fixture["project_id"],
                 assigneeId: if(po?, do: nil, else: assignee),
                 delegateId: if(po? or fixture["po_handoff"], do: fixture["test_delegate_id"]),
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
    with {:ok, data} <-
           query(
             "query TestFixture($id: String!) { issue(id: $id) { id identifier title description project { id } team { id } assignee { id } delegate { id } labels { nodes { name } } state { name } } }",
             %{
               id: fixture["id"]
             }
           ) do
      inspect_observed(stage, data["issue"], context, fixture, plan, journal)
    end
  end

  defp inspect_observed("cleanup", nil, context, %{"created" => true} = fixture, plan, journal) do
    with :ok <- cleanup_po_workspaces(context, plan),
         :ok <- remove_workspace(context, fixture["identifier"], fixture, plan) do
      save_fixture(plan, journal, Map.put(fixture, "deleted", true))
    end
  end

  defp inspect_observed(stage, issue, context, fixture, plan, journal) when is_map(issue) do
    if owned_fixture?(issue, fixture, plan) do
      inspect_owned(stage, issue, context, fixture, plan, journal)
    else
      {:error, :test_fixture_changed_externally}
    end
  end

  defp inspect_observed(_, _, _, _, _, _), do: {:error, :test_fixture_missing}

  defp owned_fixture?(issue, fixture, plan) do
    issue["id"] == fixture["id"] and issue["title"] == fixture["title"] and description_matches?(issue["description"], fixture, plan) and
      get_in(issue, ["project", "id"]) == fixture["project_id"] and get_in(issue, ["team", "id"]) == fixture["team_id"] and
      fixture_assignee?(issue, fixture) and get_in(issue, ["delegate", "id"]) in [nil, fixture["test_delegate_id"]]
  end

  defp description_matches?(description, fixture, plan) do
    if routine() && plan["scenario"] == "workflow" do
      case DurableState.read(description_receipt_path(plan, fixture)) do
        {:ok, receipt} ->
          bound_description?(receipt, fixture, plan) and description in [receipt["previous"], receipt["description"]]

        {:error, :enoent} ->
          description == fixture["description"]

        _ ->
          false
      end
    else
      description == fixture["description"]
    end
  end

  defp bound_description?(receipt, fixture, plan) do
    receipt["source"] == plan["source"] and receipt["fixture_id"] == fixture["id"] and
      get_in(receipt, ["writer", "issue_id"]) == fixture["id"] and
      get_in(receipt, ["writer", "phase"]) in ["Todo (AI)", "Planung (AI)"]
  end

  @doc false
  @spec record_description_intent(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def record_description_intent(id, description, writer) do
    with true <- routine() != nil and is_binary(description),
         {:ok, %{"scenario" => "workflow"} = plan} <- plan(),
         {:ok, journal} <- journal(plan),
         %{} = fixture <- Enum.find(journal["fixtures"], &(&1["id"] == id and &1["deleted"] == false)),
         {:ok, %{"issue" => issue}} <-
           query("query TestFixture($id: String!) { issue(id: $id) { id identifier title description project { id } team { id } assignee { id } state { name } } }", %{id: id}),
         true <- is_map(issue) and owned_fixture?(issue, fixture, plan) and get_in(issue, ["state", "name"]) == writer["phase"] do
      # Intent precedes HTTP: an uncertain reply can be reconciled against
      # exactly the authorized old/new values without replaying the mutation.
      DurableState.write(description_receipt_path(plan, fixture), %{
        "source" => plan["source"],
        "fixture_id" => id,
        "previous" => issue["description"],
        "description" => description,
        "writer" => Map.take(writer, ~w(issue_id phase run_id session_id tool_call_id))
      })
    else
      {:error, _} = error -> error
      _ -> {:error, :test_description_update_unbound}
    end
  end

  defp description_receipt_path(plan, fixture), do: Path.join([Path.dirname(journal_path(plan)), "descriptions", fixture["id"] <> ".json"])

  defp fixture_description(%{"scenario" => "workflow"} = plan) do
    "Freigegebener Symphony-Routinetest #{plan["run_id"]}. Erstelle ausschließlich test-runs/#{plan["run_id"]}.txt mit dem Inhalt #{plan["run_id"]}. Führe den regulären Workflow einschließlich aller konfigurierten Qualitäts-, Freigabe- und Merge-Gates aus. Keine Änderungen an anderen Dateien oder Produktprojekten. Erfolg ist die gemergte PR mit Merge-Evidenz im Workpad und Status Review. Testdatei als nachvollziehbaren Testbeleg erhalten."
  end

  defp fixture_description(plan) do
    "Begrenzter Symphony-Infrastrukturtest #{plan["run_id"]}. Der reguläre Todo-Bootstrap mit Workpad und Übergabe nach Planung (AI) ist das Erfolgskriterium."
  end

  defp fixture_assignee?(issue, fixture) do
    get_in(issue, ["assignee", "id"]) == fixture["assignee_id"] or (fixture["po_incoming"] == true and is_nil(issue["assignee"]))
  end

  defp inspect_owned("probe", issue, context, fixture, plan, journal) do
    with {:ok, comments} <- Client.fetch_issue_comments(fixture["id"]) do
      workpad = Enum.find(comments, &(&1.user_id == Config.settings!().tracker.app["user_id"] and SymphonyElixir.Workpad.comment_matches?(&1.body)))
      merge = workflow_merge(plan, issue, workpad)

      complete =
        if plan["scenario"] == "workflow",
          do: merge != nil,
          else: get_in(issue, ["state", "name"]) == fixture_target(fixture) and workpad != nil

      with {:ok, fixture} <- Delegation.probe(context, fixture),
           {:ok, fixture} <- PoIncoming.probe(issue, fixture),
           {:ok, fixture} <- OpenClawInterruption.probe(fixture, plan),
           {:ok, fixture} <- PoHandoff.probe(issue, fixture) do
        complete = complete and fixture_receipts?(fixture)

        save_fixture(plan, journal, Map.merge(fixture, %{"complete" => complete, "observed_state" => get_in(issue, ["state", "name"]), "merge" => merge}))
      end
    end
  end

  defp inspect_owned(stage, issue, context, fixture, plan, journal) when stage in ["delegate", "withdraw"] do
    if plan["scenario"] == "delegation" do
      with {:ok, journal} <- save_fixture(plan, journal, Map.put(fixture, "delegation_intent", stage)),
           {:ok, updated} <- Delegation.change(stage, issue, context, fixture) do
        save_fixture(plan, journal, Map.put(updated, "delegation_intent", stage))
      end
    else
      {:error, :invalid_test_delegation_stage}
    end
  end

  defp inspect_owned("cleanup", issue, context, fixture, plan, journal) do
    with :ok <- cleanup_po_workspaces(context, plan),
         :ok <- remove_workspace(context, issue["identifier"], fixture, plan),
         {:ok, journal} <- save_fixture(plan, journal, Map.merge(fixture, %{"created" => true, "identifier" => issue["identifier"]})),
         {:ok, data} <- query("mutation DeleteTestFixture($id: String!) { issueDelete(id: $id) { success } }", %{id: fixture["id"]}),
         true <- data["issueDelete"]["success"] == true do
      save_fixture(plan, journal, Map.put(fixture, "deleted", true))
    else
      {:error, _} = error -> error
      _ -> {:error, :test_cleanup_unconfirmed}
    end
  end

  defp cleanup_po_workspaces(context, plan) do
    if routine(), do: :ok, else: PoIncoming.cleanup(context, plan)
  end

  defp workflow_merge(%{"scenario" => "workflow"}, issue, workpad) do
    if get_in(issue, ["state", "name"]) in ["Review", "Fertig"] and workpad != nil and String.contains?(workpad.body, "Merge-Evidenz"),
      do: SymphonyElixir.RoutineTest.merge_evidence(issue["identifier"])
  end

  defp workflow_merge(_, _, _), do: nil

  defp fixture_target(fixture) do
    cond do
      fixture["po_aggregation"] -> "Umsetzungsticket erstellt"
      fixture["po_incoming"] -> "Verworfen"
      fixture["po_followup"] -> "Yolo Review"
      fixture["po_handoff"] -> if(fixture["initial_state"] == "Yolo Review", do: "Review", else: fixture["initial_state"])
      true -> "Planung (AI)"
    end
  end

  # Decisions arrive before agent.wait confirms the successor's end. Keep the
  # live interruption probe pending until its execution receipt is available.
  defp fixture_receipts?(%{"po_interruption" => true, "initial_state" => state} = fixture) when state != "Backlog" do
    match?(%{"state" => "completed"}, get_in(fixture, ["po_receipt", "openclaw"]))
  end

  defp fixture_receipts?(fixture) do
    (fixture["po_incoming"] != true or fixture["po_receipt"] != nil) and
      (fixture["po_handoff"] != true or fixture["handoff_receipt"] != nil)
  end

  defp remove_workspace(context, identifier, fixture, plan) do
    path = Path.join(context.settings.workspace.root, identifier)

    with :ok <- remove_existing_workspace(context, path, identifier, fixture, plan),
         {worktrees, 0} <- System.cmd("git", ["worktree", "list", "--porcelain"], cd: context.root),
         false <- String.contains?(worktrees, "worktree " <> path <> "\n"),
         {_, 1} <- System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/heads/symphony/" <> identifier], cd: context.root) do
      :ok
    else
      _ -> {:error, :test_workspace_changed_or_cleanup_failed}
    end
  end

  defp remove_existing_workspace(context, path, identifier, fixture, plan) do
    if File.exists?(path) do
      with true <- fixture["created"] == true and fixture["identifier"] == identifier,
           :ok <- verify_workspace_identity(context, path, identifier),
           {"", 0} <- System.cmd("git", ["status", "--porcelain"], cd: path, env: Config.without_linear_secret([]), stderr_to_stdout: true),
           {head, 0} <- System.cmd("git", ["rev-parse", "HEAD"], cd: path, env: Config.without_linear_secret([])),
           {:ok, expected} <- workspace_head(plan, fixture, path),
           true <- String.trim(head) == expected,
           {:ok, _} <- Workspace.remove(path) do
        :ok
      else
        _ -> {:error, :test_workspace_changed_or_cleanup_failed}
      end
    else
      :ok
    end
  end

  defp verify_workspace_identity(context, path, identifier) do
    expected = "refs/heads/symphony/" <> identifier <> "\n"
    options = [env: Config.without_linear_secret([]), stderr_to_stdout: true]

    with {^expected, 0} <- System.cmd("git", ["symbolic-ref", "--quiet", "HEAD"], [cd: path] ++ options),
         {workspace_git, 0} <- System.cmd("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], [cd: path] ++ options),
         {project_git, 0} <- System.cmd("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], [cd: context.root] ++ options),
         {:ok, common} <- PathSafety.canonicalize(String.trim(project_git)),
         {:ok, ^common} <- PathSafety.canonicalize(String.trim(workspace_git)) do
      :ok
    else
      _ -> {:error, :test_workspace_identity_changed}
    end
  end

  defp workspace_receipt_path(plan, fixture), do: Path.join([Path.dirname(journal_path(plan)), "workspaces", fixture["id"] <> ".json"])

  defp workspace_head(plan, fixture, path) do
    if plan["scenario"] == "workflow" and fixture["complete"] == true and is_map(fixture["merge"]) do
      {:ok, fixture["merge"]["head"]}
    else
      recorded_workspace_head(plan, fixture, path)
    end
  end

  defp recorded_workspace_head(plan, fixture, path) do
    source = plan["source"]

    case DurableState.read(workspace_receipt_path(plan, fixture)) do
      {:ok, %{"path" => ^path, "source" => ^source, "head" => head}} -> {:ok, head}
      {:error, :enoent} -> {:ok, fixture["project_head"]}
      _ -> {:error, :test_workspace_base_unconfirmed}
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

  @doc "The bounded handoff fixture checks the acceptance transport, not an implementation merge."
  @spec review_fixture?(String.t()) :: boolean()
  def review_fixture?(id) do
    with "run" <- stage(),
         {:ok, %{"scenario" => "po_handoff"} = plan} <- plan(),
         {:ok, journal} <- journal(plan) do
      Enum.any?(journal["fixtures"], &(&1["id"] == id and &1["po_handoff"] == true and &1["created"] == true and &1["deleted"] == false))
    else
      _ -> false
    end
  end
end
