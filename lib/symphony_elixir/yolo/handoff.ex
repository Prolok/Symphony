defmodule SymphonyElixir.Yolo.Handoff do
  @moduledoc "Evidenced acceptance or durable waiting without leaving Yolo Review prematurely."
  alias SymphonyElixir.{Config, RoutineTest, TestRun, Tracker, Workpad, Workspace}
  alias SymphonyElixir.Yolo.{ActionScope, API, Completion, Dependencies, Escalation, Operations}
  alias SymphonyElixir.Yolo.{MergeReadiness, ReviewContract, Scope, Store}

  @authorization {__MODULE__, :issue}

  @spec authorized?(String.t()) :: boolean()
  def authorized?(id), do: Process.get(@authorization) == id

  @spec invoke(map(), keyword()) :: :ok | {:error, term()}
  def invoke(%{"issue_id" => id, "report" => report} = args, opts) when is_binary(report) do
    with true <- String.trim(report) != "" and Scope.member?(id),
         {:ok, [issue]} <- ActionScope.sources([id], opts),
         true <- issue.state in ["Yolo Review", "BLOCKER"],
         {:ok, pending} <- Operations.pending([id]),
         true <- pending == [] or issue.state == "BLOCKER" or args["kind"] == "escalate",
         :ok <- validate_review(issue, args),
         report = ReviewContract.append_report(report, args) <> escalation_report(args) <> pending_report(pending),
         opts = Keyword.put(opts, :escalated_operations, if(args["kind"] == "escalate", do: Enum.map(pending, & &1["key"]), else: [])),
         :ok <- decide(issue, args, report, opts) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_handoff_not_ready}
    end
  end

  def invoke(_, _), do: {:error, :invalid_yolo_handoff}

  defp validate_review(issue, %{"kind" => "escalate"} = args) do
    with :ok <- Escalation.validate(args) do
      if is_binary(Scope.current()["review_contract"]["error"]),
        do: :ok,
        else: ReviewContract.validate(issue, args)
    end
  end

  defp validate_review(issue, args), do: ReviewContract.validate(issue, args)

  defp decide(%{state: "Yolo Review"} = issue, %{"kind" => kind} = args, report, opts) when kind in ["wait", "escalate"] do
    with {:ok, [fresh]} <- Dependencies.refresh([issue], opts),
         true <- kind == "escalate" or not Dependencies.unblocked?(fresh),
         :ok <- report(issue, report, opts),
         :ok <- maybe_escalate(issue, args, opts) do
      Completion.invoke(%{"issue_id" => issue.id, "result" => report}, Keyword.merge(opts, review_waiting: true, unresolved_escalation: kind == "escalate"))
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_wait_requires_dependency}
    end
  end

  defp decide(issue, args, report, opts) do
    with :ok <- acceptance(issue, args, opts),
         :ok <- attempt_available(issue.id),
         human when is_binary(human) <- Config.human_handoff_id(),
         :ok <- report(issue, report, opts),
         :ok <- maybe_escalate(issue, args, opts),
         {:ok, [fresh]} <- ActionScope.sources([issue.id], opts),
         true <- fresh.state == issue.state,
         :ok <- acceptance(fresh, args, opts),
         {:ok, input} <- handoff_input(fresh, human, opts),
         :ok <- update(fresh, input, opts) do
      with :ok <- Completion.invoke(%{"issue_id" => issue.id, "result" => report}, Keyword.put(opts, :handoff_completed, true)) do
        cleanup(issue)
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_handoff_not_ready}
    end
  end

  defp cleanup(issue) do
    if issue.state == "Yolo Review" and not RoutineTest.manages_project?(),
      do: Workspace.remove_issue_workspaces(issue.identifier),
      else: :ok
  end

  defp attempt_available(id) do
    scope = Scope.current()

    with {:ok, %{"attempt" => %{"members" => ids} = attempt}} <- Store.read(scope["group"]),
         true <- id in ids and attempt["id"] in [nil, scope["run_id"]] do
      :ok
    else
      _ -> {:error, :yolo_attempt_unavailable}
    end
  end

  defp acceptance(%{state: "BLOCKER"}, _args, _opts), do: :ok

  defp acceptance(issue, %{"review" => review}, opts) do
    with true <- Enum.all?(review["checks"], &(&1["result"] == "passed")) and review["limitations"] == [],
         true <- Enum.all?(review["findings"], &(&1["category"] == "new_requirement")),
         {:ok, [fresh]} <- Dependencies.refresh([issue], opts),
         true <- Dependencies.unblocked?(fresh),
         :ok <- MergeReadiness.check(issue),
         {:ok, comments} <- Keyword.get(opts, :comments, &Tracker.fetch_issue_comments/1).(issue.id),
         {:ok, workpad} <- Workpad.find_comment(comments),
         true <- Workpad.merge_handoff_status(comments) == :ready or TestRun.review_fixture?(issue.id),
         :closed <- Workpad.section_checklist_status(workpad.body, "Validierung", "Yolo Review") do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_acceptance_incomplete}
    end
  end

  defp handoff_input(%{state: "Yolo Review"} = issue, human, opts) do
    with {:ok, state} <- API.state(issue.team_id, "Review", opts), do: {:ok, %{stateId: state, assigneeId: human, delegateId: nil}}
  end

  defp handoff_input(_, human, _opts), do: {:ok, %{assigneeId: human, delegateId: nil}}

  defp update(issue, input, opts) do
    previous = Process.put(@authorization, issue.id)

    try do
      expected = if issue.state == "Yolo Review", do: "Review", else: "BLOCKER"
      result = API.update(issue.id, input, opts)
      fetch = Keyword.get(opts, :fetch, &Tracker.fetch_issue_states_by_ids/1)

      case fetch.([issue.id]) do
        {:ok, [%{delegate_id: nil, assignee_id: human, state: state}]}
        when human == input.assigneeId and state == expected ->
          :ok

        _ ->
          if(result == :ok, do: {:error, :yolo_handoff_unconfirmed}, else: result)
      end
    after
      if is_nil(previous), do: Process.delete(@authorization), else: Process.put(@authorization, previous)
    end
  end

  defp maybe_escalate(issue, args, opts) do
    if args["kind"] == "escalate" or issue.state == "BLOCKER",
      do: Escalation.notify(issue, args, opts),
      else: :ok
  end

  defp escalation_report(%{"escalation" => details}) when is_map(details),
    do: "\n\nEskalation:\n```json\n" <> Jason.encode!(Map.take(details, ~w(cause attempts proposal decision)), pretty: true) <> "\n```"

  defp escalation_report(_), do: ""

  defp pending_report([]), do: ""

  defp pending_report(pending) do
    "\n\nOffene Anlageoperationen, ausdrücklich nicht abgeschlossen; Betreiberabgleich erforderlich:\n" <>
      Enum.map_join(pending, "\n", &"- Operation #{&1["key"]}; reservierte Ticket-ID #{&1["issue_id"]}. Anlage/Links/Ursprungabschluss anhand des Journals abgleichen; keine Ersatzanlage.")
  end

  defp report(issue, report, opts) do
    fetch = Keyword.get(opts, :comments, &Tracker.fetch_issue_comments/1)
    write = Keyword.get(opts, :workpad, &Workpad.update_tracker_workpad/2)
    entry = "\n\n### YOLO-Übergabe\n\n" <> report <> "\n\nMenschliche Zuständigkeit: @" <> Config.human_handoff_id() <> "."

    with {:ok, comments} <- fetch.(issue.id), {:ok, workpad} <- Workpad.find_comment(comments) do
      if String.contains?(workpad.body, entry), do: :ok, else: write.(issue.id, workpad.body <> entry)
    end
  end
end
