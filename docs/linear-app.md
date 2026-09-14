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
Beim Poll werden der originale Workflow und die öffentlichen Root- und
Projekt-Envdateien neu geladen. Akzeptierte Änderungen gelten für Polling und spätere
Worker. Laufende Worker behalten ihren Kontext; Identitäts-/Scope- und Worktreeroot-Wechsel
erfordern einen Neustart und ungültige Konfigurationen ersetzen keinen gültigen
Snapshot. Eine externe Workflowdatei bleibt vom Symphony-Code-Root getrennt.
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
Assignee-Filter. Verschiedene Workspaces werden getrennt abgefragt. Fehler und
bestätigte Sperrfristen gelten schon bei der Startprüfung je Workspacegruppe;
unbetroffene Gruppen behalten ihre Kandidaten und ihren Polltakt. Temporäre
HTTP-5xx- und Transportfehler einer Gruppe verhindern den Start anderer bereits
verifizierter Gruppen nicht; Authentifizierungs-, Bindungs- und
Konfigurationsfehler bleiben dienstweit fail-closed. Sind alle Gruppen gesperrt,
richtet sich der nächste Poll nach der frühesten fälligen Gruppe.

Worktree-Erzeugung und Cleanup verwenden `on_create_worktree.py` bzw.
`on_remove_worktree.py` aus dem jeweiligen Projektroot. Dialog, Retry und
Reconciliation laufen im selben Projektkontext. Die Workflow-Gates bleiben
unverändert. `sym-codex Projekt:PRO-123` und `sym-watch Projekt:PRO-123` lösen
Mehrdeutigkeiten zwischen Workspaces ausdrücklich auf; eine unqualifizierte
Kennung darf niemals das erste von mehreren Ergebnissen auswählen.

## Schutz der Zugangsdaten

CLI, MCP und manuelle Skripthelfer aktivieren den ausgewählten Workflow vor
dem öffentlichen Laden der Projektumgebung. Auch bei abweichenden Workflowdateien
bleiben deren direkte und indirekte Secretreferenzen dadurch vom Export ausgeschlossen.
Envdateien werden als Daten geparst, nie als Shellcode ausgeführt. Öffentliche
Ladepfade exportieren keine Secrets. Nur der gebundene Auth-/MCP-Prozess liest die
benannte Secretquelle; `.env.local` gewinnt vor `.env`. Ein bewusst leerer Wert
stoppt den Zugriff. Ein Secret aus einer fremden Projekt- oder Rootdatei ist kein
Fallback. Ein geerbter `LINEAR_API_KEY` wird aus Worker-/Codex-Umgebungen entfernt;
er wird nicht zur Authentifizierung ausgewertet. Token und Secret bleiben aus
Logs, Prompts, Codex-Umgebung und Sessionartefakten heraus. Direkte HTTP-Redirects sind für den App-Client deaktiviert.

Symphony und seine Hilfsprogramme laufen direkt aus dem ursprünglichen Checkout.
Bestätigte Updates führen dort `git pull --ff-only` und `make all` aus; normale
Starts verwenden den inkrementellen Build und das vorhandene Escript weiter.
Es entstehen keine Laufzeitkopien oder Root-Konfigurationsdateien unter
`.symphony/installations`. Die Projektliste aus `SYM_PROJECT_ROOT` wird beim Start
ermittelt; mehrere Basispfade werden mit Komma getrennt. Änderungen dieser Liste
und des Programmcodes erfordern einen Neustart.

Worker übergeben ihren angenommenen öffentlichen Projektkontext an die gebundenen
Helfer. So ändern spätere Dateiänderungen keine bereits laufende Verarbeitung.
Codex bekommt ausschließlich die Repository-Skills und den gebundenen
`symphony_linear`-MCP; persönliche MCPs und Plugins werden ausgeschlossen.
Die vorhandene OpenAI-Anmeldung bleibt an ihrer Credential-Referenz. Dies ersetzt
keine Dateisystemisolation gegenüber beliebigen Programmen mit Betreiberrechten.
Jedes Projekt verwendet ein kleines Codex-Profil unter
`.symphony/state/codex/symphony/profiles`, mit genau seiner Trust-Freigabe
(bei Git-Worktrees für den Git-common-root). Profile werden bei unveränderten Skills
wiederverwendet; sie enthalten weder Checkout noch Build oder Projektkonfiguration.
Die erzeugte Codex-Konfiguration und die kopierten Skills werden vor dem Start
geprüft. Sessions bleiben unabhängig vom Profil im bestehenden Zustandsverzeichnis.

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
geprüften gemeinsamen Checkout vorgenommen.

## Gemeinsame Wissensbasis ohne lokales Codex-Memory

Frische Symphony-/Codex-Prozesse erzwingen `features.memories=false`,
`memories.generate_memories=false` und `memories.use_memories=false`.
Persönliche Memory-Dateien werden weder importiert noch gelöscht. Die
gemeinsame Wissensbasis bilden versionierte AGENTS-, Workflow-, Skill- und
Projektdateien sowie Ticket und Workpad. Codex übernimmt die
versionierten Repository-Skills; persönliche lokale Skill-Erweiterungen werden nicht
in den gemeinsamen Lauf importiert. Gesprächs-/Session-History, Wiederaufnahme
und Tracker-/Journalzustand bleiben erhalten. Bereits geladener Alt-Kontext
wird dadurch nicht rückwirkend entfernt.

