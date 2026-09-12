---
name: debugging
description:
  Untersuche hängende Läufe und Ausführungsfehler über Symphony- und
  Codex-Logs mit Issue-/Session-IDs; nutze den Skill bei Hängern,
  Wiederholschleifen oder unerwarteten Fehlschlägen im Symphony-Projekt.
---

# Debugging

## Ziele

- Finde heraus, warum ein Lauf hängt, wiederholt oder fehlschlägt.
- Ordne eine Linear-Issue-Identität schnell einer Codex-Session zu.
- Lies die richtigen Logs in der richtigen Reihenfolge, um die Ursache zu
  isolieren.

## Logquellen

- Primäres Runtime-Log: `<logs-root>/log/symphony.log`
  - Der Standard-Logs-Root ist das Start-CWD des gemeinsamen Dienstes;
    `SymphonyElixir.LogFile` hängt `log/symphony.log` darunter an. Alle
    entdeckten Projekte schreiben in dieses gemeinsame Log.
    `symphony --logs-root <path>` setzt den Logs-Root für den Lauf um.
  - Enthält Orchestrator-, Agent-Runner- und Codex-app-server-Lifecycle-Logs.
- Rotierte Runtime-Logs: `<logs-root>/log/symphony.log*`
  - Prüfe sie, wenn der relevante Lauf älter ist.
- Ermittle zuerst das Start-CWD beziehungsweise den `--logs-root` des
  betroffenen Dienstlaufs. Führe die Beispielbefehle aus diesem Logs-Root aus
  oder ersetze `log/symphony.log*` durch `<logs-root>/log/symphony.log*`.
  Das Projektroot eines Tickets kann in einem anderen Verzeichnis liegen.

## Korrelationsschlüssel

- `issue_identifier`: menschlicher Ticket-Key (Beispiel: `MT-625`)
- `issue_id`: Linear-UUID (stabile interne ID)
- `session_id`: Codex-Thread-/Turn-Paar (`<thread_id>-<turn_id>`)

`docs/logging.md` verlangt diese Felder für Issue-/Session-Lifecycle-Logs.
Nutze sie beim Debugging als Join-Keys.

## Schnelle Triage (hängender Lauf)

1. Bestätige Scheduler-/Worker-Symptome für das Ticket.
2. Finde aktuelle Zeilen für das Ticket (zuerst `issue_identifier`).
3. Ziehe `session_id` aus passenden Zeilen.
4. Verfolge diese `session_id` über Start-, Stream-, Abschluss-/Fehler- und
   Stall-Handling-Logs.
5. Ordne die Fehlerklasse zu: Timeout/Stall, app-server-Startfehler,
   Turn-Fehler oder Orchestrator-Retry-Schleife.

## Befehle

```bash
# 1) Nach Ticket-Key eingrenzen (schnellster Einstieg)
rg -n "issue_identifier=MT-625" log/symphony.log*

# 2) Bei Bedarf nach Linear-UUID eingrenzen
rg -n "issue_id=<linear-uuid>" log/symphony.log*

# 3) Session-IDs für dieses Ticket sammeln
rg -o "session_id=[^ ;]+" log/symphony.log* | sort -u

# 4) Eine Session Ende-zu-Ende verfolgen
rg -n "session_id=<thread>-<turn>" log/symphony.log*

# 5) Auf Hänger-/Retry-/Dialog-Finalisierungssignale fokussieren
rg -n "Issue stalled|scheduling retry|turn_timeout|turn_failed|Codex session failed|Codex session ended with error|Finalizing dialog issue after repository guard error|Finalizing dialog issue after non-interactive turn error|Finalizing dialog issue after dialog session error" log/symphony.log*
```

## Untersuchungsablauf

1. Lokalisiere den Ticket-Ausschnitt:
    - Suche nach `issue_identifier=<KEY>`.
    - Falls das zu viel Rauschen liefert, ergänze `issue_id=<UUID>`.
2. Stelle die Zeitleiste her:
    - Identifiziere das erste `Codex session started ... session_id=...`.
    - Verfolge danach `Codex session completed`, `ended with error` oder
      Worker-Exit-Zeilen.
3. Klassifiziere das Problem:
    - Stall-Schleife: `Issue stalled ... restarting with backoff`.
    - app-server-Start: `Codex session failed ...`.
    - Turn-Ausführungsfehler: `turn_failed`, `turn_cancelled`,
      `turn_timeout` oder `ended with error`.
    - Worker-Absturz: `Agent task exited ... reason=...`.
4. Prüfe den Scope:
    - Ermittle, ob die Fehler auf ein Issue/eine Session begrenzt sind oder
      mehrere Tickets betreffen.
5. Sichere Belege:
    - Speichere die relevanten Logzeilen mit Zeitstempeln, `issue_identifier`,
      `issue_id` und `session_id`.
    - Halte die wahrscheinliche Ursache und die exakte Fehlerphase fest.

## Codex-Session-Logs lesen

In Symphony werden Codex-Session-Diagnosen in `log/symphony.log` ausgegeben und
über `session_id` verknüpft. Lies sie als Lifecycle:

1. `Codex session started ... session_id=...`
2. Session-Stream-/Lifecycle-Events für dieselbe `session_id`
3. Terminales Event:
    - `Codex session completed ...`, oder
    - `Codex session ended with error ...`, oder
    - `Issue stalled ... restarting with backoff`

Für die Untersuchung einer konkreten Session halte den Trace eng:

1. Erfasse eine `session_id` für das Ticket.
2. Baue einen Zeitstempel-Ausschnitt nur für diese Session:
    - `rg -n "session_id=<thread>-<turn>" log/symphony.log*`
3. Markiere die exakte Fehlerphase:
    - Startfehler vor Stream-Events (`Codex session failed ...`).
    - Turn-/Runtime-Fehler nach Stream-Events (`turn_*` / `ended with error`).
    - Stall-Recovery (`Issue stalled ... restarting with backoff`).
4. Verbinde die Befunde mit `issue_identifier` und `issue_id` aus benachbarten
   Zeilen, damit du keine parallelen Retries vermischst.

Verbinde Session-Befunde immer mit `issue_identifier`/`issue_id`, damit keine
parallelen Läufe vermischt werden.

## Hinweise

- Bevorzuge `rg` gegenüber `grep`, weil große Logs schneller durchsucht werden.
- Prüfe rotierte Logs (`log/symphony.log*`), bevor du von fehlenden Daten
  ausgehst.
- Falls in neuen Log-Statements erforderliche Kontextfelder fehlen, richte sie
  an den Konventionen aus `docs/logging.md` aus.
