defmodule SymphonyElixir.Linear.ScopeBinding do
  @moduledoc "Fresh authenticated project/team membership for host-local service reservations."

  alias SymphonyElixir.{Config, ProjectContext}
  alias SymphonyElixir.Linear.Client

  @spec resolve(ProjectContext.t()) :: {:ok, map()} | {:error, term()}
  def resolve(context) do
    ProjectContext.with_context(context, fn ->
      tracker = context.settings.tracker

      with {:ok, {kind, scope}} <- Config.linear_scope(tracker),
           {:ok, %{"data" => data} = response} <- Client.graphql(query(kind), %{scope: scope}),
           true <- response["errors"] in [nil, []],
           %{"viewer" => %{"organization" => %{"id" => workspace}}} <- data,
           true <- workspace == tracker.app["workspace_id"],
           {:ok, binding} <- binding(kind, scope, data),
           true <- matches_test_binding?(context, kind, binding) do
        {:ok, Map.merge(binding, %{workspace: workspace, kind: kind, scope: scope})}
      else
        {:error, _} = error -> error
        _ -> {:error, {:scope_binding_rejected, context.name}}
      end
    end)
  end

  @spec complete_teams(term()) :: {:ok, [map()]} | {:error, :invalid_project_teams}
  def complete_teams(%{"nodes" => [_ | _] = teams, "pageInfo" => %{"hasNextPage" => false}}) do
    if Enum.all?(teams, &valid_team?/1) and
         length(Enum.uniq_by(teams, & &1["id"])) == length(teams) and
         length(Enum.uniq_by(teams, & &1["key"])) == length(teams) do
      {:ok, Enum.map(teams, &Map.take(&1, ["id", "key"]))}
    else
      {:error, :invalid_project_teams}
    end
  end

  def complete_teams(_), do: {:error, :invalid_project_teams}

  defp valid_team?(%{"id" => id, "key" => key}), do: valid_string?(id) and valid_string?(key)
  defp valid_team?(_), do: false
  defp valid_string?(value), do: is_binary(value) and value != "" and String.trim(value) == value

  defp matches_test_binding?(%{test_instance: nil}, _, _), do: true

  defp matches_test_binding?(context, :project, binding) do
    expected = context.test_instance["manifest"]["projects"][context.name]

    is_map(expected) and binding.project_id == expected["project_id"] and
      is_list(expected["teams"]) and Enum.sort(binding.teams) == Enum.sort(expected["teams"])
  end

  defp matches_test_binding?(_, _, _), do: false

  defp binding(:project, scope, %{"projects" => %{"nodes" => [project], "pageInfo" => %{"hasNextPage" => false}}}) do
    with true <- valid_string?(project["id"]) and project["slugId"] == scope,
         {:ok, teams} <- complete_teams(project["teams"]) do
      {:ok, %{project_id: project["id"], teams: teams}}
    else
      _ -> {:error, :invalid_project_binding}
    end
  end

  defp binding(:team, scope, %{"teams" => teams}) do
    case complete_teams(teams) do
      {:ok, [%{"key" => ^scope}] = verified} -> {:ok, %{teams: verified}}
      _ -> {:error, :invalid_team_binding}
    end
  end

  defp binding(_, _, _), do: {:error, :ambiguous_scope_binding}

  defp query(:project) do
    """
    query SymphonyProjectScope($scope: String!) {
      projects(filter: {slugId: {eq: $scope}}, first: 2, includeArchived: true) {
        nodes { id slugId teams(first: 100, includeArchived: true) { nodes { id key } pageInfo { hasNextPage } } }
        pageInfo { hasNextPage }
      }
      viewer { organization { id } }
    }
    """
  end

  defp query(:team) do
    """
    query SymphonyTeamScope($scope: String!) {
      teams(filter: {key: {eq: $scope}}, first: 2, includeArchived: true) {
        nodes { id key } pageInfo { hasNextPage }
      }
      viewer { organization { id } }
    }
    """
  end
end