## Kommentarjournal und App-Mutationen

App-Kommentarschreibvorgänge und ihre Wiederaufnahme werden pro Projektjournal
prozessübergreifend serialisiert. Jede App-Anfrage darf eine Kommentar-ID nur
einmal verändern; mehrfache Writes derselben ID werden vor HTTP mit
`invalid_comment_mutation` abgewiesen und müssen einzeln gesendet werden.
Optionale GraphQL-Felder bleiben bei fehlenden Variablen ausgelassen;
explizites `null` bleibt erhalten. Ticketkennungen werden vor der Intent-Anlage
lesend zu Issue-IDs aufgelöst. JSON-Inhalt und die String-Ausgabe von `bodyData`
werden strukturell verglichen. Kommentarupdates unterstützen die rücklesbaren
Felder `body`, `bodyData`, `quotedText`, `resolvingUserId` und
`resolvingCommentId`; andere Update-Felder werden vor HTTP abgewiesen.

Eindeutige 401/429 ohne Daten werden auch bei leerem oder textuellem Body als
abgewiesen protokolliert; unklare Ausgänge werden weiterhin abgeglichen.
GraphQL-`RATELIMITED` ohne Daten und ohne Feldpfad wird ebenso als eindeutige
Ablehnung erfasst, auch bei HTTP 400/403. Antworten mit Daten oder unklaren
zusätzlichen Fehlern bleiben abgleichpflichtig.
Ein nach unbekanntem Ausgang unverändert rückgelesenes Kommentarupdate wird nur
bei exakt gleicher Kommentar-, Issue- und Autorbindung sowie unverändertem
gespeichertem `updatedAt`-Preimage einmal aus seinem Intent wiederholt. Der
Replayversuch wird vor der Mutation dauerhaft im Intent reserviert. Der aktuelle
Schreibversuch stoppt nach bestätigtem Replay mit `comment_write_recovered`,
damit er den Stand frisch einliest. Bleibt auch der Replayausgang mehrdeutig,
wird keine weitere Mutation gesendet; der Abgleich bleibt ungelöst. Neuere
Versionen oder fremde Bindungen bleiben `comment_write_unresolved`;
Kommentarerstellungen werden nie blind wiederholt.
Historische Journalbelege werden auch nach einem kontrollierten App-Wechsel
gegen ihren gespeicherten Autor geprüft. Neue Writes und Kommentarupdates
bleiben an die aktuell geprüfte App-Identität gebunden; ein vor dem App-Wechsel
angelegtes Update-Intent darf daher unter der neuen Identität nicht abgespielt
werden.

Konkurrierende Journalzugriffe warten bis zu 10 Sekunden auf den Lock
(`comment_journal_busy` bei Zeitüberschreitung, `comment_journal_unavailable`
bei Helfer-/Backendfehlern). GraphQL-Aufrufe ohne Kommentarschreibvorgang
benötigen keinen Journal-Lock. Echte konkurrierende Issue-Owner werden sofort
mit `issue_already_owned` abgewiesen.
Der gebundene Linear-MCP überträgt UTF-8-JSON als unveränderte Bytes mit genau
einer Protokollzeile pro Nachricht, einschließlich Unicode und Text-Whitespace.

## Dialog-Polling

Der Candidate-Poll beobachtet `Todo (Dialog-AI)` über ein leichtes
letztes-Kommentar-Signal (`id`, `createdAt`, `updatedAt`) und merkt pro Issue
den zuletzt vollständig geprüften Signal-Key. Bei unverändertem Signal und
nicht fälligem Safety-Fallback entstehen weder `running`-Eintrag noch
Dashboard-Item, Codex-Start oder vollständiger Kommentarabruf.
Bei neuem/geändertem Signal lädt Symphony alle Kommentare und wertet
`Dialog.next_request/3` aus; nur eine echte offene Anfrage startet Codex.
Die Frischeprüfung vor dem Antwortposting gilt weiterhin.

Bei fehlendem oder unverändertem Signal folgt ein Safety-Full-Check im
Intervall `30 Sekunden * Anzahl sichtbarer offener Dialogtickets * active_instance_count`
pro Instanz. Candidate-Polls, unveränderte Signale und No-op-Safety-Checks
zählen nicht als Aktivität für den Idle-Shutdown. Erst echte Dialogbearbeitung,
Antwortposting, Statusänderungen, Retry-/Running-Änderungen oder reguläre
Agentenarbeit setzen die Inaktivitätszeit zurück.
Die Grenzen für Projektroot, Vorabmeldungen und gestartete Läufe stehen in
`WORKFLOW_DIALOG.md`, Abschnitt „Verbindliche Regeln“.

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
Die Paginierung prüft sichtbare Änderungen, liefert aber keinen atomaren Snapshot.
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
fachliche Ergebnisse in `### Kommentareingang` des einen Workpads. Das Workpad
wird vor der lokalen Bestätigung geschrieben; der dauerhafte Inbox-/Journalzustand
bleibt erhalten. Nach einem
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

