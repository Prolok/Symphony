defmodule SymphonyElixir.Yolo.Admission do
  @moduledoc "Fresh, idempotent human assignment and additive skip labels for delegated work."

  alias SymphonyElixir.{Config, ProjectContext, Tracker}
  alias SymphonyElixir.Linear.{Client, IssueLease, YoloAgent}
  alias SymphonyElixir.Yolo.{Dependencies, Operations}

  @labels [~s(Skip "Freigabe Implementierung"), ~s(Skip "Freigabe Review")]

  @spec needed?(map()) :: boolean()
  def needed?(issue) do
    YoloAgent.delegated?(issue) and
      (is_nil(issue.assignee_id) or not Enum.all?(@labels, &(String.downcase(&1) in issue.labels)))
  end

  @spec prepare(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(issue, opts \\ []) do
    if needed?(issue) do
      context = ProjectContext.current()
      IssueLease.with_lock(context.settings.tracker.app["workspace_id"], issue.id, fn -> prepare_locked(issue, opts) end)
    else
      {:ok, issue}
    end
  end

  defp prepare_locked(issue, opts) do
    fetch = Keyword.get(opts, :fetch, &Tracker.fetch_issue_states_by_ids/1)
    query = Keyword.get(opts, :query, &Client.graphql/2)

    with {:ok, [current]} <- fetch.([issue.id]),
         {:ok, [current]} <- Dependencies.refresh([current], opts),
         true <- eligible?(current) and Dependencies.dispatchable?(current),
         {:ok, current} <- complete_labels(current, query),
         {:ok, ids} <- missing_labels(current, query),
         :ok <- update(current, ids, query),
         {:ok, [updated]} <- fetch.([issue.id]),
         {:ok, updated} <- complete_labels(updated, query),
         true <- eligible?(updated) and not needed?(updated) do
      {:ok, updated}
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_admission_changed}
    end
  end

  defp complete_labels(issue, query) do
    if length(issue.labels) < 50 or not needed?(issue) do
      {:ok, issue}
    else
      with {:ok, labels} <- issue_labels(query, issue.id, nil, %{}, []) do
        {:ok, %{issue | labels: Enum.uniq(labels)}}
      end
    end
  end

  defp issue_labels(query, id, cursor, seen, acc) do
    document = """
    query SymphonyYoloIssueLabels($id: String!, $after: String) {
      issue(id: $id) { labels(first: 100, after: $after) {
        nodes { name } pageInfo { hasNextPage endCursor }
      } }
    }
    """

    with {:ok, response} <- query.(document, %{id: id, after: cursor}),
         true <- response["errors"] in [nil, []],
         %{"nodes" => nodes, "pageInfo" => page} <- get_in(response, ["data", "issue", "labels"]),
         true <- is_list(nodes) and Enum.all?(nodes, &(is_map(&1) and is_binary(&1["name"]))) do
      labels = acc ++ Enum.map(nodes, &String.downcase(&1["name"]))
      next = page["endCursor"]

      cond do
        page["hasNextPage"] == false ->
          {:ok, labels}

        page["hasNextPage"] == true and is_binary(next) and next != "" and not is_map_key(seen, next) ->
          issue_labels(query, id, next, Map.put(seen, next, true), labels)

        true ->
          {:error, :yolo_labels_incomplete}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_labels_incomplete}
    end
  end

  @spec eligible?(map()) :: boolean()
  def eligible?(issue) do
    context = ProjectContext.current()
    ids = Config.allowed_issue_ids()

    Operations.target_ready?(issue.id) and issue.in_project_scope and YoloAgent.delegated?(issue) and issue.project_context_id == context.id and
      issue.workspace_id == context.settings.tracker.app["workspace_id"] and
      authorized?(issue, context, ids)
  end

  defp authorized?(issue, context, ids) do
    is_binary(Config.human_handoff_id()) and Config.human_handoff_id() in context.assignee_ids and
      (is_nil(issue.assignee_id) or issue.assigned_to_worker) and (not is_list(ids) or issue.id in ids)
  end

  defp missing_labels(issue, query) do
    names = Enum.reject(@labels, &(String.downcase(&1) in issue.labels))

    if names == [] do
      {:ok, []}
    else
      with {:ok, labels} <- label_pages(query, names, nil, %{}, []),
           selected = Enum.filter(labels, &(get_in(&1, ["team", "id"]) in [nil, issue.team_id])),
           groups = Enum.group_by(selected, &String.downcase(&1["name"])),
           true <- Enum.all?(names, &(length(Map.get(groups, String.downcase(&1), [])) == 1)) do
        {:ok, Enum.map(names, &hd(groups[String.downcase(&1)])["id"])}
      else
        {:error, _} = error -> error
        _ -> {:error, :yolo_skip_labels_unavailable_or_ambiguous}
      end
    end
  end

  defp label_pages(query, names, cursor, seen, acc) do
    document = """
    query SymphonyYoloLabels($filter: IssueLabelFilter!, $after: String) {
      issueLabels(filter: $filter, first: 100, after: $after) {
        nodes { id name team { id } }
        pageInfo { hasNextPage endCursor }
      }
    }
    """

    filter = %{"or" => Enum.map(names, &%{"name" => %{"eqIgnoreCase" => &1}})}

    with {:ok, response} <- query.(document, %{filter: filter, after: cursor}),
         true <- response["errors"] in [nil, []],
         %{"nodes" => nodes, "pageInfo" => page} <- get_in(response, ["data", "issueLabels"]),
         true <- is_list(nodes) and Enum.all?(nodes, &(is_binary(&1["id"]) and is_binary(&1["name"]))) do
      next = page["endCursor"]

      cond do
        page["hasNextPage"] == false ->
          {:ok, Enum.uniq_by(acc ++ nodes, & &1["id"])}

        page["hasNextPage"] == true and is_binary(next) and next != "" and not is_map_key(seen, next) ->
          label_pages(query, names, next, Map.put(seen, next, true), acc ++ nodes)

        true ->
          {:error, :yolo_labels_incomplete}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_labels_incomplete}
    end
  end

  defp update(issue, ids, query) do
    input = if ids == [], do: %{}, else: %{addedLabelIds: ids}
    input = if is_nil(issue.assignee_id), do: Map.put(input, :assigneeId, Config.human_handoff_id()), else: input

    if input == %{} do
      :ok
    else
      document = """
      mutation SymphonyYoloAdmission($id: String!, $input: IssueUpdateInput!) {
        issueUpdate(id: $id, input: $input) { success issue { id } }
      }
      """

      with {:ok, response} <- query.(document, %{id: issue.id, input: input}),
           true <- response["errors"] in [nil, []],
           %{"success" => true, "issue" => %{"id" => id}} when id == issue.id <- get_in(response, ["data", "issueUpdate"]) do
        :ok
      else
        {:error, _} = error -> error
        _ -> {:error, :yolo_admission_write_unconfirmed}
      end
    end
  end
end
