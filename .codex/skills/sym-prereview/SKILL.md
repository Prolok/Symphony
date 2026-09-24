---
name: sym-prereview
description: Fachliche Selbstkorrektur und gezielte PreReview-Prüfungen für Symphony Elixir.
---

# Sym PreReview

Für die frühe Selbstprüfung im normalen Entwicklerworkflow; in `PreReview (AI)`
ruft `symphony-prereview` diese Checkliste auf. Der Prüfmaßstab benötigt weder
YOLO-Steuerung noch Pai, OpenClaw oder privates Memory. Statuswechsel und
menschliche Freigaben bleiben beim aufrufenden Workflow.

## Checkliste

1. Gesamten Ticketdiff gegen Zielbranch und Akzeptanzkriterien prüfen, inklusive
   bereits committeter und offener Änderungen. Betroffene Produktpfade mit
   Erfolgs-, Fehler- und Wiederaufnahmefall anhand der Auswahlhilfe bestimmen.
2. `make check` für den aktuellen Stand belegen.
3. Passende gezielte Tests aus dem betroffenen Verhalten auswählen, auch wenn
   deren Dateien unverändert sind. Fehlende oder entwertete Nachweise ausführen;
   weiterhin gültige Ergebnisse mit Quellstand und Geltungsbereich übernehmen.
4. Relevante Findings im Scope unmittelbar in derselben PreReview-Phase/Session
   beheben. Reproduktion und Ist/Soll festhalten; nach dem Fix fehlgeschlagene,
   entwertete und abhängige Prüfungen wiederholen, auch bei geänderten Fixtures,
   Schnittstellen oder Konfigurationen. Danach den gesamten Diff erneut bewerten.
5. Geprüften Stand (Basis, HEAD, offene Änderungen), Testauswahl, Ergebnisse,
   Korrekturen und verbleibende Pflichten dokumentieren; im Issue-Workflow im
   bestehenden Workpad. Erst bei behobenen relevanten Findings und gültigen
   fälligen Nachweisen weitergeben. Ein roter Test allein ist kein Blocker.

## Fachliche Auswahlhilfe

Nur vom Diff oder Auftrag berührte Risiken prüfen; dies ist keine Vollmatrix.
Die Dateien liegen unter `test/symphony_elixir/`. Testnamen am aktuellen Stand
prüfen und passende Nachbarfälle einbeziehen; die Beispiele sind nicht abschließend.

| Auslöser / Produktpfad | Beobachtbare Invariante und geeignete Bestandstests |
| --- | --- |
| Launcher, Auto-Update, Startlogging oder Terminaldarstellung | Echten Launcher/Build im isolierten PTY vom Start bis zur Hauptmaske prüfen; betroffene Updatefälle ohne Angebot sowie mit Ja/Nein über lokale Wegwerf-Remotes abdecken. Rückfrage bleibt bedienbar, Routine-/Budgetlogs bleiben unsichtbar, Warnungen/Fehler und Dateidiagnose erhalten. `startup_logging_test.exs` mit kaltem Logger, `log_file_test.exs`, `../symphony_script_test.exs`, `../autoupdate_script_test.exs`, `../linear_app/test_launcher_update.py`; bei Renderänderungen auch `status_dashboard_snapshot_test.exs`. |
| Statuswechsel, Retry, Reconciliation oder Workerabschluss im Orchestrator | Fehlende Live-Statusauskunft erhält Claim, Workspace und Wiederaufnahmekontext; alte Retry-Tokens lösen keine zweite Arbeit aus. Terminaler Status räumt erst nach Abschluss laufender Nacharbeit auf, manuelle Gates erhalten den Workspace. `retry_refresh_test.exs`. |
| Issue-Lease, Dispatch oder gemeinsame Kapazität | Kein zweiter Besitzer derselben Issue; Kapazität bleibt auch für wiederaufgenommene externe Läufe reserviert. Freigabe nach Besitzerende und Startfehler unterscheiden. `issue_lease_test.exs`, `worker_capacity_test.exs`. |
| Review-Quellenbindung, Skillladen oder Test-Executor | Falsche SHA, fremder/geänderter Skill oder verlorene Laufbindung erlauben keinen Pass; Wiederaufnahme erhält die Laufidentität. `yolo_review_contract_test.exs`, `test_executor_test.exs`. |
| Projektkontext, Workspaceroots oder Cleanup | Parallele Projekte behalten ihren Kontext; fremde/unsichere Pfade werden abgewiesen. Nur eigene unveränderte Testcheckouts bereinigen, abweichende zur Recovery erhalten. `project_context_test.exs`, `workspace_and_config_test.exs`, `yolo_workspace_test.exs`; bei Zusatztestbetrieb `test_instance_test.exs`. |
| PO-Anlage, Followup, Handoff oder Lernbeleg | Wiederaufnahme erzeugt keine doppelten Tickets; Links sind vor Übergabe bestätigt. Review/BLOCKER und menschliche Zuständigkeit bleiben erhalten; nur begründete wiederverwendbare Prüflücken schlagen Skilländerungen vor. `yolo_actions_test.exs`, `yolo_review_contract_test.exs`. |

