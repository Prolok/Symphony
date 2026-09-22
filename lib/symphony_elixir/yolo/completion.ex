defmodule SymphonyElixir.Yolo.Completion do
  @moduledoc "Explicit per-member receipts; a normal Codex exit alone never completes a PO group."
  alias SymphonyElixir.{CommentCheckpoint, Config, Tracker}
  alias SymphonyElixir.Linear.IssueLease
  alias SymphonyElixir.Yolo.{Admission, Operations, Scope, Store}

  @spec tool_spec() :: map()
  def tool_spec do
    %{
      "name" => "symphony_yolo_complete",
      "description" => "Confirm a processed PO group member with its actual decision and evidence. Call after actions and comment acknowledgements; requires the current group binding.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["issue_id", "result"],
        "properties" => %{"issue_id" => %{"type" => "string"}, "result" => %{"type" => "string"}}
      }
    }
  end

  @spec execute(term(), keyword()) :: map()
  def execute(arguments, opts \\ []) do
    result = invoke(arguments, opts)
    success = result == :ok
    output = Jason.encode!(if(success, do: %{completed: true}, else: %{error: inspect(result)}))
    %{"success" => success, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end

  @spec mcp_call(term(), keyword()) :: map()
  def mcp_call(arguments, opts \\ []) do
    result = execute(arguments, opts)
    %{"isError" => not result["success"], "content" => [%{"type" => "text", "text" => result["output"]}]}
  end

  @spec invoke(term(), keyword()) :: :ok | {:error, term()}
  def invoke(%{"issue_id" => id, "result" => result}, opts) when is_binary(result) do
    scope = Scope.current()
    fetch = Keyword.get(opts, :fetch, &Tracker.fetch_issue_states_by_ids/1)
    check = Keyword.get(opts, :before_action, &CommentCheckpoint.before_action/1)

    with true <- Scope.member?(id) and String.trim(result) != "",
         {:ok, [issue]} <- fetch.([id]),
         true <- issue.in_project_scope,
         :ok <- check.(issue),
         :ok <- completion_operations(issue, opts),
         :ok <- review_handoff(scope, issue, opts),
         true <- Admission.eligible?(issue) or Keyword.get(opts, :handoff_completed, false) do
      # Separate journal lock: the worker retains the group and issue leases.
      IssueLease.with_journal_lock(Store.path(scope["group"]) <> ".completion", fn ->
        complete(scope["group"], id, result, escalation_keys(opts))
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_completion_outside_scope}
    end
  end

  def invoke(_, _), do: {:error, :invalid_yolo_completion}

  defp escalation_keys(opts) do
    if opts[:unresolved_escalation] == true and opts[:review_waiting] == true,
      do: Keyword.get(opts, :escalated_operations, []),
      else: []
  end

  defp completion_operations(issue, opts), do: operations_complete(issue, escalation_keys(opts))

  @spec verify_operations([map()]) :: :ok | {:error, term()}
  def verify_operations(issues) do
    Enum.reduce_while(issues, :ok, fn issue, _ ->
      case operations_complete(issue, recorded_escalation(issue)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp recorded_escalation(%{state: "Yolo Review", id: id}) do
    scope = Scope.current()

    with %{"group" => group, "run_id" => run_id} <- scope,
         {:ok, %{"attempt" => attempt}} when is_map(attempt) <- Store.read(group),
         true <- attempt["id"] == run_id and is_binary(attempt["completed"][id]) do
      get_in(attempt, ["escalated_operations", id]) || []
    else
      _ -> []
    end
  end

  defp recorded_escalation(_issue), do: []

  defp review_handoff(scope, issue, opts) do
    if (scope["group"] == "review" or issue.state == "Yolo Review") and not Keyword.get(opts, :review_waiting, false) and not Keyword.get(opts, :handoff_completed, false),
      do: {:error, :yolo_review_handoff_required},
      else: :ok
  end

  defp operations_complete(issue, escalated) do
    with {:ok, pending} <- Operations.pending([issue.id]) do
      # A human owns the explicitly handed-off BLOCKER, including its unresolved
      # intents. The handoff report records these instead of claiming success.
      handed_off? = issue.state == "BLOCKER" and is_nil(issue.delegate_id) and is_binary(Config.human_handoff_id()) and issue.assignee_id == Config.human_handoff_id()

      waiting? = issue.state == "Yolo Review" and Enum.all?(pending, &(&1["key"] in escalated))
      if pending == [] or handed_off? or waiting?, do: :ok, else: {:error, {:yolo_operations_pending, Enum.map(pending, & &1["key"])}}
    end
  end

  defp complete(group, id, result, escalated) do
    with {:ok, record} <- Store.read(group),
         %{"members" => ids} = attempt <- record["attempt"],
         true <- id in ids and attempt["id"] in [nil, Scope.current()["run_id"]] do
      attempt = Map.put(attempt, "completed", Map.put(attempt["completed"] || %{}, id, result))
      attempt = Map.put(attempt, "escalated_operations", Map.put(attempt["escalated_operations"] || %{}, id, escalated))
      Store.write(group, Map.put(record, "attempt", attempt))
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_attempt_unavailable}
    end
  end

  @spec ready?(String.t(), [map()]) :: boolean()
  def ready?(group, issues) do
    case Store.read(group) do
      {:ok, %{"attempt" => %{"completed" => completed}}} -> Enum.all?(issues, &is_binary(completed[&1.id]))
      _ -> false
    end
  end
end
