# PRO-969: isolierter Ursachen- und Regressionsbeleg

Der Projekt-Orchestrator führte den YOLO-Takt einschließlich serieller
Kommentar-Scans selbst aus. Ein wartender Scan hielt deshalb auch Snapshots und
Worker-Ereignisse auf. Bereits eingereihte Poll-Zyklen konnten danach die
Stall-Prüfung ausführen, bevor ein ebenfalls eingereihter Turn-Abschluss in den
Workerzustand übernommen wurde.

Die identische Probe reproduziert diesen Zusammenhang auf beiden Quellständen.
Der konkrete Fehlerpfad bestand somit bereits vor `8f849d9..c6fba2e`.

| Quellstand | Snapshot mit 2-s-Frist | wartende Nachrichten | falscher Stall-Retry nach Freigabe | Worker |
| --- | --- | --- | --- | --- |
| `8f849d9a7096fe5e3b2971217885e364589e196b` | Timeout nach 2001 ms | 25 | 2301 ms ohne Aktivität | beendet |
| `c6fba2eec899c5fa9781a5bcd7b1d51f64ece32e` | Timeout nach 2001 ms | 25 | 2350 ms ohne Aktivität | beendet |

Die Probe verwendet fünf delegierte PO-Mitglieder, einen überwachten echten
Task-Worker und einen kontrolliert wartenden `SymphonyCommentScanSignal`-Aufruf.
Während der Wartezeit werden ein weiterer Poll-Zyklus, zwanzig Poll-Signale und
das reale Codex-Ereignis `turn_completed` gesendet. Die protokollierte Scanner-PID
ist jeweils die Orchestrator-PID; Stack und Mailbox stehen in den Rohbelegen.
Der Stack zeigt `Observation.observe → CommentCheckpoint.scan → CommentInbox →
Client.comment_scan_signal → AppAuth/RateLimit`. Im Quelltext wird dieser Pfad von
`Orchestrator.maybe_dispatch → Coordinator.tick/prepare_group` synchron betreten.
Nach Freigabe und einem Zustandsabgleich wird der bereits aktive Worker wegen
der veralteten Aktivitätsdaten beendet und ein Retry angelegt.

- [Probe vor dem Fix](before_probe.exs), SHA-256:
  `66ccaee46d67258db00e3883955ce0fae1271f51540cb153f6ce9bef61ae0544`
- [Rohbeleg 8f849d9](8f849d9-before.log)
- [Rohbeleg c6fba2e](c6fba2e-before.log)
- [Dauerhafte Regressionstests](../../test/symphony_elixir/orchestrator_io_test.exs)

Zur Wiederholung einen der genannten Stände mit `git archive` in ein temporäres
Verzeichnis **innerhalb dieses Worktrees** extrahieren, die Probe als
`test/symphony_elixir/orchestrator_io_test.exs` hinein kopieren und dort
`./scripts/mix-gate setup` sowie
`./scripts/mix-gate test test/symphony_elixir/orchestrator_io_test.exs` ausführen.
Die Vor-Fix-Probe muss mit einem Snapshot-Timeout fehlschlagen. Die beiden Läufe
nacheinander ausführen, damit ihre synthetischen HTTP-Server keinen Port teilen.
Keine produktiven Zugangsdaten, Dienste oder fremden Checkouts sind erforderlich.

Der Fix führt ausschließlich konfigurierte oder bereits laufende PO-Arbeit im
bestehenden TaskSupervisor aus. Pro Projekt bleibt ein Takt aktiv; weitere
Signale bündeln einen Folgetakt. Starts prüfen im Orchestrator den aktuellen
Projektkontext, die Taskbindung, Claims und Kapazität. Ergebnisintegration erhält
zwischenzeitliche Worker-/PO-Ereignisse und neue Claims. Kontextwechsel und
Projektende beenden den Task. Bereits eingereihte Worker-Updates werden vor der
Stall-Prüfung verarbeitet; abgeschlossene Turns und normale Exit-Finalisierung
lösen keinen Stall aus. Eine Folgesession aktiviert die Prüfung wieder.

Am Fixstand antwortete der direkte Projekt-Snapshot in 0–1 ms, während der Scan
2146–2250 ms aktiv blieb; kein Stall-Retry wurde angelegt. Elf neue Tests prüfen auch
Task-Ausfall, veraltete Ergebnisse, Kontextwechsel, normale Finalisierung,
echte Stalls und deren Wiederaktivierung, Cleanup, Ereignisintegration,
Kapazitäts-/Claim-Gates, Status-Reconciliation und den tatsächlichen Gruppenstart.