Beispiel: Bei geändertem Abschluss-Lookup den bestehenden Test
„missing live issue retains completion until authoritative recovery“ in
`retry_refresh_test.exs` samt Status-/Cleanup-Nachbarn auswählen. Ein fehlender
Tracker-Datensatz darf nicht als bestätigter Abschluss gelten. Unberührte
Delegations- oder Aggregationsszenarien werden dadurch nicht fällig.

Für den Start-/Darstellungsnachweis die Hauptmaske mindestens 20 Sekunden über
mehrere Refreshs auf Flackern, Logreste und Umbruchfehler beobachten; bei einem
Breitenbefund auch kleine Terminalgröße/Resize prüfen. Launcherziel, Quell-/Buildstand,
Terminalgröße, Dauer, zeitlichen Mitschnitt und Cleanup festhalten. Nur eigene
Wegwerf-/Testsitzungen verwenden. Externe Doubles ausweisen; ersetzte Start-,
Logging- oder Renderpfade und einzelne Screenshots belegen diesen Produktpfad
nicht. `--test-instance` überspringt Auto-Update und deckt dessen Übergang nicht ab.

## Lokale Ausführung und Grenzen

Unix-Socket-Fixtures unabhängig von `File.cwd!()` unter einem kurzen Temp-Pfad anlegen, da Reviewcheckouts lange Pfade haben und macOS höchstens 104 Bytes für Socketpfade erlaubt.

`make check` verwendet den repo-lokalen Wrapper `scripts/mix-gate` und führt
Build, Format und Lint inklusive `specs.check` ohne Tests aus. Die vollständige
Suite mit Coverage und Dialyzer bleibt in `Test (AI)`. Keine
geerbten `SYMPHONY_*`-Runtime-Variablen manuell übernehmen und kein
dauerhaftes `mise trust` voraussetzen; der Wrapper vertraut eine vorhandene
`mise.toml` nur prozesslokal über `MISE_TRUSTED_CONFIG_PATHS`.

Gezielte ExUnit-Tests über `./scripts/mix-gate test <testdatei[:zeile]>` aufrufen.
Voraussetzungen: Elixir 1.19/OTP 28 gemäß `mise.toml`, Python 3 und Git sowie die
lokalen Abhängigkeiten/Fixtures des gewählten Tests; `make check` führt `mix setup`
über den Wrapper aus. Lokale Fixtures brauchen keine produktiven Credentials.
Ein ausdrücklich erforderlicher Livebeleg behält seine produktspezifischen
Zugangs-/Betreibervoraussetzungen gemäß `docs/linear-app.md`; Fixtures ersetzen
ihn nicht. Symphonys Selbsttestumgebung ist keine Voraussetzung anderer Projekte.
