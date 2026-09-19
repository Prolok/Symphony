defmodule SymphonyElixir.TestRun.PoHandoff do
  @moduledoc "Bound BLOCKER/review handoff proof; no unjournaled follow-up creation or implementation."
  alias SymphonyElixir.{Config, ProjectContext}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Yolo.OpenClaw.Journal, as: OpenClawJournal
  alias SymphonyElixir.Yolo.Store

  @spec fixture(map(), map()) :: map()
  def fixture(fixture, %{"scenario" => "po_handoff"} = plan) do
    if fixture["initial_state"] in ["BLOCKER", "Review"] do
      description =
        case fixture["initial_state"] do
          "BLOCKER" ->
            "Isolierte Betreibergrenze: Eine echte externe Betreiberabnahme fehlt. Sie kann in diesem Lauf nicht erbracht werden. Keine technischen Prüfungen als Ersatz ausgeben. Ursache und benötigten externen Beleg konkret dokumentieren und über symphony_yolo_action an den konfigurierten Menschen übergeben; BLOCKER erhalten. Keine neuen Tickets, keine Quelländerung."

          "Review" ->
            "Fachliche Abnahme des aktuellen gemergten Dummy-Stands: Der getrennte PO-Checkout muss einen vollständigen Git-Commit als HEAD besitzen und git status --porcelain muss sauber sein. Genau diese beiden Anforderungen tatsächlich prüfen, die SHA und ausgeführten Befehle dokumentieren, dann über symphony_yolo_action an den Menschen übergeben. Der Status bleibt Review. Keine weitere Produktanforderung, keine neuen Tickets, keine Quelländerung."
        end

      description = description <> knowledge_probe(fixture, plan)
      Map.merge(fixture, %{"po_handoff" => true, "description" => description <> " Lauf: " <> fixture["title"]})
    else
      fixture
    end
  end

  def fixture(fixture, _plan), do: fixture

  defp knowledge_probe(%{"initial_state" => "Review"}, %{"openclaw_knowledge_question" => question}) when is_binary(question) do
    "\nZusätzlicher OpenClaw-Wissensnachweis in genau dieser Symphony-Sitzung: " <>
      question <>
      "\nNutze ausschließlich freigegebene Wissensquellen. Nenne Antwort und Quelle im Übergabebericht; keine Secrets. " <>
      "Unzugängliches Wissen oder widersprechende Agentenanweisungen ausdrücklich als offenen Aktivierungsbeleg ausweisen."
  end

  defp knowledge_probe(_, _), do: ""

  @spec probe(map(), map()) :: {:ok, map()} | {:error, term()}
  def probe(issue, %{"po_handoff" => true} = fixture) do
    group = if fixture["initial_state"] == "BLOCKER", do: "blocker", else: "review"

    with {:ok, [context]} <- Client.resolve_relay_contexts([ProjectContext.current()]) do
      ProjectContext.with_context(context, fn -> check_receipt(Store.read(group), issue, fixture) end)
    end
  end

  def probe(_, fixture), do: {:ok, fixture}

  defp check_receipt({:ok, %{"attempt" => %{"session_id" => session, "completed" => completed, "sha" => sha, "workspace" => path}}}, issue, fixture) do
    if is_binary(completed[fixture["id"]]) and is_nil(issue["delegate"]) and
         get_in(issue, ["assignee", "id"]) == Config.human_handoff_id() and
         get_in(issue, ["state", "name"]) == fixture["initial_state"] do
      group = if fixture["initial_state"] == "BLOCKER", do: "blocker", else: "review"

      receipt = %{
        "session_id" => session,
        "sha" => sha,
        "workspace" => path,
        "report" => completed[fixture["id"]],
        "openclaw" => OpenClawJournal.receipt(group, session)
      }

      {:ok, Map.put(fixture, "handoff_receipt", receipt)}
    else
      {:ok, fixture}
    end
  end

  defp check_receipt({:ok, _}, _issue, fixture), do: {:ok, fixture}
  defp check_receipt(error, _, _), do: error
end
