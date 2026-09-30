defmodule SymphonyElixir.Yolo.Followup do
  @moduledoc "Durable creation and linking shared by regular workers and PO aggregation/follow-ups."
  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixir.Linear.{Description, TrustedAgents}
  alias SymphonyElixir.TestRun.Derived, as: Derived
  alias SymphonyElixir.Yolo.{ActionScope, API, GeneratedLabel, Operations, Relations, Scope}

  @created_history "query YoloCreatedHistory($id: String!, $after: String) { issue(id: $id) { history(first: 100, after: $after) { nodes { id createdAt fromTitle toTitle updatedDescription fromAssigneeId toAssigneeId fromDelegate { id } toDelegate { id } fromStateId toStateId fromProjectId toProjectId fromTeamId toTeamId addedLabelIds removedLabelIds actor { id app } botActor { id } } pageInfo { hasNextPage endCursor } } } }"

  @spec invoke(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def invoke(%{"kind" => kind, "origin_ids" => ids} = args, opts) when kind in ["aggregate", "followup"] and is_list(ids) do
    request = Map.take(args, ~w(kind origin_ids operation_key title description validation blocked_by blocks_origins)) |> Map.update!("origin_ids", &Enum.sort(Enum.uniq(&1)))

    with true <- Derived.allowed?(request),
         true <- valid_request?(args),
         true <- kind != "aggregate" or match?(%{"group" => "incoming"}, Scope.current()),
         :ok <- existing_aggregation(request) do
      operation = if kind == "aggregate", do: "aggregate:" <> Enum.join(request["origin_ids"], ":"), else: "followup:" <> Enum.join(request["origin_ids"], ":") <> ":" <> args["operation_key"]
      Operations.run(operation, request, &resume(&1, opts))
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_yolo_followup}
    end
  end

  def invoke(_, _), do: {:error, :invalid_yolo_followup}

  defp valid_request?(args) do
    strings = Enum.map(~w(operation_key title description validation), &args[&1])
    blocked = args["blocked_by"] || []

    Enum.all?(strings, &(is_binary(&1) and String.trim(&1) != "")) and
      is_boolean(Map.get(args, "blocks_origins", false)) and
      Enum.all?(args["origin_ids"], &is_binary/1) and is_list(blocked) and Enum.all?(blocked, &is_binary/1)
  end

  defp existing_aggregation(%{"kind" => "aggregate", "origin_ids" => ids}) do
    with {:ok, operations} <- Operations.related(ids) do
      conflict = Enum.find(operations, &(&1["request"]["kind"] == "aggregate" and &1["request"]["origin_ids"] != ids))
      if conflict, do: {:error, {:yolo_existing_aggregation, conflict["request"]}}, else: :ok
    end
  end

  defp existing_aggregation(_), do: :ok

  defp resume(%{"done" => true, "result" => result}, _opts), do: {:ok, result}

  defp resume(intent, opts) do
    ids = intent["request"]["origin_ids"]
    missing = Enum.reject(ids, &Scope.member?/1)

    if intent["request"]["kind"] == "aggregate" and missing != [] do
      resume_partial(intent, ids, missing, opts)
    else
      authorized_execute(intent, opts)
    end
  end

  defp resume_partial(intent, ids, missing, opts) do
    fetch = Keyword.get(opts, :fetch, &Tracker.fetch_issue_states_by_ids(&1, force_full: true))

    with true <- Enum.any?(ids ++ [intent["issue_id"]], &Scope.member?/1),
         {:ok, prior} <- fetch.(missing),
         true <- Enum.sort(Enum.map(prior, & &1.id)) == Enum.sort(missing),
         true <- Enum.all?(prior, &closed_origin?(&1, intent)) do
      Scope.with_members(missing, fn -> authorized_execute(intent, opts) end)
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_aggregation_resume_scope_changed}
    end
  end

  defp closed_origin?(issue, intent) do
    issue.state == "Umsetzungsticket erstellt" and issue.id in (intent["closing"] || []) and unchanged_source?(issue, intent)
  end

  defp authorized_execute(intent, opts) do
    with {:ok, issues} <- ActionScope.sources(intent["request"]["origin_ids"], opts),
         true <- length(Enum.uniq_by(issues, &{&1.project_id, &1.team_id})) == 1,
         true <- Enum.all?(issues, &unchanged_source?(&1, intent)) do
      execute(intent, issues, opts)
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_followup_sources_changed}
    end
  end

  defp source(issue), do: Map.take(issue, [:title, :description, :project_id, :team_id, :assignee_id, :delegate_id]) |> Jason.encode!() |> Jason.decode!()
  defp unchanged_source?(issue, intent), do: is_nil(intent["sources"]) or intent["sources"][issue.id] == source(issue)

  defp execute(intent, issues, opts) do
    with {:ok, intent} <- prepare(intent, issues, opts),
         :ok <- Derived.register(intent),
         {:ok, created} <- ensure_created(intent, opts),
         :ok <- link(intent, opts),
         {:ok, fresh} <- ActionScope.sources(intent["request"]["origin_ids"], opts),
         true <- Enum.all?(fresh, &unchanged_source?(&1, intent)),
         intent = Map.put(intent, "closing", intent["request"]["origin_ids"]),
         :ok <- Operations.save(intent),
         :ok <- finish(intent, issues, opts),
         result = Map.take(created, ~w(id identifier url)),
         :ok <- Operations.save(Map.merge(intent, %{"done" => true, "result" => result})) do
      {:ok, result}
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_followup_sources_changed}
    end
  end

  defp prepare(%{"input" => _} = intent, _issues, _opts), do: {:ok, intent}

  defp prepare(intent, [lead | _] = issues, opts) do
    request = intent["request"]
    aggregate? = request["kind"] == "aggregate"
    assigned? = aggregate? or is_binary(Config.yolo_agent_id())

    with true <- not assigned? or is_binary(Config.human_handoff_id()),
         {:ok, state} <- API.state(lead.team_id, "Backlog", opts),
         {:ok, label} <- GeneratedLabel.resolve(lead.team_id, opts),
         {:ok, transferred} <- transfer(aggregate?, issues, intent["issue_id"], opts) do
      input = %{
        "id" => intent["issue_id"],
        "title" => request["title"],
        "description" => description(request, issues),
        "teamId" => lead.team_id,
        "projectId" => lead.project_id,
        "stateId" => state,
        "labelIds" => [label],
        "assigneeId" => if(assigned?, do: Config.human_handoff_id()),
        "delegateId" => if(assigned?, do: Config.yolo_agent_id())
      }

      related = Enum.map(issues, &Relations.edge(&1.id, intent["issue_id"], "related"))
      blocked = Enum.map(request["blocked_by"] || [], &Relations.edge(&1, intent["issue_id"], "blocks"))
      fixes = if request["blocks_origins"] == true, do: Enum.map(issues, &Relations.edge(intent["issue_id"], &1.id, "blocks")), else: []
      intent = Map.merge(intent, %{"input" => input, "relations" => effective_relations(related ++ transferred ++ blocked ++ fixes), "sources" => Map.new(issues, &{&1.id, source(&1)})})
      with :ok <- Operations.save(intent), do: {:ok, intent}
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_human_unavailable}
    end
  end

  defp description(request, issues) do
    originals = if request["kind"] == "aggregate", do: Enum.map_join(issues, "\n\n", &"### #{&1.identifier}: #{&1.title}\n\n#{&1.description}")

    request["description"] <>
      "\n\n## Validierung\n\n" <>
      request["validation"] <>
      "\n\n## Ursprung\n\n" <>
      Enum.map_join(issues, "\n", &"- [#{&1.identifier}](#{&1.url})") <> if(originals, do: "\n\n## Übernommene Anforderungen\n\n" <> originals, else: "")
  end

  defp transfer(true, issues, id, opts), do: Relations.transfer(Enum.map(issues, & &1.id), id, opts)
  defp transfer(false, _issues, _id, _opts), do: {:ok, []}

  defp ensure_created(intent, opts) do
    with {:ok, existing} <- API.issue(intent["issue_id"], opts) do
      create_or_verify(existing, intent, opts)
    end
  end

  defp create_or_verify(nil, intent, opts) do
    document = "mutation YoloCreate($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id } } }"

    with :ok <- API.confirmed(document, %{input: intent["input"]}, ["issueCreate", "issue"], intent["issue_id"], opts),
         {:ok, created} <- API.issue(intent["issue_id"], opts),
         do: verify_created(created, intent, opts, false)
  end

  defp create_or_verify(existing, intent, opts), do: verify_created(existing, intent, opts, true)

  defp verify_created(created, intent, opts, recovery?) when is_map(created) do
    input = intent["input"]

    # API.issue/2 already requires the returned issue ID to match the requested ID.
    checks = [
      {"project.id", input["projectId"], get_in(created, ["project", "id"])},
      {"team.id", input["teamId"], get_in(created, ["team", "id"])},
      {"title", input["title"], created["title"]},
      {"description", input["description"], created["description"]},
      {"assignee.id", input["assigneeId"], get_in(created, ["assignee", "id"])},
      {"delegate.id", input["delegateId"], get_in(created, ["delegate", "id"])},
      {"state.id", input["stateId"], get_in(created, ["state", "id"])}
    ]

    changed = Enum.reject(checks, fn {field, expected, actual} -> comparable?(field, expected, actual) end)

    case {recovery?, changed} do
      {false, [first | _]} -> changed_error(first)
      _ -> verify_labels(created, input, changed, opts, recovery?)
    end
  end

  defp verify_created(_, _, _, _), do: {:error, :yolo_created_issue_unconfirmed}

  defp comparable?("description", expected, actual), do: Description.equivalent?(expected, actual)
  defp comparable?(_, expected, actual), do: expected == actual

  defp verify_labels(created, input, changed, opts, recovery?) do
    with {:ok, labels} <- API.labels(input["id"], opts) do
      missing =
        input["labelIds"]
        |> Enum.with_index()
        |> Enum.reject(fn {id, _} -> Enum.any?(labels, &(&1["id"] == id)) end)
        |> Enum.map(fn {id, index} -> {"labelIds", id, Enum.map(labels, & &1["id"]), index} end)

      case changed ++ missing do
        [] -> {:ok, created}
        [first | _] = differences when recovery? -> verify_history(created, differences, first, opts)
        [first | _] -> changed_error(first)
      end
    end
  end

  defp changed_error({"labelIds", expected, actual, index}),
    do: {:error, {:yolo_created_issue_changed, %{field: "labelIds", at: "labelIds[#{index}]", expected: expected, actual: actual}}}

  defp changed_error({field, expected, actual}),
    do: {:error, {:yolo_created_issue_changed, difference(field, expected, actual)}}

  defp verify_history(created, differences, first, opts) do
    case DateTime.from_iso8601(created["createdAt"] || "") do
      {:ok, created_at, _} -> verify_history_pages(created, differences, first, opts, created_at)
      _ -> changed_error(first)
    end
  end

  defp verify_history_pages(created, differences, first, opts, created_at) do
    case API.pages(@created_history, %{id: created["id"]}, ["issue", "history"], opts) do
      {:ok, nodes} -> verify_history_nodes(created, differences, first, nodes, created_at)
      {:error, _} = error -> error
    end
  end

  defp verify_history_nodes(created, differences, first, nodes, created_at) do
    with {:ok, events} <- dated_history(nodes),
         true <- Enum.all?(differences, &human_change?(&1, events, created_at)) do
      {:ok, created}
    else
      _ -> changed_error(first)
    end
  end

  defp dated_history(nodes) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, acc} ->
      case DateTime.from_iso8601(node["createdAt"] || "") do
        {:ok, at, _} -> {:cont, {:ok, [{at, node} | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.sort(events, fn {left, _}, {right, _} -> DateTime.compare(left, right) == :lt end)}
      _ -> :error
    end
  end

  defp human_change?({"description", _expected, _actual}, events, created_at) do
    events
    |> Enum.filter(fn {_at, node} -> node["updatedDescription"] == true end)
    |> List.last()
    |> case do
      {at, node} -> DateTime.compare(at, created_at) == :gt and human_actor?(node)
      _ -> false
    end
  end

  defp human_change?({field, expected, actual}, events, created_at) do
    result =
      events
      |> Enum.filter(fn {at, _node} -> DateTime.compare(at, created_at) == :gt end)
      |> Enum.flat_map(&field_event(&1, field))
      |> Enum.reduce_while({:ok, expected, false}, &advance_field(&1, &2, created_at))

    case result do
      {:ok, ^actual, true} -> true
      _ -> false
    end
  end

  defp human_change?({"labelIds", expected, _actual, _index}, events, created_at) do
    events
    |> Enum.filter(fn {at, _node} -> DateTime.compare(at, created_at) == :gt end)
    |> Enum.flat_map(&label_event(&1, expected))
    |> Enum.reduce_while({:ok, :present, false}, &advance_label(&1, &2, created_at))
    |> Kernel.==({:ok, :missing, true})
  end

  defp field_event({at, node}, field) do
    case field_change(field, node) do
      nil -> []
      change -> [{at, node, change}]
    end
  end

  defp advance_field({at, node, {from, to}}, {:ok, prior, _}, created_at) do
    if DateTime.compare(at, created_at) == :gt and from == prior do
      {:cont, {:ok, to, human_actor?(node)}}
    else
      {:halt, :error}
    end
  end

  defp label_event({at, node}, id) do
    added? = id in (node["addedLabelIds"] || [])
    removed? = id in (node["removedLabelIds"] || [])

    case {added?, removed?} do
      {true, true} -> [{at, node, :ambiguous}]
      {true, false} -> [{at, node, :added}]
      {false, true} -> [{at, node, :removed}]
      _ -> []
    end
  end

  defp advance_label({at, node, action}, {:ok, prior, _}, created_at) do
    case {DateTime.compare(at, created_at), prior, action} do
      {:gt, :present, :removed} -> {:cont, {:ok, :missing, human_actor?(node)}}
      {:gt, :missing, :added} -> {:cont, {:ok, :present, human_actor?(node)}}
      _ -> {:halt, :error}
    end
  end

  defp field_change("title", node), do: changed_pair(node["fromTitle"], node["toTitle"])
  defp field_change("assignee.id", node), do: changed_pair(node["fromAssigneeId"], node["toAssigneeId"])
  defp field_change("delegate.id", node), do: changed_pair(get_in(node, ["fromDelegate", "id"]), get_in(node, ["toDelegate", "id"]))
  defp field_change("state.id", node), do: changed_pair(node["fromStateId"], node["toStateId"])
  defp field_change("project.id", node), do: changed_pair(node["fromProjectId"], node["toProjectId"])
  defp field_change("team.id", node), do: changed_pair(node["fromTeamId"], node["toTeamId"])

  defp changed_pair(from, to) when from != to, do: {from, to}
  defp changed_pair(_, _), do: nil

  defp human_actor?(node), do: TrustedAgents.human_or_trusted?(node, TrustedAgents.ids())

  defp difference("description", expected, actual) when is_binary(expected) and is_binary(actual),
    do: Map.put(Description.first_difference(expected, actual), :field, "description")

  defp difference(field, expected, actual) when is_binary(expected) and is_binary(actual) do
    offset = common_prefix_bytes(expected, actual, 0)
    prefix = binary_part(expected, 0, offset)
    lines = String.split(prefix, "\n")

    %{
      field: field,
      at: %{byte: offset, line: length(lines), column: byte_size(List.last(lines)) + 1},
      expected_fragment: fragment(expected, offset),
      actual_fragment: fragment(actual, offset)
    }
  end

  defp difference(field, expected, actual), do: %{field: field, at: field, expected: inspect(expected), actual: inspect(actual)}

  defp common_prefix_bytes(<<byte, expected::binary>>, <<byte, actual::binary>>, count),
    do: common_prefix_bytes(expected, actual, count + 1)

  defp common_prefix_bytes(_, _, count), do: count

  defp fragment(value, offset), do: value |> binary_part(offset, min(48, byte_size(value) - offset)) |> inspect()

  defp link(intent, opts) do
    edges = effective_relations(intent["relations"])

    with :ok <- Relations.validate(edges, opts) do
      Enum.reduce_while(edges, :ok, fn edge, _ -> relation_result(guarded_relation(intent, edge, opts)) end)
    end
  end

  defp effective_relations(edges) do
    # Linear stores one relation per pair; keep the directed dependency, including
    # when resuming an older intent that still planned a redundant related edge.
    blocked_pairs = for edge <- edges, edge["type"] == "blocks", into: MapSet.new(), do: Enum.sort([edge["issueId"], edge["relatedIssueId"]])

    edges
    |> Enum.reject(&(&1["type"] == "related" and MapSet.member?(blocked_pairs, Enum.sort([&1["issueId"], &1["relatedIssueId"]]))))
    |> Enum.uniq()
  end

  defp relation_result(:ok), do: {:cont, :ok}
  defp relation_result(error), do: {:halt, error}

  defp guarded_relation(intent, edge, opts) do
    with {:ok, fresh} <- ActionScope.sources(intent["request"]["origin_ids"], opts),
         true <- Enum.all?(fresh, &unchanged_source?(&1, intent)) do
      Relations.ensure(edge, opts)
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_followup_sources_changed}
    end
  end

  defp finish(%{"request" => %{"kind" => "aggregate"}} = _intent, issues, opts) do
    Enum.reduce_while(issues, :ok, fn issue, _ ->
      with {:ok, state} <- API.state(issue.team_id, "Umsetzungsticket erstellt", opts),
           :ok <- close_origin(issue, state, opts) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp finish(_intent, _issues, _opts), do: :ok

  defp close_origin(%{state: "Umsetzungsticket erstellt"}, _state, _opts), do: :ok
  defp close_origin(issue, state, opts), do: API.update(issue.id, %{stateId: state}, opts)
end
