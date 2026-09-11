defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.Linear.AppAuth
  alias SymphonyElixir.Linear.WriteContext

  alias SymphonyElixir.{Config, Dialog, Linear.Issue}

  @issue_page_size 50
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
  }
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

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
      email
    }
  }
  """

  @issue_comments_query """
  query SymphonyLinearIssueComments($id: String!, $first: Int!, $after: String) {
    issue(id: $id) {
      comments(first: $first, after: $after, includeArchived: true) {
        nodes {
          id
          body
          user { id }
          issue { id }
          createdAt
          updatedAt
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

    if missing_legacy_token?(tracker) do
      {:error, :missing_linear_api_token}
    else
      with {:ok, scope} <- Config.linear_scope(tracker),
           {:ok, assignee_filter} <- routing_assignee_filter(),
           {:ok, issues} <- do_fetch_by_states(scope, candidate_state_names(tracker.active_states), assignee_filter),
           :ok <- validate_candidate_scope(tracker, issues) do
        {:ok, issues}
      end
    end
  end

  @spec validate_candidate_scope(map(), [Issue.t()]) :: :ok | {:error, term()}
  def validate_candidate_scope(%{auth_mode: "app", app: %{"allowed_issue_ids" => ids}}, issues) when is_list(ids) do
    if Enum.all?(issues, &(&1.id in ids)), do: :ok, else: {:error, :linear_app_candidate_scope_changed}
  end

  def validate_candidate_scope(_tracker, _issues), do: :ok

  @spec resolve_legacy_assignee() :: {:ok, String.t()} | {:error, term()}
  def resolve_legacy_assignee do
    if Config.settings!().tracker.auth_mode == "legacy" do
      with {:ok, %{"data" => %{"viewer" => %{"id" => id}}} = body} <- graphql(@viewer_query),
           true <- Map.get(body, "errors", []) in [nil, []] do
        {:ok, id}
      else
        _ -> {:error, :linear_assignee_resolution_failed}
      end
    else
      {:error, :linear_assignee_requires_legacy_identity}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    case normalized_states do
      [] -> {:ok, []}
      states -> fetch_issues_by_states(Config.settings!().tracker, states)
    end
  end

  defp fetch_issues_by_states(%{auth_mode: "legacy", api_key: nil}, _state_names), do: {:error, :missing_linear_api_token}

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

    cond do
      missing_legacy_token?(tracker) ->
        {:error, :missing_linear_api_token}

      normalized_identifier == "" ->
        {:error, :missing_issue_identifier}

      true ->
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
    fetch_issue_comments_page(issue_id, nil, [])
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

    case authenticated_request(payload, request_fun) do
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
    case Config.settings!().tracker do
      %{auth_mode: "app"} = tracker ->
        AppAuth.request(tracker, payload, request_fun, context: WriteContext.current())

      _tracker ->
        with {:ok, headers} <- graphql_headers(), do: request_fun.(payload, headers)
    end
  end

  defp missing_legacy_token?(tracker), do: tracker.auth_mode == "legacy" and is_nil(tracker.api_key)

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

  defp fetch_issue_comments_page(issue_id, after_cursor, acc_comments) do
    with {:ok, response} <-
           graphql(@issue_comments_query, %{id: issue_id, first: @issue_page_size, after: after_cursor}),
         {:ok, comments, page_info} <- decode_issue_comments_page_response(response) do
      issue_comment_page_result(issue_id, comments, page_info, acc_comments)
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_comment_page_result(issue_id, comments, page_info, acc_comments) do
    updated_acc = prepend_page_issues(comments, acc_comments)

    case next_page_cursor(page_info) do
      {:ok, next_cursor} ->
        fetch_issue_comments_page(issue_id, next_cursor, updated_acc)

      :done ->
        {:ok, finalize_paginated_issues(updated_acc)}

      {:error, reason} ->
        {:error, reason}
    end
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

  defp graphql_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.settings!().tracker.endpoint,
      headers: headers,
      json: payload,
      redirect: Config.settings!().tracker.auth_mode != "app",
      retry: if(Config.settings!().tracker.auth_mode == "app", do: false, else: :safe_transient),
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

  defp decode_issue_comments_page_response(%{
         "data" => %{
           "issue" => %{
             "comments" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         }
       }) do
    {:ok, extract_comments(nodes), %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
  end

  defp decode_issue_comments_page_response(%{"errors" => errors}) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_issue_comments_page_response(_unknown) do
    {:error, :linear_unknown_payload}
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
    {:error, "Linear issue #{identifier} is outside configured team scope #{team_key}"}
  end

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]

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
      last_comment_signal: extract_last_comment_signal(issue),
      blocked_by: extract_blockers(issue),
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

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
    case normalize_assignee_config_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, mode: assignee_filter_mode(normalized), value: normalized}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", mode: :id, value: viewer_id}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
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

  defp extract_comments(comments) when is_list(comments) do
    comments
    |> Enum.map(&normalize_comment/1)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_comments(_), do: []

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

  defp normalize_comment(%{"body" => body} = comment) when is_binary(body) do
    %{
      id: comment["id"],
      body: body,
      user_id: get_in(comment, ["user", "id"]),
      issue_id: get_in(comment, ["issue", "id"]),
      created_at: parse_datetime(comment["createdAt"]),
      updated_at: parse_datetime(comment["updatedAt"])
    }
  end

  defp normalize_comment(_comment), do: nil

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
