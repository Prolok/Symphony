# Logging Best Practices

This guide defines logging conventions for Symphony so Codex can diagnose failures quickly.

## Goals

- Make logs searchable by issue and session.
- Capture enough execution context to identify root cause without reruns.
- Keep messages stable so dashboards/alerts are reliable.

## Required Context Fields

When logging issue-related work, include both identifiers:

- `issue_id`: Linear internal UUID (stable foreign key).
- `issue_identifier`: human ticket key (for example `MT-620`).

When logging Codex execution lifecycle events, include:

- `session_id`: combined Codex thread/turn identifier.

## Message Design

- Use explicit `key=value` pairs in message text for high-signal fields.
- Prefer deterministic wording for recurring lifecycle events.
- Include the action outcome (`completed`, `failed`, `retrying`) and the reason/error when available.
- Avoid logging large payloads unless required for debugging.

## Log Sink

Application logs are written through `SymphonyElixir.LogFile` to a rotating
single-line disk log shared by all discovered projects. Its default root is
the service's starting working directory. The relative path is always `log/symphony.log`;
`symphony --logs-root <path>` changes the root in front of that relative path,
so the file is written below `<path>/log/symphony.log`. The handler keeps five
files of up to 10 MiB each and removes the default console handler after disk
logging is configured.

Beim Dienststart zeigt die Konsole bereits vor Discovery und Authentifizierung
nur Meldungen ab Stufe `info`. Dazu startet der CLI-Einstieg zuerst Elixirs Logger:
Im Escript ist dieser noch nicht aktiv und würde einen vorher gesetzten
Konsolenfilter beim späteren Start ersetzen. Das gilt auch für die Testlaufphasen.
Der Filter ändert weder das primäre Logger-Level noch die Debugdiagnose im
späteren Dateilog; Warnungen und Startfehler bleiben sichtbar.

Nach bestätigtem Auto-Update unterdrückt Git seine Fortschritts-/Dateistatistik;
Fehler und Builddiagnosen bleiben sichtbar. Die Terminalmaske bereinigt beim
Refresh jede Zeile unmittelbar vor deren Ausgabe, damit auch das letzte Zeichen
voller Terminalzeilen erhalten bleibt. Überzählige Zeilen entfernt sie erst nach
dem neuen Inhalt, statt vor jedem Bild den ganzen Bildschirm zu leeren.

`sym-codex` gibt Laufzeitlogs seiner Mix-Helfer ab Stufe `info` auf stderr aus;
Debugmeldungen bleiben ausgeblendet. stdout enthält ausschließlich den
maschinenlesbaren Projekt-, Workflow- oder Promptkontext.

