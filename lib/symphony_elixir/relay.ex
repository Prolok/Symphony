defmodule SymphonyElixir.Relay do
  @moduledoc "Workspace relay integration; explicit critical actions continue to use Linear directly."
  alias SymphonyElixir.{Config, ProjectContext, ProjectPoller, Tracker}
  alias SymphonyElixir.Linear.{Assignees, Client}
  alias SymphonyElixir.Relay.{Session, Store}

  @spec open([ProjectContext.t()]) :: {:ok, Session.t()} | {:error, term()}
  def open([first | _] = contexts) do
    relay = first.settings.tracker.relay
    app = first.settings.tracker.app

    with :ok <- SymphonyElixir.Relay.Config.shared(contexts),
         {:ok, contexts} <- Client.resolve_relay_contexts(contexts),
         {:ok, assignees} <- subscription_assignees(contexts),
         {:ok, consumer} <- Store.identity(relay, app["workspace_id"]) do
      binding = binding_key(contexts)

      Session.open(relay, app["workspace_id"], consumer, assignees, binding,
        workspace_wide: workspace_wide?(contexts),
        contexts: contexts,
        authority: Store.digest({relay["endpoint"], Map.take(app, ~w(workspace_id client_id user_id))}),
        request: fn op, body -> SymphonyElixir.Relay.Client.request(relay, app, consumer, op, body) end,
        snapshot: &Client.fetch_relay_snapshot(contexts, &1),
        fetch: &Client.fetch_relay_issues(contexts, &1)
      )
    end
  end

  defp subscription_assignees(contexts) do
    if workspace_wide?(contexts), do: {:ok, []}, else: Client.relay_assignees(contexts)
  end

  defp workspace_wide?(contexts) do
    Enum.any?(contexts, fn context ->
      is_binary(context.yolo_agent_id) or ProjectContext.with_context(context, &Config.yolo?/0)
    end)
  end

  @spec binding_key([ProjectContext.t()]) :: String.t()
  def binding_key(contexts) do
    contexts
    |> Enum.map(fn context ->
      tracker = context.settings.tracker
      assignees = context.assignee_ids || Enum.sort(Assignees.parse(tracker.assignee))
      relay = if tracker.relay, do: Map.delete(tracker.relay, "owners")
      {context.id, %{tracker | assignee: assignees, relay: relay}, context.yolo_agent_id, context.human_handoff_id}
    end)
    |> Enum.sort()
    |> Store.digest()
  end

  @spec resolved_contexts(Session.t(), [ProjectContext.t()]) :: [ProjectContext.t()]
  def resolved_contexts(session, contexts) do
    fields = [:assignee_ids, :human_handoff_id, :yolo_agent_id]
    identities = Map.new(session.contexts, &{&1.id, Map.take(&1, fields)})
    Enum.map(contexts, &struct(&1, Map.get(identities, &1.id, %{})))
  end

  @spec candidates(Session.t(), [ProjectContext.t()]) :: {:ok, map()} | {:error, term()}
  def candidates(%{status: :ready} = session, contexts) do
    contexts = resolved_contexts(session, contexts)

    with {:ok, found} <- Client.relay_candidates(contexts, Map.values(session.record["issues"])) do
      {:ok, Map.new(found, fn {project, issues} -> {project, Enum.map(issues, &stamp_issue(&1, session.record))} end)}
    end
  end

  def candidates(session, _), do: {:error, {:relay_not_ready, session.status, session.error}}

  defp stamp_issue(issue, record) do
    epoch = Store.digest({record["generation"], record["epochs"][issue.id]})
    %{issue | last_comment_signal: Map.put(issue.last_comment_signal || %{}, :relay_epoch, epoch), relay_event: get_in(record, ["event_positions", issue.id])}
  end

  @spec background_issues([String.t()]) :: {:ok, [SymphonyElixir.Linear.Issue.t()]} | {:error, term()}
  def background_issues(ids) do
    if enabled?() do
      ProjectPoller.relay_issues(ProjectContext.current(), ids)
    else
      Tracker.fetch_issue_states_by_ids(ids)
    end
  end

  @spec enabled?() :: boolean()
  def enabled?, do: Config.settings!().tracker.relay != nil

  @spec execution_allowed(map()) :: :ok | {:error, term()}
  def execution_allowed(issue) do
    case Config.settings!().tracker do
      %{relay: nil} ->
        :ok

      %{relay: relay, app: app} ->
        context = ProjectContext.current()
        ids = if context, do: context.assignee_ids || [], else: []

        with true <-
               Map.get(issue, :assigned_to_worker, false) and is_binary(issue.assignee_id) and
                 issue.assignee_id != app["user_id"] and issue.assignee_id in ids,
             {:ok, _consumer} <- Store.identity(relay, app["workspace_id"]) do
          :ok
        else
          false -> {:error, :relay_requires_authorized_human}
          error -> error
        end
    end
  end
end
