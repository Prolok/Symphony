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

## Dauerhafter Kommentareingang

Reguläre übernommene aktive Issues werden im vorhandenen Polltakt (standardmäßig
30 Sekunden) gescannt. Die erste vollständige Beobachtung ist historische
Baseline. Der Worker erhält sie einmal zur Übernahme noch offener Hinweise;
bereits zuvor erkannte offene Versionen bleiben erhalten. Manuelle Gates und
Dialog-AI werden durch diesen Eingang nicht dispatcht.

Unter dem vorhandenen projektlokalen `state_root/inputs/` hält `DurableState`
pro Issue die Bindung, beobachtete Quellversionen (auch aus Vor-/Nachscan-Signalen), Baseline, letzten vollständigen
Abruf, Scanfehler und Zustände `recognized`, `delivered`, `processed` fest.
Die bestehende OS-Journal-Sperre serialisiert Scan/Ack; Beobachtungen werden mit
App-Schreibvorgängen serialisiert und unbestätigte Schreibbelege abgeglichen.
Ein fehlgeschlagener Scan ersetzt keinen vollständigen Stand. Schon gelesene
Seiten bleiben als offene Beobachtungen erhalten. Das gilt auch für gültige
Quellen innerhalb einer Seite mit GraphQL-Teilfehlern, ungültigen anderen Zeilen
oder fehlenden Seitenmetadaten; der Scan bleibt dabei unvollständig.
Ein verschwundener Kommentar
benötigt zusätzlich eine direkte Nicht-gefunden-Antwort bei weiterhin
sichtbarem Issue, bevor er als gelöscht eingeordnet wird. Nach vorheriger
Zustellung oder Bestätigung erhält die Löschung einen eigenen Quellschlüssel;
der Worker ordnet mögliche begonnene Auswirkungen ein. Frühere Ergebnisse
bleiben erhalten und bestätigen die Löschung nicht mit.

`symphony_comments` liefert sichere Checkpoints und schreibt versionsbezogene
fachliche Ergebnisse in `### Kommentareingang` des einen Workpads. Nach einem
Crash wird unbestätigte Arbeit erneut zugestellt. Ein bestätigter Workpad-Write
mit noch fehlendem lokalem Ack lässt sich anhand des vollständigen lesbaren
Eintrags mit Quellversion, Ergebnis, Begründung und gegebenenfalls Ersatzbezug
idempotent wiederholen. Den Abschnitt und diese vollständigen fachlichen
Einträge bei Workpad-Updates erhalten; zusätzliche technische Ergebnis-Marker
sind nicht nötig. Beim nächsten Ack entfernt Symphony alte HTML-Ergebnis-Marker
nur bei einem vollständig zugehörigen, über den bisherigen Hash geprüften
Eintrag und erhält dessen fachlichen Inhalt. Das gilt auch für mehrzeilige
Begründungen. Codebeispiele und fremde Marker gelten nicht als Ergebnisbelege.
Eigene App-Ausgaben werden am letzten bestätigten vollständigen Schreibstand
erkannt; Rückedits auf frühere Texte bleiben sichtbar. Andere Integrationen
aktivieren keine Arbeit. Technische Review-Subagenten bleiben isoliert.
Linear erhöht auch bei einer Thread-Antwort den `updatedAt`-Wert des
Elternkommentars. Unveränderter bestätigter App-Inhalt bleibt dabei Kontext;
die menschliche Antwort besitzt ihre eigene Quellversion.

Statusaktionen laufen durch den frischen zentralen Check. `symphony_merge` führt
den vorhandenen Land-Helper in einem gebundenen Prozess aus und beantwortet dessen
letzten Checkpoint unmittelbar vor dem GitHub-Merge. Linear-Zugang verbleibt im
App-Runtime-Prozess; der Helper erhält keine Secrets. Bei SSH-Workern wird der
Helper über den bestehenden SSH-Transport im gebundenen, bereits auf dem Worker
aufgelösten Workspace (auch bei relativen oder `~/`-Roots)
gestartet; Checkpoint-Anfragen kommen über denselben Prozesskanal zurück.
Beide Starts übernehmen die gebundene Projektumgebung, einschließlich Git-/GitHub-
Konfiguration. Linear-Secrets werden vor der Übergabe entfernt.
Ohne explizites `GH_REPO` bindet der Land-Helper sämtliche GitHub-Kindprozesse
an die URL von `origin`. Eine bestehende GitHub-CLI-Standardauswahl von
`upstream` wird dabei nicht als Projektbindung verwendet; die lokale
Git-Konfiguration bleibt unverändert. Explizites `GH_REPO` bleibt erhalten.
Der MCP-Start übernimmt den gebundenen `SYMPHONY_PROJECT_WORKTREES_ROOT`
explizit; die isolierte Runtime ersetzt nicht den Workspace des Fachprojekts.
Manuelle GitHub-Approvals,
PR-/Remote-/Head-, CI- und Review-Gates bleiben bestehen. Offene Eingaben,
fehlgeschlagene Scans oder geänderte Labels verhindern den Abschluss. Ein
GitHub-Rate-Limit bei der Merge-Anforderung beendet den Versuch; die Wiederholung
über `symphony_merge` prüft sämtliche Gates frisch. Nur lesende GitHub-Aufrufe
wiederholen Rate-Limits intern mit Backoff.

