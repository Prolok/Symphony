defmodule SymphonyElixir.WaitMarker do
  @moduledoc "Cross-workspace issue waits with fresh target state and visible failures."
  require Logger
  alias SymphonyElixir.{Config, ProjectContext, Projects, Tracker, Workpad}
  alias SymphonyElixir.Linear.{Budget, Client}

  @marker ~r/^\s*(?:[-*]\s+(?:\[[ xX]\]\s+)?)?Wartet auf:\s*([A-Z][A-Z0-9]*-[0-9]+)\s*$/mu
  @merged ["Yolo Review", "Review", "Fertig"]

  @spec targets(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def targets(issue, opts \\ []) do
    comments = Keyword.get(opts, :wait_comments, Keyword.get(opts, :comments, &Tracker.fetch_issue_comment_bodies/1))

    with {:ok, bodies} <- comments.(issue.id) do
      workpads = bodies |> Enum.map(&comment_body/1) |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, Workpad.marker())))
      markers = Enum.uniq(parse(issue.description || "") ++ Enum.flat_map(workpads, &parse/1))
      resolve_markers(issue, markers, opts)
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
        {:error, :linear_budget_reserved} = deferred -> {:halt, deferred}
        {:error, reason} -> {:halt, report(issue, identifier, reason, opts)}
      end
    end)
    |> case do
      {:ok, targets} -> {:ok, Enum.reverse(targets)}
      error -> error
    end
  end

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
    source = ProjectContext.current()
    contexts = Keyword.get(opts, :contexts, Projects.configured())
    candidates = Enum.reject(contexts, &(&1.settings.tracker.app["workspace_id"] == source.settings.tracker.app["workspace_id"]))

    Enum.reduce_while(candidates, {:ok, []}, fn context, {:ok, found} ->
      case lookup(context, identifier, opts) do
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

  defp lookup(context, identifier, opts) do
    [_, team_key, number] = Regex.run(~r/\A([A-Z][A-Z0-9]*)-([0-9]+)\z/, identifier)

    query =
      "query WaitTarget($team: String!, $number: Float!) { issues(filter: {team: {key: {eq: $team}}, number: {eq: $number}}, first: 2) { nodes { id identifier project { slugId } team { key } state { name } } pageInfo { hasNextPage } } }"

    graphql = Keyword.get(opts, :query, &Client.graphql/2)

    if Budget.low?(context.settings.tracker.app) do
      {:error, :linear_budget_reserved}
    else
      ProjectContext.with_context(context, fn ->
        lookup_in_context(context, identifier, team_key, number, query, graphql)
      end)
    end
  end

  defp lookup_in_context(context, identifier, team_key, number, query, graphql) do
    with {:ok, response} <- graphql.(query, %{team: team_key, number: String.to_integer(number)}),
         true <- response["errors"] in [nil, []],
         %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}} <- get_in(response, ["data", "issues"]),
         true <- is_list(nodes) and length(nodes) <= 1 do
      decode_target(context, identifier, nodes)
    else
      {:error, _} = error -> error
      _ -> {:error, :wait_target_lookup_incomplete}
    end
  end

  defp decode_target(context, identifier, [%{"id" => id, "identifier" => target_identifier, "state" => %{"name" => state}} = target])
       when target_identifier == identifier do
    if bound_target?(context, target) do
      {:ok, %{id: id, identifier: identifier, state: state, marker: true}}
    else
      {:ok, nil}
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
