---
name: sym-yolo-review
description: Fachliche Symphony-Schlussabnahme im exklusiven isolierten Testbetrieb aus einem separaten gemergten Checkout.
---

# Symphony-Schlussabnahme

Nur im gebundenen Review-Sammellauf aus WORKFLOW_YOLO_AGENT.md für das
Symphony-Orchestrator-Repository mit `scripts/test-instance-run` verwenden.
Die Dummy-Projekte prüfen ausschließlich ihre eigenen Ticketanforderungen;
sie starten keine weitere Symphony-Testinstanz oder rekursive Selbstabnahme.
Die allgemeinen Abnahmepflichten und technischen Vor-Merge-Gates bleiben erhalten.

1. Prüfe den eigenen Checkout unter dem konfigurierten Workspace-Root: sauber,
   detached, HEAD gleich der zu Laufbeginn dokumentierten gemergten SHA. Der
   Ursprungworktree ist keine Voraussetzung. Hauptcheckout und Hauptinstanz
   weder aktualisieren noch neu starten. Kein Projekt SymphonyTest/Symphony.
2. Lies die Anforderungen aller Review-Mitglieder und leite konkrete gemeinsame
   Verhaltenstests ab. Kennzeichne bereits vorliegende Belege mit Quelle und
   Geltungsbereich; lokale Fixtures sind keine Live-Abnahme.
3. Verwende den PRO-736-Runner `scripts/test-instance-run` aus genau diesem
   Checkout. Vor einem Live-Lauf muss der Betreiber das frische öffentliche
   Ein-Projekt-Manifest für `Prolok/symphony-test`, dessen konfigurierten
   YOLO-Agenten und erforderliche Teamstatus, Hauptinventar,
   erlaubte Zugänge und die exklusive Entscheidungshoheit bestätigt haben.
   Private Envdateien, externe Checkouts und Hauptbetrieb sind kein Workerpfad.
4. Rufe den Runner mit `--checkout <dieser-checkout> --source-mode merged`,
   `--expected-sha <dokumentierte-sha> --expected-source <source-sha256>`,
   frischem `--run-id`, gebundenem `--manifest`, freiem `--port`,
   `--timeout 600` und eigenem `--result-dir` auf. Die Quellkennung liefert
   `python3 scripts/test-instance.py source <dieser-checkout>`.
   Wähle die betroffenen Szenarien ausdrücklich: `bootstrap`, `delegation`,
   `po_incoming`, `po_handoff`, `po_aggregation` oder `po_followup`.
   Nacheinander ausführen; alle verwenden dieselbe exklusive Testumgebung. Vor-Merge-Kandidaten verwenden ausdrücklich
   `development`; sie sind kein Nachweis einer gemergten Featureversion.
5. Prüfe tatsächliche `result.json`-Ergebnisse: `evidence=live`, passende
   SHA/Quellkennung, echte Sessions, isolierte Projekt-/Relaybindungen,
   Szenariobelege sowie `cleanup`, `main_preserved`, `originals_preserved`.
   `po_aggregation` prüft Anlage/Links und Ursprungabschluss; `po_followup`
   prüft Fix-Anlage und sofortige Review-Übergabe, jeweils auch die zu prüfende
   Startmodusmatrix über `--yolo`. Diese begrenzten Belege ersetzen keinen
   vollständigen Implementierungs-/Merge-/Fixdurchlauf.
   `po_handoff` prüft einen externen BLOCKER und die dadurch frei werdende
   Review-Abnahme mit erhaltener Review-/BLOCKER-Phase und menschlicher Übergabe.
   Es ersetzt keinen Fix-/Aggregations- oder vollständigen Implementierungsfall.
   Ergänzende ticketseitige Szenarien bleiben fällig, bis reale Belege vorliegen.
6. Fehler, Timeout oder Abbruch sind kein Pass. Eigene Prozesse kontrolliert
   beenden; falls nötig denselben Aufruf mit `--resume --cleanup-only` für die
   eigene Recovery nutzen. Keine unbeteiligte Testarbeit löschen, keine alten
   Run-IDs überschreiben. Ein unveränderter externer Blocker wird nicht erneut
   getestet. Fehlende fällige Betreiberbelege mit Aktion, Rolle, Quelle,
   bestandenem Workeranteil und fehlendem Resultat im jeweiligen Workpad halten.
7. Anforderungen und gemeinsames End-to-End-Verhalten ehrlich bewerten.
   Tatsächliche Findings über `symphony_yolo_action` als verknüpfte Folge-Tickets
   erfassen. Danach die Ursprünge sofort mit Bericht an den Menschen übergeben;
   Review erhalten, Delegation entfernen, keine Nachprüfung des Ursprungs.
