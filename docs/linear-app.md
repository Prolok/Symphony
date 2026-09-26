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

`LINEAR_APP_CLIENT_ID`, `LINEAR_APP_WORKSPACE_ID` und `LINEAR_APP_USER_ID`
sind nichtgeheime Symphony-Installationskennungen. Sie verleihen für sich keinen
Zugang und dürfen in der dafür vorgesehenen versionierten `.symphony/.env`
stehen; allein ihr Vorhandensein ist kein Secret- oder Veröffentlichungsblocker
und verlangt keine Secret-Migration. Das ist eine enge Ausnahme für diese drei
Konfigurationsfelder, keine Freigabe produktiver Payloads oder fachlicher
Konto-/Workspace- und Kundendaten. `LINEAR_APP_SECRET`, `LINEAR_RELAY_KEY` und
Zugangstoken bleiben privat/geschützt und dürfen nicht veröffentlicht werden.
Widerspricht eine Fachrepositoryregel dieser Ausnahme, wird nur ihr minimales,
wertfreies Regeldelta repo-gebunden an den Betreiber übergeben; der Worker
bearbeitet keine fremden Checkouts und liest keine privaten Bindungen.

Die private `.symphony/.env.local` enthält `LINEAR_APP_SECRET`,
`LINEAR_RELAY_KEY` und `LINEAR_ASSIGNEE`. Die Datei darf nur für das Laufzeitkonto lesbar sein, etwa
mit Modus `0600`. Assignees sind kommagetrennte menschliche E-Mail-Adressen oder
UUIDs; Trimmen und Deduplizieren gelten für Polling, Dispatch und Reconciliation.
`me` und App-Identitäten sind unzulässig. Je Workspace gibt es genau einen
gemeinsamen Relay-Key für alle Projekte und Rechner. Empfangende Consumer sind
unabhängig; die verifizierte lokale Assignee-Liste bestimmt die Ausführung.
Je Workspace/Assignee darf genau ein Rechner ausführend konfiguriert sein.
Issue-Leases bleiben zusätzlich hostlokal.

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
`sym-codex` expandiert `~/` im Worktreepfad und reicht einen verifizierten
Projektkontext an Codex/MCP weiter; manuelle Starts behalten die Root-Modellvorgaben.

## LinearRelay: Empfang, Zuständigkeit und gemeinsame Umstellung

