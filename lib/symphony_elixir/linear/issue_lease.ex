defmodule SymphonyElixir.Linear.IssueLease do
  @moduledoc """
  Host-local issue ownership for app workers.
  """

  require Logger

  alias SymphonyElixir.{Config, RuntimePaths, Tracker, Workpad}
  alias SymphonyElixir.Linear.{WorkpadTransfer, WriteContext, YoloAgent}
  alias SymphonyElixir.Yolo.OpenClaw.Journal, as: OpenClawJournal
  alias SymphonyElixir.Yolo.Operations, as: Operations

  @spec run(map(), (-> term())) :: term()
  def run(issue, callback) do
    case Config.settings!().tracker do
      %{kind: "linear", auth_mode: "app", app: binding} ->
        run_owned(binding, issue, callback)

      _ ->
        callback.()
    end
  end

  @doc "Hold a delegated member locally while a retry checks whether delivery is possible."
  @spec run_pending(map(), (-> term())) :: term()
  def run_pending(issue, callback) do
    case Config.settings!().tracker do
      %{kind: "linear", auth_mode: "app", app: binding} ->
        run_pending_owned(binding, issue, callback)

      _ ->
        callback.()
    end
  end

  defp run_pending_owned(binding, issue, callback) do
    with :ok <- OpenClawJournal.member_available(issue.id),
         :ok <- SymphonyElixir.Relay.execution_allowed(issue) do
      with_lock(binding["workspace_id"], issue.id, fn -> pending_target(issue.id, callback) end)
    end
  end

  defp pending_target(id, callback) do
    with :ok <- ready_target(id), do: callback.()
  end

  @doc "Complete the member checks inside an already held pending lease before PO delivery."
  @spec ready_for_delivery(map()) :: :ok | {:error, term()}
  def ready_for_delivery(issue) do
    case Config.settings!().tracker do
      %{kind: "linear", auth_mode: "app", app: binding} -> run_ready(binding, issue, fn -> :ok end)
      _ -> :ok
    end
  end

  defp run_owned(binding, issue, callback) do
    with :ok <- OpenClawJournal.member_available(issue.id),
         :ok <- SymphonyElixir.Relay.execution_allowed(issue) do
      with_lock(binding["workspace_id"], issue.id, fn -> run_ready(binding, issue, callback) end)
    end
  end

  @spec with_lock(String.t(), String.t(), (-> term())) :: term()
  def with_lock(workspace_id, issue_id, callback) do
    lock(workspace_id, issue_id, callback, 0, {:issue_already_owned, :issue_lease_unavailable})
  end

  @spec with_journal_lock(String.t(), (-> term()), non_neg_integer(), String.t()) :: term()
  def with_journal_lock(state_root, callback, timeout \\ 10_000, purpose \\ "journal") do
    # Keep the existing lock identity/inode, including across release upgrades.
    timed = fn ->
      started = System.monotonic_time(:millisecond)

      try do
        callback.()
      after
        elapsed = System.monotonic_time(:millisecond) - started

        if elapsed > 2_000 and purpose not in ["scan-serialization", "write-serialization"] do
          context = WriteContext.current()

          Logger.debug(
            "Comment journal lock hold exceeded purpose=#{purpose} elapsed_ms=#{elapsed} " <>
              "issue_id=#{context["issue_id"] || "unknown"} issue_identifier=#{context["issue_identifier"] || "unknown"} " <>
              "session_id=#{context["session_id"] || "unknown"}"
          )
        end
      end
    end

    lock("symphony-comment-journal", Path.expand(state_root), timed, timeout, {:comment_journal_busy, :comment_journal_unavailable})
  end

  defp lock(workspace_id, issue_id, callback, timeout, {_busy, unavailable} = errors) do
    case System.find_executable("python3") do
      nil -> {:error, unavailable}
      python -> hold(python, workspace_id, issue_id, callback, timeout, errors)
    end
  end

  defp hold(python, workspace_id, issue_id, callback, timeout, {busy, unavailable}) do
    script = Path.join(RuntimePaths.workflow_dir(), "priv/linear_app/issue_lease.py")

    env =
      Enum.map(Config.without_linear_secret([]), fn
        {name, nil} -> {String.to_charlist(name), false}
        {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
      end)

    port = Port.open({:spawn_executable, python}, [:binary, :exit_status, {:line, 128}, {:env, env}, {:args, ["-I", "-u", script]}])

    try do
      Port.command(port, Jason.encode!(%{workspace_id: workspace_id, issue_id: issue_id, timeout_ms: timeout}) <> "\n")

      receive do
        {^port, {:data, {:eol, "locked"}}} -> callback.()
        {^port, {:data, {:eol, "busy"}}} -> {:error, busy}
        {^port, _message} -> {:error, unavailable}
      after
        timeout + 10_000 -> {:error, unavailable}
      end
    after
      # A rejecting helper can exit between receiving its reply and cleanup.
      # Closing an already closed port must not replace the lock result.
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp run_ready(binding, issue, callback) do
    with :ok <- ready_target(issue.id),
         :ok <- verify_delegation(issue),
         {:ok, comments} <- Tracker.fetch_issue_comments(issue.id),
         :ok <- retry_journal_busy(fn -> workpad_ready(binding, issue, comments) end, 3) do
      callback.()
    end
  end

  @spec retry_journal_busy((-> term()), pos_integer()) :: term()
  def retry_journal_busy(callback, remaining) do
    case callback.() do
      {:error, :comment_journal_busy} when remaining > 1 ->
        Process.sleep(250)
        retry_journal_busy(callback, remaining - 1)

      result ->
        result
    end
  end

  defp ready_target(id) do
    if Operations.target_ready?(id), do: :ok, else: {:error, :yolo_creation_incomplete}
  end

  defp verify_delegation(issue) do
    if YoloAgent.delegated?(issue) do
      with {:ok, [current]} <- Tracker.fetch_issue_states_by_ids([issue.id]),
           true <- YoloAgent.continued?(issue, current),
           :ok <- SymphonyElixir.Relay.execution_allowed(current) do
        :ok
      else
        {:error, _} = error -> error
        _ -> {:error, :yolo_delegation_changed}
      end
    else
      :ok
    end
  end

  defp workpad_ready(binding, issue, comments) do
    # The normal phase owns first-contact ordering and workpad creation.
    if fresh_issue?(binding, issue, comments),
      do: :ok,
      else: WorkpadTransfer.ready(binding, issue.id, Enum.map(comments, &raw_comment/1))
  end

  defp fresh_issue?(binding, issue, comments) do
    WorkpadTransfer.read(binding, issue.id) == {:error, :enoent} and
      not Enum.any?(comments, &(Workpad.comment_matches?(&1.body) or String.contains?(&1.body, "## Symphony Workpad (historisch, inaktiv)")))
  end

  defp raw_comment(comment) do
    %{"id" => comment.id, "body" => comment.body, "user" => %{"id" => Map.get(comment, :user_id)}}
  end
end