Das lokale Gate `make check` (Build, Format, Lint, Specs) ist grün. Der
abschließende gezielte Lauf enthält 328 bestandene Tests, darunter alle Tests in
`project_snapshot_test.exs`, `orchestrator_status_test.exs`, `yolo_runtime_test.exs`
und `project_snapshot_linear_test.exs` sowie die Retry-, Kommentar-Polling-,
Kapazitäts-, Projekt-Runtime- und Refresh-Gegenfälle.
[Prüflog](check.log), [Testlog](targeted.log), [Regressionslog](after.log).

Die Probe bestätigt den blockierenden Ausführungspfad und seine falsche
Stall-Recovery. Sie ist keine Messung der Hauptinstanz und bestimmt weder den
exakten Live-Auslöser noch die Dauer einzelner produktiver Scans. Die vom PO
beobachteten Abstände zwischen Scan-Logs sind kein Nachweis ihrer Laufzeit.
Ein Einfluss des Rollouts auf das Live-Aufkommen oder auf andere Lesepfade ist
damit nicht allgemein ausgeschlossen. Der Bericht übernimmt den korrigierten
PO-Befund weiterlaufender Symphony-Scans; die quellengebundene Schlussabnahme am
Merge-Stand bleibt beim Betreiberagenten in Yolo Review.

Die PreReview hat zusätzlich den prozesslokalen AgentHop-Cache geprüft. Frische
Tasks verloren zunächst die Warmprüfung und verursachten wiederholte Journal-Locks
für unveränderte Mitglieder ([Vor-Fix-Beleg](prereview-hop-before.log)). Der
bestehende YOLO-Zustand erhält nun diesen Cache zwischen Tasks. Der Regressionstest
misst über zehn Tasks drei Erstprüfungen für drei Mitglieder, eine neue Prüfung
bei geändertem Agenteneingang und drei Prüfungen nach Coordinator-Neustart.
Der Trace erfasst den eigentlichen Journal-Lock-Aufruf mit vier Argumenten und
wartet vor der Auswertung auf die vollständige Trace-Zustellung.
[Cache-Regressionslog](prereview-hop-after.log).

Die zusätzliche RelayBudget-Auswahl besteht aus 19 Tests, darunter je 360 virtuelle
Takte mit laufenden, unsichtbaren und dauerhaft fehlerhaften Einträgen. Die fünfminütigen
Warmfälle erzeugen keine Linear-Anfragen. [Lastprüflog](prereview-budget.log).
Die finalen PreReview-Gates stehen in [Prüflog](prereview-check.log) und
[Testlog](prereview-targeted.log): `make check` grün, 276 gezielte Tests grün
einschließlich aller ticketseitigen Testdateien und der Cache-Regression.
Der direkte Projekt-Snapshot antwortete erneut in 0 ms bei 2146 ms aktivem Scan.

Der isolierte read-only Review gegen `origin/main d357be5` fand drei Fehler in
der nebenläufigen Integration. Alle drei wurden im bestehenden Orchestrator
korrigiert: Regulärer Dispatch läuft auch bei ständig gebündelten Folgepolls;
Recovery akzeptiert eigene Reservierungs-Claims, schützt aber aktive Worker und
PO-Gruppen; die Ergebnisintegration entfernt auch Claims kurzlebiger Recovery-
Starts, die im ursprünglichen Baselinezustand noch fehlten.

Drei neue Regressionen waren vor diesen Korrekturen rot (14 Tests, drei passende
Fehler). Mit zusätzlichem Nachweis eines einmaligen regulären Workerstarts trotz
Folgepoll sind nun alle 15 OrchestratorIO-Tests grün. Der Kurzlauf entfernt den
Recovery-Claim und erhält zwischenzeitliche Worker-/Retry-Claims; die Recovery-
Probe weist konkurrierende Starts ab und erlaubt einen neuen Beobachter nach
Ende seines Vorgängers. [Vor-Fix-Log](review-before.log),
[Nach-Fix-Log](review-after.log).

Am finalen Review-Fixstand sind `make check` und 332 gezielte Bestandstests grün.
Der direkte Snapshot antwortet in 0 ms bei 2167 ms aktivem Scan, ohne falschen
Stall. [Prüflog](review-check.log), [Testlog](review-targeted.log).
Das Reviewbudget von einer Runde ist ausgeschöpft; die gezielt validierten
Fixes wurden vom Hauptworker bewertet und nicht erneut vom Subagenten geprüft.
Vollsuite und gebundene Routinetests bleiben Aufgabe von `Test (AI)`.
