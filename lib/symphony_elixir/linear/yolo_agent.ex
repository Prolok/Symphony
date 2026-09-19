defmodule SymphonyElixir.Linear.YoloAgent do
  @moduledoc "Workspace-bound agent identity and delegation continuity. Human ownership remains separate."

  alias SymphonyElixir.{Config, ProjectContext}
  alias SymphonyElixir.Linear.Client

  @typep page_cursors :: %{optional(String.t()) => true}

  @spec resolve(ProjectContext.t()) :: {:ok, ProjectContext.t()} | {:error, term()}
  def resolve(%{settings: %{tracker: %{yolo_agent: nil}}} = context), do: {:ok, %{context | yolo_agent_id: nil}}

  def resolve(context) do
    name = context.settings.tracker.yolo_agent

    ProjectContext.with_context(context, fn ->
      with true <- is_binary(context.human_handoff_id) and context.human_handoff_id in context.assignee_ids,
           {:ok, users} <- fetch(name, nil, %{}, []),
           [agent] <- Enum.uniq_by(users, & &1["id"]),
           true <- valid_agent?(agent, name) do
        {:ok, %{context | yolo_agent_id: agent["id"]}}
      else
        {:error, _} = error -> error
        false -> {:error, {:linear_yolo_agent_invalid, name}}
        [] -> {:error, {:linear_yolo_agent_not_found, name}}
        _ -> {:error, {:linear_yolo_agent_ambiguous, name}}
      end
    end)
  end

  defp valid_agent?(agent, name) do
    is_binary(agent["id"]) and agent["id"] != "" and agent["app"] == true and
      agent["active"] == true and agent["isAssignable"] == true and
      String.downcase(agent["name"] || "") == String.downcase(name)
  end

  @spec fetch(String.t(), String.t() | nil, page_cursors(), [map()]) :: {:ok, [map()]} | {:error, term()}
  defp fetch(name, cursor, seen, users) do
    query = """
    query SymphonyYoloAgent($filter: UserFilter!, $after: String) {
      users(filter: $filter, first: 100, after: $after) {
        nodes { id name app active isAssignable }
        pageInfo { hasNextPage endCursor }
      }
    }
    """

    with {:ok, %{"data" => %{"users" => %{"nodes" => nodes, "pageInfo" => page}}} = response} <-
           Client.graphql(query, %{filter: %{"name" => %{"eqIgnoreCase" => name}}, after: cursor}),
         true <- response["errors"] in [nil, []] and is_list(nodes) do
      next = page["endCursor"]

      cond do
        page["hasNextPage"] == false ->
          {:ok, users ++ nodes}

        page["hasNextPage"] != true or not is_binary(next) or next == "" or Map.has_key?(seen, next) ->
          {:error, :linear_invalid_page_cursor}

        true ->
          fetch(name, next, Map.put(seen, next, true), users ++ nodes)
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :linear_yolo_agent_incomplete_response}
    end
  end

  @spec delegated?(map()) :: boolean()
  def delegated?(issue) do
    id = Config.yolo_agent_id()
    is_binary(id) and Map.get(issue, :delegate_id) == id
  end

  @spec continued?(map(), map()) :: boolean()
  def continued?(previous, current) do
    not delegated?(previous) or (delegated?(current) and Map.get(current, :assigned_to_worker, false))
  end
end
