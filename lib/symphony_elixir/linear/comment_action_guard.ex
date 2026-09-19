defmodule SymphonyElixir.Linear.CommentActionGuard do
  @moduledoc "Fresh comment checks on Symphony's existing forward state action path."
  alias SymphonyElixir.Linear.YoloAgent, as: YoloAgent
  alias SymphonyElixir.Yolo.Scope, as: YoloScope

  alias SymphonyElixir.{CommentCheckpoint, Config}
  alias SymphonyElixir.Linear.{Client, CommentMutations}

  @query """
  query SymphonyCommentAction($id: String!) {
    issue(id: $id) {
      id
      team { states(first: 100) { nodes { id name } pageInfo { hasNextPage } } }
    }
  }
  """
  @escape ["Planung", "BLOCKER", "Abbruch (AI)", "Abgebrochen"]

  @spec check(map(), keyword()) :: :ok | {:error, term()}
  def check(payload, opts \\ []) do
    with {:ok, updates} <- CommentMutations.state_updates(payload, not is_nil(YoloScope.current())) do
      Enum.reduce_while(updates, :ok, fn update, _ -> reduce_update(update, opts) end)
    end
  end

  defp reduce_update(update, opts) do
    case check_update(update, opts) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp check_update(%{"state_id" => nil, "id" => id}, opts) do
    fetch = Keyword.get(opts, :fetch_issue, &Client.fetch_issue_states_by_ids/1)
    guard = Keyword.get(opts, :guard, &CommentCheckpoint.before_action/1)
    with {:ok, [issue]} <- fetch.([id]), do: authorize_group(issue, id, guard)
  end

  defp check_update(update, opts) do
    query = Keyword.get(opts, :query, &Client.graphql/2)
    fetch = Keyword.get(opts, :fetch_issue, &Client.fetch_issue_states_by_ids/1)
    guard = Keyword.get(opts, :guard, &CommentCheckpoint.before_action/1)

    with {:ok, response} <- query.(@query, %{id: update["id"]}),
         true <- Map.get(response, "errors", []) in [nil, []],
         %{"id" => id, "team" => %{"states" => %{"nodes" => states, "pageInfo" => %{"hasNextPage" => false}}}} <- get_in(response, ["data", "issue"]),
         %{"name" => target} <- Enum.find(states, &(&1["id"] == update["state_id"])),
         {:ok, [issue]} <- fetch.([id]) do
      authorize(issue, id, target, guard)
    else
      {:error, _} = error -> error
      _ -> {:error, :comment_action_scope_unverified}
    end
  end

  defp authorize(issue, id, target, guard) do
    if YoloScope.current() do
      authorize_group(issue, id, guard)
    else
      cond do
        target in @escape or target == issue.state -> :ok
        not CommentCheckpoint.active?(issue) -> :ok
        not issue.assigned_to_worker or not allowed_issue?(id) -> {:error, :comment_issue_outside_active_scope}
        true -> guard.(issue)
      end
    end
  end

  defp authorize_group(issue, id, guard) do
    cond do
      not YoloScope.member?(id) or not issue.in_project_scope or not issue.assigned_to_worker or not allowed_issue?(id) -> {:error, :yolo_action_outside_group}
      not YoloAgent.delegated?(issue) -> {:error, :yolo_delegation_changed}
      true -> guard.(issue)
    end
  end

  defp allowed_issue?(id) do
    case Config.settings!().tracker.app["allowed_issue_ids"] do
      nil -> true
      ids -> id in ids
    end
  end
end
