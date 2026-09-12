# Symphony

Symphony ist ein deutschsprachiger, bewusst vorstrukturierter Fork von OpenAI Symphony fuer Teams, die Coding Agents nicht nur einsetzen, sondern verlässlich in ihren Entwicklungsprozess einbinden wollen. Das Projekt funktioniert besonders gut in Codebasen, die [Harness Engineering](https://openai.com/index/harness-engineering/) bereits eingefuehrt haben. Ziel ist der naechste Schritt nach dem reinen Einsatz einzelner Agents: weg vom Verwalten von Coding Agents, hin zur Orchestrierung konkreter Arbeit, die erledigt werden muss.

![Symphony Dashboard](.github/media/elixir-screenshot.png)

## Was dieses Repository macht

Dieses Repository enthaelt den Elixir-basierten Orchestrator von Symphony. Der Dienst:

- pollt Linear regelmaessig nach Tickets in aktiven Stati,
- legt für reguläre Workflow-Tickets einen isolierten Git-Worktree an,
- startet Codex pro regulärem Ticket in einem eigenen Workspace,
- steuert den Ablauf ueber eine zentrale, versionierte `WORKFLOW.md`,
- und stellt Beobachtbarkeit ueber Dashboard, Logs und API bereit.

Dadurch wird aus einzelnen Agentenlaeufen ein reproduzierbarer, repo-eigener Arbeitsprozess.

## Unterschiede zur Originalversion

Gegenueber OpenAI Symphony legt dieser Fork den Schwerpunkt auf einen deutschsprachigen, klar gefuehrten Team-Workflow:

- Deutsche Sprache in Workflow, Skills und Projektdokumentation
- Eine zentrale `WORKFLOW.md` als verbindlicher Workflow- und Prompt-Vertrag
- Git-Worktrees als Standard für isolierte Ticket-Workspaces
- Gemeinsame Workflow-Skills mit repository-spezifischen Hinweisen und Checklisten

Der Sonderstatus `Todo (Dialog-AI)` ist davon ausgenommen: Er nutzt
`WORKFLOW_DIALOG.md` für dialogische Vorplanung, erstellt keinen Worktree,
führt keine Hooks aus und startet Codex im Projektroot. Die Dialoganweisung
untersagt Repository-Änderungen; Symphony prüft nach dem Turn den Git-Status.
Wenn ein zuvor vorgeschlagenes Umsetzungsticket ausdrücklich bestätigt wird,
darf der Dialog-AI-Pfad dieses Ticket in Linear erstellen, verknüpfen und das
Ursprungsticket nach `Umsetzungsticket erstellt` verschieben.

## Eine Instanz für alle Projekte

Eine Symphony-Instanz pro Entwicklerrechner entdeckt alle direkten Unterverzeichnisse
mit `.symphony` unter `SYM_PROJECT_ROOT`. Die Variable steht in `.env` bzw.
`.env.local` im Symphony-Code-Root; Standard ist `~/QuantHub`, mehrere Roots werden
mit Komma getrennt, etwa `~/QuantHub,~/ProjectHub`. Pfade werden normalisiert und
dedupliziert. Verschachtelte Worktrees werden nicht durchsucht.

Jedes Projekt behält seine `.symphony/.env(.local)`, eigenen Hooks, Worktrees,
Sessions und Journale. Ein gemeinsamer Kandidatenrequest pro Linear-Workspace und
API-Seite verknüpft die Scope-, Status- und Assignee-Auswahl projektweise.
Innerhalb eines Workspaces müssen alle Projekte dieselbe verifizierte App-Bindung
und dieselben Client Credentials verwenden. Widersprüche stoppen den Start.
Verschiedene Workspaces werden getrennt abgefragt.
Worktree-Roots müssen je Projekt getrennt sein; gleiche oder ineinander liegende
Pfade werden beim Start abgewiesen. `workspace.root: $SYMPHONY_PROJECT_WORKTREES_ROOT`
liefert einen projektspezifischen Root. Gesamt-, Status- und SSH-Hostlimits gelten
gemeinsam für den Dienst.

Symphony unterstützt ausschließlich OAuth2 Client Credentials. Persönliche API-Keys,
PKCE und Legacy-Workflows sind keine Authentifizierungswege. Die
[Betriebsanleitung](docs/linear-app.md) beschreibt Einrichtung und einmalige
Betreiberübergabe vorhandener Daten.

## Installation und Inbetriebnahme

### Voraussetzungen

- Linux (Ubuntu 24.04) oder macOS 26; die CI prüft Ubuntu x86_64 und macOS
  arm64 mit `make all` für Dependabot-Updates und andere Nicht-Symphony-PRs.
  Bei `symphony/*`-PRs wird der CI-Testjob vor der Matrixausführung übersprungen;
  maßgeblich bleibt das lokale `make all` in `Test (AI)`. Ältere OS-Versionen
  sind nicht Teil dieser Testmatrix.
- Bash ab 3.2: Auf macOS genügt `/bin/bash` mit den BSD-Systemwerkzeugen;
  GNU-Coreutils und ein externes `flock` sind nicht erforderlich.
- `mise` ab 2026.3.17 und die installierte Toolchain aus `mise.toml`
  (Erlang/OTP 28, Elixir 1.19.5 für OTP 28)
- Git ab 2.31, Python ab 3.11 als `python3`, Make und Codex CLI im `PATH`
- Build-Werkzeuge: unter macOS die Xcode Command Line Tools
  (`xcode-select --install`), unter Ubuntu `build-essential`. Für lokale
  Plattformtests zusätzlich zsh; sie führen die Hilfsbefehle aus Bash und
  zsh aus.
- Zugriff auf Linear
- Fuer den vollen PR- und Merge-Ablauf zusaetzlich `gh`

Das automatische `make all` benötigt keine echten Linear-/OpenAI-Zugangsdaten
oder privaten `.env.local`-Dateien. Authentifizierungs- und Prozessfälle nutzen
kontrollierte Testgegenstellen mit synthetischen Credentials. Echte End-to-End-
Tests (`SYMPHONY_RUN_LIVE_E2E=1`) und tokenfreie Codex-Starttests
(`SYMPHONY_TEST_REAL_CODEX=1`) sind separate Opt-ins und gehören nicht zur
Dependabot-CI; der verpflichtende Produkt-Smoke erfolgt im Symphony-Ablauf.

### Einrichtung

1. Im Symphony-Checkout die konfigurierte Laufzeit und Abhängigkeiten installieren:

   ```bash
   mise trust
   mise install
   ./scripts/mix-gate setup
   ```

2. In jedem Fachprojekt die öffentliche App-/Projektbindung in `.symphony/.env`
   konfigurieren: `LINEAR_APP_CLIENT_ID`, `LINEAR_APP_WORKSPACE_ID`,
   `LINEAR_APP_USER_ID` und genau einen Scope (`LINEAR_PROJECT_SLUG` oder
   `LINEAR_TEAM_KEY`). Die [Projektvorlage](.symphony/.env) enthält die Felder.
   Das Client-Secret `LINEAR_APP_SECRET` und persönliche Zuständigkeiten stehen
   ausschließlich in der privaten `.symphony/.env.local`.

   `LINEAR_ASSIGNEE` akzeptiert mehrere menschliche E-Mail-Adressen oder UUIDs,
   etwa `person@example.com,second@example.com`; Leerzeichen und Duplikate werden
   entfernt. App-Identitäten und `me` sind nicht zulässig. Verschiedene Rechner
   verwenden getrennte Assignee-Auswahlen. `--yolo` berücksichtigt wie bisher alle
   passenden Issues unabhängig von der Zuständigkeit.

   Projekt-Scope begrenzt auf ein Linear-Projekt; Team-Scope auf das exakte Team
   einschließlich Issues ohne Projekt. Beide Scopes zugleich oder kein Scope
   ergeben einen Konfigurationsfehler. Projektbindungen ändern sich erst mit einem
   neuen Dienststart. Hooks erhalten den richtigen Projektroot; Create-/Remove-
   Hooks kommen aus dessen `.symphony`-Verzeichnis.

   Zustand liegt unter `<Projekt>/.symphony/state`; die interne Kennung lautet
   immer `symphony`. `LINEAR_APP_INSTALLATION_ID` ist keine Benutzereinstellung.
   Vorhandene abweichende Zustandsverzeichnisse werden mit konkretem
   [Übergabehinweis](docs/linear-app.md#einmalige-betreiberübergabe) abgewiesen,
   nicht automatisch verändert oder gelöscht.

   `sym-codex Projekt:PRO-123` und `sym-watch Projekt:PRO-123` erlauben eine
   eindeutige Projektqualifizierung. Eine unqualifizierte Kennung verwendet den
   vorhandenen Projektkontext bzw. muss projektübergreifend eindeutig sein.
   Mehrdeutige Kennungen werden abgewiesen. Die Oberfläche zeigt beispielsweise
   `Projects: QuantInvest, LinearBridge`.

   Das von `sym-codex` verwendete Codex-Startprofil wird dagegen aus `.env`
   und optional `.env.local` im ursprünglichen Symphony-Root geladen, nicht aus
   `.symphony/.env(.local)`. Ein isolierter Release hält die nicht geheimen
   Werte in seinem versiegelten Root-Konfigurationssnapshot fest. Unterstützt werden:
   - `SYM_CODEX_MODEL`, Standard `gpt-6-astra`
   - `SYM_CODEX_REASONING_EFFORT`, Standard `xhigh`; zusätzliche unterstützte
     Werte umfassen `max` und `ultra`
   - `SYM_CODEX_SERVICE_TIER`, Standard `flex`
   - `SYM_CODEX_HUMAN_SERVICE_TIER`, Standard `priority`

   Die Präzedenz ist: explizite Shell-Umgebung vor `.env.local` vor `.env` vor
   eingebauten Defaults. Observer-Starts übergeben `SYM_CODEX_SERVICE_TIER` als
   `service_tier`; interaktive/manuelle Starts übergeben stattdessen
   `SYM_CODEX_HUMAN_SERVICE_TIER`.

   `SYM_MAXIMUM_REVIEW_ITERATIONS=3` in derselben Root-`.env` begrenzt die
   Reviewrunden pro Aufenthalt in `Review (AI)`, einschließlich Erst-Review.
   Es gilt dieselbe Präzedenz; erlaubt sind positive Ganzzahlen, ungültige
   oder leere Werte brechen den Promptbau mit einem Konfigurationsfehler ab.
   `Config` übergibt den Wert vor manuellen und orchestrierten Starts an den
   Review-Skill. Dieser führt das Budget im Workpad über Fortsetzungen hinweg
   und behandelt auch die letzten Findings vor der bestehenden Übergabe.
   Das ist eine Skill-Anweisung, kein technisch erzwungener Subagent-Zähler.
   Die Dateien werden am Symphony-Checkout gelesen, auch bei externer
   Workflowdatei; Projektdateien unter `.symphony/` setzen diesen Schlüssel nicht.

3. Symphony starten:

   ```bash
   ./symphony
   ```

Der reguläre Einstieg ist `./symphony`. Ein nichtblockierender OS-Lock unter
`~/.cache/symphony/service.lock` verhindert weitere Dienststarts desselben Benutzers
aus anderen Checkouts oder mit anderen Ports. Der Zweitstart endet sofort mit
„Symphony läuft bereits“, vor Build, Linkregistrierung oder Dispatch. Der Lock wird
über das Dienstende hinaus nicht gehalten; die Lockdatei bleibt bestehen. Manuelle
Helfer starten keinen zweiten Dienst. Danach prüft der Wrapper die benötigten
Werkzeuge und die installierte Toolchain und aktiviert `mise.toml` ausschließlich
für den laufenden Prozess und seine Kinder. Ein aktiviertes Shellprofil oder ein
schon global erreichbares `escript` ist nicht nötig. Fehlende Voraussetzungen
brechen vor Autoupdate, Build und Registrierung der Hilfsbefehle ab.

Danach serialisiert der Wrapper Autoupdate und Build über einen OS-Lock aus der
Python-Standardbibliothek. Die Lockdatei liegt im jeweiligen Git-Verzeichnis,
bei Worktrees in deren eigenem Git-Verzeichnis; außerhalb von Git liegt sie in
`_build/.symphony-start.lock`. Verschiedene Checkouts blockieren sich nicht.
SIGINT/SIGTERM werden an die Build-Prozessgruppe weitergegeben; nach spätestens
fünf Sekunden werden verbleibende Build-Kinder beendet. Der Kernel gibt den
Lock beim Schließen frei; die Lockdatei bleibt bestehen und muss nicht gelöscht
werden. Der gestartete Dienst erbt keinen Lock.

Innerhalb dieses Locks prüft Symphony zunächst, ob der aktuelle Git-Upstream
einen neueren Commit enthält. Wenn eine neue Version verfügbar ist, fragt
Symphony `Neue Symphony Version verfügbar. Update ausführen j/n?`; bei Zustimmung
führt das Autoupdate `git pull --ff-only` und anschließend
`make all` aus und zeigt währenddessen `Symphony Update läuft…`.
Eine durch das Update geänderte Toolchain wird vor dem Gate und Build erneut
geprüft und aktiviert.

Unabhängig davon, ob ein Update verfügbar oder angenommen wurde, folgt im selben
Lock ein selbstheilender Preflight. `mix deps.loadpaths --no-compile` prüft den
lokalen Dependency-Zustand; bei einer Abweichung folgt `mix deps.get`. Danach
kompiliert Symphony den Checkout und baut `bin/symphony` mit `mix escript.build`.
Erst nach erfolgreichem Build wird der Lock freigegeben. Der Wrapper bindet
Workflow, Skills, Helfer, Build und nicht geheime Root-Konfiguration an den
eigenen Release und startet dessen Binary. Globale Links werden nicht ersetzt. Ein nicht reparierbarer
Dependency-, Compile- oder Escript-Build-Fehler beendet den Start vorher; in
diesem Fall beginnt kein Ticket-Polling. Das Dashboard ist standardmäßig unter
`http://127.0.0.1:4000/` erreichbar; mit `--port <port>` kann der Startport
überschrieben werden. Wenn dieser Port bereits belegt ist, verwendet Symphony
automatisch den nächsten freien Port.

Für den direkten Aufruf des Build-Artefakts muss Erlang bereits aktiv sein,
zum Beispiel `mise exec -- bin/symphony`. `bin/symphony` alleine aktiviert
keine Laufzeit und benötigt `escript` im `PATH`; es übernimmt auch keinen
Autoupdate-/Build-Preflight. Der Standard-Worker wird auch hier über den
absoluten Helferpfad des ermittelten Symphony-Checkouts gestartet; ein globaler
`sym-codex`-Link ist dafür nicht erforderlich.

Symlinks und Pfade mit Leerzeichen werden unterstützt. Ein Aufruf aus einem
anderen Projektverzeichnis behält dieses als Projekt-CWD; Workflow-Dateien,
Abhängigkeiten und Build-Artefakte gehören zum aufgelösten Symphony-Checkout.
Reguläre Release-Starts registrieren keine neuen globalen Ticketbefehle.
Für einen manuellen Ticketstart verwende aus dem Fachprojektroot den absoluten
`sym-codex`-Pfad des gewünschten Symphony-Checkouts mit der Ticket-ID, etwa
`/pfad/zu/Symphony/sym-codex PRO-678`. Dieser Einstieg wählt den Worktree und
bereitet im App-Modus einen eigenen gebundenen Release vor.
Nur Hooks außerhalb eines Releases registrieren weiterhin
`symphony-<Ticket-ID>` und `sym-codex-<Ticket-ID>` unter `~/.local/bin`;
bestehende Befehle bleiben an ihre bisherige Installation gebunden. Cleanup
entfernt nur passende Links. Die ausführbaren Skripte funktionieren in Bash
und zsh; zusätzliches Sourcing von `sym-codex` wird nur in Bash unterstützt.
Auch beim App-Release-Start bleibt diese Shell danach im gewählten Worktree
mit aktivierter Projekt-Venv; der Rückgabecode von Codex bleibt erhalten.

Mix-Artefakte werden nicht zwischen Git-Checkouts geteilt. Jeder Haupt-Checkout
und jeder Worktree verwendet sein eigenes `deps` und `_build`; insbesondere
bleibt `_build` immer checkout-lokal. `symphony`, `autoupdate`, `sym-codex`,
`sym-codex-mcp`, `sym-watch` und `scripts/mix-gate` entfernen deshalb geerbte
`MIX_DEPS_PATH`-, `MIX_BUILD_ROOT`- und `MIX_BUILD_PATH`-Werte für ihre Mix-
beziehungsweise Codex-Child-Prozesse. Der gemeinsame Helfer
`scripts/mix-runtime` ergänzt
`mise.toml` nur prozesslokal zu `MISE_TRUSTED_CONFIG_PATHS` und führt Mix aus dem
jeweiligen Checkout aus.

`SYMPHONY_WORKFLOW_DIR` bezeichnet dabei den Symphony-Checkout mit dem
ausführbaren Mix-Projekt, während `SYMPHONY_WORKFLOW_FILE` die aktuell geladene
Workflowdatei bezeichnet und unabhängig davon an einem anderen Ort liegen
kann. Reguläre Läufe auf SSH-Workern setzen wie die Remote-Workspace-Hooks
voraus, dass Symphony- und Projektroot auf dem Worker unter denselben absoluten
Pfaden verfügbar sind. Die isolierten Docker-Worker der Live-E2E-Tests prüfen
nur den hook-freien SSH-/App-Server-Transport und bilden keinen vollständigen
Repository-, Test- oder Merge-Worker ab.

Nach jedem abgeschlossenen Linear-Poll plant Symphony den nächsten automatischen Refresh mit `polling.interval_ms` multipliziert mit der Anzahl laufender `bin/symphony`-Instanzen. Der konfigurierte Wert bleibt das Basisintervall; der Initial-Poll und manuelle Refresh-Anforderungen bleiben unmittelbar.

Für private, unbeaufsichtigte Projekte kann Symphony mit `./symphony --yolo` gestartet werden. In diesem Modus wird kein Assignee für das Routing benötigt, alle Tickets im konfigurierten Linear-Scope werden unabhängig vom Assignee bearbeitet, die Freigaben `Freigabe Implementierung` und `Freigabe Review` werden wie durch passende Skip-Labels übersprungen, und das Dashboard zeigt `--yolo` statt des Assignees. Der manuelle Status `Planung` wird auch im `--yolo`-Modus nicht übersprungen. Review-Findings müssen weiterhin vom Hauptagenten behandelt und dokumentiert werden; nach dieser Behandlung überspringt `--yolo` aber auch `Freigabe Review`.

Das Linear-Label `Requires Manual Review` ist davon unabhängig: Es ist kein internes Symphony-Skip-Label, sondern ein externes GitHub-Merge-Gate im Status `Merge (AI)`. Wenn das Label gesetzt ist, muss vor dem Merge ein menschliches GitHub-Approval eines Nicht-Autors auf der aktuellen PR-Head-SHA vorliegen. `--yolo` und `Skip "Freigabe Review"` umgehen dieses Gate nicht; das Label wird von Symphony weder automatisch angelegt noch nach Approval oder Merge entfernt.

Mit `./sym-watch <TicketId>` kann eine laufende Codex-Sitzung eines Tickets im Terminal verfolgt werden. Das Tool liest die Symphony-Observability-API, wartet bei fehlender Sitzung weiter und wechselt automatisch auf die nächste Sitzung desselben Tickets. Wenn Symphony nicht auf dem Standard-Dashboard `http://127.0.0.1:4000` läuft, kann die API-Basis mit `--url` oder `SYMPHONY_WATCH_URL` gesetzt werden.

### Qualitaetssicherung

Das wichtigste Projekt-Gate ist:

```bash
make all
```

Das Makefile führt Mix über `scripts/mix-gate` aus. Der Wrapper entfernt für
den Gate-Prozess bekannte geerbte `SYMPHONY_*`-Runtime-Variablen sowie
`MIX_DEPS_PATH`, `MIX_BUILD_ROOT` und `MIX_BUILD_PATH` und ergänzt
`MISE_TRUSTED_CONFIG_PATHS` prozesslokal um `<Checkout>/mise.toml`, falls die
Datei existiert. Ein dauerhaftes `mise trust` ist für `make all` nicht
erforderlich.
Der Gate-Wrapper normalisiert außerdem das temporäre Verzeichnis auf seinen
physischen Pfad, damit Skripte und Test-Fixtures unter macOS dieselbe Adresse
verwenden (`/var` und `/private/var` können auf dasselbe Verzeichnis zeigen).
Der Standardwert für `workspace.root` wird bei jeder Konfigurationsauflösung
aus dem aktuellen `System.tmp_dir!()` ermittelt, unabhängig vom Temp-Verzeichnis
beim Kompilieren.

Fuer die `@spec`-Pruefung steht zusaetzlich zur Verfuegung:

```bash
mix specs.check
```

## Dependency-Updates

Die Dependabot-Konfiguration in `.github/dependabot.yml` deckt die von GitHub
unterstuetzten Paketquellen dieses Repositories ab:

- `mix` fuer `mix.exs` und `mix.lock` im Repo-Root
- `docker` fuer `test/support/live_e2e_docker/Dockerfile`

Nicht automatisch durch Dependabot aktualisierbar sind aktuell:

- Toolchain-Versionen in `mise.toml`
- `apt-get`-Installationen im Dockerfile
- globales `npm install --global @openai/codex` im Dockerfile

## Workflow

Der Ablauf trennt bewusst zwischen automatisierten AI-Phasen und manuellen Klärungs- bzw. Freigabepunkten. `Planung` ist der manuelle Klärungspunkt, wenn `Planung (AI)` oder die spätere Umsetzung offene Verständnis-, Umsetzungs- oder Produktverhaltensfragen feststellt. `Review` bleibt die manuelle Abschlussstation nach dem Merge.
Wenn für einen Status ein passendes Label `Skip "<Status>"` gesetzt ist, verschiebt Symphony das Issue zum nächsten nicht übersprungenen Status und beendet den aktuellen Codex-Turn; der Zielstatus startet in einer neuen Session. Das gilt für die Freigabepunkte `Freigabe Implementierung` und `Freigabe Review`. Für `Planung` gibt es kein Skip-Label. Im `--yolo`-Modus gelten nur `Freigabe Implementierung` und `Freigabe Review` als übersprungen. Review-Findings, Review-Fixes, Dirty-Workspace oder uneindeutige No-Findings-Signale verhindern nicht den expliziten Skip von `Freigabe Review`; sie verhindern nur, dass ein wiederhergestelltes finales `Keine Findings.` ohne Hauptagenten-Fortsetzung nach `Test (AI)` verschoben wird.

`Requires Manual Review` verändert diese interne Skip-Semantik nicht. Es wird case-insensitive und trim-normalisiert erkannt und erst im Merge-Pfad geprüft, nachdem PR-/Remote-Preflight, Mergebarkeit, Review-Feedback und GitHub-Checks akzeptabel sind. Fehlt dann ein gültiges menschliches Approval auf der aktuellen PR-Head-SHA, dokumentiert Symphony den Blocker im Workpad, erzeugt keine Merge-Evidenz, führt keinen Merge-Versuch aus und verschiebt das Issue nach `BLOCKER`.
Kann Symphony den aktuellen Linear-Labelstand in diesem Merge-Pfad nicht sicher verifizieren, blockiert der Merge ebenfalls fail-closed vor jedem Merge-Versuch. Dieser Blocker behauptet nicht, dass `Requires Manual Review` gesetzt ist, sondern dokumentiert den fehlgeschlagenen Label-Lookup und verlangt eine Wiederholung nach behobener Label-Abfrage.

Zusätzlich überspringt ein abgeschlossener `Review (AI)` ohne Findings den Freigabepunkt `Freigabe Review` nur dann automatisch, wenn der Workspace nach dem Review sauber ist, und verschiebt nach `Test (AI)`; auch dabei endet der aktuelle Turn. Offene, fehlende oder nicht explizite Checklistenpunkte im Workpad-Abschnitt `### Review` bedeuten, dass der Review noch nicht abgeschlossen ist; Symphony führt dann keinen Review-Handoff aus und bleibt in `Review (AI)`. Sobald der Review Findings oder Änderungen hinterlässt, diese Evidenz in kombinierten Nach-Fix-Kommentaren pro behandeltem Finding oder im Workpad-Verlauf dokumentiert ist, Workspace-Evidenz fehlt oder das No-Findings-Signal nicht eindeutig ist, führt der Review-Handoff ohne Skip-Label nach `Freigabe Review`. Mit `--yolo` oder `Skip "Freigabe Review"` verschiebt er nach der erforderlichen Finding-/Fix-Behandlung nach `Test (AI)` und beendet den Turn.

| Status | Rolle | Zweck | Regulaerer Uebergang |
| --- | --- | --- | --- |
| `Backlog` | Mensch | Ticket liegt noch ausserhalb der Automatisierung. | `Todo (AI)` |
| `Todo` | Mensch | Nicht automatisiertes Benutzer-Todo ausserhalb des Symphony-Scopes. | bleibt offen bis zum naechsten AI-Status |
| `Todo (AI)` | AI | Ticket wartet auf den Start der Bearbeitung. | `Planung (AI)` |
| `Todo (Dialog-AI)` | AI | Dialogische Vorplanung über `WORKFLOW_DIALOG.md` ohne Worktree, Hooks oder Repository-Änderungen; Antworten laufen als Linear-Kommentare. Bei ausdrücklicher Bestätigung darf der Dialog-AI-Pfad ein Umsetzungsticket erstellen, verknüpfen und das Ursprungsticket verschieben. | `Umsetzungsticket erstellt` nach erfolgreicher bestätigter Ticketerstellung; sonst bleibt es bis zu externem Statuswechsel oder neuer Benutzeranfrage |
| `Umsetzungsticket erstellt` | Abschluss | Ursprungsticket nach erfolgreicher Umsetzungsticket-Erstellung aus `Todo (Dialog-AI)`; keine weitere Automatisierung. | - |
| `Planung (AI)` | AI | Ticketbeschreibung sowie Plan und Validierung vorbereiten und entscheiden, ob autonome Umsetzung möglich ist. | `In Arbeit (AI)` oder `Planung` |
| `Planung` | Mensch | Manueller Klärungs- und Planschärfungspunkt mit von Codex empfohlenen Lösungsvorschlägen. | `In Arbeit (AI)` oder `Planung (AI)` |
| `In Arbeit` | Mensch | Manueller Worktree-/Hook-Bootstrap: Symphony erstellt Workspace/Worktree inklusive `after_create`-Hook, startet keinen Codex und ändert den Status nicht. | bleibt offen bis zum nächsten AI-Status |
| `In Arbeit (AI)` | AI | Umsetzung auf Basis des vorbereiteten Plans, bei nicht-funktionalen Erkenntnissen begründete Plananpassung; produkt-/verhaltensrelevanter Klärungsbedarf geht nach `Planung`. | `PreReview (AI)` oder `Planung` |
| `PreReview (AI)` | AI | Repository-spezifischer PreReview-/Fix-Zyklus. | `Freigabe Implementierung` |
| `Freigabe Implementierung` | Mensch | Manueller Review- und Commit-Schritt nach der Umsetzung. | `Review (AI)` oder `In Arbeit (AI)` oder `Planung (AI)` |
| `Review (AI)` | AI | Gemeinsamer Review-/Fix-Zyklus mit repositoryspezifischen Review-Hinweisen. | ohne Findings und mit sauberem Workspace `Test (AI)`; mit Findings/Fixes/unklarer Evidenz ohne Skip `Freigabe Review`, mit Skip/`--yolo` `Test (AI)` |
| `Freigabe Review` | Mensch | Manueller Freigabepunkt der reviewten Version vor dem Test-/Merge-Zyklus. | `Test (AI)` oder `In Arbeit (AI)` oder `Planung (AI)` |
| `Test (AI)` | AI | Vor den Tests per Pull auf den spaeteren Merge-Stand synchronisieren und den Test-/Fix-Zyklus auf diesem Stand ausfuehren. | `Merge (AI)` |
| `Merge (AI)` | AI | PR beobachten, GitHub-Checks gemäß Policy bewerten, bei `Requires Manual Review` ein gültiges menschliches GitHub-Approval auf der aktuellen PR-Head-SHA verlangen und den Branch landen; bei mergebedingten Codeänderungen zurück nach `Test (AI)`. | `Review` oder bei fehlendem manuellem Approval beziehungsweise nicht verifizierbarem Labelstand `BLOCKER` |
| `BLOCKER` | Mensch | Kritische Abweichung oder externer Blocker; keine weitere Automatisierung, bis das Problem manuell geloest ist. | wartet auf menschliches Verschieben |
| `Abbruch (AI)` | AI | Stoppt laufende Arbeit und fuehrt Cleanup aus. | `Abgebrochen` |
| `Review` | Mensch | Manueller Endstatus nach dem Merge, bevor das Ticket ganz abgeschlossen wird. | `Fertig` |
| `Fertig` | Abschluss | Ticket ist abgeschlossen. | - |
| `Abgebrochen` | Abschluss | Ticket wurde bewusst verworfen oder bereinigt. | - |

Der typische Pfad ist damit:

`Todo (AI)` -> `Planung (AI)` -> `In Arbeit (AI)` -> `PreReview (AI)` -> `Freigabe Implementierung` -> `Review (AI)` -> `Freigabe Review` -> `Test (AI)` -> `Merge (AI)` -> `Review` -> `Fertig`

Wenn `Planung (AI)` oder die spätere Umsetzung Klärungsbedarf erkennt, verläuft der Pfad stattdessen über `Planung`; dort prüft der Benutzer die offenen Fragen und die empfohlenen Lösungsvorschläge und verschiebt das Ticket anschließend manuell weiter.

## Zentrale Dateien

- `WORKFLOW.md`: Workflow, Prompt-Vertrag und Runtime-Konfiguration
- `AGENTS.md`: Repository-spezifische Regeln für Codex
- `docs/`: ergänzende Implementierungsnotizen, aktuell zu Logging und Token Accounting
- `.codex/skills/`: mitgelieferte Codex-Skills; `symphony-*`-Skills definieren gemeinsame Workflow-Abläufe, `sym-*`-Skills repositoryspezifische Ergänzungen

## Gemeinsame Wissensbasis ohne lokales Codex-Memory

Frische Symphony-/Codex-Prozesse erzwingen `features.memories=false`,
`memories.generate_memories=false` und `memories.use_memories=false`.
Persönliche Memory-Dateien werden weder importiert noch gelöscht. Die
gemeinsame Wissensbasis bilden versionierte AGENTS-, Workflow-, Skill- und
Projektdateien sowie Ticket und Workpad. Der Release übernimmt seine
versionierten Skills; persönliche lokale Skill-Erweiterungen werden nicht
in den gemeinsamen Lauf importiert. Gesprächs-/Session-History, Wiederaufnahme
und Tracker-/Journalzustand bleiben erhalten. Bereits geladener Alt-Kontext
wird dadurch nicht rückwirkend entfernt.