`Linear app request unavailable` nennt nur die feste Anfrageart `kind`, eine
erlaubte Transportkategorie `reason` und die gemessene Dauer `elapsed_ms`.
Unbekannte Rückgaben und Exceptions erhalten feste Ersatzkategorien; ihre Texte,
URLs und beliebigen Fehlerdaten werden nicht protokolliert. Die Fehlersemantik
bleibt `linear_app_request_unavailable`; der HTTP-Pfad wiederholt nicht.
Der isolierte Testrunner darf ausschließlich seine lesende Beobachtungsprobe
begrenzt wiederholen und hält dies unter `probe_retries` im Laufbeleg fest
(siehe [Probe-Vertrag](linear-app.md#szenarien-resultate-und-wiederaufnahme)).
`Test fixture operation failed` ordnet den Abbruch über `stage`, `run_id`,
`project`, `issue_id` und `issue_identifier` dem Prüfabruf zu. Ein zeitlicher
Abstand im Log allein belegt keinen Timeout oder Authfehler.

## Scope Guidance

- `AgentRunner`: log start/completion/failure with issue context, plus `session_id` when known.
- `Orchestrator`: log dispatch, retry, terminal/non-active transitions, and worker exits with issue context. Include `session_id` whenever running-entry data has it.
- `Orchestrator`: for Review-(AI)-Handoffs zusätzlich festhalten, ob `spawn_agent`-/`wait_agent`-Signale erfasst wurden, inklusive `recovered_kind`, der getrackten Review-Sub-Agent-Call-/Agent-ID-Anzahlen und der Rohquelle (`source_method`, `source_item_type`, `source_tool`) des erkannten Handoff-Events.
- `Codex.AppServer`: log session start/completion/error with issue context and `session_id`.
- Native Reviewresultate werden erst nach bestätigter Parent-/Child-/Workspace-
  Zuordnung und dauerhafter Speicherung als `review_subagent_completed` gemeldet.
  Aktivitätsmeldungen allein belegen kein Ergebnis; fremde Terminalereignisse
  bleiben Notifications und ändern den Hauptturn-Abschluss nicht.
- `Codex.AppServer`: log protocol notifications at debug level with `method`,
  `item_type`, `tool`, `call_id` and `jsonrpc_id` when those fields are
  available. Keep the raw protocol payload in the event stream, not in normal
  log messages.

## Checklist For New Logs

- Is this event tied to a Linear issue? Include `issue_id` and `issue_identifier`.
- Is this event tied to a Codex session? Include `session_id`.
- Is the failure reason present and concise?
- Is the message format consistent with existing lifecycle logs?

## Kommentar-Checkpoints

`Comment scan completed/failed` enthält `project_root`, `issue_id`,
`issue_identifier`, den bekannten `session_id` und `last_successful_scan`.
Erfolg nennt die Anzahl offener Versionen, Fehler die vorhandene API-/Rate-Limit-
Klassifikation. Kommentartexte gehören in den gebundenen Eingang bzw. das
Workpad, nicht in normale Betriebslogs. `comment_inputs_pending` enthält deshalb
nur Quellschlüssel und den letzten erfolgreichen Scan; die Quellen bleiben über
den gebundenen Kommentar-Checkpoint abrufbar. Der letzte vollständige Stand bleibt bei
Fehlern bestehen; Empfang ist kein fachlicher Verarbeitungsnachweis.

`Linear budget headers` protokolliert auf Debug-Level erlaubte Request-/Endpoint-/
Complexity-Limit-, Remaining- und Resetwerte, `X-Complexity` und gültiges
`Retry-After`, auch bei erfolgreichen Antworten. `Linear rate limit paused` nennt
die gewählte lokale Deadline und Restpause. Vorhandene `issue_id`,
`issue_identifier` und `session_id` bleiben erhalten; Payloads, unbekannte Header
und Zugangsdaten werden nicht als Budgetdiagnose ausgegeben.

`[:symphony, :linear, :request]` liefert je tatsächlich ausgeführter Anfrage
`requests: 1`, Dauer, HTTP-Status (oder `transport_error`) und die erlaubten Antwortheader, gruppiert nach Workspace
und Anfrageart. Auch Exceptions, Exits und Throws aus einem begonnenen Transport
erzeugen genau eine `transport_error`-Messzeile ohne Fehlerinhalt; ihre bisherige
Weitergabe bleibt erhalten. Lokal unterdrückte Anfragen zählen nicht. Für kontrollierte
Messläufe aktiviert die vertrauenswürdige Runtime
`Application.put_env(:symphony_elixir, :linear_budget_measurements, true)` und
Debug-Logging; `Linear request measurement=` enthält dann dieselben Daten als
JSON. `scripts/linear-budget-report.py <log>` fasst diese Datensätze zusammen.
Fehlende `X-Complexity`-Header werden durch die separate Stichprobenzahl sichtbar,
nicht als gemessener Nullverbrauch gewertet. Normale CLI-/MCP-Ausgabe bleibt frei
von Messdatensätzen. Relay-Zustandslogs enthalten Workspace, Betriebszustand und
einen sekretfreien Fehlercode; Receipts, Snapshot-Tokens und Ereignispayloads
gehören nicht in Logs.

`[:symphony, :relay, :request]` zählt tatsächliche Transportaufrufe je Workspace
und `register`/`poll`/`ack`/`resync`, einschließlich HTTP-Fehlern und
Transportabbrüchen. Lokale Key-/Konfigurationsfehler zählen nicht als HTTP.
`symphony-PRO-716 --budget-capture /ABS/run.json` aktiviert
`SymphonyElixir.BudgetCapture` ausschließlich im Testprozess vor Discovery/Auth
bis zum Shutdown. Der bestehende Recorder zeichnet beide Ereignisse synchron als
`Budget capture=`-JSONL auf: fortlaufende Sequenz, monotone Messzeit, UTC-Zeit,
Phase, Dauer und erlaubte Metadaten. Die Datei wird exklusiv erstellt und an
Phasengrenzen synchronisiert; kein Debug-Level oder rotierendes Log nötig.
Ein verlorener Telemetry-Handler, fehlendes Ende oder eine fehlgeschlagene Aktion
verhindert einen vollständigen Capture. Der Recorder erfasst den aktuellen
BEAM-Prozess; andere App-Prozesse müssen separat erfasst/ausgewiesen werden.
Aufruf, Lastvertrag und Wiederherstellung stehen unter
[Operator-Messübergabe](linear-app.md#ausführbare-operator-messübergabe-pro-716).
