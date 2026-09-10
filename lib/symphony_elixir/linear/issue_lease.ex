defmodule SymphonyElixir.Linear.IssueLease do
  @moduledoc """
  Host-wide issue ownership for updated app workers. Legacy workers still
  require the separately verified, disjoint scopes of the migration contract.
  """

  alias SymphonyElixir.{Config, RuntimePaths, Tracker, Workpad}
  alias SymphonyElixir.Linear.WorkpadTransfer

  @spec run(map(), (-> term())) :: term()
  def run(issue, callback) do
    case Config.settings!().tracker do
      %{auth_mode: "app", app: binding} ->
        with_lock(binding["workspace_id"], issue.id, fn -> run_ready(binding, issue, callback) end)

      _ ->
        callback.()
    end
  end

  @spec with_lock(String.t(), String.t(), (-> term())) :: term()
  def with_lock(workspace_id, issue_id, callback) do
    case System.find_executable("python3") do
      nil -> {:error, :issue_lease_unavailable}
      python -> hold(python, workspace_id, issue_id, callback)
    end
  end

  defp hold(python, workspace_id, issue_id, callback) do
    script = Path.join(RuntimePaths.workflow_dir(), "priv/linear_app/issue_lease.py")

    env =
      Enum.map(Config.without_linear_secret([]), fn
        {name, nil} -> {String.to_charlist(name), false}
        {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
      end)

    port = Port.open({:spawn_executable, python}, [:binary, :exit_status, {:line, 128}, {:env, env}, {:args, ["-I", "-u", script]}])

    try do
      Port.command(port, Jason.encode!(%{workspace_id: workspace_id, issue_id: issue_id}) <> "\n")

      receive do
        {^port, {:data, {:eol, "locked"}}} -> callback.()
        {^port, _message} -> {:error, :issue_already_owned}
      after
        10_000 -> {:error, :issue_lease_unavailable}
      end
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp run_ready(binding, issue, callback) do
    with {:ok, comments} <- Tracker.fetch_issue_comments(issue.id),
         :ok <- workpad_ready(binding, issue, comments) do
      callback.()
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
