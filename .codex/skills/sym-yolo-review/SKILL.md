---
name: sym-yolo-review
description: Fachliche Symphony-Schlussabnahme am gemergten Stand mit risikobezogener Testauswahl und Lernbeleg für berechtigte Agenten.
---

# Symphony-Schlussabnahme

Für die beauftragte Schlussabnahme des Symphony-Orchestrator-Repositories durch
Pai oder einen anderen berechtigten Agenten. Maßstab sind dieser versionierte
Skill, Auftrag und Anforderungen am dokumentierten gemergten Stand; privates
Memory und die Agentenidentität ergänzen keine Pflichten oder Befugnisse.
Im gebundenen Review-Sammellauf gilt `WORKFLOW_YOLO_AGENT.md`; außerhalb davon
müssen Auftrag, Prüfstand und Berichtsweg ausdrücklich feststehen. Dieser Skill
aktiviert weder einen Lauf noch einen zusätzlichen Pflichtreviewer.
Die Dummy-Projekte prüfen ausschließlich ihre eigenen Ticketanforderungen;
sie starten keine weitere Symphony-Testinstanz oder rekursive Selbstabnahme.
Die allgemeinen Abnahmepflichten und technischen Vor-Merge-Gates bleiben erhalten.

## Prüfstand und Auswahl

1. Prüfe den eigenen Checkout unter dem konfigurierten Workspace-Root: sauber,
   detached, HEAD gleich der zu Laufbeginn dokumentierten gemergten SHA. Der
   Ursprungworktree ist keine Voraussetzung. Hauptcheckout und Hauptinstanz
   weder aktualisieren noch neu starten. Kein Projekt SymphonyTest/Symphony.
   Skillpfad und SHA256 seines Inhalts festhalten; im Sammellauf
   `review_contract.binding` unverändert übernehmen und gegen den Checkout prüfen.
   Fehlender, unversionierter oder abweichend gebundener Skill erlaubt keine
   gültige Abnahme. Referenzen nur aus demselben Checkout lesen; während der
   Abnahme keine Skillreparatur vornehmen.
2. Anforderungen aller beauftragten Review-Mitglieder und deren gesamten
   gemergten Diff gegen die jeweilige Basis lesen. Gemeinsame Produktpfade und
   betroffene Fehler-/Wiederaufnahmefälle ableiten. Die fachliche Auswahlhilfe in
   `.codex/skills/sym-prereview/SKILL.md` auch auf unveränderte Tests anwenden;
   sie löst hier keinen PreReview-Statuswechsel aus.
3. Produkt mit `./scripts/mix-gate build` bauen. Für die lokale Umgebung gelten
   die Voraussetzungen im PreReview-Skill. Geeignete vorhandene Tests über
   `./scripts/mix-gate test <testdatei[:zeile]>` ausführen. Bereits gültige
   Belege mit Quelle, Stand und Geltungsbereich übernehmen; nur entwertete,
   fehlgeschlagene oder abhängige Prüfungen wiederholen. Kein pauschales
   `make all` und keine unbedingte Szenariomatrix allein wegen Schlussabnahme.
   Lokale Fixtures sind kein Livebeleg; ausdrücklich geforderte reale
   Integrations-/End-to-End-Nachweise bleiben fällig.

## Live-Szenarien nach Bedarf

Nur wenn Auftrag oder betroffener Produktpfad reale Integrationsbelege verlangen,
die passenden bestehenden Szenarien wählen. Auswahl und nicht abgedeckte
Anforderungen begründen. Details und Grenzen stehen in `docs/linear-app.md`,
Abschnitt „Isolierter Testbetrieb“.

