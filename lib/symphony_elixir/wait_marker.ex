defmodule SymphonyElixir.WaitMarker do
  @moduledoc "Cross-workspace issue waits with fresh target state and visible failures."
  require Logger
  alias SymphonyElixir.{Config, ProjectContext, ProjectPoller, Projects, Tracker, Workpad}
  alias SymphonyElixir.Linear.{Budget, Client}

  @marker ~r/^\s*(?:[-*]\s+(?:\[[ xX]\]\s+)?)?Wartet auf:\s*([A-Z][A-Z0-9]*-[0-9]+)\s*$/mu
  @merged ["Yolo Review", "Review", "Fertig"]
  @target_safety_ms 300_000

  @spec targets(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def targets(issue, opts \\ []) do
    with {:ok, markers} <- workpad_markers(issue, opts), do: resolve_targets(issue, markers, opts)
  end

  @spec workpad_markers(map(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def workpad_markers(issue, opts) do
    comments = Keyword.get(opts, :wait_comments, Keyword.get(opts, :comments, &Tracker.fetch_issue_comment_bodies/1))

    with {:ok, bodies} <- comments.(issue.id) do
      workpads = bodies |> Enum.map(&comment_body/1) |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, Workpad.marker())))
      {:ok, workpads |> Enum.flat_map(&parse/1) |> Enum.uniq()}
    end
  end

  @spec resolve_targets(map(), [String.t()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def resolve_targets(issue, workpad_markers, opts) do
    resolve_markers(issue, Enum.uniq(parse(issue.description || "") ++ workpad_markers), opts)
  end

  @spec resolve_targets_background(map(), [String.t()], map(), keyword()) ::
          {:ok, [map()], map()} | {:error, term(), map()}
  def resolve_targets_background(issue, workpad_markers, cache, opts) do
    if opts[:resolve] do
      case resolve_targets(issue, workpad_markers, opts) do
        {:ok, targets} -> {:ok, targets, cache}
        {:error, reason} -> {:error, reason, cache}
      end
    else
      markers = Enum.uniq(parse(issue.description || "") ++ workpad_markers)

      Enum.reduce_while(markers, {:ok, [], cache}, &background_marker(&1, &2, issue, opts))
      |> case do
        {:ok, targets, updated} -> {:ok, Enum.reverse(targets), updated}
        error -> error
      end
    end
  end

  defp background_marker(identifier, {:ok, found, entries}, issue, opts) do
    case resolve_cached(identifier, entries, opts) do
      {:ok, target, updated} -> {:cont, {:ok, [target | found], updated}}
      {:error, reason, updated} -> {:halt, {:error, marker_error(issue, identifier, reason, opts), updated}}
    end
  end

  defp comment_body(%{body: body}), do: body
  defp comment_body(%{"body" => body}), do: body
  defp comment_body(body) when is_binary(body), do: body
  defp comment_body(_), do: nil

  defp resolve_markers(issue, markers, opts) do
    resolve = Keyword.get(opts, :resolve, &resolve/2)

    Enum.reduce_while(markers, {:ok, []}, fn identifier, {:ok, acc} ->
      case resolve.(identifier, opts) do
        {:ok, target} -> {:cont, {:ok, [target | acc]}}
        {:error, reason} -> {:halt, {:error, marker_error(issue, identifier, reason, opts)}}
      end
    end)
    |> case do
      {:ok, targets} -> {:ok, Enum.reverse(targets)}
      error -> error
    end
  end

  defp marker_error(issue, identifier, reason, opts) when reason in [:wait_target_unresolved, :wait_target_ambiguous] do
    {:error, reported} = report(issue, identifier, reason, opts)
    reported
  end

  defp marker_error(_issue, _identifier, reason, _opts), do: reason

  @spec open?(map(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def open?(issue, opts \\ []) do
    with {:ok, targets} <- targets(issue, opts), do: {:ok, Enum.any?(targets, &(not merged?(&1)))}
  end

  @spec planning_action(map(), keyword()) :: :continue | :wait | {:error, term()}
  def planning_action(issue, opts \\ []) do
    with {:ok, targets} <- targets(issue, opts) do
      if Enum.any?(targets, &(not merged?(&1))), do: return_backlog(issue, targets, opts), else: :continue
    end
  end

  defp return_backlog(issue, targets, opts) do
    note = Keyword.get(opts, :note_wait, &record_wait/2)
    update = Keyword.get(opts, :update_state, &Tracker.update_issue_state/2)
    with :ok <- note.(issue, targets), :ok <- update.(issue.id, "Backlog"), do: :wait
  end

  @spec merged?(map()) :: boolean()
  def merged?(target), do: target.state in @merged

  @spec parse(String.t()) :: [String.t()]
  def parse(body), do: Regex.scan(@marker, body, capture: :all_but_first) |> Enum.map(&hd/1)

  @spec record_wait(map(), [map()]) :: :ok | {:error, term()}
  def record_wait(issue, targets) do
    waiting = targets |> Enum.reject(&merged?/1) |> Enum.map_join(", ", & &1.identifier)
    note = "Wartemarker offen: #{waiting}; Ticket nach Backlog zurückgegeben."

    with {:ok, comments} <- Tracker.fetch_issue_comments(issue.id) do
      case Workpad.find_comment(comments) do
        {:ok, workpad} -> write_wait_note(issue, workpad.body, note)
        {:error, :workpad_comment_not_found} -> create_wait_workpad(issue, note)
        error -> error
      end
    end
  end

  defp create_wait_workpad(issue, note) do
    stamp = NaiveDateTime.local_now() |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
    body = "## Symphony Workpad\n\n### Plan\n\n- [ ] Wartemarker nach Ziel-Merge erneut prüfen.\n\n### Validierung\n\n- [ ] Ziel-Ticket gemergt.\n\n### Verlauf\n\n- #{stamp} - #{note}\n"
    Tracker.create_comment(issue.id, body)
  end

  defp write_wait_note(issue, body, note) do
    if String.contains?(body, note) do
      :ok
    else
      stamp = NaiveDateTime.local_now() |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
      entry = "- #{stamp} - #{note}\n"
      Workpad.update_tracker_workpad(issue.id, insert_note(body, entry))
    end
  end

  defp insert_note(body, entry) do
    if String.contains?(body, "### Kommentareingang"),
      do: String.replace(body, "### Kommentareingang", entry <> "\n### Kommentareingang"),
      else: body <> "\n" <> entry
  end

  defp resolve(identifier, opts) do
    Enum.reduce_while(foreign_workspaces(opts), {:ok, []}, fn {_workspace, contexts}, {:ok, found} ->
      case lookup(contexts, identifier, opts) do
        {:ok, nil} -> {:cont, {:ok, found}}
        {:ok, target} -> {:cont, {:ok, [target | found]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, found} ->
        case Enum.uniq_by(found, & &1.id) do
          [target] -> {:ok, target}
          [] -> {:error, :wait_target_unresolved}
          _ -> {:error, :wait_target_ambiguous}
        end

      error ->
        error
    end
  end

  defp resolve_cached(identifier, cache, opts) do
    now = Keyword.get(opts, :background_now, fn -> System.monotonic_time(:millisecond) end).()

    Enum.reduce_while(foreign_workspaces(opts), {:ok, [], cache}, &cached_workspace(&1, &2, identifier, now, opts))
    |> case do
      {:ok, found, entries} ->
        case Enum.uniq_by(found, & &1.id) do
          [target] -> {:ok, target, entries}
          [] -> {:error, :wait_target_unresolved, entries}
          _ -> {:error, :wait_target_ambiguous, entries}
        end

      error ->
        error
    end
  end

  defp cached_workspace({workspace, contexts}, {:ok, found, entries}, identifier, now, opts) do
    key = {:wait_target, workspace, identifier}

    case cached_workspace_target(contexts, identifier, entries[key], now, opts) do
      {:ok, nil, entry} -> {:cont, {:ok, found, Map.put(entries, key, entry)}}
      {:ok, target, entry} -> {:cont, {:ok, [target | found], Map.put(entries, key, entry)}}
      {:error, reason, entry} -> {:halt, {:error, reason, Map.put(entries, key, entry)}}
    end
  end

  defp cached_workspace_target(contexts, identifier, %{target: target} = entry, now, opts) when not is_nil(target) do
    case relay_target(contexts, target, opts) do
      {:ok, fresh} -> {:ok, fresh, entry |> Map.put(:target, fresh) |> Map.delete(:lookup_error)}
      :unavailable -> cached_or_lookup(contexts, identifier, entry, now, opts)
    end
  end

  defp cached_workspace_target(contexts, identifier, entry, now, opts), do: cached_or_lookup(contexts, identifier, entry, now, opts)

  defp cached_or_lookup(_contexts, _identifier, %{checked_at: checked_at, lookup_error: reason} = entry, now, _opts)
       when now - checked_at < @target_safety_ms,
       do: {:error, reason, entry}

  defp cached_or_lookup(_contexts, _identifier, %{checked_at: checked_at} = entry, now, _opts)
       when now - checked_at < @target_safety_ms,
       do: {:ok, entry.target, entry}

  defp cached_or_lookup(contexts, identifier, entry, now, opts) do
    case lookup(contexts, identifier, opts) do
      {:ok, target} ->
        {:ok, target, %{target: target, checked_at: now}}

      {:error, reason} when reason in [:wait_target_ambiguous, :wait_target_unresolved] ->
        {:error, reason, %{target: nil, checked_at: now, lookup_error: reason}}

      {:error, _reason} when is_map(entry) and not is_nil(entry.target) ->
        {:ok, entry.target, entry |> Map.put(:checked_at, now) |> Map.delete(:lookup_error)}

      {:error, reason} ->
        {:error, reason, %{target: nil, checked_at: now, lookup_error: reason}}
    end
  end

  defp relay_target(contexts, target, opts) do
    context = Enum.find(contexts, &(&1.id == target.context_id))
    relay_read = Keyword.get(opts, :target_relay, &ProjectPoller.read_issues/2)

    if context do
      case relay_read.(context, [target.id]) do
        {:ok, [{_epoch, %{id: id, state: state, in_project_scope: true}}]} when id == target.id and is_binary(state) ->
          {:ok, %{target | state: state}}

        _ ->
          :unavailable
      end
    else
      :unavailable
    end
  end

  defp foreign_workspaces(opts) do
    source_workspace = ProjectContext.current().settings.tracker.app["workspace_id"]

    Keyword.get(opts, :contexts, Projects.configured())
    |> Enum.reject(&(&1.settings.tracker.app["workspace_id"] == source_workspace))
    |> Enum.group_by(& &1.settings.tracker.app["workspace_id"])
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp lookup([context | _] = contexts, identifier, opts) do
    [_, team_key, number] = Regex.run(~r/\A([A-Z][A-Z0-9]*)-([0-9]+)\z/, identifier)

    query =
      "query WaitTarget($team: String!, $number: Float!) { issues(filter: {team: {key: {eq: $team}}, number: {eq: $number}}, first: 2) { nodes { id identifier project { slugId } team { key } state { name } } pageInfo { hasNextPage } } }"

    graphql = Keyword.get(opts, :query, &Client.graphql/2)

    if opts[:budget_background] == true and not Budget.allow_background_lookup?(context.settings.tracker.app, identifier) do
      {:error, :linear_budget_reserved}
    else
      ProjectContext.with_context(context, fn ->
        lookup_in_context(contexts, identifier, team_key, number, query, graphql)
      end)
    end
  end

  defp lookup_in_context(contexts, identifier, team_key, number, query, graphql) do
    with {:ok, response} <- graphql.(query, %{team: team_key, number: String.to_integer(number)}),
         true <- response["errors"] in [nil, []],
         %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}} <- get_in(response, ["data", "issues"]),
         true <- is_list(nodes) do
      decode_target(contexts, identifier, nodes)
    else
      {:error, _} = error -> error
      %{"pageInfo" => %{"hasNextPage" => true}} -> {:error, :wait_target_ambiguous}
      _ -> {:error, :wait_target_lookup_incomplete}
    end
  end

  defp decode_target(contexts, identifier, [%{"id" => id, "identifier" => target_identifier, "state" => %{"name" => state}} = target])
       when target_identifier == identifier do
    case Enum.find(contexts, &bound_target?(&1, target)) do
      nil -> {:ok, nil}
      context -> {:ok, %{id: id, identifier: identifier, state: state, marker: true, workspace_id: context.settings.tracker.app["workspace_id"], context_id: context.id}}
    end
  end

  defp decode_target(_context, _identifier, []), do: {:ok, nil}
  defp decode_target(_context, _identifier, _nodes), do: {:error, :wait_target_ambiguous}

  defp bound_target?(context, target) do
    case Config.linear_scope(context.settings.tracker) do
      {:ok, {:project, slug}} -> get_in(target, ["project", "slugId"]) == slug
      {:ok, {:team, key}} -> get_in(target, ["team", "key"]) == key
      _ -> false
    end
  end

  defp report(issue, identifier, reason, opts) do
    Logger.error("Wartemarker nicht auflösbar issue_id=#{issue.id} issue_identifier=#{issue.identifier} marker=#{identifier} reason=#{inspect(reason)}")
    reporter = Keyword.get(opts, :report_error, &report_workpad/3)

    case reporter.(issue, identifier, reason) do
      :ok -> {:error, {:wait_marker_unresolved, identifier, reason}}
      {:error, write_reason} -> {:error, {:wait_marker_unresolved, identifier, reason, write_reason}}
    end
  end

  defp report_workpad(issue, identifier, reason) do
    note = "Wartemarker-Fehler #{identifier}: #{inspect(reason)}; gebundene Zielkennung prüfen."

    with {:ok, comments} <- Tracker.fetch_issue_comments(issue.id) do
      write_error_workpad(issue, note, Workpad.find_comment(comments))
    end
  end

  defp write_error_workpad(issue, note, {:ok, workpad}), do: write_wait_note(issue, workpad.body, note)

  defp write_error_workpad(issue, note, {:error, :workpad_comment_not_found}) do
    stamp = NaiveDateTime.local_now() |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
    body = "## Symphony Workpad\n\n### Plan\n\n- [ ] Wartemarker auflösen.\n\n### Validierung\n\n- [ ] #{note}\n\n### Verlauf\n\n- #{stamp} - #{note}\n"
    Tracker.create_comment(issue.id, body)
  end

  defp write_error_workpad(_issue, _note, error), do: error
end
