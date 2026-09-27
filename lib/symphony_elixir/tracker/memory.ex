defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Linear.Issue, Workpad}

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, issue_entries()}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    send_event({:memory_tracker_fetch_issue_states, issue_ids})

    case Application.get_env(:symphony_elixir, :memory_tracker_state_error) do
      nil ->
        wanted_ids = MapSet.new(issue_ids)

        {:ok,
         Enum.filter(issue_entries(), fn %Issue{id: id} ->
           MapSet.member?(wanted_ids, id)
         end)}

      reason ->
        {:error, reason}
    end
  end

  @spec fetch_issue_state_history(String.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_issue_state_history(issue_id) when is_binary(issue_id) do
    send_event({:memory_tracker_fetch_issue_state_history, issue_id})
    {:ok, Application.get_env(:symphony_elixir, :memory_tracker_state_history, %{}) |> Map.get(issue_id, [])}
  end

  @spec fetch_issue_by_identifier(String.t()) :: {:ok, Issue.t()} | {:error, term()}
  def fetch_issue_by_identifier(identifier) when is_binary(identifier) do
    normalized_identifier = String.trim(identifier)

    case Enum.find(issue_entries(), &(&1.identifier == normalized_identifier)) do
      %Issue{} = issue -> {:ok, issue}
      nil -> {:error, {:issue_not_found, normalized_identifier}}
    end
  end

  @spec fetch_issue_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_issue_comments(issue_id) when is_binary(issue_id) do
    send_event({:memory_tracker_fetch_issue_comments, issue_id})
    {:ok, configured_comments() |> Map.get(issue_id, []) |> Enum.map(&normalize_comment/1)}
  end

  @spec fetch_issue_comment_bodies(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def fetch_issue_comment_bodies(issue_id) when is_binary(issue_id) do
    with {:ok, comments} <- fetch_issue_comments(issue_id) do
      {:ok, Enum.map(comments, & &1.body)}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    store_comment(issue_id, body)
    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  @spec update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(comment_id, body) when is_binary(comment_id) and is_binary(body) do
    {comments, updated_issue_id} =
      configured_comments()
      |> Enum.map_reduce(nil, fn {issue_id, issue_comments}, updated_issue_id ->
        {updated_comments, updated?} = update_comment_entries(issue_comments, comment_id, body)
        {{issue_id, updated_comments}, updated_issue_id || if(updated?, do: issue_id)}
      end)

    case updated_issue_id do
      nil ->
        {:error, :comment_not_found}

      issue_id ->
        Application.put_env(:symphony_elixir, :memory_tracker_comments, Map.new(comments))
        send_event({:memory_tracker_comment_update, issue_id, comment_id, body})
        :ok
    end
  end

  @spec workpad_exists?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def workpad_exists?(issue_id) do
    {:ok, has_workpad_comment?(issue_id)}
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  @spec update_issue_branch_name(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_branch_name(issue_id, branch_name) do
    send_event({:memory_tracker_branch_update, issue_id, branch_name})
    :ok
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp configured_comments do
    Application.get_env(:symphony_elixir, :memory_tracker_comments, %{})
  end

  defp issue_entries do
    configured_issues()
    |> Enum.filter(&match?(%Issue{}, &1))
    |> Enum.map(&maybe_put_last_comment_signal/1)
  end

  defp has_workpad_comment?(issue_id) when is_binary(issue_id) do
    configured_comments()
    |> Map.get(issue_id, [])
    |> Enum.any?(&(&1 |> normalize_comment() |> Map.get(:body) |> Workpad.comment_matches?()))
  end

  defp store_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    now = DateTime.utc_now()
    comment = %{id: new_comment_id(), body: body, created_at: now, updated_at: now}

    comments =
      configured_comments()
      |> Map.update(issue_id, [comment], &prepend_comment(&1, comment))

    Application.put_env(:symphony_elixir, :memory_tracker_comments, comments)
    :ok
  end

  defp prepend_comment(comments, comment) when is_list(comments), do: [comment | comments]
  defp prepend_comment(_comments, comment), do: [comment]

  defp new_comment_id do
    "memory-comment-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp update_comment_entries(comments, comment_id, body) when is_list(comments) do
    Enum.map_reduce(comments, false, fn comment, updated? ->
      case update_comment_entry(comment, comment_id, body) do
        {:ok, updated_comment} -> {updated_comment, true}
        :skip -> {comment, updated?}
      end
    end)
  end

  defp update_comment_entries(_comments, _comment_id, _body), do: {[], false}

  defp update_comment_entry(comment, comment_id, body) do
    normalized = normalize_comment(comment)

    if Map.get(normalized, :id) == comment_id do
      {:ok,
       normalized
       |> Map.put(:body, body)
       |> Map.put(:updated_at, DateTime.utc_now())}
    else
      :skip
    end
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp normalize_comment(%{body: body} = comment) when is_binary(body) do
    Map.take(comment, [:id, :body, :created_at, :updated_at])
  end

  defp normalize_comment(%{"body" => body} = comment) when is_binary(body) do
    %{
      id: comment["id"],
      body: body,
      created_at: comment["created_at"] || comment["createdAt"],
      updated_at: comment["updated_at"] || comment["updatedAt"]
    }
  end

  defp normalize_comment(body) when is_binary(body), do: %{body: body}
  defp normalize_comment(_comment), do: %{body: ""}

  defp maybe_put_last_comment_signal(%Issue{last_comment_signal: signal} = issue)
       when not is_nil(signal),
       do: issue

  defp maybe_put_last_comment_signal(%Issue{id: issue_id} = issue) when is_binary(issue_id) do
    %{issue | last_comment_signal: last_comment_signal(issue_id)}
  end

  defp maybe_put_last_comment_signal(%Issue{} = issue), do: issue

  defp last_comment_signal(issue_id) when is_binary(issue_id) do
    configured_comments()
    |> Map.get(issue_id, [])
    |> Enum.map(&normalize_comment/1)
    |> Enum.map(&comment_signal/1)
    |> Enum.reject(&is_nil/1)
    |> latest_comment_signal()
  end

  defp comment_signal(comment) when is_map(comment) do
    signal = %{
      id: normalize_comment_id(Map.get(comment, :id)),
      created_at: parse_datetime(Map.get(comment, :created_at)),
      updated_at: parse_datetime(Map.get(comment, :updated_at))
    }

    if Enum.any?(signal, fn {_key, value} -> not is_nil(value) end), do: signal
  end

  defp latest_comment_signal([]), do: nil

  defp latest_comment_signal(signals) when is_list(signals) do
    if Enum.all?(signals, &(match?(%DateTime{}, &1.updated_at) or match?(%DateTime{}, &1.created_at))) do
      Enum.max_by(signals, &comment_signal_timestamp_sort_key/1)
    else
      List.last(signals)
    end
  end

  defp comment_signal_timestamp_sort_key(%{updated_at: %DateTime{} = updated_at}) do
    DateTime.to_unix(updated_at, :microsecond)
  end

  defp comment_signal_timestamp_sort_key(%{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp normalize_comment_id(id) when is_binary(id) do
    case String.trim(id) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_comment_id(_id), do: nil

  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
