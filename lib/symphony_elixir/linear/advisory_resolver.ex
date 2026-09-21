defmodule SymphonyElixir.Linear.AdvisoryResolver do
  @moduledoc "Bounded, issue-local resolution through the existing Linear transport and rate limits."

  alias SymphonyElixir.Linear.Client

  @session "id appUser { id } comment { id issue { id } } sourceComment { id issue { id } } issue { id }"
  @root_metadata ~w(parentId agentSession bodyData isArtificialAgentSessionRoot)

  @spec fetch(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(issue, id, selection), do: fetch(issue, id, selection, %{agent: nil, spawned: nil}, %{}, nil, 3)

  defp fetch(_issue, _id, _selection, _cursors, _seen, previous, 0), do: partial(previous)

  defp fetch(issue, id, selection, cursors, seen, previous, budget) do
    query = """
    query SymphonyAdvisoryThread($id: String!, $agent: String, $spawned: String) {
      comment(id: $id) {
        #{selection}
        agentSessions(first: 100, after: $agent, includeArchived: true) {
          nodes { #{@session} } pageInfo { hasNextPage endCursor }
        }
        spawnedAgentSessions(first: 100, after: $spawned, includeArchived: true) {
          nodes { #{@session} } pageInfo { hasNextPage endCursor }
        }
      }
    }
    """

    case Client.graphql(query, Map.put(cursors, :id, id)) do
      {:ok, %{"data" => %{"comment" => %{"id" => ^id, "issue" => %{"id" => ^issue}} = raw}} = response} ->
        merged = merge(previous, raw)

        if response["errors"] in [nil, []],
          do: continue(issue, id, selection, merged, raw, cursors, seen, budget),
          else: partial(merged)

      _ ->
        partial(previous)
    end
  end

  defp continue(issue, id, selection, merged, raw, cursors, seen, budget) do
    with {:ok, agent} <- cursor(raw["agentSessions"]),
         {:ok, spawned} <- cursor(raw["spawnedAgentSessions"]) do
      # Keep a completed relation at its final page while the other one advances.
      next = %{agent: agent || cursors.agent, spawned: spawned || cursors.spawned}

      cond do
        agent == nil and spawned == nil -> {:ok, merged}
        Map.has_key?(seen, next) -> partial(merged)
        true -> fetch(issue, id, selection, next, Map.put(seen, next, true), merged, budget - 1)
      end
    else
      _ -> partial(merged)
    end
  end

  defp cursor(%{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}) when is_list(nodes), do: {:ok, nil}
  defp cursor(%{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => true, "endCursor" => cursor}}) when is_list(nodes) and is_binary(cursor) and cursor != "", do: {:ok, cursor}
  defp cursor(_), do: :error

  defp merge(nil, raw), do: raw

  defp merge(previous, raw) do
    merged =
      Enum.reduce(~w(agentSessions spawnedAgentSessions), raw, fn field, acc ->
        single = if field == "agentSessions", do: List.wrap(previous["agentSession"]), else: []
        nodes = Enum.uniq(single ++ List.wrap(get_in(previous, [field, "nodes"])) ++ List.wrap(get_in(raw, [field, "nodes"])))
        Map.put(acc, field, %{"nodes" => nodes})
      end)

    if previous["advisoryIncomplete"] == true or Map.take(previous, @root_metadata) != Map.take(raw, @root_metadata),
      do: Map.put(merged, "advisoryIncomplete", true),
      else: merged
  end

  defp partial(nil), do: {:error, :advisory_metadata_unavailable}
  defp partial(previous), do: {:ok, Map.put(previous, "advisoryIncomplete", true)}
end
