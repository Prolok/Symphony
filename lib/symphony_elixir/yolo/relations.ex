defmodule SymphonyElixir.Yolo.Relations do
  @moduledoc "Idempotent relation transfer with complete reads and cycle checks before writes."
  alias SymphonyElixir.Yolo.API

  @spec read(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def read(id, opts) do
    Enum.reduce_while(["relations", "inverseRelations"], {:ok, []}, fn field, {:ok, acc} ->
      document =
        "query YoloRelations($id: String!, $after: String) { issue(id: $id) { #{field}(first: 100, after: $after) { nodes { id type issue { id } relatedIssue { id } } pageInfo { hasNextPage endCursor } } } }"

      case API.pages(document, %{id: id}, ["issue", field], opts) do
        {:ok, nodes} -> {:cont, {:ok, Enum.uniq_by(acc ++ nodes, & &1["id"])}}
        error -> {:halt, error}
      end
    end)
  end

  @spec transfer([String.t()], String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def transfer(origins, target, opts) do
    with {:ok, relations} <- collect(origins, opts) do
      copied =
        relations
        |> Enum.filter(&(&1["type"] == "blocks"))
        |> Enum.map(&remap(&1, origins, target))
        |> Enum.reject(&(&1["issueId"] == &1["relatedIssueId"]))
        |> Enum.uniq()

      {:ok, copied}
    end
  end

  defp remap(relation, origins, target) do
    from = get_in(relation, ["issue", "id"])
    to = get_in(relation, ["relatedIssue", "id"])
    edge(if(from in origins, do: target, else: from), if(to in origins, do: target, else: to), "blocks")
  end

  defp collect(ids, opts) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case read(id, opts) do
        {:ok, relations} -> {:cont, {:ok, acc ++ relations}}
        error -> {:halt, error}
      end
    end)
  end

  @spec edge(String.t(), String.t(), String.t()) :: map()
  def edge(from, to, type), do: %{"issueId" => from, "relatedIssueId" => to, "type" => type}

  @spec validate([map()], keyword()) :: :ok | {:error, term()}
  def validate(edges, opts) do
    Enum.reduce_while(edges, :ok, fn item, _ -> validate_edge(item, edges, opts) end)
  end

  defp validate_edge(%{"type" => "blocks"} = item, edges, opts) do
    case reaches?([item["relatedIssueId"]], item["issueId"], edges, %{}, opts) do
      {:ok, false} -> {:cont, :ok}
      {:ok, true} -> {:halt, {:error, :yolo_dependency_cycle}}
      error -> {:halt, error}
    end
  end

  defp validate_edge(_, _, _), do: {:cont, :ok}

  defp reaches?([], _, _, _, _), do: {:ok, false}
  defp reaches?([target | _], target, _, _, _), do: {:ok, true}

  defp reaches?([id | rest], target, planned, seen, opts) do
    if Map.has_key?(seen, id) do
      reaches?(rest, target, planned, seen, opts)
    else
      with {:ok, neighbors} <- neighbors(id, planned, opts) do
        reaches?(Enum.uniq(rest ++ neighbors), target, planned, Map.put(seen, id, true), opts)
      end
    end
  end

  defp neighbors(id, planned, opts) do
    with {:ok, relations} <- read(id, opts) do
      existing = for r <- relations, r["type"] == "blocks" and get_in(r, ["issue", "id"]) == id, do: get_in(r, ["relatedIssue", "id"])
      additions = for r <- planned, r["type"] == "blocks" and r["issueId"] == id, do: r["relatedIssueId"]
      {:ok, existing ++ additions}
    end
  end

  @spec ensure(map(), keyword()) :: :ok | {:error, term()}
  def ensure(edge, opts) do
    with {:ok, relations} <- read(edge["issueId"], opts) do
      if Enum.any?(relations, &matches?(&1, edge)) do
        :ok
      else
        id = Ecto.UUID.generate()
        document = "mutation YoloRelation($input: IssueRelationCreateInput!) { issueRelationCreate(input: $input) { success issueRelation { id } } }"
        API.confirmed(document, %{input: Map.put(edge, "id", id)}, ["issueRelationCreate", "issueRelation"], id, opts)
      end
    end
  end

  defp matches?(relation, edge) do
    pair = {get_in(relation, ["issue", "id"]), get_in(relation, ["relatedIssue", "id"])}
    expected = {edge["issueId"], edge["relatedIssueId"]}
    reversed = {elem(expected, 1), elem(expected, 0)}
    relation["type"] == edge["type"] and (pair == expected or (edge["type"] == "related" and pair == reversed))
  end
end
