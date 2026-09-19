defmodule SymphonyElixir.TestRun.Derived do
  @moduledoc "Run-owned aggregation/follow-up fixtures; their IDs never authorize implementation workers."
  alias SymphonyElixir.{Config, ProjectContext, Projects, TestInstance}
  alias SymphonyElixir.Linear.{Description, DurableState, IssueLease}
  alias SymphonyElixir.Yolo.{API, Operations, Relations}

  @spec allowed?(map()) :: boolean()
  def allowed?(request) do
    if Config.test_run_stage() == "run" do
      match?({:ok, _}, bound(request))
    else
      true
    end
  end

  @spec register(map()) :: :ok | {:error, term()}
  def register(intent) do
    if Config.test_run_stage() == "run" do
      with {:ok, plan} <- bound(intent["request"]) do
        register_bound(intent, plan)
      end
    else
      :ok
    end
  end

  defp register_bound(intent, plan) do
    path = Path.join(directory(plan), ProjectContext.current().name <> ".json")

    receipt = %{
      "source" => plan["source"],
      "project" => ProjectContext.current().name,
      "key" => intent["key"],
      "input" => intent["input"],
      "origins" => intent["request"]["origin_ids"],
      "deleted" => false
    }

    IssueLease.with_journal_lock(path, fn -> persist(path, receipt) end)
  end

  defp persist(path, receipt) do
    case DurableState.read(path) do
      {:error, :enoent} -> DurableState.write(path, receipt)
      {:ok, existing} -> if(Map.take(existing, Map.keys(receipt)) == receipt, do: :ok, else: {:error, :test_derived_fixture_changed})
      _ -> {:error, :test_derived_fixture_changed}
    end
  end

  defp bound(request) do
    with %ProjectContext{} = context <- ProjectContext.current(),
         path when is_binary(path) <- Config.test_run_plan(),
         {:ok, plan} <- DurableState.read(path),
         true <- plan["source"] == context.test_instance["source"] and plan["instance"] == context.test_instance["name"],
         true <- plan["evidence"] == "live" and is_binary(plan["run_id"]) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,47}\z/, plan["run_id"]),
         {:ok, journal} <- DurableState.read(Path.join([TestInstance.state_root(), "runs", plan["run_id"], "fixtures.json"])),
         true <- journal["source"] == plan["source"] and journal["scenario"] == plan["scenario"] and journal["run_id"] == plan["run_id"],
         true <- journal["owner"] == %{"instance" => plan["instance"], "plan_path" => Path.expand(path)},
         true <- is_map(journal["binding"]) and is_list(journal["fixtures"]),
         true <- valid_binding?(journal, context),
         true <- valid_request?(request, plan, journal, context) do
      {:ok, plan}
    else
      _ -> {:error, :test_derived_outside_scope}
    end
  end

  defp valid_binding?(journal, context) do
    binding = journal["binding"][context.name]

    is_map(binding) and binding["root"] == context.root and binding["workspace_root"] == context.settings.workspace.root and
      binding["app"] == Map.take(context.settings.tracker.app, ~w(workspace_id client_id user_id)) and
      binding["project"] == context.test_instance["manifest"]["projects"][context.name]
  end

  defp valid_request?(request, plan, journal, context) do
    fixtures = Enum.filter(journal["fixtures"], &active_fixture?(&1, context))
    ids = Enum.sort(Enum.map(fixtures, & &1["id"]))
    expected = if plan["scenario"] == "po_aggregation", do: {"aggregate", 3}, else: {"followup", 1}

    context.name == "symphony-test" and plan["scenario"] in ["po_aggregation", "po_followup"] and
      {request["kind"], length(ids)} == expected and Enum.sort(request["origin_ids"]) == ids and
      (request["blocked_by"] || []) == [] and Map.get(plan, "yolo", false) == Config.yolo?()
  end

  defp active_fixture?(fixture, context),
    do:
      fixture["project"] == context.name and fixture["created"] == true and fixture["deleted"] == false and
        (fixture["po_aggregation"] == true or fixture["po_followup"] == true)

  @spec inspect_fixtures(String.t(), map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def inspect_fixtures(stage, plan, opts \\ []) do
    Path.wildcard(Path.join(directory(plan), "*.json"))
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case inspect_file(path, stage, plan, opts) do
        {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
        error -> {:halt, error}
      end
    end)
  end

  defp inspect_file(path, stage, plan, opts) do
    with {:ok, receipt} <- DurableState.read(path),
         true <- receipt["source"] == plan["source"],
         %ProjectContext{} = context <- Enum.find(Projects.configured(), &(&1.name == receipt["project"])),
         {:ok, result} <- ProjectContext.with_context(context, fn -> inspect_receipt(stage, receipt, opts) end),
         :ok <- DurableState.write(path, result) do
      {:ok, result}
    else
      {:error, _} = error -> error
      _ -> {:error, :test_derived_fixture_changed}
    end
  end

  defp inspect_receipt("cleanup", %{"deleted" => true} = receipt, _opts), do: {:ok, receipt}

  defp inspect_receipt(stage, receipt, opts) do
    with {:ok, intent} <- DurableState.read(Operations.path(receipt["key"])),
         true <-
           intent["input"] == receipt["input"] and intent["issue_id"] == receipt["input"]["id"] and
             intent["request"]["origin_ids"] == receipt["origins"],
         {:ok, issue} <- API.issue(receipt["input"]["id"], opts) do
      inspect_issue(stage, issue, receipt, opts)
    else
      {:error, _} = error -> error
      _ -> {:error, :test_derived_fixture_changed}
    end
  end

  defp inspect_issue("cleanup", nil, receipt, _opts), do: {:ok, Map.put(receipt, "deleted", true)}
  defp inspect_issue("probe", nil, receipt, _opts), do: {:ok, Map.put(receipt, "complete", false)}

  defp inspect_issue(stage, issue, receipt, opts) when is_map(issue) do
    input = receipt["input"]

    same =
      issue["id"] == input["id"] and issue["title"] == input["title"] and
        Description.equivalent?(input["description"], issue["description"]) and
        get_in(issue, ["project", "id"]) == input["projectId"] and get_in(issue, ["team", "id"]) == input["teamId"] and
        get_in(issue, ["assignee", "id"]) == input["assigneeId"] and get_in(issue, ["delegate", "id"]) == input["delegateId"] and
        get_in(issue, ["state", "id"]) == input["stateId"]

    if same, do: inspect_owned(stage, issue, receipt, opts), else: {:error, :test_derived_fixture_changed}
  end

  defp inspect_owned("probe", issue, receipt, opts) do
    with {:ok, intent} <- DurableState.read(Operations.path(receipt["key"])),
         {:ok, labels} <- API.labels(issue["id"], opts),
         {:ok, relations} <- Relations.read(issue["id"], opts) do
      links = for r <- relations, r["type"] == "related", id <- [get_in(r, ["issue", "id"]), get_in(r, ["relatedIssue", "id"])], do: id

      complete =
        intent["done"] == true and intent["issue_id"] == issue["id"] and
          Enum.all?(receipt["input"]["labelIds"], fn id -> Enum.any?(labels, &(&1["id"] == id)) end) and Enum.all?(receipt["origins"], &(&1 in links))

      {:ok, Map.merge(receipt, %{"complete" => complete, "issue" => issue, "relations" => relations})}
    end
  end

  defp inspect_owned("cleanup", issue, receipt, opts) do
    context = ProjectContext.current()
    identifier = issue["identifier"]
    # These children never receive a start allowance. Unexpected work is preserved.
    with true <- is_binary(identifier) and Regex.match?(~r/\A[A-Z][A-Z0-9]*-\d+\z/, identifier),
         false <- File.exists?(Path.join(context.settings.workspace.root, identifier)),
         {_, 1} <- System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/heads/symphony/" <> identifier], cd: context.root),
         {_, 1} <- System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/remotes/origin/symphony/" <> identifier], cd: context.root),
         {:ok, %{"issueDelete" => %{"success" => true}}} <- API.query("mutation DeleteDerivedTestFixture($id: String!) { issueDelete(id: $id) { success } }", %{id: issue["id"]}, opts) do
      {:ok, Map.put(receipt, "deleted", true)}
    else
      {:error, _} = error -> error
      _ -> {:error, :test_derived_cleanup_unconfirmed}
    end
  end

  defp directory(plan), do: Path.join([TestInstance.state_root(), "runs", plan["run_id"], "derived"])
end
