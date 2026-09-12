# Linear-App-Identität und gemeinsamer Dienst

Symphony ist ein internes Werkzeug mit einer aktuellen gemeinsamen Version und
OAuth2 Client Credentials als einzigem Authentifizierungsweg. Die Laufzeit nutzt
`grant_type=client_credentials` und `scope=read,write`. Es gibt keinen persönlichen,
PKCE- oder Legacy-Fallback. Ein App-Fehler bleibt sichtbar.

## Normale Einrichtung

Der Betreiber aktiviert Client Credentials für die Symphony-OAuth2-App in Linear.
Pro Fachprojekt stehen öffentliche Werte in `.symphony/.env`:

| Variable | Bedeutung |
| --- | --- |
| `LINEAR_APP_CLIENT_ID` | OAuth2 Client-ID |
| `LINEAR_APP_WORKSPACE_ID` | Erwartete Organisations-ID |
| `LINEAR_APP_USER_ID` | Erwartete App-User-ID |
| `LINEAR_PROJECT_SLUG` oder `LINEAR_TEAM_KEY` | Genau ein Projektscope oder exaktes Team |

Die private `.symphony/.env.local` enthält `LINEAR_APP_SECRET` und
`LINEAR_ASSIGNEE`. Die Datei darf nur für das Laufzeitkonto lesbar sein, etwa
mit Modus `0600`. Assignees sind kommagetrennte menschliche E-Mail-Adressen oder
UUIDs; Trimmen und Deduplizieren gelten für Polling, Dispatch und Reconciliation.
`me` und App-Identitäten sind unzulässig. Getrennte Entwicklerrechner verwenden
getrennte menschliche Zuständigkeiten; Issue-Leases sind hostlokal.

Im Symphony-Code-Root stehen `.env` und optional `.env.local` mit
`SYM_PROJECT_ROOT=~/QuantHub` oder beispielsweise `~/QuantHub,~/ProjectHub`.
Nur direkte Unterverzeichnisse mit `.symphony` werden entdeckt; normalisierte
Pfade werden dedupliziert, verschachtelte Worktrees werden nicht durchsucht.
Die Rootdateien enthalten außerdem astra/xhigh-Modellvorgaben, Service-Tiers und
Reviewbudget. Projektdateien überschreiben diese Rootvorgaben nicht.

## Projektbindung und Polling

Jedes Projekt bekommt einen unveränderlichen Kontext mit Scope, Assignees,
Workflow, Worktreepfad, Hookumgebung und lokalem Zustand. Parallele Worker wechseln
weder die prozessglobale Umgebung noch das gemeinsame Arbeitsverzeichnis.
Öffentliche Projektvariablen werden an Hooks und Worker weitergegeben; lokale
Codex-Kommando- und SSH-Konfigurations-Overrides verwenden ebenfalls diesen Kontext.
Ein akzeptierter Workflow-Reload erzeugt neue Snapshots für Polling und spätere
Worker. Laufende Worker behalten ihren Kontext; Identitäts-/Scope- und Worktreeroot-Wechsel
erfordern einen Neustart und ungültige Konfigurationen ersetzen keinen gültigen
Snapshot. Eine externe Workflowdatei bleibt vom Mix-/Release-Ausführungsroot getrennt.
Die gemeinsame Dashboard-Konfiguration übernimmt akzeptierte Reloads aus einem
an die Poller-Laufzeit gebundenen Snapshot, einschließlich des geltenden Gesamtlimits.
Gesamt-, Status- und SSH-Hostkapazität werden über alle Projekte atomar geprüft; auch ein
abgebrochener Projektprozess gibt die von ihm gestarteten Worker und Plätze frei.
Die Vorbereitung lehnt überschneidende Worktree-Roots verschiedener Projekte
einschließlich Symlink-Aliasen ab. Ein gemeinsamer literaler Root oder der allgemeine
Fallbackroot muss dafür durch projektspezifische Roots ersetzt werden, etwa
`workspace.root: $SYMPHONY_PROJECT_WORKTREES_ROOT`.

Pro Linear-Workspace müssen Client-ID, Workspace-ID, App-User-ID und Credentials
übereinstimmen. Konflikte werden als Konfigurationsfehler abgewiesen. Die App-/
Workspaceidentität wird bei API-Zugriffen verifiziert. Eine Kandidatenabfrage pro
Workspace und API-Seite enthält projektweise verknüpfte Scope-, Status- und
Assignee-Filter. Verschiedene Workspaces werden getrennt abgefragt.

Worktree-Erzeugung und Cleanup verwenden `on_create_worktree.py` bzw.
`on_remove_worktree.py` aus dem jeweiligen Projektroot. Dialog, Retry und
Reconciliation laufen im selben Projektkontext. Die Workflow-Gates bleiben
unverändert. `sym-codex Projekt:PRO-123` und `sym-watch Projekt:PRO-123` lösen
Mehrdeutigkeiten zwischen Workspaces ausdrücklich auf; eine unqualifizierte
Kennung darf niemals das erste von mehreren Ergebnissen auswählen.

