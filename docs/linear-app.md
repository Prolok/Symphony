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
| `LINEAR_RELAY_URL` | Gemeinsamer HTTPS-Endpunkt des Relay v1 |
| `LINEAR_RELAY_CONSUMER_ID` | Optional vorgegebene stabile Rechnerkennung (1–80 Buchstaben, Ziffern, `_`, `-`) |
| `LINEAR_RELAY_OWNERS` | Gemeinsame JSON-Zuordnung menschlicher Assignee-UUIDs zu ausführenden Consumer-IDs |

Die private `.symphony/.env.local` enthält `LINEAR_APP_SECRET`,
`LINEAR_RELAY_KEY` und `LINEAR_ASSIGNEE`. Die Datei darf nur für das Laufzeitkonto lesbar sein, etwa
mit Modus `0600`. Assignees sind kommagetrennte menschliche E-Mail-Adressen oder
UUIDs; Trimmen und Deduplizieren gelten für Polling, Dispatch und Reconciliation.
`me` und App-Identitäten sind unzulässig. Je Workspace gibt es genau einen
gemeinsamen Relay-Key für alle Projekte und Rechner. Empfangende Consumer sind
unabhängig; eine gemeinsame feste Zuordnung bestimmt den ausführenden Rechner
je menschlichem Assignee. Issue-Leases bleiben zusätzlich hostlokal.

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
Workspaceidentität wird je vollständiger App-Bindung, Credential- und Token-Generation
verifiziert und innerhalb der BEAM-Laufzeit wiederverwendet. Parallele Erstaufrufe
teilen die Verifikation. Ablauf mit 120 Sekunden Sicherheitsmarge, Credentialwechsel,
fehlende Credentialquelle und Fehler verwerfen den betroffenen Beleg. Konfiguration,
Credentialquelle und menschlicher Assignee einschließlich der App-E-Mail werden
weiterhin je Aufruf geprüft. Tokens bleiben ausschließlich im Speicher; unabhängige
CLI-/MCP-Laufzeiten besitzen eigene Caches. Der Dienst pollt je Workspace
LinearRelay und verteilt Kandidaten aus dem lokalen Cache. Nur Bootstrap,
Invalidierungen und fällige Sicherheitsabgleiche laden Linear-Daten nach;
deren Abfragen enthalten die lokal gebundenen Projekt-/Teamfilter. Fehler und
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

## LinearRelay: Empfang, Zuständigkeit und gemeinsame Umstellung

