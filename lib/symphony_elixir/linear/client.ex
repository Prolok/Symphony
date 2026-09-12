defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.Linear.AppAuth
  alias SymphonyElixir.Linear.CommentActionGuard
  alias SymphonyElixir.Linear.WriteContext

  alias SymphonyElixir.{Config, Dialog, Linear.Issue, ProjectContext}
  alias SymphonyElixir.Linear.{Assignees, CommentVersion}

  @issue_page_size 50
  @typep page_cursors :: %{optional(String.t()) => true}
  @max_error_body_log_bytes 1_000
  @manual_in_progress_state_name "In Arbeit"
  @manual_approval_state_names ["Freigabe Implementierung", "Freigabe Review"]

  @issue_selection """
  id
  identifier
  title
  description
  priority
  state {
    name
  }
  branchName
  url
  assignee {
    id
    email
    app
  }
  project { id slugId }
  team { id key }
  labels {
    nodes {
      name
    }
  }
  inverseRelations(first: $relationFirst) {
    nodes {
      type
      issue {
        id
        identifier
        state {
          name
        }
      }
    }
  }
  comments(first: 1, orderBy: updatedAt) {
    nodes {
      id
      createdAt
      updatedAt
    }
  }
  createdAt
  updatedAt
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        #{@issue_selection}
      }
    }
  }
  """

  @query_by_ids_in_team """
  query SymphonyLinearIssuesByIdInTeam($ids: [ID!]!, $teamKey: String!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}, team: {key: {eq: $teamKey}}}, first: $first) {
      nodes {
        #{@issue_selection}
      }
    }
  }
  """

  @query_by_identifier """
  query SymphonyLinearIssueByIdentifier($teamKey: String!, $number: Float!, $relationFirst: Int!) {
    issues(filter: {team: {key: {eq: $teamKey}}, number: {eq: $number}}, first: 1) {
      nodes {
        #{@issue_selection}
      }
    }
  }
  """

  @comment_selection """
  id
  body
  user { id app }
  issue { id }
  parentId
  editedAt
  resolvedAt
  archivedAt
  botActor { id type }
  externalUser { id }
  onBehalfOf { id app }
  bodyData
  quotedText
  resolvingUser { id }
  resolvingComment { id }
  createdAt
  updatedAt
  """

  @issue_comments_query """
  query SymphonyLinearIssueComments($id: String!, $first: Int!, $after: String) {
    issue(id: $id) {
      comments(first: $first, after: $after, includeArchived: true) {
        nodes {
          #{@comment_selection}
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with {:ok, scope} <- Config.linear_scope(tracker),
         {:ok, assignee_filter} <- routing_assignee_filter(),
         {:ok, issues} <- do_fetch_by_states(scope, candidate_state_names(tracker.active_states), assignee_filter),
         :ok <- validate_candidate_scope(tracker, issues) do
      {:ok, issues}
    end
  end

  @doc "Fetch every configured scope in one candidate request per workspace and page."
  @spec fetch_project_candidates([ProjectContext.t()]) :: {:ok, map()} | {:error, term()}
  def fetch_project_candidates(contexts) do
    with :ok <- validate_workspace_bindings(contexts) do
      contexts
      |> Enum.group_by(& &1.settings.tracker.app["workspace_id"])
      |> Enum.reduce_while({:ok, %{}}, &collect_workspace_candidates/2)
    end
  end

  @spec verify_project_assignees([ProjectContext.t()]) :: :ok | {:error, term()}
  def verify_project_assignees(contexts) do
    contexts
    |> Enum.group_by(& &1.settings.tracker.app["workspace_id"])
    |> Enum.reduce_while(:ok, &verify_workspace_assignees/2)
  end

  defp verify_workspace_assignees({workspace, [first | _] = contexts}, :ok) do
    configured = contexts |> Enum.flat_map(&Assignees.parse(&1.settings.tracker.assignee)) |> Enum.uniq()
    result = ProjectContext.with_context(first, fn -> fetch_assignees(configured, nil, %{}, []) end)

    case result do
      {:ok, users} ->
        if Enum.all?(configured, &verified_human?(&1, users)), do: {:cont, :ok}, else: {:halt, {:error, {:linear_assignees_not_human_or_unavailable, workspace, configured}}}

      error ->
        {:halt, error}
    end
  end

  defp verified_human?(value, users) do
    Enum.any?(users, fn user ->
      user["app"] == false and value in [user["id"], String.downcase(user["email"] || "")]
    end)
  end

  @spec fetch_assignees([String.t()], String.t() | nil, page_cursors(), [map()]) :: {:ok, [map()]} | {:error, term()}
  defp fetch_assignees([], _cursor, _seen, _users), do: {:ok, []}

  defp fetch_assignees(configured, cursor, seen, users) do
    query = """
    query SymphonyHumanAssignees($filter: UserFilter!, $after: String) {
      users(filter: $filter, first: 100, after: $after) {
        nodes { id email app }
        pageInfo { hasNextPage endCursor }
      }
    }
    """

    variables = %{filter: Assignees.filter(Enum.join(configured, ",")), after: cursor}

    with {:ok, %{"data" => %{"users" => %{"nodes" => nodes, "pageInfo" => page}}} = body} <- graphql(query, variables),
         true <- Map.get(body, "errors", []) in [nil, []] do
      next = page["endCursor"]

      cond do
        page["hasNextPage"] == false -> {:ok, users ++ nodes}
        not is_binary(next) or next == "" or Map.has_key?(seen, next) -> {:error, :linear_invalid_page_cursor}
        true -> fetch_assignees(configured, next, Map.put(seen, next, true), users ++ nodes)
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :linear_unknown_payload}
    end
  end

  @spec validate_workspace_bindings([ProjectContext.t()]) :: :ok | {:error, term()}
  def validate_workspace_bindings(contexts) do
    contexts
    |> Enum.group_by(& &1.settings.tracker.app["workspace_id"])
    |> Enum.reduce_while(:ok, &validate_workspace_group/2)
  end

  defp collect_workspace_candidates({_workspace, projects}, {:ok, acc}) do
    case fetch_workspace_candidates(projects) do
      {:ok, found} -> {:cont, {:ok, Map.merge(acc, found)}}
      error -> {:halt, error}
    end
  end

  defp validate_workspace_group({workspace, projects}, :ok) do
    bindings = Enum.uniq_by(projects, &workspace_binding/1)
    scopes = Enum.map(projects, &Config.linear_scope(&1.settings.tracker))

    result =
      cond do
        length(bindings) != 1 -> {:error, {:conflicting_workspace_app_binding, workspace}}
        length(Enum.uniq(scopes)) != length(scopes) -> {:error, {:duplicate_workspace_scope, workspace}}
        true -> shared_credentials(projects)
      end

    case result do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp workspace_binding(context) do
    tracker = context.settings.tracker
    {tracker.endpoint, Map.take(tracker.app, ~w(client_id workspace_id user_id client_secret_env))}
  end

  defp shared_credentials(projects) do
    Enum.reduce_while(projects, {:ok, MapSet.new()}, fn context, {:ok, fingerprints} ->
      case Config.linear_client_secret(context.settings.tracker.app) do
        {:ok, secret} -> {:cont, {:ok, MapSet.put(fingerprints, :crypto.hash(:sha256, secret))}}
        {:error, reason} -> {:halt, {:error, {:project_app_credentials_unavailable, context.root, reason}}}
      end
    end)
    |> case do
      {:ok, fingerprints} ->
        if MapSet.size(fingerprints) == 1, do: :ok, else: {:error, :conflicting_workspace_app_credentials}

      error ->
        error
    end
  end

  defp fetch_workspace_candidates([first | _] = projects) do
    filter = %{"or" => Enum.map(projects, &project_candidate_filter/1)}

    with {:ok, nodes} <- ProjectContext.with_context(first, fn -> fetch_workspace_page(filter, nil, %{}, []) end),
         :ok <- validate_unambiguous_candidates(nodes, projects) do
      Enum.reduce_while(projects, {:ok, %{}}, &collect_project_candidates(&1, &2, nodes))
    end
  end

  defp validate_unambiguous_candidates(nodes, projects) do
    if Enum.any?(nodes, fn node -> Enum.count(projects, &project_candidate?(node, &1)) > 1 end), do: {:error, :ambiguous_workspace_project_scope}, else: :ok
  end

  defp collect_project_candidates(context, {:ok, acc}, nodes) do
    case ProjectContext.with_context(context, fn -> normalize_project_candidates(context, nodes) end) do
      {:ok, issues} -> {:cont, {:ok, Map.put(acc, context.id, issues)}}
      error -> {:halt, error}
    end
  end

  defp normalize_project_candidates(context, nodes) do
    with {:ok, assignee_filter} <- routing_assignee_filter() do
      issues = nodes |> Enum.filter(&project_candidate?(&1, context)) |> Enum.map(&normalize_issue(&1, assignee_filter))

      case validate_candidate_scope(context.settings.tracker, issues) do
        :ok -> {:ok, issues}
        error -> error
      end
    end
  end

  defp project_candidate_filter(context) do
    tracker = context.settings.tracker
    {:ok, scope} = Config.linear_scope(tracker)

    filter =
      scope_filter(scope)
      |> Map.put("state", %{"name" => %{"in" => candidate_state_names(tracker.active_states)}})
      |> restrict_candidate_ids(tracker.app["allowed_issue_ids"])

    filter = if Config.yolo?(), do: filter, else: Map.put(filter, "assignee", Map.put(Assignees.filter(tracker.assignee), "app", %{"eq" => false}))

    # Linear propagates the enclosing OR to fields in a branch. Explicit AND
    # groups keep each project's scope, states and assignees correlated.
    %{"and" => Enum.map(filter, fn {field, value} -> %{field => value} end)}
  end

  defp restrict_candidate_ids(filter, ids) when is_list(ids), do: Map.put(filter, "id", %{"in" => ids})
  defp restrict_candidate_ids(filter, _ids), do: filter

  defp scope_filter({:project, slug}), do: %{"project" => %{"slugId" => %{"eq" => slug}}}
  defp scope_filter({:team, key}), do: %{"team" => %{"key" => %{"eq" => key}}}

  defp project_candidate?(node, context) do
    tracker = context.settings.tracker

    scope_matches =
      case Config.linear_scope(tracker) do
        {:ok, {:project, slug}} -> get_in(node, ["project", "slugId"]) == slug
        {:ok, {:team, key}} -> get_in(node, ["team", "key"]) == key
      end

    scope_matches and get_in(node, ["state", "name"]) in candidate_state_names(tracker.active_states) and
      project_assignee_matches?(node, tracker.assignee)
  end

  defp project_assignee_matches?(node, assignee) do
    if Config.yolo?() do
      true
    else
      {:ok, filter} = build_assignee_filter(assignee)
      get_in(node, ["assignee", "app"]) != true and assigned_to_worker?(node["assignee"], filter)
    end
  end

  @spec fetch_workspace_page(map(), String.t() | nil, page_cursors(), [map()]) :: {:ok, [map()]} | {:error, term()}
  defp fetch_workspace_page(filter, cursor, seen, acc) do
    query = """
    query SymphonyWorkspacePoll($filter: IssueFilter!, $first: Int!, $relationFirst: Int!, $after: String) {
      issues(filter: $filter, first: $first, after: $after) {
        nodes { #{@issue_selection} }
        pageInfo { hasNextPage endCursor }
      }
    }
    """

    with {:ok, %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => page}}} = body} <-
           graphql(query, %{filter: filter, first: @issue_page_size, relationFirst: @issue_page_size, after: cursor}),
         true <- Map.get(body, "errors", []) in [nil, []] do
      next = page["endCursor"]

      cond do
        page["hasNextPage"] == false -> {:ok, acc ++ nodes}
        not is_binary(next) or next == "" or Map.has_key?(seen, next) -> {:error, :linear_invalid_page_cursor}
        true -> fetch_workspace_page(filter, next, Map.put(seen, next, true), acc ++ nodes)
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :linear_unknown_payload}
    end
  end

  @spec validate_candidate_scope(map(), [Issue.t()]) :: :ok | {:error, term()}
  def validate_candidate_scope(%{auth_mode: "app", app: %{"allowed_issue_ids" => ids}}, issues) when is_list(ids) do
    if Enum.all?(issues, &(&1.id in ids)), do: :ok, else: {:error, :linear_app_candidate_scope_changed}
  end

  def validate_candidate_scope(_tracker, _issues), do: :ok

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    case normalized_states do
      [] -> {:ok, []}
      states -> fetch_issues_by_states(Config.settings!().tracker, states)
    end
  end

  defp fetch_issues_by_states(tracker, state_names) do
    with {:ok, scope} <- Config.linear_scope(tracker) do
      do_fetch_by_states(scope, state_names, nil)
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        tracker = Config.settings!().tracker

        with {:ok, scope} <- Config.linear_scope(tracker),
             {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_issue_states(ids, scope, assignee_filter)
        end
    end
  end

  @spec fetch_issue_by_identifier(String.t()) :: {:ok, Issue.t()} | {:error, term()}
  def fetch_issue_by_identifier(identifier) when is_binary(identifier) do
    normalized_identifier = String.trim(identifier)
    tracker = Config.settings!().tracker

    if normalized_identifier == "" do
      {:error, :missing_issue_identifier}
    else
      with {:ok, scope} <- Config.linear_scope(tracker),
           {:ok, team_key, issue_number} <- split_issue_identifier(normalized_identifier),
           :ok <- validate_identifier_scope(scope, normalized_identifier, team_key),
           {:ok, body} <-
             graphql(@query_by_identifier, %{
               teamKey: team_key,
               number: issue_number,
               relationFirst: @issue_page_size
             }),
           {:ok, issues} <- decode_linear_response(body, nil) do
        issues = Enum.filter(issues, & &1.assigned_to_worker)
        first_issue(issues, normalized_identifier)
      end
    end
  end

  @spec fetch_issue_comment_bodies(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def fetch_issue_comment_bodies(issue_id) when is_binary(issue_id) do
    with {:ok, comments} <- fetch_issue_comments(issue_id) do
      {:ok, Enum.map(comments, &Map.get(&1, :body, ""))}
    end
  end

  @spec fetch_issue_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_issue_comments(issue_id) when is_binary(issue_id) do
    fetch_issue_comments_page(issue_id, nil, [], %{})
  end

  @doc "Detect visible changes during pagination; preserve observed versions without claiming a complete scan."
  @spec scan_issue_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def scan_issue_comments(issue_id) do
    with {:ok, before} <- comment_scan_signal(issue_id) do
      scan_comment_pages(fetch_issue_comments(issue_id), issue_id, before)
    end
  end

  defp scan_comment_pages({:ok, comments}, issue_id, before) do
    finish_comment_scan(comment_scan_signal(issue_id), before, before ++ comments)
  end

  defp scan_comment_pages({:error, {:comment_scan_incomplete, reason, comments}}, _issue_id, before),
    do: incomplete_comments(reason, before ++ comments)

  defp scan_comment_pages({:error, reason}, _issue_id, before), do: incomplete_comments(reason, before)

  defp finish_comment_scan({:ok, signal}, signal, comments), do: {:ok, Enum.uniq_by(comments, &CommentVersion.key/1)}
  defp finish_comment_scan({:ok, after_scan}, _before, comments), do: incomplete_comments(:comment_scan_changed, comments ++ after_scan)
  defp finish_comment_scan({:error, {:comment_scan_incomplete, reason, observed}}, _before, comments), do: incomplete_comments(reason, comments ++ observed)
  defp finish_comment_scan({:error, reason}, _before, comments), do: incomplete_comments(reason, comments)

  defp comment_scan_signal(issue_id) do
    query = "query SymphonyCommentScanSignal($id: String!) { issue(id: $id) { comments(first: 1, orderBy: updatedAt, includeArchived: true) { nodes { #{@comment_selection} } } } }"

    with {:ok, body} <- graphql(query, %{id: issue_id}) do
      decode_comment_scan_signal(body, issue_id)
    end
  end

  defp decode_comment_scan_signal(body, issue_id) do
    with true <- Map.get(body, "errors", []) in [nil, []],
         nodes when is_list(nodes) <- get_in(body, ["data", "issue", "comments", "nodes"]),
         true <- length(nodes) <= 1 and Enum.all?(nodes, &(is_binary(&1["id"]) and is_binary(&1["body"]))),
         {:ok, comments} <- normalize_comments(nodes),
         true <- Enum.all?(comments, &(&1.issue_id == issue_id)) do
      {:ok, comments}
    else
      _ -> incomplete_comments(:comment_scan_signal_unavailable, observed_comments(body, issue_id))
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))

    request_fun =
      Keyword.get(
        opts,
        :request_fun,
        Application.get_env(:symphony_elixir, :linear_client_request_fun, &post_graphql_request/2)
      )

    with :ok <- CommentActionGuard.check(payload) do
      graphql_response(authenticated_request(payload, request_fun), payload)
    end
  end

  defp graphql_response(result, payload) do
    case result do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, response} ->
        diagnostics = http_error_diagnostics(response)
        status = Map.get(diagnostics, :status)

        Logger.error(
          "Linear GraphQL request failed status=#{status}" <>
            linear_error_context(payload, diagnostics)
        )

        {:error, {:linear_api_status, status, diagnostics}}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  defp authenticated_request(payload, request_fun) do
    AppAuth.request(Config.settings!().tracker, payload, request_fun, context: WriteContext.current())
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec http_error_diagnostics_for_test(map()) :: map()
  def http_error_diagnostics_for_test(response) when is_map(response), do: http_error_diagnostics(response)

  @doc false
  @spec candidate_query_for_test(String.t() | nil) :: String.t()
  def candidate_query_for_test(assignee) when is_binary(assignee) or is_nil(assignee) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    candidate_query({:project, "test"}, assignee_filter)
  end

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_states(ids, {:project, "test"}, nil, graphql_fun)
    end
  end

  defp do_fetch_by_states(scope, state_names, assignee_filter) do
    do_fetch_by_states_page(scope, state_names, assignee_filter, nil, [])
  end

  defp candidate_state_names(state_names) when is_list(state_names) do
    state_names
    |> Kernel.++(extra_candidate_state_names())
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extra_candidate_state_names do
    dialog_state_names =
      [Dialog.state_name()]

    [@manual_in_progress_state_name | @manual_approval_state_names] ++ dialog_state_names
  end

  defp do_fetch_by_states_page(scope, state_names, assignee_filter, after_cursor, acc_issues) do
    variables =
      scope
      |> scope_query_variables()
      |> Map.merge(%{
        stateNames: state_names,
        first: @issue_page_size,
        relationFirst: @issue_page_size,
        after: after_cursor
      })

    with {:ok, body} <-
           graphql(candidate_query(scope, assignee_filter), variables),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(scope, state_names, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp fetch_issue_comments_page(issue_id, after_cursor, acc_comments, seen) do
    case graphql(@issue_comments_query, %{id: issue_id, first: @issue_page_size, after: after_cursor}) do
      {:ok, response} ->
        observed = acc_comments ++ observed_comments(response, issue_id)
        continue_comment_page(response, issue_id, observed, seen)

      {:error, reason} ->
        incomplete_comments(reason, acc_comments)
    end
  end

  defp continue_comment_page(response, issue_id, observed, seen) do
    with {:ok, comments, page_info} <- decode_issue_comments_page_response(response),
         true <- Enum.all?(comments, &(&1.issue_id in [nil, issue_id])) do
      continue_comments(next_page_cursor(page_info), issue_id, observed, seen)
    else
      {:error, reason} -> incomplete_comments(reason, observed)
      false -> incomplete_comments(:linear_comment_issue_mismatch, observed)
    end
  end

  defp observed_comments(%{"data" => %{"issue" => %{"comments" => %{"nodes" => nodes}}}}, issue_id) when is_list(nodes) do
    Enum.flat_map(nodes, fn node ->
      case CommentVersion.normalize(node) do
        {:ok, %{issue_id: id} = comment} when id in [nil, issue_id] -> [comment]
        _ -> []
      end
    end)
  end

  defp observed_comments(_response, _issue_id), do: []

  defp continue_comments({:ok, cursor}, issue_id, comments, seen) do
    if Map.has_key?(seen, cursor),
      do: incomplete_comments(:linear_invalid_page_cursor, comments),
      else: fetch_issue_comments_page(issue_id, cursor, comments, Map.put(seen, cursor, true))
  end

  defp continue_comments(:done, _issue_id, comments, _seen), do: {:ok, Enum.uniq_by(comments, &CommentVersion.key/1)}
  defp continue_comments({:error, reason}, _issue_id, comments, _seen), do: incomplete_comments(reason, comments)

  defp incomplete_comments(reason, []), do: {:error, reason}
  defp incomplete_comments(reason, comments), do: {:error, {:comment_scan_incomplete, reason, Enum.uniq_by(comments, &CommentVersion.key/1)}}

  @doc "A complete issue scan plus a direct missing entity response is required to mark deletion."
  @spec confirm_comment_absence(String.t(), String.t()) :: :deleted | {:present, map()} | {:error, term()}
  def confirm_comment_absence(issue_id, comment_id) do
    with {:ok, issue} <- graphql("query($id: String!) { issue(id: $id) { id } }", %{id: issue_id}),
         true <- Map.get(issue, "errors", []) in [nil, []],
         ^issue_id <- get_in(issue, ["data", "issue", "id"]),
         {:ok, body} <- graphql("query($id: String!) { comment(id: $id) { id } }", %{id: comment_id}) do
      absent_comment_result(body, comment_id)
    else
      {:error, _} = error -> error
      _ -> {:error, :comment_absence_unverified}
    end
  end

  defp absent_comment_result(body, id) do
    errors = Map.get(body, "errors", []) || []

    case get_in(body, ["data", "comment"]) do
      %{"id" => ^id} = comment when errors == [] ->
        {:present, comment}

      nil ->
        if errors != [] and Enum.all?(errors, &missing_comment_error?/1),
          do: :deleted,
          else: {:error, :comment_absence_unverified}

      _ ->
        {:error, :comment_absence_unverified}
    end
  end

  defp missing_comment_error?(error) do
    error["path"] == ["comment"] and error["message"] == "Entity not found: Comment" and
      get_in(error, ["extensions", "code"]) == "INPUT_ERROR"
  end

  defp do_fetch_issue_states(ids, scope, assignee_filter) do
    do_fetch_issue_states(ids, scope, assignee_filter, &graphql/2)
  end

  defp do_fetch_issue_states(ids, scope, assignee_filter, graphql_fun)
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, scope, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _scope, _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, scope, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    variables =
      scope
      |> issue_states_query_variables()
      |> Map.merge(%{
        ids: batch_ids,
        first: length(batch_ids),
        relationFirst: @issue_page_size
      })

    case graphql_fun.(issue_states_query(scope), variables) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response(body, assignee_filter) do
          updated_acc = prepend_page_issues(issues, acc_issues)

          do_fetch_issue_states_page(
            rest_ids,
            scope,
            assignee_filter,
            graphql_fun,
            updated_acc,
            issue_order_index
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, diagnostics) when is_map(payload) and is_map(diagnostics) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body = Map.get(diagnostics, :body_excerpt, "")

    operation_name <>
      " body=" <>
      body <>
      diagnostic_log_part(" classification", Map.get(diagnostics, :classification)) <>
      diagnostic_log_part(" errorCodes", Map.get(diagnostics, :extensions_codes)) <>
      diagnostic_log_part(" rateLimit", Map.get(diagnostics, :rate_limit))
  end

  defp http_error_diagnostics(response) when is_map(response) do
    status = response_status(response)
    body = response_body(response)
    decoded_body = decode_error_body(body)
    errors = graphql_errors(decoded_body)
    extensions_codes = graphql_extension_codes(errors)
    rate_limit = rate_limit_hints(status, response_headers(response), extensions_codes)

    %{
      status: status,
      body_excerpt: summarize_error_body(body),
      errors: errors,
      extensions_codes: extensions_codes,
      rate_limit: rate_limit,
      classification: classify_http_error(status, errors, extensions_codes, rate_limit)
    }
  end

  defp response_status(response) when is_map(response) do
    Map.get(response, :status) || Map.get(response, "status")
  end

  defp response_body(response) when is_map(response) do
    Map.get(response, :body) || Map.get(response, "body")
  end

  defp response_headers(response) when is_map(response) do
    response
    |> Map.get(:headers, Map.get(response, "headers", []))
    |> normalize_headers()
  end

  defp normalize_headers(headers) when is_map(headers) do
    Enum.reduce(headers, %{}, fn {key, value}, acc ->
      Map.put(acc, normalize_header_name(key), normalize_header_value(value))
    end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.reduce(headers, %{}, fn
      {key, value}, acc -> Map.put(acc, normalize_header_name(key), normalize_header_value(value))
      _other, acc -> acc
    end)
  end

  defp normalize_headers(_headers), do: %{}

  defp normalize_header_name(key) do
    key
    |> to_string()
    |> String.downcase()
  end

  defp normalize_header_value(values) when is_list(values) do
    Enum.map_join(values, ", ", &to_string/1)
  end

  defp normalize_header_value(value), do: to_string(value)

  defp decode_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp decode_error_body(body), do: body

  defp graphql_errors(%{"errors" => errors}) when is_list(errors), do: Enum.map(errors, &sanitize_graphql_error/1)
  defp graphql_errors(%{errors: errors}) when is_list(errors), do: Enum.map(errors, &sanitize_graphql_error/1)
  defp graphql_errors(_body), do: []

  defp sanitize_graphql_error(error) when is_map(error) do
    error
    |> stringify_keys()
    |> Map.take(["message", "extensions", "locations", "path"])
    |> truncate_graphql_error_message()
  end

  defp sanitize_graphql_error(error), do: %{"message" => inspect(error)}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(values) when is_list(values), do: Enum.map(values, &stringify_value/1)
  defp stringify_value(value), do: value

  defp truncate_graphql_error_message(%{"message" => message} = error) when is_binary(message) do
    Map.put(error, "message", truncate_error_body(message))
  end

  defp truncate_graphql_error_message(error), do: error

  defp graphql_extension_codes(errors) when is_list(errors) do
    errors
    |> Enum.flat_map(fn
      %{"extensions" => %{"code" => code}} when is_binary(code) -> [code]
      _error -> []
    end)
    |> Enum.uniq()
  end

  defp rate_limit_hints(status, headers, extensions_codes)
       when is_map(headers) and is_list(extensions_codes) do
    header_hints =
      headers
      |> Enum.filter(fn {key, value} -> rate_limit_header?(key) and value != "" end)
      |> Map.new()

    limited? =
      status == 429 or Enum.member?(extensions_codes, "RATELIMITED") or
        (status == 403 and rate_limit_headers_limited?(header_hints))

    cond do
      limited? -> Map.put(header_hints, "limited", true)
      header_hints != %{} -> header_hints
      true -> %{}
    end
  end

  defp classify_http_error(status, errors, extensions_codes, rate_limit) do
    cond do
      Map.get(rate_limit, "limited") == true -> "rate_limited"
      status in [401, 403] or auth_error_code?(extensions_codes) -> "auth"
      status == 400 or errors != [] -> "graphql"
      true -> "http"
    end
  end

  defp auth_error_code?(extensions_codes) when is_list(extensions_codes) do
    Enum.any?(extensions_codes, &(&1 in ["AUTHENTICATION_ERROR", "FORBIDDEN", "UNAUTHENTICATED"]))
  end

  defp rate_limit_header?(header_name) when is_binary(header_name) do
    header_name == "retry-after" or String.contains?(header_name, ["ratelimit", "rate-limit"])
  end

  defp rate_limit_headers_limited?(header_hints) when is_map(header_hints) do
    retry_after? = Map.has_key?(header_hints, "retry-after")

    remaining_exhausted? =
      Enum.any?(header_hints, fn {header_name, value} ->
        String.ends_with?(header_name, "-remaining") and
          value
          |> to_string()
          |> String.trim()
          |> then(&Regex.match?(~r/\A0(?:\.0+)?\z/, &1))
      end)

    retry_after? or remaining_exhausted?
  end

  defp diagnostic_log_part(_label, value) when value in [nil, "", [], %{}], do: ""
  defp diagnostic_log_part(label, value), do: label <> "=" <> inspect(value)

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.settings!().tracker.endpoint,
      headers: headers,
      json: payload,
      redirect: false,
      retry: false,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       ) do
    with {:ok, issues} <- decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter), do: decode_linear_response(response, assignee_filter)

  defp decode_issue_comments_page_response(%{"errors" => errors}) when is_list(errors) and errors != [] do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_issue_comments_page_response(%{
         "data" => %{
           "issue" => %{
             "comments" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         }
       })
       when is_list(nodes) and is_boolean(has_next_page) do
    with {:ok, comments} <- normalize_comments(nodes) do
      {:ok, comments, %{has_next_page: has_next_page, end_cursor: end_cursor}}
    end
  end

  defp decode_issue_comments_page_response(_unknown), do: {:error, :linear_unknown_payload}

  defp normalize_comments(nodes) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, acc} ->
      case CommentVersion.normalize(node) do
        {:ok, comment} -> {:cont, {:ok, acc ++ [comment]}}
        error -> {:halt, error}
      end
    end)
  end

  defp first_issue([%Issue{} = issue | _rest], _identifier), do: {:ok, issue}
  defp first_issue([], identifier), do: {:error, {:issue_not_found, identifier}}

  defp split_issue_identifier(identifier) when is_binary(identifier) do
    case Regex.named_captures(~r/\A(?<team_key>[A-Za-z0-9]+)-(?<issue_number>\d+)\z/, identifier) do
      %{"team_key" => team_key, "issue_number" => issue_number} ->
        {:ok, String.upcase(team_key), String.to_integer(issue_number)}

      _ ->
        {:error, {:invalid_issue_identifier, identifier}}
    end
  end

  defp validate_identifier_scope({:project, _project_slug}, _identifier, _identifier_team_key), do: :ok

  defp validate_identifier_scope({:team, team_key}, _identifier, team_key), do: :ok

  defp validate_identifier_scope({:team, team_key}, identifier, _identifier_team_key) do
    {:error, {:issue_outside_team_scope, identifier, team_key}}
  end

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]
    context = ProjectContext.current()

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      project_context_id: context && context.id,
      project_name: context && context.name,
      workspace_id: context && context.settings.tracker.app["workspace_id"],
      last_comment_signal: extract_last_comment_signal(issue),
      blocked_by: extract_blockers(issue),
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter) and issue_in_context?(issue, context),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp issue_in_context?(_issue, nil), do: true

  defp issue_in_context?(issue, context) do
    case Config.linear_scope(context.settings.tracker) do
      {:ok, {:project, slug}} -> get_in(issue, ["project", "slugId"]) == slug
      {:ok, {:team, key}} -> get_in(issue, ["team", "key"]) == key
    end
  end

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{"app" => true}, _filter), do: false

  defp assigned_to_worker?(assignee, %{mode: :any, filters: filters}) do
    Enum.any?(filters, &assigned_to_worker?(assignee, &1))
  end

  defp assigned_to_worker?(%{} = assignee, %{mode: :id, value: value}) when is_binary(value) do
    assignee_id(assignee) == value
  end

  defp assigned_to_worker?(%{} = assignee, %{mode: :email, value: value}) when is_binary(value) do
    assignee_email(assignee) == value
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp assignee_email(%{} = assignee), do: normalize_assignee_email_value(assignee["email"])

  defp routing_assignee_filter do
    if Config.yolo?() do
      {:ok, nil}
    else
      case Config.settings!().tracker.assignee do
        nil ->
          {:ok, nil}

        assignee ->
          build_assignee_filter(assignee)
      end
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case Assignees.parse(assignee) do
      [] ->
        {:ok, nil}

      [single] ->
        build_single_assignee_filter(single)

      values ->
        filters = Enum.map(values, &%{configured_assignee: &1, mode: assignee_filter_mode(&1), value: &1})
        if "me" in values, do: {:error, :linear_app_requires_human_assignee}, else: {:ok, %{mode: :any, filters: filters}}
    end
  end

  defp build_single_assignee_filter(assignee) do
    case normalize_assignee_config_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        {:error, :linear_app_requires_human_assignee}

      normalized ->
        {:ok, %{configured_assignee: assignee, mode: assignee_filter_mode(normalized), value: normalized}}
    end
  end

  defp assignee_filter_mode(value) when is_binary(value) do
    if String.contains?(value, "@"), do: :email, else: :id
  end

  defp candidate_query({:project, _project_slug}, assignee_filter) do
    """
    query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
      issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}#{candidate_query_assignee_filter(assignee_filter)}}, first: $first, after: $after) {
        nodes {
          #{@issue_selection}
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
    """
  end

  defp candidate_query({:team, _team_key}, assignee_filter) do
    """
    query SymphonyLinearTeamPoll($teamKey: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
      issues(filter: {team: {key: {eq: $teamKey}}, state: {name: {in: $stateNames}}#{candidate_query_assignee_filter(assignee_filter)}}, first: $first, after: $after) {
        nodes {
          #{@issue_selection}
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
    """
  end

  defp scope_query_variables({:project, project_slug}), do: %{projectSlug: project_slug}
  defp scope_query_variables({:team, team_key}), do: %{teamKey: team_key}

  defp issue_states_query({:project, _project_slug}), do: @query_by_ids
  defp issue_states_query({:team, _team_key}), do: @query_by_ids_in_team

  defp issue_states_query_variables({:project, _project_slug}), do: %{}
  defp issue_states_query_variables({:team, team_key}), do: %{teamKey: team_key}

  defp candidate_query_assignee_filter(nil), do: ""

  defp candidate_query_assignee_filter(%{mode: :any, filters: filters}) do
    branches =
      Enum.map_join(filters, ", ", fn filter ->
        field = if filter.mode == :email, do: "email: {eqIgnoreCase: #{Jason.encode!(filter.value)}}", else: "id: {eq: #{Jason.encode!(filter.value)}}"
        "{#{field}}"
      end)

    ", assignee: {or: [#{branches}]}"
  end

  defp candidate_query_assignee_filter(%{mode: :id, value: value}) when is_binary(value) do
    ", assignee: {id: {eq: #{graphql_string_literal(value)}}}"
  end

  defp candidate_query_assignee_filter(%{mode: :email, value: value}) when is_binary(value) do
    ", assignee: {email: {eqIgnoreCase: #{graphql_string_literal(value)}}}"
  end

  defp graphql_string_literal(value) when is_binary(value), do: Jason.encode!(value)

  defp normalize_assignee_config_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      "me" -> "me"
      normalized -> normalize_assignee_identifier(normalized)
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    normalize_assignee_identifier(value)
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp normalize_assignee_email_value(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_email_value(_value), do: nil

  defp normalize_assignee_identifier(value) when is_binary(value) do
    normalized = String.trim(value)

    cond do
      normalized == "" ->
        nil

      String.contains?(normalized, "@") ->
        normalize_assignee_email_value(normalized)

      true ->
        normalized
    end
  end

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp extract_last_comment_signal(%{"comments" => %{"nodes" => comments}}) when is_list(comments) do
    comments
    |> Enum.map(&normalize_comment_signal/1)
    |> Enum.reject(&is_nil/1)
    |> latest_comment_signal()
  end

  defp extract_last_comment_signal(_issue), do: nil

  defp latest_comment_signal([]), do: nil

  defp latest_comment_signal(signals) when is_list(signals) do
    if Enum.all?(signals, &(match?(%DateTime{}, &1.updated_at) or match?(%DateTime{}, &1.created_at))) do
      Enum.max_by(signals, &comment_signal_timestamp_sort_key/1)
    else
      List.first(signals)
    end
  end

  defp comment_signal_timestamp_sort_key(%{updated_at: %DateTime{} = updated_at}) do
    DateTime.to_unix(updated_at, :microsecond)
  end

  defp comment_signal_timestamp_sort_key(%{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp normalize_comment_signal(comment) when is_map(comment) do
    signal = %{
      id: normalize_comment_id(comment["id"]),
      created_at: parse_datetime(comment["createdAt"]),
      updated_at: parse_datetime(comment["updatedAt"])
    }

    if Enum.any?(signal, fn {_key, value} -> not is_nil(value) end), do: signal
  end

  defp normalize_comment_signal(_comment), do: nil

  defp normalize_comment_id(id) when is_binary(id) do
    case String.trim(id) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_comment_id(_id), do: nil

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
