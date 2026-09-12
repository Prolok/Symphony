defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          projects: Map.get(snapshot, :projects, []),
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found | :ambiguous_issue_identifier}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        project_issue_payload(snapshot, issue_identifier)

      _ ->
        {:error, :issue_not_found}
    end
  end

  defp project_issue_payload(snapshot, reference) do
    identities =
      (snapshot.running ++ snapshot.retrying)
      |> Enum.filter(&matches_reference?(&1, split_reference(reference)))
      |> Enum.uniq_by(&entry_identity/1)

    case identities do
      [] ->
        {:error, :issue_not_found}

      [entry] ->
        running = Enum.find(snapshot.running, &(entry_identity(&1) == entry_identity(entry)))
        retry = Enum.find(snapshot.retrying, &(entry_identity(&1) == entry_identity(entry)))
        {:ok, issue_payload_body(reference, running, retry)}

      _ ->
        {:error, :ambiguous_issue_identifier}
    end
  end

  defp entry_identity(entry), do: {Map.get(entry, :project_root), entry.issue_id}

  defp matches_reference?(entry, {project, identifier}) do
    entry.identifier == identifier and
      (is_nil(project) or project in [Map.get(entry, :project), Map.get(entry, :project_root)])
  end

  defp split_reference(reference) do
    case String.split(reference, ":", parts: 2) do
      [identifier] -> {nil, identifier}
      [project, identifier] -> {project, identifier}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: recent_events_payload(running)
      },
      recent_events: recent_events_payload(running),
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      project: Map.get(entry, :project),
      issue_reference: issue_reference(entry),
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp issue_reference(entry) do
    case Map.get(entry, :project_qualifier, Map.get(entry, :project)) do
      nil -> entry.identifier
      project -> project <> ":" <> entry.identifier
    end
  end

  defp retry_entry_payload(entry) do
    %{
      project: Map.get(entry, :project),
      issue_reference: issue_reference(entry),
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(running) do
    running
    |> Map.get(:recent_codex_events, [])
    |> case do
      [] -> fallback_recent_event(running)
      events -> events
    end
    |> Enum.map(&recent_event_payload(&1, running))
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp fallback_recent_event(running) do
    case running.last_codex_message do
      nil ->
        []

      message ->
        [
          %{
            event: running.last_codex_event,
            message: message,
            session_id: running.session_id,
            timestamp: running.last_codex_timestamp
          }
        ]
    end
  end

  defp recent_event_payload(event, running) do
    event
    |> recent_event_base_payload(running)
    |> maybe_put(:sequence, Map.get(event, :sequence) || Map.get(event, "sequence"))
  end

  defp recent_event_base_payload(event, running) do
    %{
      at: iso8601(Map.get(event, :timestamp) || Map.get(event, "timestamp")),
      event: event_name(Map.get(event, :event) || Map.get(event, "event")),
      session_id: Map.get(event, :session_id) || Map.get(event, "session_id") || running.session_id,
      message: summarize_message(Map.get(event, :message) || Map.get(event, "message"))
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp event_name(event) when is_atom(event), do: Atom.to_string(event)
  defp event_name(event) when is_binary(event), do: event
  defp event_name(_event), do: nil

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