| Auslöser | Szenario im `scripts/test-instance-run` | Erwartetes beobachtbares Ergebnis / Grenze |
| --- | --- | --- |
| Start, Discovery, Testisolation | `bootstrap` | Eigene Todo-Fixture erreicht Planung mit echter regulärer Session; Isolation und Cleanup bestätigt. Kein vollständiger Implementierungs-/Mergebeleg. |
| Agentendelegation oder Relay-Verarbeitung | `delegation` | Zuweisung/Entzug nur über `delegateId`, Mensch unverändert; Relay-Cursor und Ticket-Epoche fortgeschritten. Kein Ersatz durch Vollsnapshot. |
| Gemeinsamer PO-Eingang | `po_incoming` | Drei eigene Eingangsmitglieder in einer PO-Session begründet abgeschlossen, Zuständigkeit/Skip-Labels und Checkout-SHA belegt; keine Aggregation oder Reviewabnahme. |
| Externer BLOCKER und Freigabe wartender Reviews | `po_handoff` | BLOCKER wird übergeben, Review danach geprüft; echte Sessions, Status erhalten, Delegation entfernt und Cleanup bestätigt. Kein Fixdurchlauf. |
| Aggregationsanlage, Links oder Ursprungabschluss | `po_aggregation` | Genau ein verknüpftes Aggregationsticket, Links vor Ursprungabschluss bestätigt; betroffene Zuweisungsvarianten mit/ohne `--yolo` prüfen. Endet bei Anlage/Übergabe. |
| Findings, Fixanlage oder sofortige Reviewübergabe | `po_followup` | Genau ein verknüpftes Fix-Ticket, Ursprung sofort an Menschen übergeben; betroffene Zuweisungsvarianten mit/ohne `--yolo` prüfen. Kein Warten auf Fix und kein Fix-/Mergebeleg. |

Bei einem reinen Retry-/Cleanup-Diff zunächst die Status-/Wiederaufnahmefälle aus
`retry_refresh_test.exs` wählen. Die obigen PO-Szenarien werden nur bei zusätzlicher
fachlicher Betroffenheit fällig; ihr Pass würde den Retryfall nicht belegen.

Der gebundene Routineaufruf `symphony_test` ist ein anderer, auf die regulären
AI-Workerphasen begrenzter Weg gemäß `docs/linear-app.md`, „Gebundener Testaufruf“:
`bootstrap` prüft Todo→Planung, `workflow` den regulären Ablauf bis zur gemergten
Dummy-PR, `failure-probe` einen absichtlichen Fehler samt Cleanup. Diese
`development`-Belege nicht als Ausführung der gemergten Featureversion ausgeben
oder den Routineaufruf im Review-Sammellauf voraussetzen. Bestehende gültige
Belege dürfen mit ihrer Grenze übernommen werden; kein Ausbau des Testsystems.

## Voraussetzungen, Ausführung und Cleanup eines Live-Laufs

1. Verwende `scripts/test-instance-run` aus genau dem geprüften Checkout.
   Vor einem Live-Lauf muss der Betreiber das frische öffentliche
   Ein-Projekt-Manifest für `Prolok/symphony-test`, dessen konfigurierten
   YOLO-Agenten und erforderliche Teamstatus, Hauptinventar,
   erlaubte Zugänge und die exklusive Entscheidungshoheit bestätigt haben.
   Der Betreiber stellt diese Voraussetzungen nach `docs/linear-app.md`,
   „Betreiberbeleg und Einrichtung“, bereit; der berechtigte Prüfer führt den
   freigegebenen Lauf aus und bewertet ihn. Lokale grüne Tests ersetzen weder
   diese Einrichtung noch einen erforderlichen Aktivierungsbeleg.
   Private Envdateien, externe Checkouts und Hauptbetrieb sind kein Workerpfad.
2. Rufe den Runner mit `--checkout <dieser-checkout> --source-mode merged`,
   `--test-instance <freigegebener-name>`,
   `--expected-sha <dokumentierte-sha> --expected-source <source-sha256>`,
   frischem `--run-id`, gebundenem `--manifest`, freiem `--port`,
   `--timeout 600`, gewähltem `--scenario` und eigenem `--result-dir` außerhalb
   der Quellen auf. Die Quellkennung liefert
   `python3 scripts/test-instance.py source <dieser-checkout>`.
   Szenarien nacheinander ausführen; alle verwenden dieselbe exklusive
   Testumgebung. Symphonys Sondervoraussetzungen gelten nicht für andere Projekte.
   Vor-Merge-Kandidaten verwenden ausdrücklich
   `development`; sie sind kein Nachweis einer gemergten Featureversion.