Der Dienst benötigt den [Transportvertrag v1](https://github.com/Prolok/LinearRelay/blob/96ccb515e527b9ee8dd708d274aa6015e05c0ab5/docs/transport-v1.md).
`tracker.relay` bindet `endpoint`, die Secret-Referenz `key_env`, optional
`consumer_id`, `reconcile_ms` und optional einen absoluten `state_root`.
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
UUIDs aus `LINEAR_ASSIGNEE` (maximal 20 je Workspace). Mehrere kommagetrennte
E-Mails/UUIDs sind möglich; Trimmen und Deduplizieren erfassen auch dieselbe Person
per E-Mail und UUID. Die lokale Auswahl bestimmt je Projekt die Ausführung;
die vereinigte Workspace-Subscription erweitert keine Projektberechtigung.
`--yolo` oder eine konfigurierte Agentenbindung empfängt workspaceweit, darf aber ebenfalls nur Issues lokal
konfigurierter, verifizierter Menschen ausführen. Ohne lokale Auswahl bleiben
Starts gesperrt. Consumer-ID und Zustellstand hängen nicht von der Reihenfolge
oder Schreibweise der Auswahl ab.

Genau ein ausführender Rechner pro Workspace/Assignee ist gemeinsame
Betriebsvoraussetzung: Dieselbe Person darf nicht gleichzeitig auf mehreren
Symphony-Rechnern konfiguriert sein. Es gibt keine globale Erkennung, verteilte
Sperre oder automatisches Failover. Eine zusätzliche Beobachter-/Executorrolle
über OWNERS entfällt. Andere Relay-Consumer bleiben davon unberührt.
Diese Zuständigkeit gilt für Dispatch, Retry/Resume und manuelle Helfer.
Reconciliation beendet laufende Worker bei einem nicht mehr lokalen Assignee.
Lokale Issue-Leases, Service-Mutex und beide PO-Freigaben bleiben erhalten.

### Agentenbindung

Die wirksame menschliche Delegation autorisiert PO-Steuerung und Aktivierung im
Ticketscope gemäß [Laufvertrag](../WORKFLOW_YOLO_AGENT.md#laufvertrag), auch ohne
CLI-`--yolo`. Dort sind spätere Delegation nach Anlage, aktuelle Stopps/Entzug und
die Grenze menschlicher Eskalation geregelt; Agentenbindung und Startmodus sind
unabhängig. Neu angelegte Followups übernehmen die konfigurierte Agentenbindung
ebenfalls unabhängig von `--yolo`.

Der optionale lokale OpenClaw-Ausführungsweg für diese PO-Läufe ist in
[OpenClaw-YOLO](openclaw-yolo.md) beschrieben, einschließlich Testisolation,
Werkzeugbindung und gesondertem Aktivierungsnachweis.

`LINEAR_YOLO_AGENT` in der projektspezifischen `.symphony/.env.local` benennt
optional einen Linear-Agenten. Fehlend oder leer erhält den bisherigen Betrieb,
auch bei `--yolo`. Ein Name wird über den gebundenen App-Client vollständig und
eindeutig im konfigurierten Workspace aufgelöst. Der Benutzer muss aktiv sein,
eine App-Identität besitzen und zuweisbar sein (`isAssignable=true`).
Linear-Agent-Sessions sind keine Voraussetzung für die PO-Ausführung durch
Symphony/Codex. Unbekannte,
mehrdeutige oder ungeeignete Identitäten sperren den Start mit einem
Konfigurationsfehler; eine unvollständige Abfrage gilt nicht als Auflösung.

Die Agent-ID gehört zu `Issue.delegate`/`delegateId`. `assignee` bleibt ein
Mensch aus `LINEAR_ASSIGNEE`; der erste getrimmte, deduplizierte Eintrag wird
separat als Übergabeziel aufgelöst. Die sortierte Relay-Auswahl verändert diese
Reihenfolge nicht. Auch unter `--yolo` verlangt eine Agentenbindung eine gültige
menschliche Konfiguration. Agentenname und Assignee-Reihenfolge sind Teil der
Neustartgrenze. Ungültiger Reload erhält den zuvor akzeptierten Kontext;
Worker/Helfer erhalten dessen Identitäten und den unabhängigen Startmodus.

Pro Workspace/Agent/Projektbereich darf genau ein Rechner die Agentenarbeit
ausführen. Eine bestehende Agent-Integration muss auf dieselbe
PO-Entscheidungshoheit abgestimmt sein; eine zweite Integration darf die
delegierten Tickets nicht gleichzeitig autonom steuern. Workspaceweiter
Empfang erweitert weder Projekt- noch menschliche Ausführungsberechtigungen.
Die regulären Worker bewahren die Delegation in Cache, Dispatch und Retry.
Entzug bei unverändertem Assignee stoppt den begonnenen delegierten Lauf;
die Issue-Lease prüft die Delegation vor Arbeitsbeginn erneut.

Der vollständige delegierte Projektbestand bleibt für PO-Entscheidungen im
Relay-Cache sichtbar, auch wenn ein fremder menschlicher Assignee seine lokale
Ausführung sperrt. Unzugewiesene delegierte Arbeit erhält nach frischer Prüfung
unter der Ticketsperre den ersten konfigurierten Menschen. Die beiden vorhandenen
Skip-Labels werden additiv ergänzt; andere Labels und vorhandene menschliche
Zuweisungen bleiben erhalten. Unvollständige oder mehrdeutige Labelauflösung
verhindert die Aufnahme.

Backlog/Todo/Definiert bilden eine gemeinsame PO-Gruppe. Eine Gruppe belegt eine
Sessionkapazität; ihre Mitglieder bleiben bis zum Abschluss für Einzelläufe
reserviert. Gruppensperre und deterministisch erworbene Ticketleases verhindern
lokale Doppelstarts. Der gesonderte Checkout liegt unter
`<workspace.root>/yolo/<statusgruppe>/<lauf-id>` auf einer festgehaltenen
`origin/main`-SHA, ohne Ticket-Hooks oder Änderung des Hauptcheckouts.
Der App-Server erhält dafür eine eigene Laufbindung mit Projekt, Agent,
Mitgliedern, Lauf-ID, Checkout und SHA. `sym-codex` prüft den exakten sauberen,
detached Git-Checkout und dessen Projektzugehörigkeit, bevor es das normale
Projektprofil samt gebundenem MCP startet. Manuelle Aufrufe oder Ticketargumente
aktivieren diesen Pfad nicht. Die Ticketbranchprüfung bleibt für Einzelläufe
bestehen. Nach Checkout-Erstellung und Kommentarabgleich prüft der Sammelrunner
die eingefrorenen Mitglieder erneut frisch, während er alle Leases hält;
geänderte Delegation, Zuständigkeit oder Anforderungen verhindern den Start.

Beobachtungen und explizite Mitgliedsabschlüsse liegen dauerhaft unter dem
projektgebundenen App-Zustand in `yolo/`. Relay-Signale entscheiden, ob Kommentare
frisch eingelesen werden müssen. Bestätigte eigene Kommentare und Skip-Labels
erzeugen keine neuen fachlichen Beobachtungen. Ein reguläres Turn-Ende ersetzt
keine `symphony_yolo_complete`-Bestätigung; Änderungen während des Turns bleiben
gegenüber dem eingefrorenen Ausgangsstand offen. Pro Mitglied und fachlicher Phase
wird bereits die Zustellung dauerhaft gespeichert. Gruppenbeitritt/-austritt,
Status-Rundläufe und Neustarts erzeugen keine erneute Zustellung unveränderter
Arbeit. Inhalt, externe Kommentare, wirksame Abhängigkeiten und belegte
Delegations- oder menschliche Prioritätsimpulse bestimmen die nächste fachliche
Version. Relay-Ereignispositionen und Resync-Snapshots stoßen einen paginierten
Abgleich der Linear-Issue-Historie an; nur nachgewiesene relevante Feldwechsel
erhöhen die Impulsgeneration. Vollständig paginierte Relationsabfragen beobachten
Vorgängerzustände auch ohne Änderung am Ursprung. Geblocktes Backlog bleibt
unbewertet; frische Abhängigkeiten sperren auch Aktionen eines bereits laufenden
PO-Turns, wenn das Backlog-Ticket inzwischen blockiert wurde. Zusammenhängende Reviewketten warten auf sämtliche Folgefixes und
externe Vorgänger. Unabhängige Arbeit erzeugt keine globale Review-Warteschleife.
Beobachtete Blockierung und erneute Freigabe werden je Mitglied und Phase
dauerhaft gezählt; auch ein identischer freier Endstand erlaubt genau eine neue Bewertung.

Nach einem Gruppenfehler bleibt die vollständige Beobachtung auch ohne
erfolgreichen PO-Start erhalten. Unveränderte Relay-Signale lösen während des
Cooldowns keine ticketbezogenen Linear-Lesezugriffe aus. Wiederholungen verwenden
den zuletzt vollständig gelesenen Abhängigkeitsstand. Derselbe Fehlergrund
wiederholt nach 30, 60, 120, 240, 480 und höchstens 900 Sekunden; sein Wechsel
wird einmal protokolliert. Eine fremde Kommentar- oder Statusänderung im Relay
setzt den Cooldown zurück und lässt die Gruppe sofort neu prüfen. Vor einer
tatsächlichen Zustellung gelten weiterhin die frischen Mitglieds-, Abhängigkeits-
und Kommentarprüfungen.

Ein belegter lokaler App-Server-Fehler vor `turn/start` gibt den Zustellversuch
für einen technischen Retry frei. Unklare oder bereits gestartete Turns bleiben
zunächst reserviert. Neue unterbrochene OpenClaw-Aufträge darf Symphony nach
wirksamem Schreibentzug und frischer Inaktivitäts-/Eingabeprüfung
[kontrolliert technisch aufgeben](openclaw-yolo.md#kontrollierte-aufgabe-unterbrochener-aufträge).
Danach wird nur unerledigte Arbeit aus frischen Ticketdaten neu geplant;
bestätigte Entscheidungen und neuere Zustellungen bleiben erhalten.
Fehler-/Teilresultate erhalten
ihren Lauf-/Sessionbezug. Der Sammelvertrag steht in
[WORKFLOW_YOLO_AGENT.md](../WORKFLOW_YOLO_AGENT.md).

PO-Anlagen und Übergaben verwenden `symphony_yolo_action`. Der gemeinsame
Folgeticketpfad steht auch regulären Workern zur Verfügung: Agentenkonfiguration
setzt unabhängig von `--yolo` Agent und ersten konfigurierten Menschen, sonst
entsteht das Backlog-Ticket ohne beide Zuweisungen. Aggregation übernimmt die
Delegation unabhängig vom Startmodus. Das dauerhafte Journal `yolo-actions/`
reserviert die ID vor Anlage und erhält den genauen Auftrag, Anforderungen und
Relationsplan. Wiederaufnahme gleicht dieselbe ID ab; eine veränderte Operation
oder Quelle wird abgewiesen. Vollständig gelesene Abhängigkeiten werden in beide
Richtungen übertragen; erkannte Zyklen verhindern Relationsschreiben und
Ursprungabschluss. Ursprünge schließen erst nach bestätigten Links. Unfertige
Anlagen sperren die menschliche Schlussübergabe. Bleibt nach dem letzten
Ursprungabschluss eine Aggregationsoperation offen, lädt der Eingangslauf die
journalisierten Ursprünge gezielt nach. Nur unveränderte, weiterhin delegierte
Ursprünge nehmen diese Operation wieder auf; das neue Ticket bleibt bis zum
bestätigten Operationsabschluss gesperrt. Daraus entsteht keine neue Arbeit
für sonstige abgeschlossene Tickets.
Offene PO-Anlagen werden unter Gruppen-/Ticketleases direkt aus diesem Journal
fortgesetzt, ohne unveränderte Modellaufträge erneut zuzustellen. Aktive oder
unklar angenommene externe Aufträge sperren die Recovery; ausdrücklich eskalierte
Operationen des abgeschlossenen Warteentscheids bleiben beim Betreiber.

Die Review-Warteentscheidung entsteht ohne Modelllauf. Agentendelegierte Tickets
gehen nach Merge in `Yolo Review`; nur dort führt der PO die Schlussabnahme aus.
Ein lokal vorhandener ungeprüfter Merge-Dateistand sperrt bereits diesen Eintritt:
Das Ticket bleibt in `Merge (AI)` für den regulären Test-Rücklauf. Auch die
Schlussübergabe verweigert einen inzwischen veränderten regulären Workspace,
ohne die Einbahnregel von `Yolo Review` aufzuheben.
Interne Kanten vollständig gemergter Reviewketten bleiben erhalten. Vor Start
und Aktionen werden Mitglieder, Abhängigkeiten und Kommentare erneut geprüft.
Für Folgefixes erzeugt `blocks_origins=true` die echte Blocks-Kante Fix → Ursprung
statt `related` zwischen demselben Ticketpaar; die Herkunft bleibt im Tickettext
verlinkt. `blocked_by` bezeichnet weiterhin Vorgänger des neuen Tickets.
Keine Gegenkante und kein Freitext als Blockierungsersatz.

`kind=wait` beendet den Lauf nach bestätigter Fixanlage mit Prüf-/Lernbeleg;
Status und Delegation bleiben erhalten. Erfolgreiches `kind=handoff` verlangt
erledigte Vorgänger, bestandene Prüfungen, geschlossene Pflichtnachweise und
Merge-Evidenz. Es setzt `Review` mit menschlicher Zuständigkeit und ohne Agent.
Nach bestätigtem Abschluss bereinigt der PO-Pfad den regulären Issue-Workspace;
der Abnahmecheckout bleibt separat. Reservierte Routine-Testworkspaces bleiben
ausschließlich dem gebundenen Test-Cleanup vorbehalten.
Rücksprünge aus `Yolo Review` nach BLOCKER oder Coding sowie direktes Fertig sind
gesperrt. Externe Voraussetzungen werden mit `kind=escalate` dort übergeben.
Ausdrücklich eskalierte offene Anlageoperationen erlauben den Laufabschluss als
belegtes Warten; ihre Anlage/Links bleiben offen. Der Beleg gilt nur für die
benannten Operationen dieses Laufs, nicht für später hinzugekommene Anlagen.
Der normale BLOCKER-Pfad vor dieser Schlussphase bleibt erhalten.
Details: [Symphony-Schlussabnahme](../.codex/skills/sym-yolo-review/SKILL.md) und
[OpenClaw-Eskalation](openclaw-yolo.md#seltene-eskalationen).

Unvollständige lokale YOLO-Anlageoperationen sperren den Start ihres Zieltickets
bis zur bestätigten Verknüpfung und zum Ursprungabschluss. Externe BLOCKER dürfen
mit offenem Anlagejournal an den Menschen übergeben werden: Der Bericht nennt
die reservierten IDs und den erforderlichen Abgleich, ohne die Operationen als
erledigt zu markieren. Review-Übergaben verlangen weiterhin abgeschlossene
Anlagen und Links.

### Verwaiste PO-Reviewcheckouts

Ein technischer Nichtstart vor bestätigter Zustellung entfernt seinen eigenen
unveränderten Reviewcheckout. Der Gruppen-Store hält Grund, Lauf-ID,
Bereinigungsergebnis und ein auf 15 Minuten begrenztes wachsendes `retry_at` für
dieselbe Gruppenbeobachtung. Ist die sichere Entfernung nicht bestätigt, bleibt
der Gruppenstart gesperrt. Eine aktive oder unklare Zustellung bleibt erhalten.

Für Altbestände erstellt der Betreiber nach Prüfung ein JSON-Inventar mit
expliziten Pfaden und dem jeweils dokumentierten vollständigen Commit-SHA:

```json
{"version":1,"checkouts":[{"path":"/ABS/WORKSPACE-ROOT/yolo/review/UUID","sha":"0123456789abcdef0123456789abcdef01234567"}]}
```

Aus dem Symphony-Checkout mit dem gebundenen Projektroot und funktionsfähigem
Linear-App-Zugang ausführen; der Befehl verifiziert die Projekt-/Agentenbindung:

```bash
mix yolo.review_checkouts --project /ABS/PROJECT-ROOT --inventory /ABS/inventory.json
mix yolo.review_checkouts --project /ABS/PROJECT-ROOT --inventory /ABS/inventory.json --apply
```

Der erste Aufruf ist ein Trockenlauf. Beide Aufrufe geben die Anzahl registrierter
Reviewcheckouts vor und nach der Prüfung sowie jeden Kandidatenstatus aus.
`--apply` entfernt ausschließlich registrierte, saubere, unveränderte und nicht
journalierte Reviewcheckouts des gebundenen Projekts per `git worktree remove`.
Der Gruppen-Lock muss frei sein; aktuelle Gruppenversuche, Zustellreservierungen,
OpenClaw-Journale, Laufartefakte, falsche SHAs, veränderte oder nicht im Inventar genannte Pfade
bleiben erhalten. `protected` verlangt Einzelprüfung und ist keine
Löschfreigabe. Vor und nach der einmaligen Altbereinigung `git worktree list`
zählen und Hauptcheckout sowie aktive Läufe abgleichen. Der Betreiberbeleg wird
im Workpad der fälligen `Yolo Review`-Phase dokumentiert.

### Snapshot und Ereignisabgleich

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

Reguläre HTTPS-Polls laufen standardmäßig alle fünf Sekunden. `Next refresh`
zeigt den tatsächlichen lokalen Abruf-Countdown; ein bereits verfügbares Event
wird beim nächsten Poll zuzüglich Transport/Verarbeitung abgeholt. Das Intervall
ist kein Netzwerk-Timeout, und UI-Neuzeichnen löst keinen API-Poll aus.
Ein warmer Leertick verursacht keine
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

Die bestehende Status-API unterscheidet `initializing`, `catching_up`, `ready`, `resyncing`,
`degraded`, `access_error` und `upgrade_required`. Fehler sperren neue Starts aus
unvollständigem Cache. Relay-Ausfälle erhalten exponentiellen Backoff ab 30 Sekunden
bis 15 Minuten plus Jitter; es gibt keinen Ersatzpoll gegen Linear. Retention-Lücke,
Consumer-Verlust, Generation-/Receipt-Konflikt oder explizites Resync-Signal führen
über einen neuen Snapshot und Replay zurück. Unbekannte Vertragsdaten bleiben
unbestätigt. Fehlender Cache bei bestehendem Consumer verlangt ebenfalls einen
neuen Snapshot; verlorene Zwischenhistorie wird nicht als rekonstruiert dargestellt.

Die gemeinsame Umstellung erfolgt nach gesichertem Ende aller laufenden Jobs und
Retryarbeit. Sessions, Kommentar-Inbox/-Journal und vorhandenen Relay-Zustand
sichern, die freigegebene Symphony-Version gemeinsam übernehmen und lokale
Assignee-Listen ohne Überschneidung zwischen Rechnern festlegen.
`LINEAR_RELAY_OWNERS` und `tracker.relay.owners` aus der eigenen Konfiguration
entfernen; verbliebene Werte werden ignoriert und sind keine zweite Routingquelle.
Benutzerdateien werden nicht automatisch geändert, lokale Zustände nicht gelöscht.
Relay/AWS und LinearBridge benötigen dafür keine Änderung oder neuen Secrets.

Mit derselben Consumer-ID und demselben Zustandsroot neu starten, niemals parallel
zu einer bestehenden Symphony-Instanz. Ein vorhandenes Receipt wird vor einer
Subscription-Änderung bestätigt; danach verwendet Symphony bei Bedarf den vom
Relay bestätigten Snapshot-Anker und spielt Ereignisse nach. Reihenfolge und
E-Mail-/UUID-Aliase erzeugen keine neue Identität oder Generation. Ältere lokale
Records werden beim authentifizierten Registrierungsabgleich mit anschließendem
Sicherheitsabgleich übernommen; Cache und Zustellfortschritt bleiben erhalten.
Fehler sind über Logs, reguläre Fehlerpfade und Status-API diagnostizierbar;
die zusätzlichen Relay-UUID-Zeilen entfallen im Terminal-Dashboard.

Vor der Produktprüfung den normalen Ticketlauncher `symphony-PRO-720` für den
geprüften Worktree verwenden, erst nach kontrolliertem Ende der bisherigen Instanz.
Fokussiert prüfen: zwei lokale Menschen ohne OWNERS und fremder Assignee gesperrt;
zwei Workspaces ohne Relay-Detailzeilen mit 5s-Countdown; verfügbare Änderung beim
nächsten Poll; Neustart und Listenänderung mit gleicher Consumer-ID und fortgesetztem
Zustand. Hauptkonfiguration und laufenden Testbetrieb dabei erhalten.
Lokale HTTP-/Prozesstests und diese Vorbereitung sind keine Cloudabnahme auf
3–5 Rechnern. Die nachfolgenden PRO-716-Messwerte beschreiben den damaligen Stand.



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
Bestätigte Updates führen dort `git pull --ff-only` und den Build über `scripts/mix-runtime` ohne Tests aus; normale
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
geprüft. Codex darf seine Modellhinweis-Zähler (`tui.model_availability_nux`)
ergänzen; die übrige Profilkonfiguration bleibt unverändert. Sessions bleiben
unabhängig vom Profil im bestehenden Zustandsverzeichnis.

## Betreiberpflichten und Wiederaufnahme

Maßgeblich sind die [Phasenpflichten](../WORKFLOW.md#phasenpflichten-und-betreiberübergaben).
Planung/Workpad halten Aktion, Rolle, Phase und Entscheidungsquelle oder technische
Begründung fest. Finale Produkt-/Zielumgebungsabnahme gehört standardmäßig nach
Merge in `Review`, bei Agentdelegation in `Yolo Review`; das Belegformat und die strikte Rückstellung späterer Pflichten
regelt [symphony-workpad](../.codex/skills/symphony-workpad/SKILL.md).
Bei Agentdelegation sind auch isolierte Symphony-, OpenClaw- und LinearBridge-Proben,
Dienstwechsel und Paketaktivierung erst in `Yolo Review` fällig. Vor Merge bleiben
Build, automatisierte Tests, technischer Review, Mergegates und gebundene
Routinetests über `symphony_test` fällig. Ohne Delegation gilt die bisherige
Betreiberübergabe für frühe Nachweise und die finale Abnahme in `Review`.

Der **Produkt-Quellhash** ist SHA-256 über die sortierten Pfade, Modusbits und
Inhalte aller versionierten Produktdateien des Kandidatenstands. Workpad-, Log-
und Fixturedateien sind ausgenommen; nicht ignorierte neue Kandidatendateien
zählen mit, ein reiner Autocommit ohne Produktänderung ändert ihn nicht.
`python3 scripts/test-instance.py product-source <Workspace>`
liefert `product_source_sha256` nach dieser Definition. Der vorhandene
`source_sha256` des Testarchivs darf nur verwendet werden, wenn seine Dateimenge
dieser Definition entspricht. Betreiber- und Live-Belege nennen Hash, geprüfte
Aktion, Ergebnis und Geltungsbereich. Vor erneuter Anforderung vergleichen Worker
und PO den Hash: unverändert erhält den Beleg, bei Produktdelta sind nur die
betroffenen Prüfungen zu wiederholen.
Eine irrtümliche agentenseitige Frühfrist ist mit Begründung korrigierbar,
keine Nutzerfreigabe; offene Pflicht, Quelle und technische Belege bleiben erhalten.
Tatsächliche frühe Test-/Freigabegates bleiben bindend, auch bei technischem Review-Skip.

Eine weiterhin fällige PO-Abnahme steht als offener Punkt unter `### Validierung`
mit `; fällig: Freigabe Review`. Der automatische Review-Handoff übergibt dann
auch bei sauberem Workspace und technischem No-Findings-Ergebnis an dieses
manuelle Gate, auch bei Wiederaufnahme ohne neue Review-Session. Ein späterer
Merge-Nachweis oder eine belegte, abgehakte Abnahme
erzwingt diesen Handoff nicht. Autorisierte manuelle Skip-Labels und `--yolo`
bleiben wirksam; übersprungene Abnahmen werden nicht als bestanden markiert.

Der Worker erledigt seinen erlaubten Anteil einschließlich zulässiger Nacharbeit
und gebundener Testaufrufe. Fehlt danach ein fälliger, nur extern erfüllbarer
Nachweis, ergänzt er im einen Workpad die Übergabe und wechselt gemäß Workflow
nach `BLOCKER`. Der Grund lautet konkret „ausstehende Betreiberaktion“ mit der
fehlenden Aktion, nicht pauschal „kein Authzugriff“. Eine Übergabe enthält:

| Feld | Sekretfreies synthetisches Beispiel |
| --- | --- |
| Aktion und Rolle | Betreiber stellt die erlaubte Docker-Testlaufzeit für Projekt `Beispiel` bereit und bestätigt die Testdatenbank-Erreichbarkeit. |
| Quell-/Paketstand | Produkt-Quellhash `aaaaaaaa…`, Commit `1111111`; bei ungecommittiertem Stand zusätzlich eindeutiger Diff-/Paketbezug `Paket A`. |
| Bestandene lokale Prüfungen | Format/Lint für `Paket A` bestanden; keine Aussage über noch ausstehende Datenbanktests. |
| Fehlende externe Nachweise | Docker-Daemon erreichbar, bestehender repo-lokaler Testdatenbank-Start erfolgreich, Datenbank erreichbar; Bezug zu Projekt und Testumgebung. |
| Fortsetzungsphase | `Test (AI)`; nach Entblockung repo-lokale Wiederholungsregel anwenden. |

Der Betreiber übernimmt die autorisierte Aktion über den vorhandenen
Kommentar-/Statusweg, führt sie in seinem Zuständigkeitsbereich aus und liefert
Ergebnis, Belegquelle, Geltungsbereich und Quell-/Paketstand. Ein Statuswechsel
allein bestätigt weder Ausführung noch Abnahme. Ein Worker darf keine
Betreiberübernahme oder erfolgreiche externe Aktion erfinden.

### Quellengebundener Betreiberauftrag

Wird nach ausgeführter Zwischenarbeit eine neue Betreiberpflicht fällig, hält der
Worker sie im einen Workpad unter `### Betreiberauftrag` zusätzlich in genau einem
Block fest. Dieser Beleg macht die neue Arbeit auch bei unverändertem Titel,
Beschreibung und menschlichem Eingang für die bestehende BLOCKER-Zustellung
unterscheidbar. Nur fällige, bereits autorisierte Arbeit eintragen; keine Entwürfe,
Zufallskennungen oder Zeitstempel zum Wecken. Beispiel mit synthetischen Quellhashes:

````text
### Betreiberauftrag

```symphony-operator-handoff
{
  "version": 1,
  "action": "Isolierten Unterbrechungstest am geprüften Kandidaten ausführen",
  "head_sha": "1111111111111111111111111111111111111111",
  "source_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "expected": "Neue Annahme, Schreibentzug, einmalige Folgeentscheidung und Cleanup belegen",
  "resume_state": "Test (AI)"
}
```
````

Alle sechs Felder sind erforderlich; keine Zusatzfelder. `head_sha` ist der volle
Commit, `source_sha256` der tatsächliche Quell-/Paketfingerprint einschließlich
relevanter offener Änderungen. Aktion und erwarteter Nachweis sind konkrete,
stabile Beschreibungen der Pflicht. `resume_state` nennt eine reguläre Phase von
Planung (AI) bis Merge (AI), ausgenommen Todo und Abbruch. Rolle, Fälligkeitsquelle,
lokale Prüfungen und Ergebnisse stehen weiterhin im normalen Übergabetext.
Ein neuer Kandidat oder fachlich anderer Prüfumfang verlangt einen aktualisierten
Beleg. Bloße Wartezeit, Statusrundläufe und redaktionelle Pflege tun das nicht.
Nach Ausführung den letzten Beleg samt Ergebnis erhalten, erst für eine neue
fällige Pflicht ersetzen. Keine neue Freigabe oder Scheduler-Infrastruktur entsteht.

Symphony berücksichtigt dafür ausschließlich bestätigte eigene Workpadversionen
aus einem vollständigen Kommentareingang. Aktuelle mehrdeutige/ungültige Belege
oder fehlgeschlagene Scans sperren die Beobachtung. Normale Eigenkommentare und
Integrationsausgaben bleiben ohne Wiederanlaufwirkung. Die Menge der bereits
beobachteten fachlichen Aufträge geht stabil in die bestehenden Deliverybelege ein:
Polls, Neustarts, Formatierung sowie Entfernen oder Wiederherstellen alter Belege
setzen Entscheidungen nicht zurück. Alte Belege bleiben Historie, keine erneut
auszuführende Liste. Laufende Reservierungen, Leases, frische Ticketprüfung und
offene Eingaben behalten ihre bisherigen Schutzregeln; eine Zustellung bestätigt
weder Ausführung noch Abnahme. Historische Übergaben ohne Block werden nicht
automatisch rekonstruiert.

### Prüfung bei Wiederaufnahme

Bei Wiederaufnahme prüft der Hauptworker zuerst die Fälligkeitsquelle und dann
für tatsächlich fällige Pflichten diese Belege vor weiterer Phasenarbeit:
fehlender, negativer, veralteter oder unpassender Nachweis erfüllt das Gate nicht.
Negative Befunde im Scope zuerst korrigieren und über verfügbare gebundene
Prüfwege erneut testen; das Gate bleibt bis zum passenden Erfolg offen. Nur ohne
zulässigen autonomen Fortsetzungsweg bleibt die Übergabe bestehen und führt gemäß
Workflow nach `BLOCKER`. Keinen unerfüllbaren Auftrag unverändert wiederholen
oder allein wegen Wartezeit einen Review neu starten. Passende Nachweise erlauben
die dokumentierte Fortsetzung. Reine Wartezeit entwertet keinen Quellenstand;
relevante Änderungen entwerten betroffene Belege. Lokale Tests werden entsprechend
dem geänderten Stand und der repo-lokalen Wiederholungsregel ausgeführt. Negative
Abnahmen führen bei einem im Scope lösbaren Fehler zur regulären Behebung und
erneuten Prüfung, bei einer neuen materiellen Entscheidung nach `Planung`.

Für Docker/Testdatenbank zunächst den erlaubten repo-lokalen Startpfad verwenden
(bei QuantInvest `npm run startTestDb`). Fehlende Host-Laufzeit oder fehlende
Erlaubnis zu ihrer Bereitstellung begründet die konkrete Betreiberübergabe.
Teilprüfungen bleiben dokumentiert; Vitest/E2E oder andere von der Datenbank
abhängige Gates werden nicht als bestanden ausgegeben. Keine Host-/Colima-Reparatur,
neue Containerplattform oder Datenlöschung durch den Symphony-Worker.

### Synthetische Vertragsfälle

Die folgenden Fälle prüfen den Entscheidungsvertrag ohne Live-Betriebsumstellung.
Runtime-Regressionen prüfen zusätzlich den tatsächlichen Workpad-/AgentRunner-Pfad.

| Eingabe | Erwartete Einordnung und Fortsetzung |
| --- | --- |
| Lokales Plugin-/Dienstpaket und technische Tests grün, finale Installation nach Merge | Technische Pipeline bis Review; offene finale Abnahme übernehmen. Kein Betriebswechsel vor Merge und kein behaupteter Live-Erfolg. |
| Delegiertes Ticket, Test-Checkliste geschlossen, Live-/Host-Probe offen | Vor Merge `; fällig: Yolo Review` offen lassen; Handoff nach `Merge (AI)` und nach Merge in `Yolo Review`. Keine frühe BLOCKER-Übergabe. |
| Dasselbe Ticket ohne Agentdelegation | Frühe Betreiberprobe bleibt nach bisherigem Vertrag fällig; bei fehlendem Beleg konkrete BLOCKER-Übergabe. Finale Abnahme in `Review`. |
| Workpad-, Log-, Fixture- oder reiner Autocommit-Stand ändert sich ohne Produktdelta | Produkt-Quellhash und positiver Betreiberbeleg bleiben gültig; keine neue Übergabe. |
| Produktdatei ändert sich, andere Prüfbereiche bleiben unverändert | Neuer Produkt-Quellhash; nur die vom Delta betroffene Prüfung erneut anfordern, übrige Belege mit Geltungsbereich erhalten. |
| Agent hat finale Zielumgebungsabnahme ohne frühe Nutzerentscheidung in Test eingeplant | Quelle prüfen, begründet nach Review korrigieren, Nachweis offen erhalten und regulär wiederaufnehmen. |
| Notwendige Testdatenbank/Buildabhängigkeit fehlt | Technisches Gate bleibt offen; zulässige Diagnose/Startwege nutzen, sonst konkrete Betreiberübergabe. Keine Umetikettierung als finale Betriebsabnahme. |
| In Review fehlt autorisierte Bereitstellung | Offene Review-Abnahme mit Standbezug und benötigter Aktion übergeben; kein Rücksprung zum ungemergten Testauftrag. |
| Betreiber bereits festgelegt, Abnahme erst in Merge fällig | Keine erneute Zuständigkeitsfrage; Aktion/Phase übernehmen, aktuelle lokale Phase abschließen, Nachweis offen lassen. |
| Lokale Tests für Paket A grün; Betreiberabnahme jetzt fällig, fehlt | Vollständige Übergabe für Paket A, ausstehende Betreiberaktion in BLOCKER; keine Abnahme behaupten. |
| Manuell weitergeschoben, kein neuer Beleg und keine autonome Nacharbeit möglich | Übergabe erhalten, zurück nach BLOCKER; kein unveränderter Betreiberauftrag oder zusätzlicher Review. |
| Positiver Beleg für Paket B oder anderes Projekt statt Paket A | Gate bleibt offen; erlaubte Nacharbeit/Prüfung fortsetzen, sonst fehlenden passenden Nachweis übergeben. |
| Positiver Beleg für Paket A, unveränderter relevanter Stand | In der vereinbarten Phase fortsetzen; reine Wartezeit erzeugt keine neue Reviewrunde. |
| Negative Abnahme für Paket A | Gate bleibt offen; im Scope beheben/erneut prüfen, neue Produktentscheidung nach Planung. |
| Echter HTTP 401/403 ohne Rate-Limit; andererseits `RATELIMITED` | Zugriffsfehler über erlaubte Fallbacks/Escape Hatch behandeln; Rate-Limit bleibt Rate-Limit, kein Betreiber- oder Authersatzgrund. |
| Expliziter Nutzerauftrag zum Review-Skip, bewusster Test-/Merge-Einstieg oder `Skip "Review (AI)"` | Quelle und Geltungsbereich als `bewusst übersprungen` dokumentieren; historische Reviewpunkte nicht als bestanden abhaken oder als Nachholrunde fordern. |
| Nur `Skip "Freigabe Review"` | Nur manuelles PO-Gate übersprungen; kein technischer Review-Skip. |
| Älterer Beschreibungs-/Workpad-Default verlangt beide manuellen PO-Gates, spätere belegte menschliche Entscheidung setzt deren Skip-Labels | Spätere Entscheidung und Labels erhalten; frühere Pflichtpunkte mit Quelle als bewusst übersprungen einordnen. Separate PO-Prüfung außerhalb der fälligen Gate-Checkliste führen, kein versteckter Pflichtstop und keine erneute Zustimmung. Technische Gates bleiben eigenständig. |
| Früherer Zustand unbekannt | Kein Review-Erfolg und kein nachgewiesener Skip; nur für aktuelle Gates nötige Evidenz abgleichen, keine historische Pflicht erfinden. |
| Review bewusst übersprungen, Docker/Testdatenbank fehlt | Erlaubten Startpfad prüfen, konkrete Betreiberübergabe mit Fortsetzung Test; Review-/Linear-Authdiagnose wäre falsch. |
| Passender neuer Docker-/Testdatenbank-Verfügbarkeitsbeleg | Testpfad gemäß repo-lokaler Wiederholungsregel fortsetzen; Verfügbarkeit ersetzt keine bestandenen Tests. |
| Nur drei öffentliche Installations-IDs in versionierter `.symphony/.env` | Kein Secret-Blocker; regulärer Commit-/Testpfad erlaubt. |
| Tatsächliches Secret in öffentlicher Konfiguration | Veröffentlichung verhindern; autorisierten Bereinigungsweg verwenden, keine Werte in Diagnose/Fixtures übernehmen. |
| Review-Skip, aber Test-Evidenz fehlt oder `Requires Manual Review` ohne gültiges Approval | Test-/GitHub-Gate bleibt erforderlich; Skip liefert weder Tests noch Approval oder Betreiberbelege. |

### BLOCKER-Schleifenbremse und Workspace-Warten

Für delegierte `BLOCKER`-Tickets journalisiert Symphony vor der PO-Zustellung
den SHA-256 der offenen Betreiberaktion im Workpad oder der strukturierten
`escalation`. Erscheint dieselbe Ursache innerhalb von 24 Stunden erneut,
erfolgt kein weiterer PO-Lauf: Das Ticket bleibt in `BLOCKER`, die Delegation
endet, der erste konfigurierte Mensch übernimmt, das Workpad erhält Ursache,
Versuche, Vorschlag und Entscheidung. Der bestehende OpenClaw-Kanal erhält
genau einen korrelierten Eskalationsversuch; ein unklarer Versand wird nicht
blind wiederholt. Eine andere Ursache oder ein neues Zeitfenster erlaubt Arbeit.

`Wartet auf: <IDENT>` darf mehrfach als eigene Zeile in Beschreibung oder Workpad
stehen. Die Kennung muss ein Ticket in einem anderen gebundenen Workspace
bezeichnen. Symphony prüft dessen Projektbindung und Status frisch. In
`Backlog`/`BLOCKER` bleibt der wartende Status bestehen; PO-Aufträge in
`incoming`, `blocker`, `planning` und `review` warten bis `Yolo Review`,
`Review` oder `Fertig` des Ziels. Ein regulärer `Planung (AI)`-Kandidat mit
offenem Marker erhält einen Workpad-Vermerk und geht nach `Backlog` zurück.
Fehlt eine eindeutige Zielbindung, steht der Fehler in Log und Workpad; er wird
nicht als stilles Warten behandelt. Vor Zustellung und Aktion wird neu geprüft.

Die koordinierte PO-Prüfung gleicht den Worker-Vertrag mit der Betreiberübernahme
und gegebenenfalls dem repo-gebundenen öffentlichen Konfigurations-Regeldelta ab.
Die Vertragsänderung selbst belegt keine externen Aktionen und entblockt keine
Ursprungstickets. Ihre lokale Prüfung verlangt keine vorgezogene Host-/AWS-Abnahme.

### Entscheidungsfälle für autonome Nacharbeit

| Eingabe | Entscheidung, Aktion und Status | Beleg |
| --- | --- | --- |
| Auftrag verlangt knappe Kommentare, genaue Wortzahl offen | Reversibles Format wählen und begründen; in In Arbeit (AI) umsetzen | Vorher/nachher mit Pflichtfeldern |
| Auftrag lässt zentrale Nutzergruppe und Leistungsumfang widersprüchlich offen | Kontext ausschöpfen; wesentliche Produktentscheidung mit Empfehlung nach Planung | Widerspruch, untersuchte Quellen, Fortsetzungsbedingung |
| Build rot / negative Integrationsabnahme, Fehler im Scope | Reproduzieren, Ursache korrigieren, passend erneut prüfen; aktuelle Phase bleibt aktiv | Rot/Fix/Grün auf jeweiliger Quelle; Gate bis Grün offen |
| Timeout/503 oder 429/403+RATELIMITED | Begrenzte Recovery mit Wartefrist gemäß symphony-linear, Fortschritt prüfen | Fehlerklassifikation und Ergebnis; kein erfundener Authblocker |
| Schreibantwort verloren | Bekannte Kommentar-ID/Intent abgleichen; keinen zweiten Kommentar anlegen | Journal/Readback, höchstens eine erfolgreiche Mutation |
| Notwendiger Zugriff fehlt, erlaubte Fallbacks scheitern | BLOCKER mit Diagnose, Versuchen und exakter Zugangsbedingung | Authfehler ohne Secret, betroffene Pflicht/Phase |
| Geeignete Lösungsversuche zeigen notwendige externe Abhängigkeit | BLOCKER; kein Statuswechsel allein wegen Fehlerzahl/Aufwand | Konkretes Hindernis und warum lokale Fortsetzung unmöglich ist |
| Neuer passender Beleg / nur max_turns erreicht | Mit Beleg fortsetzen; bei max_turns offene Arbeit in derselben Phase behalten | Quellen-/Scopebezug; kein falscher Gateabschluss |

### Knappe Linear-Texte

Gemeinsamer Vertrag und Größenreserve stehen in `symphony-workpad`. Verdichtung
ist eine inhaltliche Agentenaufgabe; die Runtime schneidet keine Texte ab.
Ein zurückgewiesener großer Ack lässt den Kommentareingang offen. Zuerst dasselbe
Workpad unter Erhalt vollständiger Acks/Pflichten verdichten, dann erneut bestätigen.

| Anlass | Entscheidungsfähige Kurzfassung |
| --- | --- |
| Planung | „Variante A gewählt: reversibel, erfüllt bestehende Konvention. Test: leere/volle Eingabe; keine Produktfrage offen.“ |
| Fortschritt | „503-Abgleich behoben; gezielter Wiederholungstest auf Quelle A grün. Livepflicht V5 bleibt offen.“ |
| Review/Fix | „P1: Wiederholung konnte doppelt anlegen. Journalabgleich vor Write ergänzt; Lost-response-Test grün. Quelle A, Finding-Kommentar ID.“ |
| Betreiberübergabe | „Liveprüfung blockiert: Executor fehlt. Gebundene Transporte geprüft, kein Worker-Zugang zu Betreiberkontext. Quelle A lokal grün. Betreiber stellt O1 bereit; Fortsetzung In Arbeit (AI), V5 offen.“ |
| Großer Verlauf | „Aktuell: Quelle A lokal grün, V5 offen. Überholte Diagnose/Logs: verlinkter Beleg. Alle offenen Pflichten, Gateentscheidungen und vollständigen Acks bleiben in ihren Abschnitten.“ |

Umfangreiche Originalbeschreibungen und Belegarchive unverändert referenzieren;
keine versteckte Kürzung von Anforderungen. Testfixtures prüfen Verdichtung eines
überlangen Verlaufs bei identischer Workpad-/Handoff-Auswertung.

## Einmalige Betreiberübergabe

Die interne Installationskennung ist konstant `symphony`.
`LINEAR_APP_INSTALLATION_ID` wird nicht mehr als Benutzereinstellung ausgewertet.
Regulärer Zustand liegt unter `<Projekt>/.symphony/state`, Codex-Sessions unter
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
auch aus einem anderen Checkout oder mit einem anderen Port, endet ohne expliziten Testmodus mit
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

## Isolierter Testbetrieb

`--test-instance <name> --port <port>` ist der ausdrückliche Zusatzbetrieb für
**Prolok/symphony-test**. Der normale Dienst bleibt
laufen. Unterschiedliche Testnamen teilen eine exklusive Umgebung; der Lock gilt
bereits vor Build und Discovery, beim Runner bis nach dem Cleanup. Shelllauncher,
Ticket-Symlink und direkter Escript verwenden denselben Vertrag. Ein Teststart
führt kein Autoupdate aus und richtet keine globalen Launcher ein.

Testquellcode liegt außerhalb des Testsammelroots. Dieser enthält direkt genau
das freigegebene Dummy-Projekt, aber keine eigene `.symphony` und keinen Symphony-Code.
Discovery bleibt einstufig. Symlink-Aliase und überlappende Roots werden abgewiesen.
Ein verpflichtendes öffentliches Manifest bindet echte Workspace-/Projekt-IDs;
der gebundene App-Client verifiziert zusätzlich Organisation, Projektname,
`slugId` und die vollständige Teamzuordnung. Teamweiter Scope der Testinstanz,
produktiver Consumer-Override, SSH-Worker und falsche
Bindungen sperren den Start. Der feste `workspace.root` im Workflow muss weiterhin
`$SYMPHONY_PROJECT_WORKTREES_ROOT` verwenden.

| Zustand | Testbetrieb |
| --- | --- |
| Dienstreservierung | `~/.cache/symphony/test-environment.lock` plus `test-instances/<name>.lock` |
| Projektzustand, Profile, Sessions, Kommentarjournale | `~/.local/state/symphony/test-environment/projects/<projekt>/` |
| Relay-Identität, Cache und Empfang/Ack | `~/.local/state/symphony/test-environment/relay/` |
| Laufjournal | `~/.local/state/symphony/test-environment/runs/<lauf-id>/fixtures.json` |
| Dienstlog | `~/.local/state/symphony/test-environment/runs/<name>/log/symphony.log` |
| Worktrees | `<manifest.workspace_root>/<projekt>/<issue>` |
| Ergebnisdateien | ausdrücklich angegebenes `--result-dir` außerhalb der Quellen |

Die Testumgebung behält pro Workspace eine selbst erzeugte Consumer-ID über
Neustarts, Instanznamen und Quellcheckouts hinweg. Produktiven Relay-Zustand nicht
kopieren. Die ursprünglichen Projektdateien bleiben die gebundene Credentialquelle;
Token/Relay-Key gehen nur durch die vorhandenen vertrauenswürdigen Laufzeitwege.
Kein HOME-/XDG-Umbiegen: Issue-Leases und API-Cooldowns bleiben hostweit gemeinsam.
Zusätzlich liest jeder Dienst vor der Projektreservierung seine Bindungen frisch
über den gebundenen App-Client: eindeutige Projekt-ID zum konfigurierten Slug samt
vollständiger Team-ID/Key-Menge beziehungsweise eindeutige Team-ID zum Team-Key.
Fehlende, mehrdeutige oder unvollständig geladene Antworten sperren den Start;
GraphQL-Teilfehler und eine weitere Ergebnisseite gelten nicht als Nachweis.
Die begrenzte Abfrage umfasst höchstens 100 Teams je Projekt einschließlich
archivierter Teams. Projekt-IDs werden exklusiv, ihre Teams gemeinsam reserviert;
ein Team-Scope reserviert sein Team exklusiv. So dürfen verschiedene Projekte
desselben Teams sowie ein QAI-Team-Scope und ein ausschließlich PRO zugeordnetes
Dummy-Projekt parallel laufen. Ein Projekt mit mehreren Teams überschneidet sich
mit jedem dieser Team-Scopes. ID und Key werden beide gesperrt; alte Workspace-
und Projektslug-Locks bleiben kompatibel. Ein alter Dienst mit workspaceweiter
Teamreservierung bleibt konservativ sperrend und wird vom Testlauf nicht geändert.
Ein Verlust des Lockhalters beendet den
betroffenen Dienst. Diese Sperren ersetzen keine verteilte Zuständigkeitsregel.

### Betreiberbeleg und Einrichtung

Vor jedem Live-Lauf muss der Betreiber den Hauptdienst nach dem bereits erfolgten
Projektumzug kontrolliert neu gestartet haben. Der Beleg umfasst PID, Prozessstart,
Quell-SHA und **alle tatsächlich geladenen** Projektbindungen einschließlich
kanonischer Projekt-/Worktreeroots. Alte Aliase dürfen die Dummy-Projekte nicht
wieder sichtbar machen. Bei einem älteren Hauptstand ist dessen Inventar separat
zu prüfen; der neue Dashboard-Abschnitt `service` unterstützt künftige Belege.
Eine freie Dienstsperre, ein alter Prozess oder ein überlappender/mehrdeutiger Scope
wird abgewiesen. Während des Testdiensts werden Quellstand und Prozessbeleg erneut
geprüft. Der Testprozess stoppt bei einer Abweichung ausschließlich sich selbst.

Das Manifest ist eine lokale öffentliche JSON-Datei, enthält keine Secrets und
wird vom Betreiber mit den frisch gebunden verifizierten IDs erstellt. Alle Pfade
sind absolute kanonische Pfade; Platzhalter im folgenden Muster ersetzen:

```json
{
  "project_root": "/ABS/QuantHub/SymphonyTest",
  "workspace_root": "/ABS/QuantHub/SymphonyTest-worktrees",
  "fixtures_idle": true,
  "projects": {
    "symphony-test": {
      "workspace": "prolok", "workspace_id": "WORKSPACE-UUID-1",
      "project_id": "PROJECT-UUID-1", "slug_id": "VERIFIED-SLUG-1",
      "teams": [{"id": "TEAM-UUID-PRO", "key": "PRO"}], "verified_at": 0
    }
  },
  "main_instance": {
    "pid": 12345, "started": "EXACT-PS-LSTART", "sha": "FULL-MAIN-COMMIT-SHA",
    "verified_at": 0,
    "projects": [
      {"workspace_id": "WORKSPACE-UUID-1", "project_id": "OTHER-PROJECT-UUID",
       "root": "/ABS/QuantHub/Symphony", "workspace_root": "/ABS/QuantHub/Symphony-worktrees"},
      {"workspace_id": "WORKSPACE-UUID-1", "team_id": "TEAM-UUID-QAI", "team_key": "QAI",
       "root": "/ABS/QuantHub/QuantAI", "workspace_root": "/ABS/QuantHub/QuantAI-worktrees"}
    ]
  }
}
```

`started` ist die getrimmte Ausgabe von `ps -p <pid> -o lstart=`;
`verified_at` sind Unix-Sekunden der jeweiligen gebundenen Prüfung, höchstens eine
Stunde alt und nicht zukünftig; dies gilt für den Hauptbeleg und das Dummy-Projekt.
`projects.<name>.slug_id` ist die authentifiziert gelesene kanonische API-`slugId`.
Die Projektkonfiguration darf wie im Normalbetrieb den vollständigen Projektslug
oder diese ID verwenden; der Vergleich nutzt die zentrale Scope-Normalisierung.
`projects.<name>.teams` enthält alle authentifiziert gelesenen Projektteams mit
ID und Key, keine manuelle Auswahl. Leere, doppelte oder fehlende Teamzuordnungen
sperren den Start. Die Runtime liest sie erneut und verlangt Übereinstimmung mit
dem Manifest, auch unmittelbar vor der Lockreservierung. Änderung oder Ablauf
des Manifests beendet den Testdienst; Cleanup eigener Fixtures bleibt möglich.
`fixtures_idle: true` bestätigt keine fremden Worker, Retries oder manuell
laufenden Helfer im Dummy-Projekt. Bestehende lokale Änderungen und
vorhandene Worktrees bleiben erhalten. Bei einem Haupt-Team-Scope sind statt
`project_id` die frisch authentifizierten `team_id` und `team_key` anzugeben.
Ein solcher Scope im Dummy-Workspace ist nur zulässig, wenn weder ID noch Key
zu einem der vollständigen Dummy-Projektteams gehören. Der Hauptbeleg muss
Organisation, Team-ID und Team-Key aus derselben gebundenen Prüfung enthalten.
Alle Inventareinträge aufführen, keine Auswahl nur der günstigen. Historische
Manifeste ohne Teambelege müssen vor dem nächsten Lauf erneuert werden.
Vor Änderungen an der Projektmenge alte Läufe mit ihrem gebundenen Runner und
Manifest bereinigen. Offene alte Journale bleiben sperrend; die neue Bindung
übernimmt oder löscht keine früheren Fixtures.

Für PRO-736 waren kontrollierter Hauptneustart/Inventar, reale Zugänge und
Runnerresultate beider Checkouts samt Cleanup und Relay-Empfang/Ack als damalige
Betreiberbelege in **Test (AI)** vorgesehen. Diese historische Projektpflicht
bleibt für ihren Kandidatenstand bestehen. Für neu delegierte Tickets gelten die
oben beschriebenen Fälligkeiten: Live- und isolierte Integrationsbelege werden
erst in `Yolo Review` am gemergten Stand geprüft. Der Worker liest keine private
Envdatei und startet, stoppt oder aktualisiert die Hauptinstallation nicht.

### Aufrufvertrag für Entwicklung und PRO-734

Den Quellstand zuerst vollständig vorbereiten. Die Quellkennung umfasst HEAD,
Dateimodi, versionierte Dateien und nicht ignorierte Ergänzungen; ignorierte
Zugangsdaten/Buildartefakte gehören nicht hinein. Ein Entwicklungsstand darf
ungecommittet sein, muss aber während der Prüfung unverändert bleiben.

```bash
python3 /ABS/CHECKOUT/scripts/test-instance.py source /ABS/CHECKOUT
/ABS/CHECKOUT/scripts/test-instance-run \
  --checkout /ABS/CHECKOUT --test-instance development --run-id infra-001 \
  --manifest /ABS/test-manifest.json --expected-sha FULL-SHA \
  --expected-source SOURCE-SHA256 --port 4101 --timeout 180 \
  --result-dir /ABS/test-results/infra-001 --source-mode development
```

Der Runner setzt `SYM_PROJECT_ROOT` ausschließlich für seine Kinder auf den
Manifestroot. Er prüft und baut über den regulären Launcher; der Build bettet
Quell-SHA und Quellkennung ein. Bereitschaft erfordert dieselben Angaben im
**laufenden** Escript, richtige Projekt-IDs, dessen PID und betriebsbereiten Relay.
Ein vorhandener belegter Port führt zum Fehler, nicht zu einem anderen Port.
Die angegebene Frist umfasst Build, Zugangsprüfung und Szenarien; Cleanup erhält
anschließend zusätzlich höchstens 60 Sekunden für die gebundene Trackeroperation.
Auch der Fetch im Modus `merged` unterliegt dieser Frist; bei Timeout werden seine
eigenen Transportprozesse beendet. Reguläre Mix-/Make-Builds erzeugen denselben
aktuellen Quellstempel wie der Launcher.

Für einen direkten Start nach regulärem Build dieselben Bindungen exportieren:
`SYM_PROJECT_ROOT`, `SYMPHONY_TEST_MANIFEST`, `SYMPHONY_TEST_EXPECTED_SHA` und
`SYMPHONY_TEST_EXPECTED_SOURCE`; anschließend
`mise exec -- bin/symphony --test-instance development --port 4101`.
`./symphony --test-instance development --port 4101` baut selbst.
Ein lokaler `symphony-PRO-736`-Symlink auf diesen Launcher verhält sich gleich.
Ein direkter Dienst ohne Runner ist auf das Dummy-Projekt beschränkt; für
begrenzte prüfbare Szenarien den Runner verwenden.

Für spätere Schlussabnahme einen unabhängigen projektbezogenen Checkout unter
dem konfigurierten Symphony-Workspace-Root vorbereiten, etwa
`Symphony-worktrees/yolo-review/<lauf-id>`. Dort `origin/main` frisch holen,
auf dessen vollständige SHA festlegen und denselben Runner mit
`--source-mode merged` und neuer Laufkennung verwenden. Dieser Modus holt origin
nochmals zu Laufbeginn und verlangt sauberen HEAD gleich `origin/main`; eine
Abweichung stoppt, statt die Prüf-SHA zu ändern. Der ursprüngliche Ticketworktree
wird nicht benötigt. Vor Merge kann ein unabhängiger Kandidatencheckout mit
`development` geprüft werden; dies ist kein Nachweis eines schon gemergten Stands.
Nie einen Abnahmecheckout unter `SymphonyTest/Symphony` anlegen.

### Gebundener Testaufruf

`symphony_test` verwendet in DynamicTool und gebundenem MCP denselben Pfad.
Er ist ausschließlich für einen gebundenen lokalen Worker in In Arbeit,
PreReview, Review oder Test (jeweils AI) vorgesehen. SSH-Worker benötigen einen
separat bereitgestellten Ausführungspfad; es gibt keinen stillen lokalen Ersatz.
Die normale Einrichtung verwendet ausschließlich den gemeinsamen Prolok-Zugang.
Das vorhandene Checkout `symphony-test` wird mit seiner `.symphony/.env` unter
`SYM_PROJECT_ROOT` entdeckt, wie jedes andere Projekt. Dieselbe verifizierte
Prolok-App, die lokalen menschlichen Assignees sowie vorhandene Codex-, GitHub-
und Relay-Zugänge gelten auch hier. Keine persönliche Zuständigkeit, kein privater
Workspace und kein zusätzlicher Assistenzdienst gehören zu diesem Vertrag.

Einmalig in der vertrauenswürdigen Installation im Front-Matter von WORKFLOW.md
freigeben (öffentliche IDs durch die tatsächliche Prolok-Bindung ersetzen):

```yaml
worker:
  test_executor_socket: /ABS/private-test/test.sock
  test_executor:
    workspace_id: 11111111-1111-4111-8111-111111111111
    project_id: 22222222-2222-4222-8222-222222222222
    slug_id: symphony-test-slug
    teams: [{id: 33333333-3333-4333-8333-333333333333, key: PRO}]
    scenarios: [bootstrap, workflow, failure-probe, po_handoff, po_followup]
    timeout: 1800
    result_root: /ABS/private-test/results
```

Ohne `test_executor` bleibt der verwaltete Weg deaktiviert. Socket und Ergebnisroot
liegen außerhalb aller Quell- und Worktreeroots; ihre Verzeichnisse gehören dem
Dienstbenutzer mit Modus 0700, Socket/Dateien haben Modus 0600. Der Socketpfad muss
für macOS/Linux kürzer als 104 Bytes sein. Symlink-Aliase werden abgewiesen.
Die Einrichtung ist neustartgebunden. Beim normalen `./symphony`-Start werden
Workspace, Projekt, vollständige Teamliste und App-Bindung frisch geprüft.
Der CLI-Kaltstart startet dafür die HTTP-Laufzeit vor der Projektprüfung, auch
für gebundene Prepare-/Probe-/Cleanup-Aufrufe; der Symphony-Supervisor startet
erst nach erfolgreicher Prüfung.
Der Supervisor startet den vorhandenen Executor aus der vertrauenswürdigen
Installation, wartet auf Socketbereitschaft und beendet ihn mit dem Dienst.
Kein separater Executorstart und keine Konfigurationsdatei je Ticket sind nötig.
Worker mit gesperrtem Secretzugriff dürfen keine Bereitstellung ausführen.

Die reguläre Dienstinstanz übernimmt die Test-Fixtures selbst. Das konfigurierte
Dummy-Projekt ist für eigene freigegebene Routineläufe reserviert; andere Tickets
dieses Projekts werden im Routinebetrieb nicht gestartet. Die normalen Leases,
Kapazitätsgrenzen, Relay-Verbindung und Freigabe-/Merge-Gates bleiben wirksam.
Für einen wartenden aufrufenden Worker und den Dummy-Worker muss genügend
reguläre Agentenkapazität verfügbar sein. `workflow` erstellt ein begrenztes
Änderungsticket für `test-runs/<run_id>.txt` und beobachtet den regulären Ablauf
bis zur gemergten PR mit Workpad-Mergebeleg. Vorgesehene menschliche Gates werden
nicht automatisch bestätigt oder mit neuen Skip-Labels umgangen. Bereits
konfigurierte Freigaben bleiben maßgeblich. Der gemergte Dummy-Testbeleg bleibt
im Testrepository; eigene Tickets und unveränderte Worktrees werden bereinigt.
`bootstrap` prüft nur Todo→Planung, `failure-probe` den Fehler-/Cleanup-Pfad.
Diese Teilprüfungen ersetzen keinen geforderten Test-/Merge-Nachweis.

Ein Live-Lauf verlangt identischen HEAD/Quellhash von Kandidat und tatsächlich
laufendem Build. `runtime_source_mismatch` benennt eine erforderliche kontrollierte
Aktivierung durch den Betreiber, keinen Zugriffsfehler. Worker ändern keine
fremden Checkouts oder laufenden Dienste. Eine gültige Einrichtung braucht keine
erneute Betreiberbestätigung pro Routinelauf.

Die aufrufende Issue-Bindung aus jedem gebundenen Projekt beider Workspaces wird
bei Start und Cleanup gegen den aktuellen
Projektkontext des regulären Pollers geprüft, einschließlich seiner verifizierten
menschlichen Assignees. Fehlende Zuständigkeit oder ein nicht erreichbarer Poller
sperren den Lauf; der unaufgelöste Startkontext ersetzt diese Prüfung nicht.

Start/Ergebnis/Cancel/Cleanup verwenden dieselbe Issue-, Worktree-, Quell- und
Laufbindung. Der Executor persistiert die Absicht vor dem Start und startet eine
bestehende Absicht nie doppelt. Nach unklarer Antwort dieselbe Kennung mit `result`
abgleichen. Bei Runtime-Neustart werden eigene Fixtures zunächst gesperrt;
unterbrochene Läufe bleiben fehlgeschlagen und verlangen `cleanup`, bevor ein
neuer Lauf zulässig ist. Ein verlorener Socketprozess wird durch den Supervisor
begrenzt neu gestartet. Offene/fremde/beschädigte Journale sperren Neuanlagen.
Cancel/Timeout sperren weitere Fixturestarts, stoppen nur eigene Worker und nutzen
den bestehenden prüfenden Cleanup. Probeabfragen sind an die verbleibende Laufzeit
gebunden; Cancel und Frist werden vor Übernahme eines Erfolgs erneut geprüft.
Bei vorübergehend nicht erreichbarem Linear-Transport oder Identitätsdienst sowie
HTTP 502/503/504 werden lesende Proben höchstens zweimal nach zwei und fünf Sekunden wiederholt;
Cancel und Gesamtfrist gelten auch während der Pause. Danach bleibt der Lauf
mit `linear_temporarily_unavailable` fehlgeschlagen. GraphQL-, Auth-, Scope-, Journal-
und Rate-Limit-Fehler werden dadurch nicht erneut ausgeführt; Mutationen ebenfalls nicht.
Im reservierten Dummy-Projekt überlässt auch der reguläre Terminal-/Startup-Cleanup
die Worktrees diesem prüfenden Cleanup, unabhängig vom Executor-Startzustand.
Im Szenario `workflow` wird zulässige Beschreibungspflege durch den gebundenen
Todo-/Planungsworker vor der Mutation mit Quelle, Fixture, Phase und altem/neuem
Text journalisiert.
Beide Tooltransporte verwenden diesen Beleg; eine verlorene Antwort erfordert
keine Wiederholung der Mutation. Abweichende Beschreibungen bleiben gesperrt.
Änderungen von außen bleiben erhalten und
werden als unbestätigter Cleanup sichtbar. Ergebnisbelege enthalten Lauf/Quelle,
Dienst-PID/Buildstand, Fixture-/Sessionbezug und den Bereinigungszustand; synthetische
Tests sind ausdrücklich `fixture`, niemals Liveabnahmen. Cleanup macht FAILED
niemals zu PASSED. Pflichtnachweise bleiben im jeweiligen Phasenvertrag fällig.

Der explizite Zusatztestbetrieb mit `--test-instance` bleibt eine alternative,
separat freizugebende Einrichtung unter den bestehenden Disjunktheitsregeln; er
ist keine Voraussetzung des normalen Routinewegs. Für diesen bisherigen Weg
kann `worker.test_executor_socket` weiterhin auf einen bewusst extern gestarteten
Executor zeigen, ohne `worker.test_executor` zu setzen:
`python3 /ABS/INSTALLATION/scripts/test-executor.py --config /ABS/executor.json
--socket /ABS/private-executor/test.sock`.

Öffentliche Executor-Konfiguration, vom Betreiber passend zu genau einem
freigegebenen Issue und kanonischen Worktree bereitzustellen:

```json
{
  "issue_id": "11111111-1111-4111-8111-111111111111",
  "identifier": "PRO-756",
  "checkout": "/ABS/Symphony-worktrees/PRO-756",
  "manifest": "/ABS/test-manifest.json",
  "result_root": "/ABS/private-results/pro756",
  "instance": "worker-development",
  "port": 4101,
  "timeout": 180
}
```

Der Ergebnisroot liegt außerhalb des Quellworktrees. Manifest, Zugang und
Hauptinventar bleiben im Executor; Workerargumente können sie nicht ersetzen.
Die Konfiguration bleibt für bestehende Läufe unverändert. Vor neuen Läufen
prüft der vorhandene Runner das vereinbarte Dummy-Projekt frisch über die
gebundenen Zugänge, einschließlich vollständiger Teams, Hauptbeleg, Sperren,
Quellstempel und fremder offener Fixturejournale. Die exklusive Reservierung gilt
bereits vor Build/Ticketanlage. Bestehende Bereitstellungs- und Belegfälligkeiten
bleiben erhalten; der Worker erfindet keine zusätzliche Liveabnahme je Zwischenfix.

Jeder Aufruf enthält `operation`, `run_id`, `head_sha`, `source_sha256` und
`scenario`. Die Quellkennung liefert `scripts/test-instance.py source <Workspace>`.
Feste Operationen: `start`, `result`, `cancel`, `cleanup`; Szenarien: `bootstrap`,
`workflow`, `failure-probe`, `po_handoff` und `po_followup`. `failure-probe` ist
ein absichtlicher Fehler nach Fixtureanlage mit regulärem Cleanup.
Keine Shellbefehle, Pfadargumente oder Envwerte. Issue/Workspace ergänzt das Tool
aus seinem verifizierten Kontext und der Executor vergleicht seine Betreiberbindung.

Im expliziten Zusatztestbetrieb persistiert `start` zuerst die Laufabsicht und
startet den bestehenden `test-instance-run`. Dieselbe Laufkennung mit identischen Bindungen liefert das
bestehende Ergebnis, auch nach verlorener Antwort oder Executor-Neustart. Mit
`result` abgleichen, keinen neuen Lauf für eine unklare Antwort anlegen. Eine
geänderte Quelle verlangt einen neuen Lauf nach bestätigtem Cleanup des alten.
Lauf-/Konfigurationsabweichungen, fremde Journale und offene Bereinigung sperren
Neuanlage. Der bestehende Runner liefert Bereitschaft, Konkurrenz-/Restartprobe
und Fixture-/Prozesscleanup; der Executor ersetzt keinen dieser Nachweise.

`cancel` markiert nur den eigenen Lauf; der Supervisor beendet dessen Runner mit
Signal und lässt bis zu 75 Sekunden für Cleanup. Die normale Runnerfrist gilt
weiter. Ein separater Supervisor und eine vererbte Laufsperre überstehen den
Socketserver-Neustart; ein gestorbener Supervisor erzeugt keinen Testpass.
`cleanup` nimmt ausschließlich den alten Lauf mit unverändertem Quell-/Planbezug
und dessen gebautem Escript wieder auf. Historische Resultate archiviert der
Runner vor Recovery. Ein Cleanupbeleg wertet FAILED niemals zu PASSED auf.
Ohne angelegten Plan und ohne lebenden Lauf bestätigt Recovery nur „nicht gestartet“.
Scheitert der Build vor der ersten Fixture-Anlage, gleicht der Runner nach
Prozessende unter der exklusiven Reservierung das dauerhafte Fixturejournal ab.
Nur dessen nachgewiesenes Fehlen bestätigt `cleanup_scope: no_fixture_intent`;
der Lauf bleibt FAILED, eine korrigierte Quelle darf neu geprüft werden.
Das gilt auch bei Cleanup-Wiederaufnahme ohne passenden Build. Vorhandene,
beschädigte oder unlesbare Journale verlangen weiterhin Runtime-Abgleich.
Neue Builds erst nach Bereinigung; falls ein Fehler die eigene Cleanup-Runtime
selbst betrifft, bleibt der quellgebundene Betreiber-Recoveryvertrag erforderlich.

Antworten enthalten nur Lauf-/Quellbezug, Status, laufend/abgeschlossen, Szenario-
und Cleanup-/Erhaltsergebnisse. Volle Resultate und geschützte Prozesslogs bleiben
im Ergebnisroot. `evidence: fixture` ist kein Livepass. Negative Befunde zuerst
lokal diagnostizieren/fixen und neu testen; nur fehlende Bereitstellung, echte
Freigaben oder autonom unlösbare Hindernisse begründen die Betreiberübergabe.

### Szenarien, Resultate und Wiederaufnahme

Vor Ticketanlage prüft die gebundene Runtime für das Projekt Linear-Identität,
menschlichen Assignee, Schema, Relay-Bootstrap und Codex-App-Server-Handschlag.
Je Projekt entsteht genau ein journalisiertes Ticket in `Todo (AI)`. Der reguläre
Worker erzeugt dessen Workpad und verschiebt es nach `Planung (AI)`; die für diesen
Lauf gebundene Startliste erlaubt ausschließlich die vollständig journalisierten Fixture-IDs und nur Todo.
Bereits laufende Bootstrap-Worker dürfen den Statuswechsel nach Planung abschließen;
die Startbegrenzung verhindert anschließend einen neuen Planungsworker.
Erfolg verlangt eine vollständige, eindeutige Zuordnung der Fixtures und
beobachteten Session-IDs sowie bestätigte Workpads/Statuswechsel.
Danach prüft ein Dienstneustart dieselben Test-Consumer-IDs. Konkurrenzstarts über
Normal-/Test-/Ticketlauncher und Escript müssen mit „Symphony läuft bereits“ scheitern.

Alle Szenarien bleiben an das einzige verifizierte `Prolok/symphony-test`
gebunden. Vor der ersten Fixtureanlage prüft der Runner den konfigurierten
Agenten sowie vollständig paginierte Projektteams und alle benötigten Teamstatus,
einschließlich der Zielstatus wie `Umsetzungsticket erstellt`. Fehlende oder
mehrdeutige Status und unvollständige Abfragen sperren die Anlage. Der Runner
legt keine Teamstatus an. Fixture-/Sessionmengen richten sich nach dem Szenario:

| Szenario | Ursprungsfixtures | Sessionzuordnung |
| --- | --- | --- |
| bootstrap / delegation | 1 Todo (AI) | 1 reguläre Session |
| po_incoming / po_aggregation | 1 Todo (AI), Backlog, Todo, Definiert | 1 reguläre und 1 gemeinsame PO-Session |
| po_handoff | 1 Todo (AI), BLOCKER, Yolo Review | 1 reguläre, 1 BLOCKER- und 1 Review-Session |
| po_followup | 1 Todo (AI), Yolo Review | 1 reguläre und 1 Review-Session |

Der begleitende reguläre Bootstrap erhält in PO-Szenarien keine Delegation;
er zählt nicht zur weiteren erwarteten YOLO-Arbeit. Alle IDs und Rollen müssen
vollständig und eindeutig erhalten bleiben. Gemeinsame Session-IDs sind nur für
die drei Mitglieder der Eingangsgruppe zulässig.

Der explizite Runnerparameter `--scenario delegation` ergänzt einen begrenzten
Delegationsnachweis. Vor Beginn muss der Betreiber im freigegebenen Projekt
`Prolok/symphony-test` `LINEAR_YOLO_AGENT` konfigurieren und die bestehende
Agent-Integration für diesen Test auf eine Entscheidungshoheit abstimmen.
Der Runner löst die Identität frisch auf, reserviert genau eine eigene
Fixture-ID und lässt ausschließlich deren Todo-Bootstrap zu. Dieses Ticket
startet erst mit der vorgesehenen Delegation. Zuweisung und anschließender
Entzug ändern ausschließlich `delegateId`, der menschliche Assignee bleibt
gleich. Beide Änderungen müssen im isolierten Relay-Cache mit fortgeschrittenem
Cursor und Ticket-Epoche beobachtet werden. Ein zwischenzeitlicher Vollsnapshot
ersetzt diesen Ereignisbeleg nicht. Journal und Ergebnis enthalten die konkreten
IDs und Beobachtungen, ohne Relay-Receipts oder Secrets. Neustart, Exklusivität,
Zeitgrenze und Cleanup des Bootstrap-Szenarios bleiben wirksam.

`--scenario po_incoming` prüft den ersten gemeinsamen Eingangslauf: ein regulärer
Bootstrap und drei anfänglich menschlich unzugewiesene, an den konfigurierten
Agenten delegierte Fixtures im selben `symphony-test`
aus Backlog/Todo/Definiert. Deren bereits erfüllte Anforderungen werden gemeinsam
beurteilt und begründet verworfen. Erwartet werden Erstzuweisung, beide Skip-Labels,
drei explizite Mitgliedsabschlüsse in genau einer PO-Session sowie die ausgeführte
Checkout-SHA. Die Startliste enthält ausschließlich diese vier IDs; weitere
AI-Phasen und neue Tickets gehören nicht zu diesem begrenzten Szenario. Eigene
PO-Worktrees werden mit separaten Quell-/SHA-Belegen journalisiert und nach
Sauberkeits-/Identitätsprüfung entfernt. Abweichende Worktrees bleiben zur
Recovery erhalten; das Cleanup meldet einen Fehler. Das Szenario ersetzt weder
Aggregation/Relationsübernahme noch Folge-Ticket- oder gemeinsame Reviewbelege.

`--scenario po_handoff` verwendet genau drei eigene IDs: einen regulären
Bootstrap sowie einen delegierten BLOCKER und ein delegiertes Yolo Review im selben
`symphony-test`.
Der BLOCKER beschreibt einen erforderlichen externen Betreiberbeleg und wird
begründet an den Menschen übergeben. Die unabhängige Yolo-Review-Fixture prüft den sauberen separaten Checkout und dessen vollständige gemergte SHA.
Erfolg verlangt beide tatsächlichen Sessions, ausdrückliche Mitgliedsbelege,
entfernte Delegation, BLOCKER-Erhalt beziehungsweise Abschluss nach Review und
bestätigtes Cleanup. Die explizit registrierte Übergabefixture prüft den
Abnahmetransport am gebundenen Checkout, keinen Implementierungsmerge; sie
benötigt und erzeugt keine erfundene PR-Merge-Evidenz. Weitere
Implementierungsphasen, Aggregationen und neue Folge-Tickets sind in diesen
begrenzten Szenarien gesperrt; sie brauchen eigene registrierte Testszenarien.
Dieser Pass wäre keine vollständige Featureabnahme oder Fix-Ticket-Abnahme.

`--scenario po_aggregation` prüft drei eigene Backlog-/Todo-/Definiert-Ursprünge
in einer Sitzung und genau ein journalisiertes Aggregationsticket. Anforderungen,
`symphony-generated`, menschliche Zuständigkeit, Delegation und sämtliche
Ursprunglinks werden bestätigt, bevor die Ursprünge abgeschlossen werden.
`--scenario po_followup` prüft ein eigenes Yolo-Review-Ticket mit einer tatsächlich
fehlenden Dokumentationsdatei, genau ein verknüpftes Fix-Ticket, dessen echte
Blockierung des Ursprungs und eine Warteentscheidung in Yolo Review. Der Fix
erhält den konfigurierten Menschen und Agenten auch ohne `--yolo`. Der Startmodus gehört zum
Laufplan und darf bei Wiederaufnahme nicht geändert werden.

Diese beiden begrenzten Szenarien enden bei Anlage/Ursprungabschluss bzw. Warten. Abgeleitete IDs werden
vor dem ersten Schreibversuch in separaten Laufbelegen registriert und beim Probe-
und Cleanup-Pfad einbezogen; sie erweitern **nicht** die Startfreigabe der
Testinstanz. Eine zweite Anlage, fremde Ursprünge oder Abhängigkeiten werden
abgewiesen. Eigene abgeleitete Tickets werden vor den Ursprüngen gelöscht;
unerwartete Workspaces, fremde Änderungen oder unbestätigte Löschung erhalten das
Journal und verhindern Erfolg. Ein vollständiger Implementierungs-/Merge-/Fix-
Durchlauf ist damit noch nicht nachgewiesen.

Für diesen Gesamtweg ergänzt `scripts/test-instance-pipeline` einen begrenzten
Betreiberstart mit ausdrücklich angegebenen eigenen Ticket-UUIDs. Er verwendet
die PRO-736-Projektprüfung, gemeinsame Exklusivsperre und Prozessbereinigung.
Ein separates Workflow-Abbild unter `_build/` ergänzt ausschließlich
`tracker.app.allowed_issue_ids` und `allow_yolo_followup_ids: true`; alle regulären Phasen, Hooks, Tests, Skills und
Merge-Gates bleiben erhalten. Es gibt keine Bootstrap-Phasensperre. Der bereits
gebaute, quellgebundene Kandidat startet über `mise exec -- bin/symphony`;
Hauptcheckout und Hauptinstanz werden nicht aktualisiert. Dieses Betreiberwerkzeug
ist kein zusätzlicher Workerzugriff auf private Konfiguration oder Linear.

1. Die vorhandene Umgebung exklusiv übernehmen; frisches Manifest, vollständiges
   Dummy-Inventar, eigene Fixture-UUIDs und GitHub-Rechte bestätigen. Unbeteiligte
   Projekte/Worktrees/Dateien, Remote-Stand und Konfiguration protokollieren.
   Den Kandidaten mit `make check` bauen, seine Quelle mit
   `python3 scripts/test-instance.py source "$PWD"` in einer Datei unter `_build/`
   festhalten. Vor dem ersten Schreibversuch die eigenen UUIDs journalisieren.
2. Über den erlaubten gebundenen Linear-Weg ein delegiertes Umsetzungsticket im
   Dummy-Projekt mit einer konkreten, begrenzten Anforderung an eine neue Datei
   `docs/po-proof-<lauf-id>.md` anlegen. Anforderungen/Validierung und menschliche
   Zuständigkeit vollständig angeben. Projekt/Team/Agent/Labels frisch bestätigen;
   keine fremden Tickets in die Startliste aufnehmen. Für die gemeinsame
   Eingangsprüfung können mehrere eigene IDs übergeben werden.
3. Den folgenden Aufruf zunächst ohne `--execute` prüfen; zum tatsächlichen Start
   einen neuen Ergebnisordner verwenden. `--yolo` entsprechend der zu prüfenden
   Startmodusmatrix setzen. Der Prozess endet spätestens nach 600 Sekunden;
   SIGTERM/SIGINT beendet eigene Worker kontrolliert. Zeitablauf ist kein Pass.

   ```bash
   scripts/test-instance-pipeline --source "$SOURCE_JSON" --manifest "$MANIFEST" \
     --run-id "$RUN_ID" --issue-id "$FIXTURE_UUID" \
     --result-dir "$PWD/_build/pipeline/$RUN_ID" --port 4101 --timeout 600 --yolo --execute
   ```

4. Reguläre Planung/Implementierung/PreReview/Review/Test/Merge anhand tatsächlicher
   Workpads, Sessions, Prüfungen und GitHub-PR beobachten. Merge-Commit-SHA und
   fachlichen Reviewcheckout belegen. Keine Statussprünge zum Vortäuschen des
   Durchlaufs. Ein bewusst eingebrachtes, separat beschriebenes Review-Finding
   muss ein Fix-Ticket mit gerichteter Blockierung des Ursprungs erzeugen; Ursprung
   und Delegation bleiben in Yolo Review. Nur bestätigte eigene Folgefixe aus
   abgeschlossenen Anlagejournalen erweitern transitiv die Startliste dieses
   isolierten Pipeline-Laufs. Fremde Ursprünge, unfertige Anlagen und gewöhnliche
   Folgetickets ohne Abnahmesperre erhalten keine Freigabe. Der Fix durchläuft
   dieselben regulären Gates; anschließend die gemeinsame Schlussabnahme und
   Review mit entfernter Delegation belegen, auch ohne `--yolo`. Die begrenzten
   po_followup-Fixtures erhalten diese Erweiterung ausdrücklich nicht.
   Zusätzlich Backlog mit echter Vorgängerrelation zurückstellen, nur den
   Vorgänger freigeben und genau einen neuen Auftrag anhand dauerhafter
   Zustellbelege prüfen; unveränderte Wiedervorlage/Neustart zählen null weitere.
5. `result.json` protokolliert ausschließlich `operator_pipeline_observation`,
   beobachtete Sessions/Status/Projektbindungen und Prozessbereinigung. Es vergibt
   keinen Abnahmestatus und quittiert Daten-Cleanup nie automatisch. Betreiber
   ergänzt tatsächliche Test-/PR-/Merge-/Abnahmebelege, getrennte Relay-Consumer
   und Empfang/Ack sowie Hauptfortschritt. Fehlende kurze Statusbeobachtungen
   anhand dauerhafter Session-/Workpad-Belege abgleichen, nicht erfinden.
6. Eigene Testtickets/Relationen, Branches/PRs und Workspaces über ihre exakten IDs
   bereinigen; gemergte Teständerungen gezielt reversieren, keinen fremden Stand
   zurücksetzen oder force-pushen. Unerwartete Änderungen erhalten. Konfiguration,
   unbeteiligte Ausgangsarbeit, Portfreiheit und gestoppte Prozesse unabhängig
   bestätigen. Prüf-/Fehlerbelege und SHAs erhalten. Ein separater Cleanupbeleg
   ändert kein fehlgeschlagenes Testergebnis. Erst der vollständige fachliche
   Beleg einschließlich Restore erfüllt den Gesamtfall.

`--scenario bootstrap` ist der unveränderte Standard. Ein Wiederaufnahmelauf
muss dasselbe Szenario angeben; `--resume --cleanup-only` räumt ausschließlich
seine eigenen Fixtures auf. Verlorene Schreibantworten bleiben Fehlläufe und
werden beim Cleanup anhand der bereits journalisierten IDs abgeglichen.
Der Delegationstest weist noch keine PO-Aggregation oder Schlussabnahme nach.

`result.json` enthält `evidence: live`, Quellstand/-modus, Projektbindungen,
Zeitgrenze/-punkte, Szenarioresultate, Worker-/Sessionbezug, Test-Consumer-IDs,
Ausgangsfingerprints der Dummy-Repositories, Cleanup- und Hauptprozessnachweis.
`status: passed` plus Exit 0 verlangt vollständige Szenarien und Cleanup.
Fehlende Bereitschaft, Timeout, Signal, ungültiger Quellstand und unbestätigtes
Cleanup bleiben Fehler mit Exit 1. Synthetische Tests unter `test/` haben keinen
Livebeleg; deren Ergebnis heißt ausdrücklich `fixture`. Providerpayloads, Tokens
und Relay-Receipts gehören nicht in öffentliche Belege. Lokale Logs sind privat.
Bei einem fehlgeschlagenen App-Probeabruf bleibt der sichere Fehlercode
`runtime_failure.code=linear_app_request_unavailable` im Ergebnis erhalten.
Die privaten Prozesslogs ergänzen eine feste Transportkategorie und Anfragedauer
sowie den Fixture-/Laufbezug; weder Providertexte noch Exceptions gelangen in
den öffentlichen Fehlerbeleg. Nur die in Linear rein lesende Beobachtungsprobe
darf bei genau diesem Fehler oder `linear_http` mit Status `503` innerhalb
desselben Laufs erneut beginnen: insgesamt
höchstens zwei Wiederholungen nach zwei bzw. fünf Sekunden, auch über erfolgreiche
Zwischenprobes und `--resume` hinweg. Dienst, Fixtures und Gesamtfrist bleiben bestehen;
`probe_retries` dokumentiert die Versuche. Erst eine vollständige frische Probe
kann Erfolg belegen. Auth-, Rate-Limit-, Schema-, Journal- und fachliche Fehler
sowie abgelaufene Fristen stoppen weiterhin. Anlage, Delegationsänderung und
Cleanup werden nicht automatisch wiederholt. Bei ausgeschöpftem Budget bleibt
der Lauf fehlgeschlagen; Cleanup läuft weiterhin. Ein unbekannter Transportgrund
ist kein Authnachweis.

Eine PO-Probe löst Menschen und Agenten einmal je gebundenem Projektkontext auf
und verwendet diese IDs für alle Mitglieder desselben Aufrufs. Die nächste
CLI-Probe beginnt mit frisch geladenen Kontexten; die aufgelösten IDs werden
nicht im Laufjournal oder einem zusätzlichen Cache gespeichert. Ticketdaten und
Kommentare bleiben je Mitglied frisch. Fehler bei der Auflösung brechen die
Probe ab; das Cleanup benötigt keine erneute Agentenauflösung.

Das dauerhaft vor Ticketanlage geschriebene Laufjournal enthält die gewählten UUIDs.
Unklare Anlageantworten erzeugen keine erneute Anlage. `--resume` akzeptiert nur
dieselbe Laufkennung, Instanz, Quelle und Ergebnisablage, bewahrt vorherige Resultate
und verwendet bekannte Fixtures. Vor dem Preflight einer Wiederaufnahme wird das
vorherige Resultat archiviert, auch wenn inzwischen Quelle oder Hauptdienst abweichen.
Eine noch offene frühere Laufkennung sperrt neue Läufe und den freien Testdienst.
Zum reinen Aufräumen denselben Aufruf mit
`--resume --cleanup-only` ausführen: keine neuen Tickets/Worker, vorhandenes Escript
mit passendem eingebettetem Quellbezug, auch nach Quelländerung oder Hauptdienstende.
Die Wiederherstellung wird dokumentiert, aber nicht als bestandener Test ausgegeben.

Benötigt gerade das Cleanup eine Codekorrektur, den korrigierten Stand zunächst
lokal prüfen und mit `make build` bauen. Für denselben alten Lauf zusätzlich
`--cleanup-plan-sha256 <SHA256-der-unveränderten-plan.json>` angeben; dabei
`--expected-sha` und `--expected-source` auf den korrigierten Build setzen.
`--resume --cleanup-only`, ursprüngliche Instanz, Lauf-ID, Ergebnisablage,
Checkout, Szenario und Startmodus bleiben erforderlich. Der `--yolo`-Startmodus
wird auch in den Hilfsphasen vor der Projektvorbereitung gesetzt. Der Preflight prüft
aktuellen Quellstand und Buildstempel sowie den ausdrücklich benannten alten
Plan. Die Runtime erlaubt diesen Quellwechsel ausschließlich für Cleanup und
prüft unverändert die alten Journal-, Projekt-, App-, Fixture- und Workspacebindungen.
Plan und Operationsintents werden nicht umgeschrieben. Das Recoveryresultat
nennt alten Plan samt Hash und tatsächlich ausgeführten neuen Build; archivierte
Fehlresultate bleiben erhalten, Exitstatus 1 und `status=failed` bleiben auch bei
`cleanup=true` bestehen. Keine neue Probe oder Sitzung vor bestätigtem Cleanup.

Für neu angelegte YOLO-Tickets verwenden Anlageabgleich und abgeleitete
Testfixtures denselben begrenzten Beschreibungsvergleich: `-`/`*` bei
obersten Listen, zusammengefasste leere Zeilen, eine Leerzeile zwischen
Doppelpunkt-Einleitung und oberster Aufzählung oder `1. `-Liste sowie belegte
Linear-Issuelinks am Zeilenende oder im Fließtext: Die nackte URL und
`[ISSUE-SCHLÜSSEL](URL)` sind nur bei identischem URL-Schlüssel austauschbar.
Das gilt auch neben Code-Spans, aber nie innerhalb von Code-Spans. Nummerierung,
Listentrennzeichen und Abstände innerhalb nummerierter Listen bleiben unverändert.
Für eindeutige Prosa gilt zusätzlich der belegte Backslash-Roundtrip:
Ein oder zwei Backslashes vor ASCII-Buchstaben/Ziffern stellen denselben
literalen Backslash dar ([CommonMark §2.4](https://spec.commonmark.org/0.31.2/#backslash-escapes)).
Längere Folgen, Satzzeichen-Escapes und Zeilenumbrüche werden nicht angeglichen.
Diese zusätzliche Toleranz gilt konservativ nur für Dokumente ohne Code,
allgemeine Linksyntax, HTML oder verschachtelte/eingerückte Blöcke; bekannte
endständige Linear-Issuelinks sind ausgenommen, URL-Zeilen bleiben unverändert.
Der beobachtete Linkziel-Roundtrip `[Text](URL)` / `[Text](<URL>)` wird für
einfache Linear-Issue-URLs in eindeutigen Prosaabsätzen angeglichen
([CommonMark §6.3](https://spec.commonmark.org/0.31.2/#links)). Beschriftung und
URL bleiben exakt; Absätze mit Code, Escapes, Bildern, verschachtelten Links,
HTML oder unbestätigter Linksyntax sind von dieser Toleranz ausgeschlossen.
Anlagepayload und journalisierter Intent werden dabei nicht umgeschrieben.
Codeblöcke bleiben unverändert; Dokumente mit
eingerückten Blöcken oder rohem HTML verlangen weiterhin Bytegleichheit.
Andere Texte, Links, Einrückungen, Checkboxen, Titel, Identitäten, Status und
Zuweisungen bleiben strikt geprüft. Bei abweichenden angelegten Tickets nennt
`yolo_created_issue_changed` das erste abweichende Feld und seine Stelle; die
Beschreibung erhält Byteposition, Zeile, Spalte und kurze Textfragmente der
normalisierten Vergleichsfassung.
Unbekannte Transformationen werden abgewiesen;
unvollständige Anlagen sind weder erfolgreiche Aggregationen noch Testpässe.

SIGINT/SIGTERM lösen kontrolliertes Cleanup aus; ein Guardian hält die Reservierung,
bis eigene Nachkommen beendet sind, auch nach SIGKILL des Runners. Kernel-Locks
werden freigegeben, Lockdateien niemals gelöscht. Nach SIGKILL bleiben Journal und
letztes Fehlerresultat zur expliziten Wiederaufnahme erhalten. Das Fixture-Journal
bindet die Laufkennung zusätzlich an Instanz und absoluten Planpfad der Ergebnisablage;
eine neue Ergebnisablage oder Instanz darf bestehende Fixtures nicht übernehmen.
Fehlende oder abweichende Journalbindungen werden abgewiesen. Ein neuer Run darf
keine unklare alte Anlage verdecken. Cleanup prüft UUID, Titel, Beschreibung,
Projekt, Team und Assignee vor Löschung. Nur saubere eigene Bootstrap-Worktrees
auf der erwarteten Basis, dem erwarteten `symphony/<Kennung>`-Branch und im
Git-common-root des gebundenen Projekts werden über die normalen Projekthooks entfernt.
Diese Identitätsprüfungen erfolgen vor jedem Entfernungshook; fremde
Änderungen führen zu einem sichtbaren Fehler und bleiben erhalten. Ein unklarer
Worktree-Basisstand wird abgewiesen; die tatsächliche Basis nach dem Erstellungshook
wird vor Workerarbeit je Fixture dauerhaft erfasst. Auch ohne Workspaceverzeichnis
müssen dessen Git-Registrierung und Branch entfernt sein, bevor Cleanup Erfolg meldet.
Ein unklarer Anlage-/Cleanupausgang erfordert Prüfung des vorhandenen Journals über die
gebundene Runtime, kein blindes Löschen oder Umbenennen der Reservierung.

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

Runtime-Statuswechsel lesen den aktuellen Status vor dem Schreiben. Ist der
Zielstatus bereits erreicht, entfällt die Mutation. Geht ihre Transportantwort
verloren, wird der Status einmal frisch gelesen: Nur der vollständig bestätigte
Zielstatus zählt als Erfolg. Fehlgeschlagene oder partielle Abgleiche sowie ein
abweichender Status bleiben Fehler; der Aufruf wiederholt keine Mutation.
Das ist ein Zustandsabgleich, kein zusätzliches Journal oder atomarer Schutz
gegen gleichzeitige fremde Statusänderungen. Für direkt aufgerufene
`linear_graphql`-Mutationen gilt weiterhin der agentenseitige Abgleichvertrag.

App-Kommentarschreibvorgänge und ihre Wiederaufnahme werden pro Projekt
prozessübergreifend serialisiert. Der bisherige Journal-Lock schützt die lokale
Intent-Anlage, Bestätigung, Klassifikation und Archivierung; Linear-Requests
laufen außerhalb dieses Locks. Scans holen Kommentare vor dem lokalen Abgleich
und verwenden danach eine frisch geladene Intent-Sicht. Eine zusätzliche
Issue-spezifische Scan-Sperre verhindert doppelte Abrufe bei parallelen Scans.
Jede App-Anfrage darf eine Kommentar-ID nur
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

Abgeschlossene bestätigte oder verworfene Beleggruppen verlassen nach 14 Tagen
in kleinen Chargen den aktiven Suchpfad. Ihre Dateien liegen unverändert unter
`comments/archive/`; ein vor dem Verschieben dauerhaft gespeicherter, geprüfter
Suchindex erhält die Klassifikation alter eigener Kommentare sowie Relay-,
Antwort- und Recovery-Abfragen. Offene oder unklare Intents bleiben aktiv.
Bei einem unterbrochenen Verschieben gilt der Index bereits als maßgeblich.

Konkurrierende Journalzugriffe warten regulär bis zu 10 Sekunden auf den Lock
(`comment_journal_busy` bei Zeitüberschreitung, `comment_journal_unavailable`
bei Helfer-/Backendfehlern). Scans verwenden für den lokalen Journalabgleich
eine kürzere Wartezeit und wiederholen `comment_journal_busy` begrenzt; die
Startprüfung wiederholt diesen Fehler ebenfalls, bevor ein Workerfehler zählt.
Schreibvorgänge behalten eine begrenzte Wartezeit. Eine Journal-Haltezeit über
zwei Sekunden wird mit Dauer, Zweck und verfügbarem Issue-/Session-Kontext auf
Debug-Level protokolliert. GraphQL-Aufrufe ohne Kommentarschreibvorgang
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
Fälligkeit wird nach der Journal-Sperre erneut geprüft. Ein vollständiger
Checkpoint aktualisiert den persistierten Hintergrundcache. Dessen Schlüssel
bindet Projekt, App-Workspace, Client, App-User, Beratungsauswahl, Issue und Signalformat; Neustart und neue
Übernahme entwerten ihn nicht. Scanfehler erhalten die letzte verlässliche
Beobachtung, sperren aber die Abkürzung bis zum nächsten erfolgreichen Vollscan.
Erst ein vollständiger Scan aktualisiert `last_successful_scan`; ein Signalcheck
beweist weder Vollständigkeit noch Löschung. Ein ausgefallener Poller ist ein
sichtbarer Fehler, kein Anlass für direkte Ersatzabfragen gegen Linear.

Ein GraphQL-Request liest den neuesten Kommentar und den neuesten Kommentar
eines anderen Autors. Ein unverändertes Signal benötigt keinen Seitenabruf;
bestätigte eigene Kommentarversionen aus dem Journal bleiben ohne Vollscan.
Fremde oder ungeklärte Relay-Kommentarereignisse lösen sofort einen Vollscan aus,
auch bei unverändertem Signal. Offene `held`-Stränge erzwingen für sich allein
keinen Vollscan. Eigene Relay-Echos verlangen einen Beleg für die konkrete
Schreibaktion und bei Updates die bestätigte Kommentarversion; unklare Echos
gelten als fremde Ereignisse. Ohne Relay erfolgt spätestens nach fünf Minuten ein
Sicherheitsvollscan, mit Relay spätestens nach 30 Minuten. Der reguläre
Hintergrundtakt beträgt mit Relay mindestens 60 Sekunden, unter 20 %
App-Restbudget mindestens 180 Sekunden; fremde Ereignisse überholen diese Frist.
Explizite Checkpoints, Acks und Status-/Merge-Aktionen führen immer einen frischen
Vollscan aus, auch nach einem Cache-Hit oder einem bereits laufenden Hintergrundscan. Die erste vollständige Beobachtung ist historische
Baseline. Der Worker erhält sie einmal zur Übernahme noch offener Hinweise;
bereits zuvor erkannte offene Versionen bleiben erhalten. Manuelle Gates und
Dialog-AI werden durch diesen Eingang nicht dispatcht.

### Beratende AgentSession-Stränge

Linear repräsentiert AgentActivities selbst im Kommentar-API-Modell: auslösende
Mentions, menschliche Popup-Folgefragen und Antwortspiegel können über
`issue.comments` erscheinen. Die UI-Trennung ist deshalb keine Coding-Grenze.
Die Bridge soll keine zusätzlichen `commentCreate`-Spiegel erzeugen; bestehende
Providerrepräsentationen werden nicht gelöscht. Symphony trennt am Kommentareingang.

`tracker.advisory_agent_ids` nimmt eine Liste stabiler App-User-UUIDs oder eine
kommagetrennte Zeichenfolge an, auch `$LINEAR_ADVISORY_AGENT_IDS`. Ohne expliziten
Workflowwert gilt die gleichnamige öffentliche Projektvariable; Standard ist `[]`.
Werte werden getrimmt, dedupliziert und auf höchstens 20 UUIDs begrenzt.
Die gebundene App prüft Appstatus, Aktivität und Workspacezugehörigkeit; ihre
eigene Coding-App-ID ist unzulässig. Namen, Textmuster, YOLO-Auswahl und bloße
App-Autorenschaft begründen keinen Ausschluss. Vorhandene Konfiguration wird um
diesen Wert ergänzt, nicht ersetzt. Projekt-/Workerbindung und Hintergrundcache
berücksichtigen die Auswahl; Änderungen benötigen Neustart, ein abgelehnter
Reload erhält den bisherigen Kontext. Andere Projekte behalten ihre Auswahl.

Der vollständige Scan sammelt Sessionmetadaten über alle Seiten. Eine belegte
`agentSession.appUser.id` bindet Root und gegebenenfalls `sourceComment` an das
gescannte Issue; Nachkommen folgen transitiv über `parentId`. Fehlende Roots,
künstliche Sessionroots und strukturierte Mentions einer konfigurierten UUID
lösen begrenzte direkte Root-/Sessionabfragen aus. Beide Sessionrelationen werden
paginiert: maximal acht Rootauflösungen pro Scan, jeweils drei API-Seiten;
fehlgeschlagene/unvollständige Auflösungen frühestens nach 30 Sekunden erneut.
Das Budget gilt auch bei Scanfehlern. Fällige Roots werden nach frühester Retryfrist
priorisiert, damit wiederholt ungeklärte Roots spätere Kandidaten nicht verdrängen.
Alle über die Seiten beobachteten Sessionbindungen bleiben erhalten; abweichende
Rootmetadaten erlauben keine reguläre Freigabe. Auch aus GraphQL-Teilantworten bleiben
vollständig belegte Bindungen erhalten; die Antwort gilt weiterhin als unvollständig.
Die vorhandenen Transport-, Rate-Limit- und Journalwege bleiben maßgeblich.
Zyklen, widersprüchliche oder unvollständige Bindungen bleiben zurückgehalten;
Zeitablauf und eine Null-Session allein geben Kandidaten nicht frei. Unabhängige
Coding-Kommentare bleiben verfügbar. Der bestehende Hintergrundabgleich prüft
ungeklärte Stränge bei fremder Änderung oder spätestens beim Sicherheitsvollscan erneut.

Die projektlokale Inbox speichert Zuordnung und Quarantäne ohne zusätzlichen
Quelltext unter derselben Journal-Sperre. Sie bewertet neue Metadaten auch bei
unverändertem Body/Zeitstempel, erhält Kommentarversionen und Acks und entfernt
Beratung vor neuer Baseline und jeder Zustellung. Altbaselines werden für die
Ausgabe gefiltert; gespeicherte Historie und Sessiondateien bleiben erhalten.
Bekannte Beratung bleibt über Edit, Auflösen, Root-Löschung und Prozessneustart
ausgeschlossen. Filterung gilt nicht als Löschung. Ein zunächst zurückgehaltener
normaler Kommentar wird nach belegter Klärung regulär zugestellt; bestätigte
Quellversionen bleiben bestätigt. Bereits geladener Modellkontext lässt sich
nicht rückwirkend entfernen. `advisory_threads` im Checkpoint meldet nur IDs,
`held`/`excluded` und `previously_delivered`, ohne Beratungstext erneut auszugeben.
Letzteres bezeichnet den protokollierten Zustellstatus, keinen Nachweis über den
tatsächlich geladenen Modellkontext.

Die synthetische Regression läuft mit:

```sh
./scripts/mix-gate test test/symphony_elixir/advisory_comments_test.exs test/symphony_elixir/advisory_config_test.exs
```

Für die reale tilor-Abnahme lädt Pai als Betreiber den Kandidaten in den bereits
freigegebenen authentisierten Scanner für das ausschließlich synthetische
PRI-169. Keine Worker-, Gateway- oder Relaystarts und keine Linear-Schreibmutation.
Der Helfer `scripts/advisory-isolation.exs` ergänzt diesen bestehenden Scanner;
er richtet keinen Zugang ein und wird vom Worker nicht live gestartet. Im
verifizierten tilor-Projektkontext mit dessen öffentlicher Beratungs-ID:

```elixir
Code.require_file("scripts/advisory-isolation.exs", candidate_root)
# issue_id: interne UUID von PRI-169; probe_root: neuer, separater Report-/Journalroot.
AdvisoryIsolationProbe.run(issue_id, Path.join(probe_root, "baseline"), :baseline)
AdvisoryIsolationProbe.run(issue_id, Path.join(probe_root, "incremental"), :incremental)
# In einem neuen Scannerprozess mit derselben Kandidaten-/Projektbindung:
AdvisoryIsolationProbe.run(issue_id, Path.join(probe_root, "baseline"), :resume)
AdvisoryIsolationProbe.run(issue_id, Path.join(probe_root, "incremental"), :resume)
```

Der Helfer verwendet den echten `Client.scan_issue_comments`, die zentrale Inbox
und die ausgelieferte Baseline/Eingangsliste. Er verlangt null `A1-`-Marker,
genau eine Coding-Kontrolle vor dem lokalen Probe-Ack und keine erneute offene
Eingabe danach oder beim Neustart. Fehlschläge sind keine Abnahme. Pai hält
Quell-SHA und gegebenenfalls Diff-/Paketdigest, die wirksame öffentliche
Workspace-/Projekt-/App-Bindung, getrennte Journale und alle vier Ergebnisse
im Ticketbeleg fest. Diese Prüfung ist vor Merge fällig; die kontrollierte
Betriebsübernahme nach Merge erhält laufende Jobs und dokumentiert die Grenze
bereits geladenen Kontexts.

### Journal und Zustellung

Unter dem vorhandenen projektlokalen `state_root/inputs/` hält `DurableState`
pro Issue die Bindung, beobachtete Quellversionen (auch aus Vor-/Nachscan-Signalen), Baseline, letzten vollständigen
Abruf, Scanfehler und Zustände `recognized`, `delivered`, `processed` fest.
Eine Issue-eigene Scan-Sperre serialisiert parallele Scans. Linear-Abrufe laufen
außerhalb der OS-Journal-Sperre; diese schützt kurze lokale Journal-Snapshots,
Belegbestätigungen und App-Schreibbelege. Der Scan gleicht unbestätigte Belege
vor der Entscheidung ab und übernimmt den Inbox-Stand nur bei unverändertem
lokalem Ausgangszustand. Ack und Scan-Commit sind getrennte lokale Transaktionen.
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
Dispatch-Refresh erhält den sichtbaren Retry samt Ergebnis und IDs.
Definitive Zugriffsablehnung (401/403 ohne Rate-Limit, Auth-GraphQL-Fehler auch
bei der Identitätsprüfung oder abgelehnte App-Identität/Zugangsdaten) pausiert
den betroffenen Dispatch-, Retry- oder Abschlussabgleich ohne weiteren Timer
oder Modellstart. Workspace,
Claim und Fortsetzungskontext bleiben erhalten. Dashboard/API zeigen den Fehler
mit der Fortsetzungsbedingung und ohne Fälligkeit. Nach Reparatur des Zugriffs
aktiviert ein expliziter Dashboard/API-Refresh den bestehenden Retry; dieser
prüft den Tracker frisch und pausiert bei erneuter Ablehnung wieder. Reguläre
Polls und alte Timer aktivieren ihn nicht; ein Statuswechsel ist nicht nötig.
Der projektweite Refresh reiht die Anfrage je Projekt ein, ohne auf beschäftigte
Projektorchestratoren zu warten.
Auch erfolgreiche Antworten mit bestätigtem `remaining: 0`/`0.0` setzen eine Pause.
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
Der Dienst zählt Requests je App-Bindung nach Anfrageart und protokolliert bei
laufendem Verkehr alle fünf Minuten `Linear budget summary` mit Restbudget und
Zählern. Unter 20 % von `x-ratelimit-requests-limit` werden nur Hintergrundscans
und wiederholte workspaceübergreifende Wartemarker-Lookups verlängert;
deren erste Prüfung bleibt möglich und Hintergrund-Wiederholungen erfolgen
frühestens nach zwei Minuten. Frische Aktionsprüfungen sowie Kandidatenabfragen,
Checkpoints, Handoffs und Schreibvorgänge bleiben vorrangig.

Die historische Vorher-Referenz aus PRO-715/PRO-716 verglich 3.600 simulierte Sekunden
mit 5-Sekunden-Arbeitstakt, einer Seite je Abfrage und unveränderten Kommentaren,
ohne Workeraktionen. Kaltstart und Token/Identity/Candidates/Status/Signal/Seiten
werden getrennt gezählt; dies ist keine Live-Lastmessung:

| Szenario | Vor PRO-715 HTTP/h | Nach PRO-715, vor Relay HTTP/h (warm) |
| --- | ---: | ---: |
| Idle, ein Workspace | 1.440 | 720 |
| Ein aktives Ticket | 7.200 | 1.584 |
| Drei aktive Projekte, ein Workspace | 18.720 | 3.312 |
| Drei aktive Projekte, zwei Workspaces | 20.160 | 4.032 |

Die damalige Relay-Regression über dieselben 3.600 Sekunden ergab in allen vier
Szenarien warm **0 Linear-HTTP/h** vor dem fälligen Sicherheitsabgleich.
Die aktuellen `linear_budget_test.exs` und `relay_budget_test.exs` prüfen stattdessen
je Szenario 60 Ticks (fünf simulierte Minuten) sowie Kommentar- und Reconcilefristen
gezielt an ihren Grenzen; ein echter 5-Sekunden-Timer bleibt abgedeckt. Diese
Kurztests sind keine neue Stunden- oder Livemessung. Kaltstart, Reconcile und Aktionen werden
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
Es gibt keine harte Zustell-SLA; zwischen Polls überschriebene Kommentartexte
sind nicht rekonstruierbar. Delegations- und Prioritätswechsel werden nur soweit
erkannt, wie sie in der Linear-Issue-Historie abrufbar sind. Eine atomare
Linear-/GitHub- oder Exactly-once-Garantie besteht nicht.
Das unvermeidbare Fenster zwischen letzter API-Antwort und Aktion bleibt bestehen.

### Ausführbare Operator-Messübergabe PRO-716

Diese installationsspezifische historische Messübergabe ist kein gemeinsames
Pflichtgate. Der geschützte Betreiberlauf verwendet ausschließlich **`symphony-PRO-716`**.
Vor dem Wechsel alle laufenden Symphony-Jobs abschließen oder kontrolliert
beenden, deren Worker/Leases prüfen und die alte Dienstinstanz beenden.
Der bestehende hostweite Mutex und der auf den Ticketworktree zeigende Launcher
bleiben unverändert. Symphony-/Insight-Hauptkonfigurationen bleiben unverändert.
Der Betreiber richtet die isolierten Testprojektbindungen und deren Wiederherstellung ein;
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
cd /ABS/Symphony-worktrees/PRO-716
# Erst nach Ende aller Jobs und der alten Instanz: Feature -> Baseline.
git apply --check --reverse /ABS/HANDOFF/feature.patch
git apply --reverse /ABS/HANDOFF/feature.patch
git apply --check /ABS/HANDOFF/instrumentation.patch
git apply /ABS/HANDOFF/instrumentation.patch
# Der Betreiber hat jetzt die isolierten Baseline-Testbindungen vorbereitet.
symphony-PRO-716 --budget-capture /ABS/MEASUREMENT/baseline.run.json
```

Nach regulärem Ende der Baseline, gesicherten Belegen und freiem Mutex:

```sh
cd /ABS/Symphony-worktrees/PRO-716
git apply --check --reverse /ABS/HANDOFF/instrumentation.patch
git apply --reverse /ABS/HANDOFF/instrumentation.patch
git apply --check /ABS/HANDOFF/feature.patch
git apply /ABS/HANDOFF/feature.patch
# Der Betreiber stellt denselben isolierten Ausgangszustand und die Featurebindung her.
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
Ein gemeinsamer Lauf mit sieben Phasen genügt; es gibt keine
Pflicht, jede Profilkombination separat gleich lang zu wiederholen. Sämtliche
relevanten Pfade, tatsächlichen Aktionen und zusätzlichen App-Prozesse müssen
vollständig gezählt sein. Fehlende Pfade bleiben offen.

| Parameter | Festlegung |
| --- | --- |
| Workspace-/Projektbindung | verifizierte Workspace-UUIDs, Projekt-Slug-IDs und isolierte Projektroots; keine erfundenen IDs |
| Schreib-/Arbeitsziele | ausschließlich Prolok/symphony-test; aktuelle IDs vor Verwendung gebunden verifizieren |
| Startbegrenzung | vorhandenes `tracker.app.allowed_issue_ids` auf Dummy-UUIDs, für zusätzlich lesende Projekte `[]`; keine produktiven Tickets aktivieren |
| Assignee/U1 | verifizierte menschliche UUIDs/E-Mails, stabile Consumer-ID und gemeinsame Owner-Zuordnung; keine Assigneeänderung |
| Öffentliche Appfelder | `LINEAR_APP_CLIENT_ID`, `LINEAR_APP_WORKSPACE_ID`, `LINEAR_APP_USER_ID`, `LINEAR_PROJECT_SLUG`, `LINEAR_ASSIGNEE` |
| Secret-Referenznamen | je Projekt `LINEAR_APP_SECRET` und `LINEAR_RELAY_KEY`; Werte nur beim Betreiber, gleiche App-Credentials/Workspace-Key je Workspace |
| Relay | `LINEAR_RELAY_URL=https://5jald162lk.execute-api.eu-west-1.amazonaws.com`, `LINEAR_RELAY_CONSUMER_ID`, `LINEAR_RELAY_OWNERS`; Release `a29a853a8d06fd140aae1167f1f542b89addfec6` |
| Laufparameter | gleiche Polltakte, Kapazitäten/Workerprofile; Reconcile-Intervall plus unveränderten Jitter und öffentliche Konfigurationshashes vorab festhalten |
| Zustände/Restore | frische isolierte Ausgangszustände für beide Kaltstarts, danach Zustände über alle Phasen erhalten; Consumer-/Inbox-/Journal-/Cooldown-Satz, Konfiguration und ursprüngliche Dummy-Status-/Kommentarwerte sichern |
| Last | identische Aktivierung/Arbeitsaufträge, Burst mit fünf Kommentaränderungen je Dummy innerhalb eines Polltakts, natürliche Reconcile-Zeitpunkte, begrenzte Relay-Netzwerkstörung samt Rücknahme, explizite Kommentar-/Aktionscheckpoints und Anzahl eigener App-Aktionen |

Zusätzliche reale Projekte nur lesend einbeziehen. Drei gleichzeitig aktive
Projekte und mehrere aktive Workspaces bleiben mit dem einen freigegebenen Dummy-Projekt synthetisch. Zeitpunkte,
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
    "workspace_ids": ["<verifizierte UUID Prolok>"]
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

Der Betreiber nimmt die vorbereitete Netzwerkstörung und Dummy-Teständerungen zurück:
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
Details der damaligen Projektbindungen und Zeitfenster stehen ausschließlich im
historischen Messbeleg PRO-716. Sie sind keine Vorgabe für die aktuelle Testumgebung.
B1 verlangt keinen identischen KI-Fortschritt.
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
Bei einem Retry zur Abschlussklärung genügt ein fehlender Cache-Kandidat dagegen
nicht: Erst der direkte Ticketabruf klärt den Abgang. Fehler oder eine leere
Antwort erhalten den Retry und den Reviewzustand bis zur verlässlichen Klärung.
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