Logs `Comment scan completed/failed` nennen Projektroot, Issue-/Session-Kontext,
letzten erfolgreichen Scan und Fehler bzw. offene Eingaben. Bestätigte Linear-
Sperrfristen aus `Retry-After` oder Rate-Limit-Reset gelten gemeinsam für Token-,
Identity- und Geschäftsanfragen derselben App. Der nicht geheime Dauerzustand
unter `~/.cache/symphony/rate-limits` ist nach Workspace-/Client-ID gebunden und
unabhängig von Projekt-State-Root und Symphony-Checkout. Er erhält die Fristen auch über
Prozessneustarts und beide Tooltransporte; Polling und Worker-Retries der
betroffenen App warten mindestens bis zum Ablauf. Projektzustände und private
Credentialquellen bleiben im jeweiligen Projekt.
Nicht erschöpfte Diagnoseheader erzeugen keine Sperre. Ein fehlgeschlagener
Dispatch-Refresh erhält den sichtbaren Retry samt Ergebnis und IDs. Auch eine
erfolgreiche Antwort mit bestätigtem `remaining: 0` und verwertbarem zukünftigem
Reset setzt die gemeinsame Sperrfrist.
Es gibt keine harte Zustell-SLA, keine rekonstruierbare Historie
zwischen Polls und keine atomare Linear-/GitHub- oder Exactly-once-Garantie.
Das unvermeidbare Fenster zwischen letzter API-Antwort und Aktion bleibt bestehen.

### Review-Wiederaufnahme

Ein Codex-Terminalereignis beendet nur den zugehörigen Hauptturn (`threadId`
und `turn.id`). Native `subAgentActivity`-Meldungen und leere Collab-Waitzustände
enthalten keinen Ergebnistext. Vollständige Finals werden über den bestehenden
App-Server mit `thread/read` und vollständig paginiertem `thread/turns/list`
gelesen; Child-ID, Parent-ID und Workspace müssen zur gespeicherten Bindung passen.
Während solcher RPCs eintreffende Ereignisse bleiben gepuffert.

Der atomare Zustand unter `state/reviews` bindet Projekt, Issue, Workspace und
Workerhost an den aktuellen Review-Parentthread. Er erhält Aufruf-/Child-IDs,
vollständige Resultate und deren Zustellung vor nachfolgenden Linear-Aktionen.
Jedes gespeicherte Resultat muss dabei auf ein im selben Zustand gebundenes
Child verweisen; dessen vollständige Historie wird beim Erfassen beziehungsweise
Wiederherstellen erneut gegen Parent und Workspace geprüft.
Ist der gebundene Workerhost belegt, wartet die Wiederaufnahme auf dessen
Kapazität, statt denselben Reviewthread auf einen anderen Host umzubinden.
Native `subAgentActivity(kind=started)` zählen anhand ihrer Call-ID und des
Parentturns auch ohne separaten Collab-Spawn. Live-Ereignisse und vollständige
Parenthistorie ergänzen dieselben Aufrufe idempotent; Completed-IDs zählen nicht
als weitere Starts. Die Historie ergänzt auch bisher fehlende Start-IDs, ohne
vorhandene Resultate oder Zustellungen zurückzusetzen.
Eine Wiederaufnahme verwendet `thread/resume` und die vorhandene Historie;
bereits zugestellte Resultate werden nicht erneut als Zusatzkontext eingespielt.
Die fachliche Verarbeitung bleibt im bestehenden Workpad nachgewiesen. Mehrere
Resultate bleiben nebeneinander erhalten, auch wenn später „Keine Findings“
folgt; Budget und Pflichtgates bleiben unverändert. Beschädigter Zustand oder
unvollständige/falsch gebundene Historie erlauben keinen Ersatzreviewstart.
Der Zustand aktiviert keine abgeschlossenen Tickets und wird beim Verlassen der
Reviewphase auch durch die externe Reconciliation verworfen. Bei einem manuellen
oder terminalen Abgang beendet sie den laufenden Reviewworker vor der
Zustandslöschung; bei einem aktiven Phasenübergang wird die Löschung bis zum Ende
desselben Workers vorgemerkt. Ein bereits wartender Review-Retry wird bereinigt,
sobald das Ticket die Phase verlassen hat oder nicht mehr sichtbar ist.
Ist nach einem Dienstneustart weder ein Worker noch ein Retry vorhanden, räumt
bereits ein sichtbar gepollter manueller Handoff den gebundenen Reviewzustand
auf. Die Abkehr wird dabei zuerst dauerhaft markiert; bis zur bestätigten
Löschung von Autocommit-Marker und Reviewzustand ist kein erneuter Reviewstart
zulässig. Ein vollständiges Verlassen und Wiedereintreten ausschließlich
zwischen zwei beobachteten Polls ist dagegen nicht rekonstruierbar.

### GitHub-CI und No-CI

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
