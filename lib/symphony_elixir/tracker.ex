defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.{Config, ProjectContext, ProjectPoller}

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_by_identifier(String.t()) :: {:ok, term()} | {:error, term()}
  @callback fetch_issue_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_issue_comment_bodies(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback workpad_exists?(String.t()) :: {:ok, boolean()} | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_branch_name(String.t(), String.t()) :: :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    case {ProjectContext.current(), Process.whereis(ProjectPoller)} do
      {%SymphonyElixir.ProjectContext{} = context, pid} when is_pid(pid) -> ProjectPoller.candidates(context)
      _ -> adapter().fetch_candidate_issues()
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec fetch_issue_by_identifier(String.t()) :: {:ok, term()} | {:error, term()}
  def fetch_issue_by_identifier(identifier) when is_binary(identifier) do
    adapter().fetch_issue_by_identifier(identifier)
  end

  @spec fetch_issue_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_issue_comments(issue_id) when is_binary(issue_id) do
    adapter().fetch_issue_comments(issue_id)
  end

  @spec fetch_issue_comment_bodies(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def fetch_issue_comment_bodies(issue_id) when is_binary(issue_id) do
    adapter().fetch_issue_comment_bodies(issue_id)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(comment_id, body) do
    adapter().update_comment(comment_id, body)
  end

  @spec workpad_exists?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def workpad_exists?(issue_id) do
    adapter().workpad_exists?(issue_id)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec update_issue_branch_name(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_branch_name(issue_id, branch_name) do
    adapter().update_issue_branch_name(issue_id, branch_name)
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      _ -> SymphonyElixir.Linear.Adapter
    end
  end
end
