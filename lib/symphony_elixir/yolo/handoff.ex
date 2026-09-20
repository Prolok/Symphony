defmodule SymphonyElixir.Yolo.Handoff do
  @moduledoc "Immediate, evidenced human handoff after review or an external blocker."
  alias SymphonyElixir.{Config, Tracker, Workpad}
  alias SymphonyElixir.Yolo.{ActionScope, API, Completion, Operations, ReviewContract, Scope}

  @spec invoke(map(), keyword()) :: :ok | {:error, term()}
  def invoke(%{"issue_id" => id, "report" => report} = args, opts) when is_binary(report) do
    with true <- String.trim(report) != "" and Scope.member?(id),
         {:ok, [issue]} <- ActionScope.sources([id], opts),
         true <- issue.state in ["Review", "BLOCKER"],
         {:ok, pending} <- Operations.pending([id]),
         true <- pending == [] or issue.state == "BLOCKER",
         :ok <- ReviewContract.validate(issue, args),
         report = ReviewContract.append_report(report, if(issue.state == "Review", do: args, else: %{})) <> pending_report(pending),
         human when is_binary(human) <- Config.human_handoff_id(),
         :ok <- report(issue, report, opts),
         {:ok, [fresh]} <- ActionScope.sources([id], opts),
         true <- fresh.state == issue.state,
         :ok <- API.update(id, %{assigneeId: human, delegateId: nil}, opts) do
      Completion.invoke(%{"issue_id" => id, "result" => report}, Keyword.put(opts, :handoff_completed, true))
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_handoff_not_ready}
    end
  end

  def invoke(_, _), do: {:error, :invalid_yolo_handoff}

  defp pending_report([]), do: ""

  defp pending_report(pending) do
    "\n\nOffene Anlageoperationen, ausdrücklich nicht abgeschlossen; Betreiberabgleich erforderlich:\n" <>
      Enum.map_join(pending, "\n", &"- Operation #{&1["key"]}; reservierte Ticket-ID #{&1["issue_id"]}. Anlage/Links/Ursprungabschluss anhand des Journals abgleichen; keine Ersatzanlage.")
  end

  defp report(issue, report, opts) do
    fetch = Keyword.get(opts, :comments, &Tracker.fetch_issue_comments/1)
    write = Keyword.get(opts, :workpad, &Workpad.update_tracker_workpad/2)
    entry = "\n\n### YOLO-Übergabe\n\n" <> report <> "\n\nMenschliche Zuständigkeit: @" <> Config.human_handoff_id() <> ". Status bleibt " <> issue.state <> "."

    with {:ok, comments} <- fetch.(issue.id),
         {:ok, workpad} <- Workpad.find_comment(comments) do
      if String.contains?(workpad.body, entry), do: :ok, else: write.(issue.id, workpad.body <> entry)
    end
  end
end