Der Dienst benötigt den [Transportvertrag v1](https://github.com/Prolok/LinearRelay/blob/96ccb515e527b9ee8dd708d274aa6015e05c0ab5/docs/transport-v1.md).
`tracker.relay` bindet `endpoint`, die Secret-Referenz `key_env`, optional
`consumer_id`, `owners`, `reconcile_ms` und optional einen absoluten `state_root`.
Der Standardroot ist `~/.local/state/symphony/relay`, unabhängig von Release und
Projekt. Alle Projekte eines Workspace müssen dieselbe Relay-Konfiguration und
denselben Key haben. Auth-/Scope-/Relay-Konfigurationsänderungen erfordern einen
Neustart. Der Key wird nur im vertrauenswürdigen Transport gelesen; direkte und
indirekte Secretreferenzen werden aus öffentlichen Kindprozessen entfernt.
HTTPS-Redirects und automatische HTTP-Retries sind deaktiviert; Verbindung und
Antwort haben feste Zeitlimits. AWS-Credentials werden nicht benötigt.

Ohne vorgegebene ID erzeugt Symphony unter dem gemeinsamen Zustandsroot genau
eine dauerhafte Consumer-ID je Workspace. Eine vorhandene ID wird niemals still
ersetzt; Gerätewechsel erfordert eine neue Instanz mit eigener ID und gemeinsame
Konfiguration. Identität und Cache sind atomar mit Datei- und Verzeichnis-fsync
persistiert, Dateien mit `0600`, Verzeichnisse mit `0700`. Den lokalen Zustand
weder zwischen gleichzeitig laufenden Rechnern teilen noch die ID klonen.
Beschädigter Zustand sperrt Starts sichtbar, statt einen leeren Erfolg zu melden.

Normale Subscriptions enthalten die deduplizierten, verifizierten menschlichen
UUIDs (maximal 20). `--yolo` empfängt workspaceweit; auch dann braucht jedes
startbare Ticket einen menschlichen Assignee mit fester Ausführungszuordnung.
Beispiel einer auf allen Rechnern gemeinsamen `LINEAR_RELAY_OWNERS`-Zuordnung:

```json
{"11111111-1111-4111-8111-111111111111":"rechner-anna","22222222-2222-4222-8222-222222222222":"rechner-ben"}
```

Ein zusätzlicher Consumer für dieselbe Person empfängt und bestätigt unabhängig,
startet jedoch keine Arbeit. Fehlende oder mehrdeutige Zuordnungen sperren neue
Starts und erscheinen in Terminal, Dashboard und Status-API. Die Zuordnung gilt
für alle Projekte, automatische Starts, Retries/Resume und manuelle Helfer.
Die Reconciliation beendet laufende Worker bei Verlust der Zuständigkeit,
auch nach einem Wechsel zwischen zwei konfigurierten menschlichen Assignees.
Offline-Zeit löst keinen Wechsel aus. Menschliche Assignees, lokale Leases,
Service-Mutex und beide PO-Freigaben bleiben erhalten. Konsistente gemeinsame
Konfiguration ist Betriebsvoraussetzung; widersprüchliche Konfigurationen auf
verschiedenen Rechnern werden nicht durch verteilte Claims abgesichert.

Die Subscription bzw. `resync begin` wird vor dem Initialsnapshot registriert.
Erst nach dauerhaftem Snapshot folgen `complete` und Replay ab dem gespeicherten
Anker. Jeder Batch einschließlich Receipt und Dirty-IDs liegt dauerhaft vor dem
Transport-Ack vor. Verlorene Antworten oder ein Prozessabbruch können denselben
Batch erneut liefern. Transport-Acks bestätigen ausschließlich Empfang, niemals
die fachliche Verarbeitung im Kommentar-Workpad. Ereignisse invalidieren IDs;
Payload und Position ersetzen keinen frischen Linear-Stand. Gebündeltes Nachladen
berücksichtigt auch bisher bekannte, entzogene oder entfernte Issues. Ältere
Issue-Versionen überschreiben keine neueren. Kommentarereignisse invalidieren den
bestehenden vollständigen Inbox-Scan; Teilfehler liefern keinen Löschbeleg.
Ereignisse zu bekannten Blockern invalidieren auch abhängige Cacheeinträge mit
eingebettetem Blockerstatus. Die lokale Kandidatenauswahl berücksichtigt je Projekt
`tracker.app.allowed_issue_ids`; zusätzlich gelesene Issues außerhalb dieser
Startfreigabeliste blockieren die übrigen Kandidaten nicht.

Reguläre HTTPS-Polls laufen alle 30 Sekunden. Ein warmer Leertick verursacht keine
Linear-Anfrage, auch für laufende Issues und unveränderten Kommentarhintergrund.
Bei Rückstand folgen weitere Seiten unmittelbar, jeweils in einem eigenen
Verarbeitungsschritt des bestehenden Pollers. Andere Workspaces behalten ihren
regulären Takt; Fehler beenden das Aufholen und beachten den bestehenden Backoff.
`reconcile_ms` ist standardmäßig eine Stunde, mindestens fünf Minuten, zusätzlich
mit stabilem Jitter bis 25 Prozent je Workspace/Consumer. Diese Sicherheitsabgleiche
und Änderungen laden Daten gezielt nach. Explizite Checkpoints, Schreiboperationen,
Dispatch-Refresh sowie Status- und Merge-Gates prüfen Linear weiterhin frisch und
unter den gemeinsamen App-Budgets. Eine Linear-Sperrfrist blockiert neue Starts,
während Relay-Empfang möglich bleibt.

Die Statusanzeige unterscheidet `initializing`, `catching_up`, `ready`, `resyncing`,
`degraded`, `access_error` und `upgrade_required`. Fehler sperren neue Starts aus
unvollständigem Cache. Relay-Ausfälle erhalten exponentiellen Backoff ab 30 Sekunden
bis 15 Minuten plus Jitter; es gibt keinen Ersatzpoll gegen Linear. Retention-Lücke,
Consumer-Verlust, Generation-/Receipt-Konflikt oder explizites Resync-Signal führen
über einen neuen Snapshot und Replay zurück. Unbekannte Vertragsdaten bleiben
unbestätigt. Fehlender Cache bei bestehendem Consumer verlangt ebenfalls einen
neuen Snapshot; verlorene Zwischenhistorie wird nicht als rekonstruiert dargestellt.

Die gemeinsame Umstellung erfolgt nach Ende aller alten Arbeiten: Sessions,
Kommentar-Inbox/-Journal und vorhandenen Relay-Zustand sichern, die freigegebene
Symphony-/Relay-Version und je Workspace identische Keys/Zuordnungen verteilen,
Rechner mit ihren jeweiligen stabilen IDs neu starten und `ready` sowie die
Ausführungszuordnung prüfen. Für einen bewussten Rechnerwechsel zuerst alte Arbeit
beenden, dann die Zuordnung gemeinsam ändern und neu starten. Es gibt keinen
parallelen dauerhaften Legacy-Pollbetrieb. Cloudbereitstellung und gemeinsame
Abnahme auf 3–5 Rechnern sind eigenständige Betriebsnachweise; lokale HTTP- und
Prozess-E2E-Tests belegen keine Cloudabnahme.

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

Der Candidate-Poll beobachtet `Todo (Dialog-AI)` über das lokale letzte
Kommentarsignal und die Relay-Invalidierung des Issues. Der vor dem Kommentarabruf
gespeicherte Stand bleibt dessen Frischebezug; ein währenddessen eintreffendes
Ereignis wird dadurch nicht versehentlich als bereits geprüft behandelt. Auch die
Löschung eines älteren Kommentars invalidiert den Stand. Bei unverändertem Cache
entstehen weder `running`-Eintrag, Dashboard-Item, Codex-Start noch Linear-Abruf.

Geänderte Ereignisse und der gestaffelte Workspace-Sicherheitsabgleich lösen einen
vollständigen Kommentarabruf aus. Symphony wertet `Dialog.next_request/3` aus;
nur eine echte offene Anfrage startet Codex. Die frische Prüfung vor dem
Antwortposting bleibt bestehen. Candidate-Polls, unveränderte Signale und
No-op-Sicherheitsabgleiche zählen nicht als Aktivität für den Idle-Shutdown.
Erst echte Dialogbearbeitung, Antwortposting, Statusänderungen, Retry-/Running-
Änderungen oder reguläre Agentenarbeit setzen die Inaktivitätszeit zurück.
Die Grenzen für Projektroot, Vorabmeldungen und gestartete Läufe stehen in
`WORKFLOW_DIALOG.md`, Abschnitt „Verbindliche Regeln“.

## Dauerhafter Kommentareingang

Reguläre übernommene aktive Issues verwenden im Hintergrund den lokalen Relay-
Stand. Gleichzeitige Prüfungen derselben Bindung teilen das Ergebnis; die
Fälligkeit wird nach der Journal-Sperre erneut geprüft. Relay-Invalidierungen und
der gestaffelte Workspace-Sicherheitsabgleich verlangen einen vollständigen Scan,
unveränderte Leerticks lesen nur den lokalen Inbox-Zustand. Fehlende Baseline,
Neustart, geänderte Bindung oder Scanfehler erlauben keine Wiederverwendung eines
alten Frischebelegs. Erst ein vollständiger Scan aktualisiert
`last_successful_scan`; ein Signalcheck beweist weder Vollständigkeit noch Löschung.
Die Cache-Bindung umfasst Projekt-/App-/Issue-Kontext, Laufzeit/Übernahme und den
vor dem Scan erfassten Relay-Stand. Ein ausgefallener Poller ist ein sichtbarer
Fehler, kein Anlass für direkte Ersatzabfragen gegen Linear.
Explizite Checkpoints, Acks und Status-/Merge-Aktionen führen immer einen frischen
Vollscan aus, auch nach einem Cache-Hit oder einem bereits laufenden Hintergrundscan. Die erste vollständige Beobachtung ist historische
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
Dispatch-Refresh erhält den sichtbaren Retry samt Ergebnis und IDs. Auch erfolgreiche Antworten mit bestätigtem `remaining: 0`/`0.0` setzen eine Pause.
Request-, Endpoint- und Complexity-Budgets werden getrennt ausgewertet;
`Retry-After` akzeptiert Sekunden oder HTTP-Datum, Resets Epoch-Millisekunden
(kompatibel auch Epoch-Sekunden). Nur Resets tatsächlich erschöpfter Budgets und
gültige zukünftige Retry-After-Fristen bestimmen die Serverpause. Ohne verwertbare
Frist gilt ein lokaler exponentieller Backoff ab 30 Sekunden, maximal 5 Minuten
plus bis zu 25 Prozent Jitter. Die unter Sperre gewählte Deadline wird beim Lesen
nicht verlängert und durch parallele Antworten nicht verkürzt. Dies koordiniert
Prozesse auf demselben Rechner, keine Budgets zwischen mehreren Rechnern.
Budgetdiagnosen enthalten nur erlaubte Zahlenheader und gültiges `Retry-After`,
einschließlich `X-Complexity`; erfolgreiche Antworten sind im Debug-Log sichtbar.

Die erhaltene Vorher-Referenz `linear_budget_test.exs` vergleicht 3.600 simulierte Sekunden
mit 5-Sekunden-Arbeitstakt, einer Seite je Abfrage und unveränderten Kommentaren,
ohne Workeraktionen. Kaltstart und Token/Identity/Candidates/Status/Signal/Seiten
werden getrennt gezählt; dies ist keine Live-Lastmessung:

| Szenario | Vor PRO-715 HTTP/h | Nach PRO-715, vor Relay HTTP/h (warm) |
| --- | ---: | ---: |
| Idle, ein Workspace | 1.440 | 720 |
| Ein aktives Ticket | 7.200 | 1.584 |
| Drei aktive Projekte, ein Workspace | 18.720 | 3.312 |
| Drei aktive Projekte, zwei Workspaces | 20.160 | 4.032 |

Die Relay-Regression `relay_budget_test.exs` wiederholt dieselben 3.600 Sekunden
mit 5-Sekunden-Takt: In allen vier Szenarien ergeben sich warm **0 Linear-HTTP/h**
vor dem fälligen Sicherheitsabgleich. Kaltstart, Reconcile und Aktionen werden
separat erfasst (eine Snapshotseite pro Workspace; ein vollständiger unveränderter
Kommentarcheck benötigt in dieser Fixture drei Requests).
Weitere Relay-Regressionen messen getrennt Kaltstart, warme Leerticks, gebündelte
Änderungen, Sicherheitsabgleiche, Störung und frische Checkpoints. Die Zähler der
lokalen Fixtures sind synthetisch; insbesondere deren Complexity-Header sind
keine gemessene Linear-Complexity.

Für die verpflichtende reale Vorher-/Nachher-Abnahme aktiviert der Betreiber im
vertrauenswürdigen Runtime-Transport die in [Logging](logging.md) beschriebene
Messung. Beide freigegebenen Versionen erhalten dieselbe Last und Messdauer pro
Workspace: Idle, aktive Tickets, drei Projekte, mehrere Workspaces sowie getrennte
Fenster für Kaltstart, Burst, Reconcile, Störung und kritische Aktionen. Der
Messhook kann für die Vorher-Version isoliert übernommen werden, ohne Relay zu
aktivieren. Alle beteiligten App-Prozesse müssen erfasst sein; externe App-Nutzung
und Zeitraum gehören zum Messprotokoll. Die Auswertung mit
`scripts/linear-budget-report.py` zählt tatsächliche Requests und vorhandene
`X-Complexity`-Stichproben. Request-/Endpoint-/Complexity-Limit-, Remaining- und
Resetheader sowie Relay-HTTP-Zahlen getrennt aufbewahren. Fehlende Header oder
nicht erfasste Prozesse machen die Messung unvollständig. Keine privaten Secrets
an Worker weitergeben; nur die sekretfreien Messartefakte übergeben.

Zusätzliche Aktionen/Checkpoints und geänderte Inhalte erhöhen den Verbrauch.
Es gibt keine harte Zustell-SLA, keine rekonstruierbare Historie
zwischen Polls und keine atomare Linear-/GitHub- oder Exactly-once-Garantie.
Das unvermeidbare Fenster zwischen letzter API-Antwort und Aktion bleibt bestehen.

### Ausführbare Operator-Messübergabe PRO-716

Der geschützte Betreiberlauf verwendet ausschließlich **`symphony-PRO-716`**.
Vor dem Wechsel alle laufenden Symphony-Jobs abschließen oder kontrolliert
beenden, deren Worker/Leases prüfen und die alte Dienstinstanz beenden.
Der bestehende hostweite Mutex und der auf den Ticketworktree zeigende Launcher
bleiben unverändert. Symphony-/Insight-Hauptkonfigurationen bleiben unverändert.
Pai richtet die isolierten Testprojektbindungen und deren Wiederherstellung ein;
der Worker liefert nur Quellen und sekretfreie lokale Prüfnachweise.

`--budget-capture /ABS/run.json` aktiviert den vorhandenen Recorder ausschließlich
in diesem CLI-Prozess. Ohne Option gibt es keinen Recorder, Timer oder Dateizugriff.
Der Anschluss beginnt **vor Projekt-Discovery/Auth und Initialsnapshot** und
endet nach dem Anwendungs-Shutdown bzw. Ende des Supervisors. Er verändert
weder Polling noch Dienststeuerung, Workflow-Gates oder Leases. Build/Autoupdate
liegen vor dem Messfenster; dort entsteht kein Linear-App-Transport.
Es gibt keinen IEx-Ersatzstart und keinen zweiten Dienst-/Lockroot.

#### Fester Quellenstand und reversibler Wechsel

Das im Workpad mit SHA-256 fixierte Paket enthält `baseline.tar` (exakt
`65927695ab49a2113121632177267c44bfb5a768`), `feature.tar`, `feature.patch`,
`instrumentation.patch`, Auswerter, Vorlagen und Quellenmanifest.
Das Instrumentierungspatch ergänzt ausschließlich die bestehenden Linear-
Telemetrypfade, den gemeinsamen Recorder und CLI-/Shutdown-Anschluss.
Die Baseline erhält keinen Relay-/Pollingpfad. Die Quellenarchive enthalten
keine Gitdaten, privaten Envdateien, Builds oder Secrets; versionierte öffentliche
Envdefaults stammen unverändert aus Git. Alle Pakethashes vor Verwendung prüfen.

Die folgenden **Betreiberbefehle** wechseln nur die fixierten Quelldateien im
Ticketworktree, damit derselbe bestehende Launcher beide Stände startet. Sie
setzen exakt den Paket-Featurestand voraus; ein fehlgeschlagener `--check`
blockiert den Wechsel. Kein `reset`, kein `clean`, keine Hauptcheckoutänderung.
Die beiden Patches wurden lokal in beide Richtungen geprüft.

```sh
cd /Users/tr/QuantHub/Symphony-worktrees/PRO-716
# Erst nach Ende aller Jobs und der alten Instanz: Feature -> Baseline.
git apply --check --reverse /ABS/HANDOFF/feature.patch
git apply --reverse /ABS/HANDOFF/feature.patch
git apply --check /ABS/HANDOFF/instrumentation.patch
git apply /ABS/HANDOFF/instrumentation.patch
# Pai hat jetzt die isolierten Baseline-Testbindungen vorbereitet.
symphony-PRO-716 --budget-capture /ABS/MEASUREMENT/baseline.run.json
```

Nach regulärem Ende der Baseline, gesicherten Belegen und freiem Mutex:

```sh
cd /Users/tr/QuantHub/Symphony-worktrees/PRO-716
git apply --check --reverse /ABS/HANDOFF/instrumentation.patch
git apply --reverse /ABS/HANDOFF/instrumentation.patch
git apply --check /ABS/HANDOFF/feature.patch
git apply /ABS/HANDOFF/feature.patch
# Pai stellt denselben isolierten Ausgangszustand und die Featurebindung her.
symphony-PRO-716 --budget-capture /ABS/MEASUREMENT/feature.run.json
```

Bei Abbruch im Baselinestand ist derselbe zweite Patchblock der **Quellen-
Restorepfad**, ohne den anschließenden Teststart. Bei einem Fehler zwischen
Patchschritten den letzten erfolgreich angewandten Schritt anhand Manifest/
Hashes bestimmen; keine blinde Wiederholung. Der ungecommittete Featurestand
bleibt erhalten. Testbindungen/-zustände separat gemäß gesichertem Betreiber-
Inventar zurücknehmen; Patches ändern keine privaten Konfigurationen.

#### Öffentliche Parameter und gemeinsame Last

Vor **beiden** Läufen dieselbe öffentliche `workload.json` fixieren und hashen.
Ein gemeinsamer Zwei-Workspace-Lauf mit sieben Phasen genügt; es gibt keine
Pflicht, jede Profilkombination separat gleich lang zu wiederholen. Sämtliche
relevanten Pfade, tatsächlichen Aktionen und zusätzlichen App-Prozesse müssen
vollständig gezählt sein. Fehlende Pfade bleiben offen.

| Parameter | Festlegung |
| --- | --- |
| Workspace-/Projektbindung | verifizierte Workspace-UUIDs, Projekt-Slug-IDs und isolierte Projektroots; keine erfundenen IDs |
| Schreib-/Arbeitsziele | ausschließlich Prolok/symphony-test (`PRO-718`, `87b14c07-bd4c-4f1a-908a-b1ae99ea027a`) und tilor/symphony-test-tilor (`PRI-110`, `6ef9d62f-49e1-4a70-a7cd-de8b743bc2dd`); IDs vor Verwendung prüfen |
| Startbegrenzung | vorhandenes `tracker.app.allowed_issue_ids` auf Dummy-UUIDs, für zusätzlich lesende Projekte `[]`; keine produktiven Tickets aktivieren |
| Assignee/U1 | verifizierte menschliche UUIDs/E-Mails, stabile Consumer-ID und gemeinsame Owner-Zuordnung; keine Assigneeänderung |
| Öffentliche Appfelder | `LINEAR_APP_CLIENT_ID`, `LINEAR_APP_WORKSPACE_ID`, `LINEAR_APP_USER_ID`, `LINEAR_PROJECT_SLUG`, `LINEAR_ASSIGNEE` |
| Secret-Referenznamen | je Projekt `LINEAR_APP_SECRET` und `LINEAR_RELAY_KEY`; Werte nur bei Pai, gleiche App-Credentials/Workspace-Key je Workspace |
| Relay | `LINEAR_RELAY_URL=https://5jald162lk.execute-api.eu-west-1.amazonaws.com`, `LINEAR_RELAY_CONSUMER_ID`, `LINEAR_RELAY_OWNERS`; Release `a29a853a8d06fd140aae1167f1f542b89addfec6` |
| Laufparameter | gleiche Polltakte, Kapazitäten/Workerprofile; Reconcile-Intervall plus unveränderten Jitter und öffentliche Konfigurationshashes vorab festhalten |
| Zustände/Restore | frische isolierte Ausgangszustände für beide Kaltstarts, danach Zustände über alle Phasen erhalten; Consumer-/Inbox-/Journal-/Cooldown-Satz, Konfiguration und ursprüngliche Dummy-Status-/Kommentarwerte sichern |
| Last | identische Aktivierung/Arbeitsaufträge, Burst mit fünf Kommentaränderungen je Dummy innerhalb eines Polltakts, natürliche Reconcile-Zeitpunkte, begrenzte Relay-Netzwerkstörung samt Rücknahme, explizite Kommentar-/Aktionscheckpoints und Anzahl eigener App-Aktionen |

Zusätzliche reale Projekte nur lesend einbeziehen. Drei gleichzeitig aktive
Projekte bleiben mit zwei freigegebenen Dummy-Projekten synthetisch. Zeitpunkte,
Dauer und netzwerkspezifische Störungs-/Restoreaktion vorab im Lastplan bestimmen;
kein HTTP-/Providerstub im Live-Lauf. Die Baseline durchläuft dieselben Fenster
und Aktionen ohne Relayverkehr. Natürlichen Reconcile abwarten, keine internen
Deadlines manipulieren. Checkpoints über die vorhandenen gebundenen Helfer/
Workerwerkzeuge auslösen und deren App-Verkehr erfassen; der Recorder löst
selbst keine Netzwerk- oder Arbeitsaktion aus.

#### Messplan und Phasenbeobachtung

Die Vorlage `run.template.json` enthält öffentliche Daten, keine ausführbaren
Anweisungen. `output` muss ein absoluter, **noch nicht existierender** Dateipfad
sein. Hash-Platzhalter durch tatsächlich berechnete Werte ersetzen:

```json
{
  "output": "/ABS/MEASUREMENT/baseline.jsonl",
  "metadata": {
    "variant": "baseline",
    "evidence": "live",
    "revision": "65927695ab49a2113121632177267c44bfb5a768",
    "source_sha256": "<SHA256 des jeweiligen Quellenarchivs>",
    "instrumentation_sha256": "<SHA256 des gemeinsamen Messpatches>",
    "workload_sha256": "<SHA256 der identischen workload.json>",
    "workspace_ids": ["<verifizierte UUID Prolok>", "<verifizierte UUID tilor>"]
  },
  "phases": [
    {"name": "cold_start", "duration_ms": 60000},
    {"name": "idle", "duration_ms": 180000},
    {"name": "active", "duration_ms": 180000},
    {"name": "burst", "duration_ms": 60000},
    {"name": "reconcile", "duration_ms": 660000},
    {"name": "outage", "duration_ms": 240000},
    {"name": "checkpoint", "duration_ms": 60000}
  ]
}
```

Diese 24 Minuten sind ein **anpassbares Beispiel**, keine starre Abnahmematrix.
Vor Beginn des Paares Fenster passend zu Reconcile/Jitter/Arbeitsauftrag fixieren;
pro Phase höchstens eine Stunde, identische Dauer und Reihenfolge in beiden
Ständen. Für Feature `variant=feature`, `revision=uncommitted`, dessen Quellenhash
und einen neuen Ausgabepfad verwenden. Lokale Dryruns zwingend `evidence=fixture`.

Der Recorder schreibt `start`, `phase_start`, `phase_end`, `request`, `finish`
als `Budget capture=`-JSONL. Phasen wechseln automatisch nach dem fixierten Plan;
`tail -f /ABS/MEASUREMENT/feature.jsonl` zeigt die öffentlichen Marken ohne
zusätzlichen Dienst. Aktionen an diesen Marken gemäß Lastplan ausführen und
beobachtete Zeitpunkte/Ergebnisse im Aktionsjournal festhalten. Verkehr nach den
sieben Fenstern bleibt bis zum Shutdown unter `setup` erfasst, auch Restoreverkehr.
Anfragen werden bei Transportende zugeordnet; grenzübergreifende Anfragen anhand
ihrer Dauer einordnen. Mehr als eine Sekunde Phasenüberlauf, fehlende Fenster,
fehlender natürlicher Reconcile, vorzeitiges Ende oder abweichende Last machen
den Nachweis unvollständig. SIGKILL/VM-Abbruch ohne `finish` ist kein Erfolg.
Der Messplan beendet **keine** Arbeit und **keinen** Dienst automatisch.

Der Recorder erfasst diese BEAM-Instanz. Zusätzliche Worker-/MCP-/Operatorprozesse
mit eigenem App-Transport benötigen separate Messbelege und Prozessinventar.
Solange diese nicht abgeglichen sind, bleibt `all_app_processes_captured=false`.
Die normalen App-Server-DynamicTools laufen über `Codex.AppServer` und
`DynamicTool` im Dienst-BEAM: ihre Linear-Aufrufe sind bereits im Dienst-Capture
enthalten. Ein Codex-Kindprozess bedeutet deshalb nicht automatisch fehlenden
Linearverkehr. Der gebundene `sym-codex-mcp` startet dagegen einen eigenen BEAM;
dessen Aufrufe brauchen den vorhandenen separaten Messlogger. Dienst-Capture und
Messlog desselben BEAM niemals addieren. Ein erfolgreicher MCP-Handshake oder
eine Prozessliste nach Shutdown belegt keine vollständige Erfassung während
des Laufs, auch keine Nullmessung.
Tokenabrufe separat zählen; fehlende Token-Complexity ist keine GraphQL-Nullmessung.
Externe App-Nutzung gegen Limit-/Remaining-/Resetreihen prüfen; Differenzen über
Resetgrenzen nicht summieren. Fehlende Header niemals ergänzen.

#### Gezielte Nachprüfung vorhandener Belege

Vor einem weiteren Dienstlauf die archivierten Prozess-/Session-/Messbelege
zuordnen: pro Stand, Workspace und App-Prozess PID, Lebenszeit, Quellenstand,
Transportrolle, vollständige Messdatei und Hash festhalten. Auch kurzlebige
MCP-Prozesse und nachgewiesene Prozesse ohne Requests erfassen. Host-DynamicTools
dem Dienst zuordnen; zusätzliche MCP-/Operatorlogs separat mit
`linear-budget-report.py <log>` auswerten. Die originalen Zeitstempel bleiben
für die Zuordnung zu den Capture-Phasen erforderlich. Keine Quoten-Restwerte
anstelle fehlender Requestprotokolle verwenden.

Worker-Workpads belegen berichtete Checkpoints. Für deren einzelne Kosten
vorhandene Toolereignisse (`session_id`, `call_id`, Werkzeug, Operation,
Start/Ende/Ergebnis) mit dem zuständigen Prozess und seinen Requests verbinden.
Ein `Comment scan completed` kann auch aus einem Hintergrundscan stammen;
eine frische GraphQL-Leseabfrage ist kein `symphony_comments`-RPC. Überlappende
Aufrufe ohne eindeutige Zuordnung nur gemeinsam zählen, keine Einzelkosten raten.

Die **effektiv geladene** Pollkonfiguration beider Stände gegen Lastplan und
Zeitreihe prüfen. Die PRO-715-Baseline enthält im Root-Workflow 5 Sekunden,
der Relay-Featurestand 30 Sekunden. Ein Vergleich dieser Standardstände misst
auch die Taktumstellung. Für einen Vergleich bei gleichem Takt diesen vorab in
beiden isolierten Testworkflows ausdrücklich gleich setzen und die effektiven
Werte protokollieren. Gleiche äußere Last und gleiche Arbeitsergebnisse belegen
keinen identischen internen Workflowfortschritt; beide Größen separat ausweisen.

Vorhandene echte Teilergebnisse bleiben erhalten. Nachträglich ausgeschnittene
ruhige Fenster ausdrücklich als solche kennzeichnen; die ursprünglichen
Phasenzahlen nicht umetikettieren. Eine Ergänzung beschränkt sich auf konkret
unbelegte Pfade mit vorab gleicher Last/Dauer, weiterhin über den Ticketlauncher
und bestehende gebundene Werkzeuge. Fehlende Endpoint-Header bleiben als fehlend
ausgewiesen; aus deren Abwesenheit weder Nullverbrauch noch einen Filterfehler
ableiten. Originalcaptures und Attestationen nicht überschreiben. Zusätzliche
Belege separat mit Hash-/Quellbezug übergeben; B1 und die regulären Gates bleiben
bis zur vollständigen fachlichen Auswertung offen.

Bei dieser Auswertung die einzelnen Aussagen getrennt bewerten: Ein vorab
gleichgetakteter, ereignisfreier warmer Leerlauf kann vollständig belegt sein,
auch wenn der frühere Aktivvergleich unterschiedliche Standardeinstellungen
verwendete. Gleiche äußere Aktionen und Arbeitsergebnisse verlangen keinen
identischen internen KI-Workflow; dessen unterschiedliche Aufrufzahlen begrenzen
aber die Aussage über eine ursächliche Einsparung pro Arbeitseinheit.
Echte Host-Checkpoints gehören auch bei überlappenden Hintergrundanfragen zum
Dienstgesamtverbrauch. Isolierte Kosten pro RPC sind keine zusätzliche
Abnahmevoraussetzung. Nicht gelieferte Providerheader bleiben unbekannt; ein
Rohheadervergleich ohne Verlust ist kein Produktfehler. Ein automatisches
`evidence_complete=false` ersetzt deshalb keine Prüfung der einzelnen Lücken.

Eine vollständige Werkzeughistorie ordnet bekannte Aufrufe zu. Sie ersetzt
keinen vollständigen Transportbeleg für zusätzlich gestartete App-Prozesse;
insbesondere ist ein MCP-Startmarker kein gemessener Nullverbrauch. Fehlt nur
dieser Nachweis, die Ergänzung auf einen vorab begrenzten Aktiv-/Checkpointlauf
mit Messung aller tatsächlich gestarteten App-Prozesse beschränken. Bereits
belegte Idle-/Burst-/Reconcile-/Störungspfade nicht pauschal wiederholen.
Vorhandenen Recorder auch im gebundenen Helfer vor dessen Bootstrap beobachten
lassen; Quellenpatch ausschließlich im isolierten Betreiber-Teststand, identisch
auf Baseline und Feature, danach vollständig zurücknehmen. Rohdaten, Laufzeiten
und Prozesszuordnung erhalten; frühere Summen nicht rückwirkend ergänzen.

Den Helferabschluss synchron nach Rückkehr des MCP-Eingabepfads erfassen.
`System.at_exit` allein ist kein zuverlässiger Transportabschluss: Bei EOF und
gleichzeitigem SIGTERM kann die VM Telemetry bereits vor `finish` abbauen.
Geschriebene Buchungsslots oder OS-Exit 0 ersetzen dessen Integritätsprüfung
nicht. Ein ausschließlich im Testprozess installierter Signalhook darf den
laufenden Abschluss höchstens 250 ms zum Fertigschreiben synchronisieren;
danach bleibt der normale SIGTERM-Shutdown wirksam, auch ohne EOF. Diese
Messverzögerung identisch auf beiden Ständen aktivieren und Shutdownverkehr
separat zählen. Ohne beendeten Eingabepfad und intakte Handler kein erfolgreicher
Endbeleg; Handler niemals zur nachträglichen Freigabe neu registrieren.
Sekretfreie Prozessmarken für MCP-Rückkehr, Signal, Handlerzustand und
`finish`-Ergebnis erlauben die Zuordnung. Fehlende Originalabschlüsse bleiben
unvollständig; eine lokale Fehlerreproduktion beweist keinen unbeobachteten
Live-Auslöser. Nach einer solchen Lücke zuerst den korrigierten Anschluss lokal
gegen EOF/Signalrennen, Fehlerexit und ausbleibendes EOF prüfen.

#### Shutdown, Restore und Ergebnisübergabe

Pai nimmt die vorbereitete Netzwerkstörung und Dummy-Teständerungen zurück:
ursprüngliche Statuswerte, ausschließlich eigene Kommentar-IDs/Preimages,
unveränderte menschliche Assignees. Unklare Writes frisch abgleichen. Alle
Testjobs abschließen/kontrolliert beenden, Ende der Worker/Leases prüfen, dann
die eigene Testinstanz über ihren normalen Shutdown beenden. Der Recorder
synchronisiert und schließt dabei die Datei. Kein Restore-Erfolg wird automatisch
behauptet; ein Startup-/Supervisorfehler bleibt im Capture sichtbar.

Nach beiden Testständen den Paket-Featurequellstand wiederherstellen (Patchblock
oben), isolierte Testkonfigurationen/-zustände gemäß Inventar zurücknehmen und
den ursprünglichen Betriebszustand nach freiem Mutex über seinen bestehenden
Startweg wiederherstellen. Hauptkonfigurationen bleiben unverändert, kein
Testzustand wird über produktiven Zustand kopiert. Bereitschaft und erfolgreiche
Rücknahme im Restoreprotokoll belegen; isolierte Testbelege erhalten.

**Erst nach dem Restore** je Capture eine öffentliche `*.attestation.json`
mit tatsächlichen Bestätigungen erstellen. `capture_sha256` bindet sie an die
unveränderte Rohdatei; `false` bleibt für fehlende Belege stehen:

```json
{
  "capture_sha256": "<SHA256 der geschlossenen JSONL-Datei>",
  "all_app_processes_captured": false,
  "same_load_completed": false,
  "restore_verified": false,
  "external_app_traffic": "<tatsächlich geprüfte externe App-Nutzung und Belegverweis>"
}
```

```sh
python3 /ABS/HANDOFF/linear-budget-report.py /ABS/MEASUREMENT/baseline.jsonl \
  --compare /ABS/MEASUREMENT/feature.jsonl \
  --baseline-attestation /ABS/MEASUREMENT/baseline.attestation.json \
  --feature-attestation /ABS/MEASUREMENT/feature.attestation.json > /ABS/MEASUREMENT/comparison.json
```

Ergebnis: `schema=1`, `evidence=live|fixture`, Soll-/Istzeiten,
`totals[Phase][Transport][Workspace]` mit Nullzählern und
`groups[Phase/Transport/Workspace/Art]` mit HTTP-Zahlen, Statusverteilung,
Complexitysumme **und Stichprobenzahl**, sämtlichen vorhandenen numerischen
Headerproben und `gaps`. Exit 2 bedeutet unvollständige oder synthetische Evidenz;
fehlerhafte Bindung/Sequenz/Last/Dauer wird abgewiesen. `evidence_complete` ist
nur eine Vollständigkeitsvorprüfung, keine B1-/Cloudfreigabe.

Sekretfreie Übergabe: Rohcaptures, Attestationen, `comparison.json`, öffentliche
Run-/Last-/Konfigurationshashes, vollständige Prozessmessungen und Aktionsjournal,
Runtime-Bereitschafts-/Reconcile-/Störungsbelege und Restoreprotokoll. Keine Tokens,
Keys, privaten Envdateien oder Providerpayloads. Reale Pflichtmessung, spätere
Mehrrechner-/Multi-Consumer-/Cloudabnahme und beide PO-Gates bleiben offen,
solange die jeweiligen echten Nachweise fehlen.

#### Bewerteter Messstand vom 15.09.2026

Die fachliche Auswertung in [PRO-716, Plan 8.4/B1](https://linear.app/prolok/issue/PRO-716)
führt die echten Anbindungs-, Idle-, Header-, Burst-, Reconcile-, Störungs- und
Checkpointbelege mit dem vollständigen zusätzlichen Prozessnachweis zusammen.
Das feste Lifecyclepaket liegt unter
`_build/operator-lifecycle-supplement-20260915/OPERATOR-LIFECYCLE-SUPPLEMENT.md`;
SHA-256 seines `SHA256SUMS.json`:
`7ce504a641a3b376de3403cd44d751ac89219fe6cecb76b7e28dbe20766978f8`.
166 Dateihashes und 24 Berichte wurden mit unveränderten Auswertern reproduziert;
alle 19 MCP-Lebenszeiten (7 Baseline/12 Feature) besitzen vollständige Abschlüsse.

| Vergleich | Linear-HTTP Baseline → Feature | Empfangene Complexity Baseline → Feature | Relay-HTTP Baseline → Feature |
| --- | ---: | ---: | ---: |
| Gleicher warmer 90s-Idle, 30s-Polling, keine Worker/Events | 6 → 0 | 1.104 → 0 | 0 → 6 |
| Festes 95s-Paar, gleiche Dummyaktivierung/30s-Polling, alle App-Prozesse | 40 → 37 | 4.075 → 4.206 | 0 → 17 |
| Außerhalb der 95s-Fenster: Vor-/Nachlauf, unterschiedliche Dauer/Arbeitsfortschritte | 272 → 411 | 15.421 → 17.627 | 0 → 61 |

Die Complexity des 95s-Fensters stammt aus 35/33 Headerproben. Je vier Tokenabrufe
und ein zusätzlicher Baseline-Transportfehler liefern keine Complexity; deren
unbekannter Verbrauch wird nicht ergänzt. Endpointheader bleiben unbekannt.
Außerhalb der Fenster entfallen je 6 HTTP/8 Complexity auf die Vorbereitung;
der reine Nachlauf zählt 266→405 HTTP/15.413→17.619 Complexity.
Die Rohzeitstempel korrigieren eine Aussage der Operatorzusammenfassung:
Feature-tilor startet erst um 13:43:58 CEST, nach dem Aktivfenster und knapp nach
allen festen Fenstern; seine spätere Aktivität ist vollständig separat erfasst.
Beide Dummys wurden im Aktivfenster gleich beauftragt, Prolok führte in beiden
Varianten reguläre Werkzeuge aus. B1 verlangt keinen identischen KI-Fortschritt.
Die Pflichtmessung ist damit fachlich belegt; daraus folgt keine garantierte
Einsparung pro Arbeitseinheit. Alte unvollständige Captures/Attestationen bleiben
unverändert. Die gemeinsame Mehrrechnerabnahme und alle PO-/Review-/Test-/Merge-Gates
bleiben eigenständige Voraussetzungen.

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
