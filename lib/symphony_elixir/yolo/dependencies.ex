defmodule SymphonyElixir.Yolo.Dependencies do
  @moduledoc "Complete, fresh dependency snapshots and connected acceptance chains."
  alias SymphonyElixir.Linear.YoloAgent
  alias SymphonyElixir.Yolo.{Admission, API}

  @terminal ~w(completed canceled duplicate)
  @terminal_names ["Review", "Fertig", "Abgebrochen", "Verworfen", "Duplicate", "Umsetzungsticket erstellt"]

  @spec refresh([map()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def refresh(issues, opts \\ []) do
    refresh = Keyword.get(opts, :dependencies, &load(&1, opts))
    refresh.(issues)
  end

  defp load(issues, opts) do
    Enum.reduce_while(issues, {:ok, []}, fn issue, {:ok, acc} ->
      case refresh_issue(issue, opts) do
        {:ok, refreshed} -> {:cont, {:ok, [refreshed | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, refreshed} -> {:ok, Enum.reverse(refreshed)}
      error -> error
    end
  end

  defp refresh_issue(issue, opts) do
    if YoloAgent.delegated?(issue) and issue.state in ["Backlog", "Yolo Review"] do
      with {:ok, blockers} <- blockers(issue.id, opts), do: {:ok, %{issue | blocked_by: blockers}}
    else
      {:ok, issue}
    end
  end

  @spec blockers(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def blockers(id, opts) do
    document =
      "query YoloBlockers($id: String!, $after: String) { issue(id: $id) { inverseRelations(first: 100, after: $after) { nodes { id type issue { id identifier state { name type } } } pageInfo { hasNextPage endCursor } } } }"

    with {:ok, nodes} <- API.pages(document, %{id: id}, ["issue", "inverseRelations"], opts),
         true <- Enum.all?(nodes, &valid_relation?/1) do
      {:ok, nodes |> Enum.filter(&(&1["type"] == "blocks")) |> Enum.map(&blocker/1) |> Enum.sort_by(& &1.id)}
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_dependencies_incomplete}
    end
  end

  defp valid_relation?(%{"type" => "blocks", "issue" => %{"id" => id, "state" => %{"name" => name, "type" => type}}}),
    do: is_binary(id) and is_binary(name) and is_binary(type)

  defp valid_relation?(%{"type" => type}), do: is_binary(type) and type != "blocks"
  defp valid_relation?(_), do: false
  defp blocker(%{"issue" => issue}), do: %{id: issue["id"], identifier: issue["identifier"], state: issue["state"]["name"], state_type: issue["state"]["type"]}

  @spec terminal?(map()) :: boolean()
  def terminal?(blocker), do: Map.get(blocker, :state_type) in @terminal or Map.get(blocker, :state) in @terminal_names

  @spec unblocked?(map()) :: boolean()
  def unblocked?(issue), do: is_list(issue.blocked_by) and Enum.all?(issue.blocked_by, &terminal?/1)

  @doc "Recheck Backlog blocking at the action boundary, including predecessor-only changes."
  @spec actionable([map()], keyword()) :: :ok | {:error, term()}
  def actionable(issues, opts) do
    backlog = Enum.filter(issues, &(&1.state == "Backlog" and YoloAgent.delegated?(&1)))

    with {:ok, fresh} <- refresh(backlog, opts) do
      if Enum.all?(fresh, &unblocked?/1), do: :ok, else: {:error, :yolo_backlog_blocked}
    end
  end

  @spec review_members([map()]) :: [map()]
  def review_members(issues) do
    candidates = Enum.filter(issues, &(&1.state == "Yolo Review" and Admission.eligible?(&1) and not Admission.needed?(&1)))

    candidates
    |> components()
    |> Enum.flat_map(fn members -> if ready?(members), do: ordered(members), else: [] end)
  end

  @spec components([map()]) :: [[map()]]
  def components([]), do: []

  def components([first | rest]) do
    {members, remaining} = expand([first], rest)
    [members | components(remaining)]
  end

  defp expand(members, remaining) do
    ids = Enum.map(members, & &1.id)
    blockers = Enum.flat_map(members, &Enum.map(&1.blocked_by, fn b -> b.id end))
    {joined, remaining} = Enum.split_with(remaining, &(&1.id in blockers or Enum.any?(&1.blocked_by, fn b -> b.id in ids end)))
    if joined == [], do: {members, remaining}, else: expand(members ++ joined, remaining)
  end

  defp ready?(members) do
    ids = Enum.map(members, & &1.id)
    Enum.all?(members, fn issue -> Enum.all?(issue.blocked_by, &(terminal?(&1) or &1.id in ids)) end) and length(ordered(members)) == length(members)
  end

  defp ordered([]), do: []

  defp ordered(members) do
    ids = Enum.map(members, & &1.id)
    {roots, rest} = Enum.split_with(members, fn issue -> not Enum.any?(issue.blocked_by, &(&1.id in ids)) end)
    if roots == [], do: [], else: Enum.sort_by(roots, & &1.id) ++ ordered(rest)
  end

  @spec review_ready?([map()], [map()]) :: boolean()
  def review_ready?(members, project) do
    ready = review_members(project)
    ids = MapSet.new(members, & &1.id)
    available = MapSet.new(ready, & &1.id)

    MapSet.subset?(ids, available) and
      Enum.all?(components(ready), fn chain ->
        chain_ids = MapSet.new(chain, & &1.id)
        MapSet.disjoint?(ids, chain_ids) or MapSet.subset?(chain_ids, ids)
      end)
  end
end
