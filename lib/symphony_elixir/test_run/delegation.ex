defmodule SymphonyElixir.TestRun.Delegation do
  @moduledoc "Limited operator proof of delegation events, with an unchanged human assignee."

  alias SymphonyElixir.{Config, ProjectContext}
  alias SymphonyElixir.Linear.{Client, DurableState}
  alias SymphonyElixir.Relay.Store

  @spec preflight([ProjectContext.t()], map()) :: :ok | {:error, term()}
  def preflight(contexts, %{"scenario" => scenario}) when scenario in ["delegation", "po_incoming", "po_handoff", "po_aggregation", "po_followup"] do
    case Enum.find(contexts, &(&1.name == "symphony-test")) do
      %ProjectContext{} = context ->
        ProjectContext.with_context(context, fn -> preflight_context(context) end)

      _ ->
        {:error, :test_agent_project_missing}
    end
  end

  def preflight(_contexts, _plan), do: :ok

  defp preflight_context(context) do
    with {:ok, [verified]} <- Client.resolve_relay_contexts([context]),
         true <- is_binary(verified.yolo_agent_id) and verified.yolo_agent_id != "",
         {:ok, %{"data" => %{"__type" => %{"inputFields" => fields}}} = response} <-
           Client.graphql("query TestDelegationSchema { __type(name: \"IssueUpdateInput\") { inputFields { name } } }"),
         true <- response["errors"] in [nil, []] and Enum.any?(fields, &(&1["name"] == "delegateId")) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :test_agent_delegation_unavailable}
    end
  end

  @spec fixture(ProjectContext.t(), map()) :: map()
  def fixture(%{name: "symphony-test"} = context, %{"scenario" => scenario} = plan) when scenario in ["delegation", "po_incoming", "po_handoff", "po_aggregation", "po_followup"] do
    if scenario == "delegation" or plan["fixture_state"] != "Todo (AI)",
      do: %{"test_delegate_id" => context.yolo_agent_id},
      else: %{}
  end

  def fixture(_context, _plan), do: %{}

  @spec start_allowed?(map(), map(), map()) :: boolean()
  def start_allowed?(issue, %{"scenario" => scenario}, journal) when scenario in ["delegation", "po_incoming", "po_handoff", "po_aggregation", "po_followup"] do
    case Enum.find(journal["fixtures"], &(&1["id"] == issue.id)) do
      %{"test_delegate_id" => id, "created" => true, "deleted" => false} when is_binary(id) -> Map.get(issue, :delegate_id) == id
      %{"created" => true, "deleted" => false} -> true
      _ -> false
    end
  end

  def start_allowed?(_issue, _plan, _journal), do: true

  @spec change(String.t(), map(), ProjectContext.t(), map()) :: {:ok, map()} | {:error, term()}
  def change(stage, issue, context, %{"test_delegate_id" => agent} = fixture) when is_binary(agent) and agent != "" do
    target = if stage == "delegate", do: agent

    with {:ok, before} <- observation(context, fixture),
         true <- get_in(issue, ["delegate", "id"]) in [nil, agent],
         {:ok, fixture} <- remember_before(stage, before, fixture),
         :ok <- update(issue, fixture, target) do
      {:ok, Map.put(fixture, "delegation_stage", stage)}
    else
      {:error, _} = error -> error
      _ -> {:error, :test_delegation_changed_externally}
    end
  end

  def change(_stage, _issue, _context, _fixture), do: {:error, :test_delegation_fixture_unconfirmed}

  defp remember_before("delegate", before, fixture) do
    if before["delegate_id"] == nil,
      do: {:ok, Map.put_new(fixture, "before_delegation", before)},
      else: {:error, :test_initial_delegation_unconfirmed}
  end

  defp remember_before("withdraw", before, fixture) do
    if before["delegate_id"] == fixture["test_delegate_id"] and observed_change?(fixture["before_delegation"], before),
      do: {:ok, Map.put_new(fixture, "before_withdrawal", before)},
      else: {:error, :test_assigned_delegation_unconfirmed}
  end

  defp update(issue, fixture, target) do
    if get_in(issue, ["delegate", "id"]) == target do
      :ok
    else
      query = """
      mutation TestDelegation($id: String!, $input: IssueUpdateInput!) {
        issueUpdate(id: $id, input: $input) { success issue { id delegate { id } assignee { id } } }
      }
      """

      with {:ok, %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => updated}}} = response} <-
             Client.graphql(query, %{id: fixture["id"], input: %{delegateId: target}}),
           true <-
             response["errors"] in [nil, []] and updated["id"] == fixture["id"] and
               get_in(updated, ["delegate", "id"]) == target and get_in(updated, ["assignee", "id"]) == fixture["assignee_id"] do
        :ok
      else
        {:error, _} = error -> error
        _ -> {:error, :test_delegation_write_unconfirmed}
      end
    end
  end

  @spec probe(ProjectContext.t(), map()) :: {:ok, map()} | {:error, term()}
  def probe(context, %{"test_delegate_id" => agent, "delegation_stage" => stage} = fixture) do
    with {:ok, observed} <- observation(context, fixture) do
      {key, before, target} =
        if stage == "delegate", do: {"delegation_assigned", fixture["before_delegation"], agent}, else: {"delegation_withdrawn", fixture["before_withdrawal"], nil}

      if observed["delegate_id"] == target and observed_change?(before, observed),
        do: {:ok, Map.put(fixture, key, observed)},
        else: {:ok, fixture}
    end
  end

  def probe(_context, fixture), do: {:ok, fixture}

  defp observed_change?(before, observed) when is_map(before) do
    # A scheduled snapshot is not evidence of delegation event delivery.
    before["generation"] == observed["generation"] and before["reconcile_at"] == observed["reconcile_at"] and
      observed["cursor"] > before["cursor"] and observed["epoch"] > before["epoch"] and
      before["assignee_id"] == observed["assignee_id"]
  end

  defp observed_change?(_, _), do: false

  @spec observation(ProjectContext.t(), map()) :: {:ok, map()} | {:error, term()}
  def observation(context, fixture) do
    tracker = context.settings.tracker
    workspace = tracker.app["workspace_id"]

    with true <- Config.test_instance() != nil,
         {:ok, consumer} <- Store.identity(tracker.relay, workspace),
         {:ok, record} <- DurableState.read(Store.path(tracker.relay, workspace, consumer)),
         true <- valid_observation_record?(record, workspace, consumer, fixture["id"]),
         true <-
           record["phase"] == "ready" and record["subscription"]["assigneeIds"] == [] and
             fixture["id"] not in record["dirty"],
         node when is_map(node) <- record["issues"][fixture["id"]],
         true <- get_in(node, ["assignee", "id"]) == fixture["assignee_id"] do
      {:ok,
       %{
         "consumer" => consumer,
         "generation" => Store.digest(record["generation"]),
         "cursor" => record["cursor"],
         "epoch" => record["epochs"][fixture["id"]] || 0,
         "reconcile_at" => record["reconcile_at"],
         "delegate_id" => get_in(node, ["delegate", "id"]),
         "assignee_id" => fixture["assignee_id"]
       }}
    else
      _ -> {:error, :test_delegation_cache_unconfirmed}
    end
  end

  defp valid_observation_record?(record, workspace, consumer, id) do
    record["workspace"] == workspace and record["consumer"] == consumer and
      SymphonyElixir.Relay.Config.id?(record["generation"]) and
      Enum.all?(
        [record["cursor"], record["reconcile_at"], get_in(record, ["epochs", id])],
        &(is_integer(&1) and &1 >= 0)
      )
  end
end