Der Land-Helper unterscheidet bestandene/akzeptierte Checks von No-CI.
Für No-CI liest er im selben gebundenen GitHub-Repository die aktiven Regeln
des konkreten PR-Zielbranches (`rules/branches`, einschließlich übergeordneter
Rulesets) und die klassische Protection über GraphQL
`Ref.branchProtectionRule`. Nur eine fehlerfreie Antwort mit explizitem `null`
belegt fehlende klassische Protection; ein REST-404 oder eine Rechte-/API-Lücke
tut dies nicht. Erforderliche Statuskontexte und gegebenenfalls deren App werden
auch dann geprüft, wenn andere Checks bereits grün sind. Unbekannte oder weitere
CI-erzwingende Regeln (etwa erforderliche Workflows) bleiben konservativ gesperrt.
Das gilt auch für klassisch erforderliche Deployments; fehlende Deploymentfelder
sind kein Negativnachweis. Bei appgebundenen Commitstatusmeldungen liest der
Helper die Autoridentität aus der vollständig paginierten `/commits/<sha>/statuses`-
Historie; der kombinierte `/status`-Endpunkt enthält keinen Autor. Der neueste
Historieneintrag des Kontexts muss zur aktuellen Status-ID und zum Ergebnis
passen; fehlende Einträge oder Änderungen zwischen den Abfragen blockieren.
Der Helper verifiziert den Bot-Autor über `users/<app-slug>[bot]` und
`apps/<app-slug>` einschließlich Benutzer-/App-ID. Menschliche Autoren erfüllen
keine App-Bindung; unbekannte Herkunft oder fehlgeschlagene Lookups blockieren.

No-CI verlangt zusätzlich ein leeres Actions-Workflowinventar (auch deaktivierte
Workflows zählen), keine `.github/workflows/*.yml`-/`*.yaml`-Dateien an PR-Head
und Base sowie keine Check-Runs, Commitstatusmeldungen oder Check-Suites an
diesen beiden Ständen. Ein kombinierter Commitstatus `pending` ohne einzelne
Statusmeldungen belegt keine laufende CI. Paginierung, Identitäten, Zähler und
vollständige Git-Bäume werden geprüft; Fehler und abgeschnittene Antworten
erlauben keinen Negativnachweis. Vorhandene CI ohne Ergebnisse bleibt im
Warte-/Fehlerpfad. Die Meldung lautet bei bestätigtem No-CI „GitHub CI not
configured and not required“; sie ersetzt keine lokalen Tests oder Reviews.
Automatisch erzeugte externe Suites mit `queued`, ohne Ergebnis und mit
`latest_check_runs_count=0` halten vorhandene grüne Checks nicht offen. Sie
belegen aber auch kein No-CI. Fehlende Pflichtchecks, Actions-Suites ohne Jobs
und tatsächlich laufende oder nicht ersetzte fehlgeschlagene Suites blockieren.
Eine abgeschlossene Fehlersuite entfällt nur, wenn ihre vollständig gelesenen
Jobs gemäß der bestehenden Jobname-/App-Zuordnung durch neuere akzeptierte Jobs
in abgeschlossenen akzeptierten Suites derselben SHA ersetzt sind. Suite-/Job-IDs,
Zeitfolge und Jobanzahl müssen passen; unersetzte Jobs, leere Fehlersuites und
unbekannte Ergebnisse oder Teilantworten bleiben gesperrt.
`symphony_merge` wiederholt die CI-Prüfung nach den Label-/Review-Gates und prüft
PR-/Base-/Head-, Remote- und Workspace-Konsistenz vor dem letzten Linear-Checkpoint.
Es gibt keine gespeicherte No-CI-Freigabe, zusätzliche Skip-Option oder Änderung
der Repositoryschutzregeln. Das verbleibende API-/Aktionsfenster bleibt bestehen.

Logs `Comment scan completed/failed` nennen Projektroot, Issue-/Session-Kontext,
letzten erfolgreichen Scan und Fehler bzw. offene Eingaben. Rate-Limits folgen
der bestehenden Fehlerklassifikation und werden beim nächsten Poll/Checkpoint
wieder geprüft. Es gibt keine harte Zustell-SLA, keine rekonstruierbare Historie
zwischen Polls und keine atomare Linear-/GitHub- oder Exactly-once-Garantie.
Das unvermeidbare Fenster zwischen letzter API-Antwort und Aktion bleibt bestehen.
