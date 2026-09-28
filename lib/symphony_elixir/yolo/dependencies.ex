defmodule SymphonyElixir.Yolo.Dependencies do
  @moduledoc "Complete, fresh dependency snapshots and connected acceptance chains."
  alias SymphonyElixir.{CommentCheckpoint, ProjectContext, ProjectPoller, Relay}
  alias SymphonyElixir.Linear.{Budget, YoloAgent}
  alias SymphonyElixir.WaitMarker
  alias SymphonyElixir.Yolo.{Admission, API}

  @terminal ~w(completed canceled duplicate)
  @waiting_states ["Backlog", "Todo", "Definiert", "BLOCKER", "Planung", "Yolo Review"]
  @terminal_names ["Review", "Fertig", "Abgebrochen", "Verworfen", "Duplicate", "Umsetzungsticket erstellt"]

  @spec refresh([map()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def refresh(issues, opts \\ []) do
    refresh = Keyword.get(opts, :dependencies, &load(&1, opts))
    refresh.(issues)
  end

  @spec refresh_background([map()], map(), keyword()) ::
          {:ok, [map()], map()} | {:error, term()} | {:error, term(), map()}
  def refresh_background(issues, cache, opts) do
    case opts[:dependencies] do
      nil ->
        load_background(issues, cache, opts)

      refresh ->
        case refresh.(issues) do
          {:ok, refreshed} -> {:ok, refreshed, cache}
          error -> error
        end
    end
  end

  defp load_background(issues, cache, opts) do
    project_id = ProjectContext.current().id
    current_ids = MapSet.new(issues, & &1.id)

    cache =
      Map.reject(cache, fn
        {{context_id, issue_id}, _} -> context_id == project_id and not MapSet.member?(current_ids, issue_id)
        _ -> false
      end)

    issues
    |> Enum.reduce_while({:ok, [], cache}, fn issue, {:ok, acc, entries} ->
      case refresh_background_issue(issue, entries, opts) do
        {:ok, refreshed, updated} -> {:cont, {:ok, [refreshed | acc], updated}}
        {:error, reason, updated} -> {:halt, {:error, reason, updated}}
      end
    end)
    |> finish_background()
  end

  defp finish_background({:ok, refreshed, entries}) do
    refreshed = Enum.reverse(refreshed)

    active_markers =
      refreshed
      |> Enum.flat_map(&Enum.filter(&1.blocked_by, fn blocker -> Map.get(blocker, :marker) == true end))
      |> MapSet.new(& &1.identifier)

    entries =
      Map.reject(entries, fn
        {{:wait_target, _workspace, identifier}, _} -> not MapSet.member?(active_markers, identifier)
        _ -> false
      end)

    {:ok, refreshed, entries}
  end

  defp finish_background(error), do: error

  defp refresh_background_issue(issue, cache, opts) do
    if YoloAgent.delegated?(issue) and issue.state in @waiting_states do
      refresh_waiting_issue(issue, cache, opts)
    else
      {:ok, issue, cache}
    end
  end

  defp refresh_waiting_issue(issue, cache, opts) do
    marker_opts = Keyword.put_new(opts, :budget_background, true)

    with {:ok, blockers} <- background_blockers(issue, opts),
         {:ok, workpad_markers, updated} <- background_markers(issue, cache, opts) do
      case WaitMarker.resolve_targets_background(issue, workpad_markers, updated, marker_opts) do
        {:ok, markers, resolved} -> {:ok, %{issue | blocked_by: blockers ++ markers}, resolved}
        {:error, reason, resolved} -> {:error, reason, resolved}
      end
    else
      {:error, reason} -> {:error, reason, cache}
    end
  end

  defp background_markers(issue, cache, opts) do
    epoch = get_in(issue.last_comment_signal || %{}, [:relay_epoch])

    if opts[:relay_background] == true and is_binary(epoch) and relay_ready?(issue, opts) do
      relay_markers(issue, cache, epoch, opts)
    else
      key = {ProjectContext.current().id, issue.id}
      read_markers(issue, Map.delete(cache, key), nil, nil, opts)
    end
  end

  defp relay_markers(issue, cache, epoch, opts) do
    key = {ProjectContext.current().id, issue.id}
    now = Keyword.get(opts, :background_now, fn -> System.monotonic_time(:millisecond) end).()
    entry = cache[key]
    interval = max(900_000, CommentCheckpoint.background_interval_ms())

    cond do
      is_map(entry) and entry.epoch == epoch and now - entry.scanned_at < interval ->
        {:ok, entry.markers, cache}

      is_map(entry) and entry.epoch == epoch and not safety_lookup_allowed?(issue) ->
        {:ok, entry.markers, cache}

      true ->
        read_markers(issue, cache, key, {epoch, now}, opts)
    end
  end

  defp safety_lookup_allowed?(issue) do
    Budget.allow_background_lookup?(SymphonyElixir.Config.settings!().tracker.app, issue.id <> ":wait_marker")
  end

  defp read_markers(issue, cache, key, stamp, opts) do
    case WaitMarker.workpad_markers(issue, Keyword.put_new(opts, :budget_background, true)) do
      {:ok, markers} -> {:ok, markers, put_marker_cache(cache, key, stamp, markers)}
      error -> error
    end
  end

  defp put_marker_cache(cache, nil, nil, _markers), do: cache
  defp put_marker_cache(cache, key, {epoch, now}, markers), do: Map.put(cache, key, %{epoch: epoch, scanned_at: now, markers: markers})

  defp relay_ready?(issue, opts) do
    ready? =
      Keyword.get(opts, :relay_ready, fn issue ->
        Relay.enabled?() and match?({:ok, _}, ProjectPoller.comment_epoch(ProjectContext.current(), issue.id))
      end)

    ready?.(issue)
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
    if YoloAgent.delegated?(issue) and issue.state in @waiting_states do
      with {:ok, blockers} <- background_blockers(issue, opts),
           {:ok, markers} <- WaitMarker.targets(issue, Keyword.put_new(opts, :budget_background, true)) do
        {:ok, %{issue | blocked_by: blockers ++ markers}}
      end
    else
      {:ok, issue}
    end
  end

  defp background_blockers(%{id: id, blocked_by: blockers, relations_complete: complete?, last_comment_signal: %{relay_epoch: epoch}}, opts)
       when is_list(blockers) and is_binary(epoch) do
    cond do
      opts[:relay_background] != true -> blockers(id, opts)
      complete? and Enum.all?(blockers, &is_binary(Map.get(&1, :state_type))) -> {:ok, blockers}
      Budget.allow_background_lookup?(SymphonyElixir.Config.settings!().tracker.app, id) -> blockers(id, opts)
      true -> {:error, :linear_budget_reserved}
    end
  end

  defp background_blockers(issue, opts), do: blockers(issue.id, opts)

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
  def terminal?(%{marker: true} = blocker), do: WaitMarker.merged?(blocker)
  def terminal?(blocker), do: Map.get(blocker, :state_type) in @terminal or Map.get(blocker, :state) in @terminal_names

  @spec unblocked?(map()) :: boolean()
  def unblocked?(issue), do: is_list(issue.blocked_by) and Enum.all?(issue.blocked_by, &terminal?/1)

  @spec dispatchable?(map()) :: boolean()
  def dispatchable?(issue) do
    is_list(issue.blocked_by) and
      (issue.state != "Backlog" or unblocked?(issue)) and
      Enum.all?(issue.blocked_by, fn blocker -> not Map.get(blocker, :marker, false) or terminal?(blocker) end)
  end

  @doc "Recheck Backlog blocking at the action boundary, including predecessor-only changes."
  @spec actionable([map()], keyword()) :: :ok | {:error, term()}
  def actionable(issues, opts) do
    backlog = Enum.filter(issues, &YoloAgent.delegated?/1)

    with {:ok, fresh} <- refresh(backlog, Keyword.put(opts, :budget_background, false)) do
      cond do
        Enum.all?(fresh, &dispatchable?/1) -> :ok
        Enum.any?(fresh, &(&1.state == "Backlog" and not dispatchable?(&1))) -> {:error, :yolo_backlog_blocked}
        true -> {:error, :yolo_dependency_blocked}
      end
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
