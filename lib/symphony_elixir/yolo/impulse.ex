defmodule SymphonyElixir.Yolo.Impulse do
  @moduledoc "Durable, history-backed reasons to recheck an already delivered PO member."
  alias SymphonyElixir.{Config, ProjectContext}
  alias SymphonyElixir.Yolo.API

  @history "query YoloIssueHistory($id: String!, $after: String) { issue(id: $id) { history(first: 100, after: $after) { nodes { id createdAt fromDelegate { id } toDelegate { id } fromPriority toPriority actor { id app } botActor { id } } pageInfo { hasNextPage endCursor } } } }"

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

    with {:ok, nodes} <- history.(issue.id),
         true <- Enum.all?(nodes, &valid_history?/1),
         {:ok, recent} <- recent(nodes, prior) do
      reasons = recent |> Enum.reverse() |> Enum.flat_map(&reasons(&1, issue)) |> Enum.uniq()
      generation = if(is_map(prior), do: prior["generation"], else: 0) || 0

      {:ok,
       %{
         "relay" => event,
         "history_head" => if(nodes == [], do: nil, else: hd(nodes)["id"]),
         "generation" => generation + if(reasons == [], do: 0, else: 1),
         "reason" => if(reasons == [], do: "no_relevant_history", else: Enum.join(reasons, ","))
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_history_incomplete}
    end
  end

  defp history(id, opts), do: API.pages(@history, %{id: id}, ["issue", "history"], opts)

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
           get_in(node, ["fromDelegate", "id"]) != Config.yolo_agent_id(),
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

    is_map(actor) and actor["app"] == false and is_nil(node["botActor"]) and
      is_binary(actor["id"]) and actor["id"] == issue.assignee_id and actor["id"] in (context.assignee_ids || [])
  end
end
