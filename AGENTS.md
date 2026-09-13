# Symphony Elixir

Dieses Verzeichnis enthält den in Elixir geschriebenen Orchestrierungsdienst für Agents. Er pollt Linear, legt pro Ticket isolierte Workspaces an und startet Codex im App-Server-Modus.

## Umgebung

- Elixir: `1.19.x` (OTP 28) via `mise`
- Abhängigkeiten installieren: `mix setup`
- Wichtigstes Qualitäts-Gate: `make all` (Format-Check, Lint, Coverage, Dialyzer)

## Projektspezifische Konventionen

- Die Laufzeitkonfiguration wird über den Front-Matter von `WORKFLOW.md` via `SymphonyElixir.Workflow` und `SymphonyElixir.Config` geladen.
- Wenn [SPEC.md](SPEC.md) im Worktree vorhanden ist, halte die Implementierung nach Möglichkeit damit in Einklang.
  - Die Implementierung darf eine Obermenge der Spezifikation sein.
  - Die Implementierung darf der Spezifikation nicht widersprechen.
  - Wenn Implementierungsänderungen das beabsichtigte Verhalten wesentlich verändern, aktualisiere nach Möglichkeit die Spezifikation im selben Change, damit sie aktuell bleibt.
- Führe neue Konfigurationszugriffe bevorzugt über `SymphonyElixir.Config` ein, statt Umgebungsvariablen ad hoc direkt zu lesen.
- Workspace-Isolation gilt für reguläre Workflow-Schritte:
  - Reguläre Workspaces müssen unterhalb des konfigurierten Workspace-Roots bleiben.
  - Der Status `Todo (Dialog-AI)` ist davon bewusst ausgenommen: Codex läuft dort aus dem Projektroot, erstellt keinen Worktree und darf keine Code-, Dokumentations- oder Konfigurationsänderungen vornehmen.
- Das Verhalten des Orchestrators ist zustandsbehaftet und nebenläufigkeitssensibel. Bewahre daher die Semantik für Retries, Reconciliation und Cleanup.
- Folge für Logging-Konventionen und die erforderlichen Issue-/Session-Kontextfelder der Datei `docs/logging.md`.
- Verwende echte deutsche Umlaute, also z.B. ä statt ae

## Tests und Validierung

Führe während der Iteration gezielte Tests aus und vor der Übergabe die vollständigen Gates.

```bash
make all
```

## Verbindliche Regeln

- Öffentliche Funktionen (`def`) in `lib/` müssen ein direkt benachbartes `@spec` haben.
- `defp`-Specs sind optional.
- Callback-Implementierungen mit `@impl` sind von der lokalen `@spec`-Pflicht ausgenommen.
- Halte Änderungen eng am Scope; vermeide nicht zusammenhängende Refactorings.
- Folge den bestehenden Modul- und Stilmustern in `lib/symphony_elixir/*`.

Validierungsbefehl:

```bash
mix specs.check
```

## Dokumentationspolitik

Wenn sich Verhalten oder Konfiguration ändern, aktualisiere die Dokumentation im selben PR:

- `WORKFLOW.md` für Änderungen am Workflow- oder Konfigurationsvertrag

`WORKFLOW.md` ist Startkontext und zentraler Agentenvertrag. Ergänze nur
notwendige, präzise, kompakte und widerspruchsfreie Regeln mit minimalem Delta.
Keine Ticketchronik, Debug-Erzählungen, Implementierungsdetails oder Dopplungen;
benötigte Details gehören in vorhandene passende Docs oder zuständige Skills,
mit gezieltem Verweis, soweit für die Aufgabe nötig. Prüfe bei jeder Änderung
das notwendige Delta und die Gesamtwirkung auf den Startkontext; Pflichtgates
und Verhaltensgrenzen müssen vollständig erhalten bleiben.
