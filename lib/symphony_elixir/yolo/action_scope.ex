defmodule SymphonyElixir.Yolo.ActionScope do
  @moduledoc "Fresh ownership and comment authorization shared by PO actions and ordinary follow-ups."
  alias SymphonyElixir.{CommentCheckpoint, Config, Tracker}
  alias SymphonyElixir.Linear.WriteContext
  alias SymphonyElixir.Yolo.{Admission, Scope}

  @spec sources([String.t()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def sources(ids, opts) do
    fetch = Keyword.get(opts, :fetch, &Tracker.fetch_issue_states_by_ids/1)

    with true <- ids != [] and Enum.all?(ids, &bound?/1),
         {:ok, issues} <- fetch.(ids),
         true <- Enum.sort(Enum.map(issues, & &1.id)) == Enum.sort(ids),
         true <- Enum.all?(issues, &authorized?/1),
         :ok <- check(issues, opts) do
      {:ok, issues}
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_action_scope_changed}
    end
  end

  defp bound?(id), do: Scope.member?(id) or (is_nil(Scope.current()) and WriteContext.current()["issue_id"] == id)

  defp authorized?(issue) do
    allowed = Config.allowed_issue_ids()

    issue.in_project_scope and issue.assigned_to_worker and (is_nil(allowed) or issue.id in allowed) and
      if Scope.current(), do: Admission.eligible?(issue), else: CommentCheckpoint.active?(issue)
  end

  defp check(issues, opts) do
    guard = Keyword.get(opts, :before_action, &CommentCheckpoint.before_action/1)

    Enum.reduce_while(issues, :ok, fn issue, _ ->
      case guard.(issue) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
