defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Linear.Client, Workpad}

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment { id body updatedAt user { id } issue { id } }
    }
  }
  """

  @update_comment_mutation """
  mutation SymphonyUpdateComment($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body}) {
      success
      comment {
        id
        body
        updatedAt
        user { id }
        issue { id }
      }
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @update_branch_name_mutation """
  mutation SymphonyUpdateIssueBranchName($issueId: String!, $branchName: String!) {
    issueUpdate(id: $issueId, input: {branchName: $branchName}) {
      success
    }
  }
  """

  @issue_update_input_fields_query """
  query SymphonyIssueUpdateInputFields {
    __type(name: "IssueUpdateInput") {
      inputFields {
        name
      }
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec fetch_issue_by_identifier(String.t()) :: {:ok, term()} | {:error, term()}
  def fetch_issue_by_identifier(identifier) when is_binary(identifier) do
    client_module().fetch_issue_by_identifier(identifier)
  end

  @spec fetch_issue_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_issue_comments(issue_id) when is_binary(issue_id) do
    client_module().fetch_issue_comments(issue_id)
  end

  @spec fetch_issue_comment_bodies(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def fetch_issue_comment_bodies(issue_id) when is_binary(issue_id) do
    client_module().fetch_issue_comment_bodies(issue_id)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(comment_id, body) when is_binary(comment_id) and is_binary(body) do
    with {:ok, response} <-
           client_module().graphql(@update_comment_mutation, %{commentId: comment_id, body: body}),
         true <- get_in(response, ["data", "commentUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_update_failed}
    end
  end

  @spec workpad_exists?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def workpad_exists?(issue_id) when is_binary(issue_id) do
    with {:ok, comments} <- client_module().fetch_issue_comment_bodies(issue_id) do
      {:ok, Enum.any?(comments, &Workpad.comment_matches?/1)}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec update_issue_branch_name(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_branch_name(issue_id, branch_name)
      when is_binary(issue_id) and is_binary(branch_name) do
    if branch_name_update_supported?() do
      with {:ok, response} <-
             client_module().graphql(@update_branch_name_mutation, %{
               issueId: issue_id,
               branchName: branch_name
             }),
           true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
        :ok
      else
        false -> {:error, :issue_branch_name_update_failed}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :issue_branch_name_update_failed}
      end
    else
      :ok
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp branch_name_update_supported? do
    cache_key = {__MODULE__, :branch_name_update_supported}

    case Process.get(cache_key) do
      value when is_boolean(value) ->
        value

      _ ->
        supported? =
          case client_module().graphql(@issue_update_input_fields_query, %{}) do
            {:ok, response} ->
              response
              |> get_in(["data", "__type", "inputFields"])
              |> List.wrap()
              |> Enum.any?(&match?(%{"name" => "branchName"}, &1))

            _ ->
              false
          end

        Process.put(cache_key, supported?)
        supported?
    end
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
end
