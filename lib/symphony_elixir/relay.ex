defmodule SymphonyElixir.Relay do
  @moduledoc "Workspace relay integration; explicit critical actions continue to use Linear directly."
  alias SymphonyElixir.{Config, ProjectContext, ProjectPoller, Tracker}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Relay.{Session, Store}

  @spec open([ProjectContext.t()]) :: {:ok, Session.t()} | {:error, term()}
  def open([first | _] = contexts) do
    relay = first.settings.tracker.relay
    app = first.settings.tracker.app

    with :ok <- SymphonyElixir.Relay.Config.shared(contexts),
         {:ok, assignees} <- subscription_assignees(contexts),
         {:ok, consumer} <- Store.identity(relay, app["workspace_id"]) do
      binding = binding_key(contexts)

      Session.open(relay, app["workspace_id"], consumer, assignees, binding,
        workspace_wide: Config.yolo?(),
        request: fn op, body -> SymphonyElixir.Relay.Client.request(relay, app, consumer, op, body) end,
        snapshot: &Client.fetch_relay_snapshot(contexts, &1),
        fetch: &Client.fetch_relay_issues(contexts, &1)
      )
    end
  end

  defp subscription_assignees(contexts) do
    if Config.yolo?(), do: {:ok, []}, else: Client.relay_assignees(contexts)
  end

  @spec binding_key([ProjectContext.t()]) :: String.t()
  def binding_key(contexts), do: Store.digest(Enum.map(contexts, &{&1.id, &1.settings.tracker}))

  @spec candidates(Session.t(), [ProjectContext.t()]) :: {:ok, map()} | {:error, term()}
  def candidates(%{status: :ready} = session, contexts) do
    with {:ok, found} <- Client.relay_candidates(contexts, Map.values(session.record["issues"])) do
      {:ok, Map.new(found, fn {project, issues} -> {project, Enum.map(issues, &stamp_issue(&1, session.record))} end)}
    end
  end

  def candidates(session, _), do: {:error, {:relay_not_ready, session.status, session.error}}

  defp stamp_issue(issue, record) do
    epoch = Store.digest({record["generation"], record["epochs"][issue.id]})
    %{issue | last_comment_signal: Map.put(issue.last_comment_signal || %{}, :relay_epoch, epoch)}
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
        with true <- Map.get(issue, :assigned_to_worker, true) and issue.assignee_id != app["user_id"],
             {:ok, consumer} <- Store.identity(relay, app["workspace_id"]) do
          owner(relay["owners"], issue.assignee_id, consumer)
        else
          false -> {:error, :relay_requires_authorized_human}
          error -> error
        end
    end
  end

  @spec owner(map(), term(), String.t()) :: :ok | {:error, atom()}
  def owner(owners, assignee, consumer) do
    case owners[assignee] do
      ^consumer when is_binary(assignee) -> :ok
      other when is_binary(other) -> {:error, :relay_other_executor}
      _ -> {:error, :relay_executor_missing_or_ambiguous}
    end
  end
end
