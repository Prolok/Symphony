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
