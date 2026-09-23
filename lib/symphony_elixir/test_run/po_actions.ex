defmodule SymphonyElixir.TestRun.PoActions do
  @moduledoc "Bound real creation proofs, stopping before any implementation of derived tickets."

  @spec fixture(map(), map()) :: map()
  def fixture(%{"po_incoming" => true} = fixture, %{"scenario" => "po_incoming", "openclaw_interruption" => true}) do
    instruction = """

    Kontrollierter Unterbrechungstest: Wenn die eingefrorene Mitgliederliste dieses Auftrags
    das Testticket mit initialem Backlog enthält, ausschließlich dieses Mitglied regulär
    nach Verworfen entscheiden und mit symphony_yolo_complete bestätigen. Danach im
    unveränderten Prüfcheckout mit exec `sleep 300` warten, ohne den Auftrag abzuschließen
    oder andere Tickets zu bearbeiten. Der Testbetreiber unterbricht genau diesen Lauf.
    Keine eigenen Neustarts, Wiederholungen oder Unteragenten. Wenn die eingefrorene
    Liste nur noch die beiden anderen Testtickets enthält, beide regulär abschließen;
    die bereits bestätigte Backlog-Entscheidung weder erneut schreiben noch bestätigen.
    """

    Map.merge(fixture, %{"po_interruption" => true, "description" => fixture["description"] <> String.trim_trailing(instruction, "\n")})
  end

  def fixture(%{"po_incoming" => true} = fixture, %{"scenario" => "po_aggregation"} = plan) do
    requirement = "Ergänze eine Dokumentation docs/po-proof-#{plan["run_id"]}.md mit einem Abschnitt zu #{fixture["initial_state"]}, einschließlich Zweck und prüfbarer Abnahmekriterien."

    description =
      requirement <>
        "\n\nDiese drei zusammengehörigen Dokumentationsanforderungen aus Backlog/Todo/Definiert zuerst gemeinsam bewerten und genau ein Aggregationsticket mit symphony_yolo_action erstellen. Alle Anforderungen übernehmen, verknüpfen und Ursprünge nach Umsetzungsticket erstellt abschließen. Der begrenzte Test endet bei bestätigter Anlage; keine Implementierung oder Bearbeitung des neuen Tickets in diesem Sammellauf."

    Map.merge(fixture, %{"po_aggregation" => true, "description" => description})
  end

  def fixture(%{"initial_state" => "Yolo Review"} = fixture, %{"scenario" => "po_followup"} = plan) do
    description =
      "Fachlich prüfen, ob docs/po-proof-#{plan["run_id"]}.md im gemergten Checkout die Bedienung des Dummy-Projekts erklärt. Datei tatsächlich prüfen. Bei fehlender Dokumentation genau ein verknüpftes Fix-Ticket mit Anforderungen und Validierung über symphony_yolo_action anlegen. blocks_origins=true verwenden: Folgefix blockiert Ursprung als echte Linear-Relation. Anschließend kind=wait mit Prüf-/Lernbeleg; Ursprung und Delegation in Yolo Review erhalten. Der begrenzte Test endet bei bestätigter Anlage und Warteentscheidung; keine Quelländerung oder Implementierung des Fixes."

    Map.merge(fixture, %{"po_followup" => true, "po_handoff" => true, "description" => description})
  end

  def fixture(fixture, _), do: fixture
end