3. Prüfe tatsächliche `result.json`-Ergebnisse: `status=passed`, `evidence=live`, passende
   SHA/Quellkennung, echte Sessions, isolierte Projekt-/Relaybindungen,
   Szenariobelege sowie `cleanup`, `main_preserved`, `originals_preserved`.
   Ergänzende ticketseitige Szenarien bleiben fällig, bis reale Belege vorliegen.
4. Fehler, Timeout oder Abbruch sind kein Pass. Eigene Prozesse kontrolliert
   beenden; falls nötig denselben Aufruf mit `--resume --cleanup-only` für die
   eigene Recovery nutzen. Keine unbeteiligte Testarbeit löschen, keine alten
   Run-IDs überschreiben. Ein unveränderter externer Blocker wird nicht erneut
   getestet. Fehlende fällige Betreiberbelege mit Aktion, Rolle, Quelle,
   bestandenem Workeranteil und fehlendem Resultat im jeweiligen Workpad halten.
   Bei Wiederaufnahme Beleg, Stand und Geltungsbereich abgleichen;
   Statusschieben allein erfüllt keine Betreiberpflicht. Kein Dienstwechsel
   durch den Prüfer, um fehlende Voraussetzungen zu umgehen.

## Findings, Lernen und Übergabe

Pro Finding Reproduktion, Ist/Soll und Beleg dokumentieren. Mit damaligem Wissen
bewerten, ob eine kostengünstige Erkennung in PreReview möglich war; Ursache
und Maßnahme gemäß `WORKFLOW_YOLO_AGENT.md`, „Review: gemeinsame fachliche
Schlussabnahme“, begründen. Für Symphony insbesondere:

- Einzelne Status-/Retry-Regressionsvariante: `regression` →
  `fix_and_regression_test`; den konkreten Fall absichern, keine allgemeine
  Skillregel allein aus einer Einzelbesonderheit ableiten.
- Vorhandener passender Status-/Cleanup-Test wurde übersehen: `test_selection`
  → `correct_test_selection`; Auswahl korrigieren, auch unveränderte Tests
  berücksichtigen, keinen spiegelgleichen Test hinzufügen.
- Dieselbe Invariante fehlt plausibel in mehreren Produktpfaden: `reusable_gap`
  → `fix_and_review_skill_proposal` nur mit konkreter Regel, künftiger Relevanz,
  Kosten und Nutzen. Etwa eine kurze Prüfung unklarer Abschlusszustände mit
  vorhandenen Retry-/Reconciliation-Tests statt einer neuen Live-Vollmatrix.
  Bei seltenem Nutzen begründet `fix_and_regression_test` wählen.
- Erst im Zusammenspiel mit realer Laufzeit entstandener Fehler: `integration`
  → `fix_and_integration_test`; erforderliche Umgebung benennen, keine
  rückwirkende PreReview-Erkennbarkeit behaupten.
- Erst nachträglich gewünschtes Statusverhalten: `new_requirement` →
  `requirement_ticket`; eigenen Anforderungsscope planen.

Skillvorschläge gehen über ein reguläres Korrekturticket/PR in die versionierte
Projektquelle zurück, nie durch spontane Änderung im Abnahmelauf oder in Memory.
Zusammengehörige Findings sinnvoll bündeln. Bericht mit Prüfstand/Skillhash,
tatsächlichen Prüfungen und Belegen, Findings samt Lernentscheidung,
Einschränkungen und Folgeentscheidung im vereinbarten Berichtsweg festhalten.
Nicht ausgeführte Prüfungen als Einschränkung, nicht als Pass ausweisen.

Im Sammellauf Findings über `symphony_yolo_action` als verknüpfte Folge-Tickets
mit stabilen Operationsschlüsseln erfassen. Nach bestätigter Anlage/Verknüpfung
die Ursprünge sofort mit `kind=handoff`, lesbarem `report` und strukturiertem
`review`-Beleg gemäß gemeinsamem Vertrag an den Menschen übergeben; dabei
`review_contract.binding` unverändert übernehmen. Review erhalten, Delegation
entfernen, keine Nachprüfung des Ursprungs. Außerhalb des Sammellaufs den
autorisierten Berichts-/Korrekturweg nutzen. Geprüfte Erfolge und ausgelagerte
Mängel unterscheiden; vollständige Fehlerfreiheit ist kein Abschlusskriterium.