## Schutz der Zugangsdaten

Envdateien werden als Daten geparst, nie als Shellcode ausgeführt. Öffentliche
Ladepfade exportieren keine Secrets. Nur der gebundene Auth-/MCP-Prozess liest die
benannte Secretquelle; `.env.local` gewinnt vor `.env`. Ein bewusst leerer Wert
stoppt den Zugriff. Ein Secret aus einer fremden Projekt- oder Rootdatei ist kein
Fallback. Token und Secret bleiben aus Logs, Prompts, Codex-Umgebung und
Sessionartefakten heraus. Direkte HTTP-Redirects sind für den App-Client deaktiviert.

Release-Checkouts binden Code, Workflow, Helfer, Skills und Build-Artefakte an den
geprüften Stand. Der Root-Konfigurationssnapshot enthält nur öffentliche
Startwerte einschließlich Discovery-Roots und Reviewbudget sowie die Rootreferenz.
Discovery und Promptbau verwenden diese eingefrorenen Werte; spätere Änderungen
am ursprünglichen Root wirken erst in einem neuen Release.
Codex bekommt kopierte Skills und nur den
gebundenen `symphony_linear`-MCP; persönliche MCPs und Plugins werden ausgeschlossen.
Die vorhandene OpenAI-Anmeldung bleibt an ihrer Credential-Referenz. Dies ersetzt
keine Dateisystemisolation gegenüber beliebigen Programmen mit Betreiberrechten.
Jedes Projekt hat ein eigenes Codex-Home. Dessen erzeugte Konfiguration wird vor
jedem Start vollständig mit dem erwarteten Inhalt verglichen; veränderte
Konfigurationen werden abgewiesen, ohne Sessions zu ändern.

## Einmalige Betreiberübergabe

Die interne Installationskennung ist konstant `symphony`.
`LINEAR_APP_INSTALLATION_ID` wird nicht mehr als Benutzereinstellung ausgewertet.
Zustand liegt unverändert unter `<Projekt>/.symphony/state`, Codex-Sessions unter
`codex/symphony`, Kommentarjournale unter `comments`.

Bei tatsächlich abweichendem vorhandenen Zustand:

1. Aktive Arbeit mit dem bisherigen Stand beenden.
2. Den gesamten lokalen Zustand einschließlich Sessions und Journalen sichern;
   den bisherigen Programmstand und die Sicherung aufbewahren.
3. Benötigte Sessions gezielt nach `codex/symphony` übernehmen und zugehörige
   Journalmetadaten kontrolliert der Kennung `symphony` zuordnen. Keine blinde
   Zusammenführung verschiedener Projekte oder Workspaces.
4. Den alten abweichenden Zustand außerhalb des aktiven Zustandsroots aufbewahren
   und mit der gemeinsamen aktuellen Version starten. Arbeitsergebnisse und
   Workpads vor Wiederaufnahme zurücklesen.

Die Laufzeit meldet abweichende Sessionverzeichnisse bzw. Journalmetadaten mit
konkretem Übergabehinweis. Sie verschiebt und löscht diese Daten nicht automatisch.
Zugangswiderrufe oder Secretrotation sind für diese Codebereinigung nicht nötig.
Es gibt keine langfristige Mischversions- oder Altkonfigurationsmatrix.

## Dienst-Mutex und Nachweise

`./symphony` hält vor Build-/Link-/Dispatch-Nebenwirkungen einen nichtblockierenden
OS-Lock pro Benutzer unter `~/.cache/symphony/service.lock`. Ein zweiter Start,
auch aus einem anderen Checkout oder mit einem anderen Port, endet sofort mit
„Symphony läuft bereits“. Die Datei wird nicht gelöscht. Nach sauberem Ende oder
Crash wird der OS-Lock freigegeben. Direkte escript-Starts verwenden denselben
Lock; manuelle Codex-/Watch-Helfer sind kein zweiter Dienst.
Der Lockhalter läuft in einer eigenen Prozessgruppe, damit Terminalsignale den
Mutex erst nach dem Ende des Eigentümers und seiner regulären Bereinigung freigeben.

Automatisierte kontrollierte Mehrprojekt-/Mehrworkspace-Tests und ein realer
Linear-/Codex-Smoke werden getrennt ausgewiesen. Für reale Prüfungen dient das
bereits freigegebene Dummy-Projekt Symphony Test. Reguläre PreReview-, Review-,
Test- und Merge-Schritte bleiben erhalten; Installationsupdates werden am
geprüften gemeinsamen Release gebündelt vorgenommen.

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
