defmodule SymphonyElixir.Yolo.API do
  @moduledoc "Strict, paginated Linear operations used by durable PO actions."
  alias SymphonyElixir.Linear.Client

  @spec query(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def query(document, variables, opts) do
    with {:ok, response} <- Keyword.get(opts, :query, &Client.graphql/2).(document, variables),
         true <- response["errors"] in [nil, []],
         data when is_map(data) <- response["data"] do
      {:ok, data}
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_response_incomplete}
    end
  end

  @spec pages(String.t(), map(), [String.t()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def pages(document, variables, path, opts), do: page(document, variables, path, opts, nil, %{}, [])

  defp page(document, variables, path, opts, cursor, seen, acc) do
    with {:ok, data} <- query(document, Map.put(variables, :after, cursor), opts),
         %{"nodes" => nodes, "pageInfo" => info} <- get_in(data, path),
         true <- is_list(nodes) and Enum.all?(nodes, &(is_map(&1) and is_binary(&1["id"]))) do
      next = info["endCursor"]

      cond do
        info["hasNextPage"] == false -> {:ok, Enum.uniq_by(acc ++ nodes, & &1["id"])}
        info["hasNextPage"] == true and is_binary(next) and next != "" and not is_map_key(seen, next) -> page(document, variables, path, opts, next, Map.put(seen, next, true), acc ++ nodes)
        true -> {:error, :yolo_page_incomplete}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_page_incomplete}
    end
  end

  @spec state(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def state(team, name, opts) do
    document = "query YoloStates($id: String!, $after: String) { team(id: $id) { states(first: 100, after: $after) { nodes { id name } pageInfo { hasNextPage endCursor } } } }"

    with {:ok, states} <- pages(document, %{id: team}, ["team", "states"], opts),
         [%{"id" => id}] <- Enum.filter(states, &(&1["name"] == name)) do
      {:ok, id}
    else
      {:error, _} = error -> error
      _ -> {:error, {:yolo_state_unavailable, name}}
    end
  end

  @spec update(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def update(id, input, opts) do
    document = "mutation YoloUpdate($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success issue { id } } }"
    confirmed(document, %{id: id, input: input}, ["issueUpdate", "issue"], id, opts)
  end

  @spec confirmed(String.t(), map(), [String.t()], String.t(), keyword()) :: :ok | {:error, term()}
  def confirmed(document, variables, [field, object], id, opts) do
    with {:ok, data} <- query(document, variables, opts),
         %{"success" => true, ^object => %{"id" => ^id}} <- data[field] do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_write_unconfirmed}
    end
  end

  @spec labels(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def labels(id, opts) do
    document = "query YoloCreatedLabels($id: String!, $after: String) { issue(id: $id) { labels(first: 100, after: $after) { nodes { id } pageInfo { hasNextPage endCursor } } } }"
    pages(document, %{id: id}, ["issue", "labels"], opts)
  end

  @spec issue(String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def issue(id, opts) do
    document =
      "query YoloCreatedIssue($id: ID!) { issues(filter: {id: {eq: $id}}, first: 2) { nodes { id identifier url title description project { id } team { id } assignee { id } delegate { id } state { id name } } pageInfo { hasNextPage } } }"

    case query(document, %{id: id}, opts) do
      {:ok, %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}}} ->
        case nodes do
          [] -> {:ok, nil}
          [%{"id" => ^id} = issue] -> {:ok, issue}
          _ -> {:error, :yolo_created_issue_unconfirmed}
        end

      {:error, _} = error ->
        error

      _ ->
        {:error, :yolo_created_issue_unconfirmed}
    end
  end
end
