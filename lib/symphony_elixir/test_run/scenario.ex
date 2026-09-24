defmodule SymphonyElixir.TestRun.Scenario do
  @moduledoc "Fixture membership and read-only prerequisites for the single bound test project."
  alias SymphonyElixir.{Config, ProjectContext}
  alias SymphonyElixir.Yolo.API

  @spec states(map()) :: [String.t()]
  def states(plan) do
    additional =
      case plan["scenario"] do
        scenario when scenario in ["po_incoming", "po_aggregation"] -> ["Backlog", "Todo", "Definiert"]
        "po_handoff" -> ["BLOCKER", "Yolo Review"]
        "po_followup" -> ["Yolo Review"]
        _ -> []
      end

    ["Todo (AI)" | additional]
  end

  @spec preflight([ProjectContext.t()], map()) :: :ok | {:error, term()}
  def preflight(contexts, plan) do
    Enum.reduce_while(contexts, :ok, &preflight_context(&1, &2, plan))
  end

  defp preflight_context(context, :ok, plan) do
    case ProjectContext.with_context(context, fn -> check_states(context, plan) end) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp check_states(context, plan) do
    project = Config.test_instance()["manifest"]["projects"][context.name]["project_id"]
    teams_query = "query TestScenarioTeams($id: String!, $after: String) { project(id: $id) { teams(first: 100, after: $after) { nodes { id } pageInfo { hasNextPage endCursor } } } }"
    states_query = "query TestScenarioStates($id: String!, $after: String) { team(id: $id) { states(first: 100, after: $after) { nodes { id name } pageInfo { hasNextPage endCursor } } } }"

    with :ok <- check_openclaw(plan),
         {:ok, [team]} <- API.pages(teams_query, %{id: project}, ["project", "teams"], []),
         {:ok, available} <- API.pages(states_query, %{id: team["id"]}, ["team", "states"], []) do
      required = Enum.uniq(states(plan) ++ ["Planung (AI)"] ++ result_states(plan))
      missing = Enum.reject(required, fn name -> Enum.count(available, &(&1["name"] == name)) == 1 end)
      if missing == [], do: :ok, else: {:error, {:test_scenario_states_unavailable, missing}}
    else
      {:error, _} = error -> error
      _ -> {:error, :test_scenario_team_unconfirmed}
    end
  end

  defp check_openclaw(plan) do
    if Config.openclaw_yolo_agent() == plan["openclaw_agent"] and
         (plan["openclaw_interruption"] != true or (plan["scenario"] == "po_incoming" and is_binary(plan["openclaw_agent"]))),
       do: :ok,
       else: {:error, :test_openclaw_explicit_agent_mismatch}
  end

  defp result_states(%{"scenario" => "po_incoming"}), do: ["Verworfen"]
  defp result_states(%{"scenario" => "po_aggregation"}), do: ["Umsetzungsticket erstellt"]
  defp result_states(%{"scenario" => "po_handoff"}), do: ["Review"]
  defp result_states(%{"scenario" => "po_followup"}), do: ["Backlog"]
  defp result_states(_), do: []
end
