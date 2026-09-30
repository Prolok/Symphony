defmodule SymphonyElixir.Yolo.Impulse do
  @moduledoc "Durable history- and session-backed reasons to recheck an already delivered PO member."
  alias SymphonyElixir.{Config, ProjectContext}
  alias SymphonyElixir.Linear.TrustedAgents
  alias SymphonyElixir.Yolo.API

  @history "query YoloIssueHistory($id: String!, $after: String) { issue(id: $id) { history(first: 100, after: $after) { nodes { id createdAt fromDelegate { id } toDelegate { id } fromPriority toPriority actor { id app } botActor { id } } pageInfo { hasNextPage endCursor } } } }"
  @sessions "query YoloIssueAgentSessions($id: String!, $after: String) { issue(id: $id) { agentSessions(first: 100, after: $after, includeArchived: true) { nodes { id createdAt appUser { id } issue { id } sourceComment { id } comment { id issue { id } isArtificialAgentSessionRoot } } pageInfo { hasNextPage endCursor } } } }"

  @spec observe([map()], map(), keyword()) :: {:ok, map()} | {:error, term()}
  def observe(issues, record, opts \\ []) do
    previous = record["impulses"] || %{}

    Enum.reduce_while(issues, {:ok, previous}, fn issue, {:ok, acc} ->
      case inspect_issue(issue, acc[issue.id], opts) do
        {:ok, current} -> {:cont, {:ok, Map.put(acc, issue.id, current)}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, impulses} -> {:ok, Map.put(record, "impulses", impulses)}
      error -> error
    end
  end

  @spec generations(map()) :: map()
  def generations(record), do: Map.new(record["impulses"] || %{}, fn {id, entry} -> {id, entry["generation"] || 0} end)

  defp inspect_issue(issue, prior, opts) do
    event = issue.relay_event

    cond do
      not is_map(event) and is_map(prior) -> {:ok, prior}
      not is_map(event) and is_nil(Config.settings!().tracker.relay) -> {:ok, %{"generation" => 0, "reason" => "no_relay_event"}}
      is_map(prior) and prior["relay"] == event -> {:ok, prior}
      true -> inspect_history(issue, event, prior, opts)
    end
  end

  defp inspect_history(issue, event, prior, opts) do
    history = Keyword.get(opts, :history, &history(&1, opts))
    sessions = Keyword.get(opts, :sessions, &sessions(&1, opts))

    with {:ok, nodes} <- history.(issue.id),
         true <- Enum.all?(nodes, &valid_history?/1),
         {:ok, recent} <- recent(nodes, prior),
         {:ok, session_nodes} <- sessions.(issue.id),
         true <- Enum.all?(session_nodes, &valid_session?/1),
         agent_sessions = session_nodes |> Enum.filter(&delegation_session?(&1, issue.id)) |> Enum.sort_by(&{&1["createdAt"], &1["id"]}, :desc),
         {:ok, new_sessions} <- recent_sessions(agent_sessions, prior) do
      {:ok, history_record(issue, event, prior, nodes, recent, agent_sessions, new_sessions)}
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_history_incomplete}
    end
  end

  defp history_record(issue, event, prior, nodes, recent, agent_sessions, new_sessions) do
    reasons = recent |> Enum.reverse() |> Enum.flat_map(&reasons(&1, issue)) |> Enum.uniq()
    reasons = if(new_sessions != [] and issue.delegate_id == Config.yolo_agent_id(), do: Enum.uniq(["delegated_again" | reasons]), else: reasons)
    generation = if(is_map(prior), do: prior["generation"], else: 0) || 0
    generation = generation + if(reasons == [], do: 0, else: 1)

    %{
      "relay" => event,
      "history_head" => head_id(nodes),
      "session_head" => head_id(agent_sessions),
      "session_head_ids" => head_session_ids(agent_sessions),
      "agent_input_ids" => input_ids(recent, &TrustedAgents.trusted?(&1, TrustedAgents.ids())),
      "human_input_ids" => input_ids(recent, &TrustedAgents.human_or_trusted?(&1, [])),
      "generation" => generation,
      "delegation_generation" => if("delegated_again" in reasons, do: generation, else: last_delegation_generation(prior)),
      "reason" => if(reasons == [], do: "no_relevant_history", else: Enum.join(reasons, ","))
    }
  end

  defp last_delegation_generation(nil), do: 0

  defp last_delegation_generation(prior) do
    prior["delegation_generation"] ||
      if("delegated_again" in String.split(prior["reason"] || "", ","), do: prior["generation"] || 0, else: 0)
  end

  defp head_id([]), do: nil
  defp head_id([head | _]), do: head["id"]
  defp input_ids(nodes, actor?), do: nodes |> Enum.filter(actor?) |> Enum.map(& &1["id"])

  defp history(id, opts), do: API.pages(@history, %{id: id}, ["issue", "history"], opts)
  defp sessions(id, opts), do: API.pages(@sessions, %{id: id}, ["issue", "agentSessions"], opts)

  defp recent_sessions(_sessions, nil), do: {:ok, []}
  defp recent_sessions(_sessions, prior) when not is_map_key(prior, "session_head"), do: {:ok, []}
  defp recent_sessions(sessions, %{"session_head" => nil}), do: {:ok, sessions}

  defp recent_sessions(sessions, %{"session_head" => head} = prior) do
    case Enum.find(sessions, &(&1["id"] == head)) do
      nil ->
        {:error, :yolo_session_gap}

      previous ->
        case prior["session_head_ids"] do
          ids when is_list(ids) ->
            seen = MapSet.new(ids)
            at = previous["createdAt"]
            {:ok, Enum.filter(sessions, &(&1["createdAt"] > at or (&1["createdAt"] == at and not MapSet.member?(seen, &1["id"]))))}

          _ ->
            {:ok, []}
        end
    end
  end

  defp head_session_ids([]), do: []
  defp head_session_ids([head | _] = sessions), do: sessions |> Enum.filter(&(&1["createdAt"] == head["createdAt"])) |> Enum.map(& &1["id"])

  defp valid_session?(%{
         "id" => id,
         "createdAt" => at,
         "appUser" => %{"id" => app},
         "issue" => %{"id" => issue},
         "comment" => %{"id" => root, "issue" => %{"id" => root_issue}, "isArtificialAgentSessionRoot" => artificial},
         "sourceComment" => source
       }) do
    Enum.all?([id, at, app, issue, root, root_issue], &is_binary/1) and
      is_boolean(artificial) and (is_nil(source) or is_map(source))
  end

  defp valid_session?(_), do: false

  defp delegation_session?(session, issue_id) do
    session["appUser"]["id"] == Config.yolo_agent_id() and session["issue"]["id"] == issue_id and
      session["comment"]["issue"]["id"] == issue_id and session["comment"]["isArtificialAgentSessionRoot"] == true and
      is_nil(session["sourceComment"])
  end

  defp recent(_nodes, nil), do: {:ok, []}
  defp recent(nodes, %{"history_head" => nil}), do: {:ok, nodes}
  defp recent(_nodes, %{"reason" => "no_relay_event"}), do: {:ok, []}

  defp recent(nodes, %{"history_head" => head}) do
    {recent, rest} = Enum.split_while(nodes, &(&1["id"] != head))
    if rest == [], do: {:error, :yolo_history_gap}, else: {:ok, recent}
  end

  defp valid_history?(%{"id" => id, "createdAt" => at}) when is_binary(id) and is_binary(at), do: true
  defp valid_history?(_), do: false

  defp reasons(node, issue) do
    delegation =
      if get_in(node, ["toDelegate", "id"]) == Config.yolo_agent_id() and
           get_in(node, ["fromDelegate", "id"]) != Config.yolo_agent_id() and
           TrustedAgents.human_or_trusted?(node, TrustedAgents.ids()),
         do: ["delegated_again"],
         else: []

    priority =
      if raised?(node) and human_actor?(node, issue), do: ["human_priority_raised"], else: []

    delegation ++ priority
  end

  defp raised?(%{"fromPriority" => from, "toPriority" => to})
       when is_integer(from) and is_integer(to) and from in 0..4 and to in 1..4,
       do: from == 0 or to < from

  defp raised?(_), do: false

  defp human_actor?(node, issue) do
    actor = node["actor"]
    context = ProjectContext.current()

    TrustedAgents.trusted?(node, TrustedAgents.ids()) or
      (is_map(actor) and actor["app"] == false and is_nil(node["botActor"]) and
         is_binary(actor["id"]) and actor["id"] == issue.assignee_id and actor["id"] in (context.assignee_ids || []))
  end
end
