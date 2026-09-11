# Linear-App-Identität

Der gemeinsame ausgelieferte `WORKFLOW.md` verwendet `tracker.auth_mode: app`.
Er referenziert die App-Konfiguration im **jeweiligen Fachprojekt** unter
`.symphony/.env(.local)`. Es sind keine Workflowkopien je Projekt nötig; dieselbe
Symphony-Installation kann isolierte Projektinstanzen parallel bedienen.
Ein gezieltes Update auf diesen Workflow benötigt die App-Konfiguration.
Unveränderte alte Versionen und alte Workflows ohne `auth_mode` sowie explizites
`auth_mode: legacy` behalten den bisherigen Zugang und ihre Semantik. Eine
App-Installation allein ändert keinen laufenden Worker. App-Fehler führen niemals
zum persönlichen Fallback.

## Normale Einrichtung

Der Betreiber aktiviert Client Credentials für die Symphony-OAuth2-App in Linear
und stellt das Client-Secret bereit. Alte Access-/Refresh-Tokens ersetzen dieses
Secret nicht. Frühere PKCE-Grants müssen administrativ kontrolliert umgestellt
werden; ihre Existenz belegt keine Client-Credentials-Aktivierung. Die Laufzeit
verwendet immer `grant_type=client_credentials` und `scope=read,write`.

Im Symphony-Root liegen die gemeinsamen `SYM_CODEX_*`-Startwerte und
`SYM_MAXIMUM_REVIEW_ITERATIONS` in `.env` und optional `.env.local`. Die führende Projektvorlage ist
[.symphony/.env](../.symphony/.env). Nicht entwicklerspezifische öffentliche
Bindungen, Projektscope und die feste Projektkennung `LINEAR_APP_INSTALLATION_ID`
werden dort versioniert. Secret, persönliche Zuständigkeit und lokale Overrides gehören ausschließlich
in die private `.symphony/.env.local` (nur für das Laufzeitkonto lesbar, etwa `0600`).

| Variable | Bedeutung und Ablage |
| --- | --- |
| `LINEAR_APP_CLIENT_ID` | Öffentliche Client-ID in `.symphony/.env` |
| `LINEAR_APP_WORKSPACE_ID` | Erwartete Organisations-ID in `.symphony/.env` |
| `LINEAR_APP_USER_ID` | Erwartete App-User-ID in `.symphony/.env` |
| `LINEAR_APP_INSTALLATION_ID` | Feste Projektkennung in `.symphony/.env`, für Symphony `symphony`; stabil über Tickets, Releases und Rechner |
| `LINEAR_APP_SECRET` | OAuth2 Client-Secret ausschließlich in der privaten Projektdatei oder geschützter Prozessumgebung |

Die Namen bleiben für alle Projekte gleich. Andere Projekte können unter denselben
Namen andere App-/Workspacewerte und Secrets setzen; keine benannten Workspaceprofile
oder neuen Provider sind nötig. Der gemeinsame Workflow enthält dafür ausschließlich
Variablenreferenzen für die Bindung; `client_secret_env: LINEAR_APP_SECRET`
ist der feste Secretname. Eine zusätzliche Auswahlvariable ist nicht nötig;
vorhandene interne Unterstützung anderer Secretreferenzen bleibt erhalten.
Bei einer indirekten Referenz wie `$SECRET_SELECTOR` liest der öffentliche
Loader zuerst ausschließlich deren Namen aus beiden Projektdateien. Alle dort
referenzierten Secret-Schlüssel werden bereits vor dem ersten Export ausgeschlossen,
auch wenn `.env.local` einen anderen Namen auswählt oder der Secret-Eintrag vor
der Auswahlvariable steht. Secretwerte werden nur im geschützten Auth-Pfad gelesen.
CLI, MCP und manuelle Skripthelfer aktivieren deshalb den ausgewählten Workflow
vor dem ersten öffentlichen Env-Laden, auch beim frischen Start mit einem
anderen Workflow als dem Default des Arbeitsverzeichnisses.

Der Zustandspfad ist fest **`<gebundener Fachprojektroot>/.symphony/state`**,
unabhängig von Release-, Worktree- oder späterem Prozess-CWD. Dafür gibt es keine
Benutzervariable und keinen absoluten Override. `.gitignore` schließt
`/.symphony/state/` aus. Die Projektkennung muss nicht global eindeutig sein:
Sie dient lokalen Codex-Namensräumen und Journalmetadaten, nicht der Authentifizierung
oder einem verteilten Lock. Zwei getrennte Projektkopien dürfen dieselbe Kennung
verwenden; ihre Zustände und Tokens bleiben lokal getrennt. Der bestehende
IssueLease ist hostlokal. Rechnerübergreifend müssen menschlicher Assignee und
Issue-Auswahl die Arbeitsumfänge trennen. Projektkennung und Zustandspfad bleiben
über Releasewechsel gleich; Journale, Übergaben und Codex-Sessions bleiben erhalten. Keine
Secretwerte in Befehlsargumenten, Prompts, Logs, Sessionartefakten oder Dokumentation.
Ein leeres Secret oder fehlende Bindungswerte sind **keine Startbereitschaft**;
der Zugriff stoppt sichtbar. Workspace und App-Actor werden per API geprüft.

Der Projektscope bleibt in `.symphony/.env` mit möglichen lokalen Overrides;
der menschliche `LINEAR_ASSIGNEE` bleibt unverändert in `.symphony/.env.local`.
E-Mail-Adressen werden weiterhin ohne
Beachtung der Großschreibung gefiltert, UUIDs als ID; es gibt keine neue
Benutzerverwaltung. `me` wird im App-Modus gezielt abgewiesen, ebenso die App-ID
und die per API erkannte eigene App-E-Mail. Nur wer bisher literales `me` nutzt,
muss es vor dem Wechsel unter der bisherigen Identität kontrolliert auflösen.
Bestehende explizite E-Mail- oder UUID-Einstellungen müssen nicht geändert werden.

Danach sind die üblichen Einstiege `symphony` und `sym-codex` vorgesehen.
Der App-Einstieg von `sym-codex` bereitet einen eigenen Release vor und startet
nur die angeforderte Codex-Sitzung. Das Update bleibt bestätigungspflichtig;
vorhandene Checkouts, globale Links und andere laufende Instanzen bleiben erhalten.
Die optionale Übergabe bestehender Workpads ist ein **separater späterer Schritt**.

## Root- und Projektladepfad

Der Launcher bindet den tatsächlichen Symphony-Root als `SYMPHONY_ROOT_DIR`.
Nach Update und Build werden die vier `SYM_CODEX_*`-Startwerte und das Reviewbudget
`SYM_MAXIMUM_REVIEW_ITERATIONS` aus
Release-`.env` und Root-`.env.local` in `.symphony/root-config.json` festgehalten und
mit dem Release versiegelt. Der Snapshot enthält diese feste Liste und die
Rootreferenz, keine Linear-Bindung und kein Secret. Die private Rootdatei wird
nicht kopiert. Die Präzedenz bleibt: extern gesetzte Startvariable vor
Root-`.env.local` vor `.env` vor eingebautem Startdefault. Das Reviewbudget bleibt
damit ebenfalls an den Release gebunden; Projektdateien können es nicht überschreiben. Rootänderungen werden
beim nächsten Release übernommen.

Orchestrator, `sym-codex`, MCP und `scripts/linear-app` behalten den jeweiligen
Fachprojektroot. `EnvFile.load_runtime/1` lädt dessen `.symphony/.env(.local)`
mit der bestehenden Override-Semantik für nicht geheime Projektwerte: Projektdateien
vor geerbten Projektwerten,
`.env.local` vor `.env`. Root-`SYM_CODEX_*` werden dabei nicht überschrieben.
Die dort gesetzten App-Bindungen, Scope und E-Mail/UUID werden für diesen Prozess
aufgelöst. Verschiedene Projekt-CWDs laufen in getrennten Prozessen/Releases;
sie schreiben keine gemeinsame App-Konfiguration. Der bestehende Bindungshash
weist Änderungen der App-/Scope-Zuordnung während eines Laufs zurück.

`EnvFile` parst Dateien ausschließlich als Daten. Das gebundene Projekt-Konfigurationsverzeichnis
steht nicht geheim in `SYMPHONY_LINEAR_ENV_DIR`; der OTP-Start verwendet diese
bereits festgelegte Quelle erneut, auch nach einem CWD-Wechsel. Öffentliche Loader interpretieren
keinen Secretwert als Shellcode und exportieren ihn nicht. Erst
`Config.linear_client_secret/1` liest im vertrauenswürdigen Auth-/MCP-Prozess die
gleichnamigen Wert aus den gebundenen Projektdateien: `.env.local` vor `.env`,
auch ein bewusst leerer Eintrag gewinnt und stoppt den Zugriff. Nur wenn der
Schlüssel in beiden Projektdateien fehlt, darf die referenzierte geschützte
Prozessvariable als Fallback dienen. Es gibt **keinen Secret-Fallback zum Symphony-Root oder einem fremden
Projekt**. Leere, fehlende oder unzugängliche Quellen stoppen sichtbar.

Direkt aufgerufene Release-Helfer finden den ursprünglichen Symphony-Root über
den öffentlichen Snapshot; ihre Projektbindung kommt weiterhin aus dem
aufrufenden Fachprojekt beziehungsweise `SYMPHONY_SOURCE_REPO`/`SYMPHONY_PROJECT_ROOT`.
Alte Versionen und unveränderte alte Workflows behalten ihre bisherigen Ladepfade.
Auch neue Versionen unterstützen alte Workflows ohne `auth_mode` und explizites
Legacy mit `LINEAR_API_KEY`; der neue gemeinsame Workflow verlangt dagegen die
projektspezifische App-Konfiguration.

Linux und macOS benutzen denselben Datenloader. SSH überträgt weder private
Projektdatei noch Secret. Der Betreiber stellt auf dem Zielhost den gebundenen
Release und die passende Fachprojekt-Konfiguration separat bereit. Die dort
gültigen Projekt-/Releasepfade müssen zur konfigurierten Remote-Installation
passen; eine lokale Datei beweist keine Remote-Einrichtung. OS-/Remote-Live-
Abnahmen bleiben von synthetischen Tests getrennt.

## Tokenlebenszyklus und Schreibwege

Linear dokumentiert 30 Tage Tokenlaufzeit und bis zu 1000 parallele Tokens bei
identischen Scopes. Scopewechsel widerruft bestehende App-Tokens; frühere
App-Grants anderer Art verhindern ihren parallelen Betrieb. Aktivierung und
kontrollierte Grant-Umstellung sind administrative Abnahmen.

Ein `AppAuth`-Cache lebt je BEAM-VM und wird innerhalb dieser VM von den Clients
geteilt. Der Orchestrator und seine lokalen Agent-Tasks benutzen damit denselben
laufzeitbezogenen Token. Ein eigenständiger `sym-codex-mcp`-Prozess besitzt eine
andere BEAM-VM und hält einen eigenen Token für seine gesamte MCP-Sitzung. Jeder
separate Aufruf von `scripts/linear-app` oder eines autorisierten Mix-Fallbacks
besitzt ebenfalls eine eigene VM und einen eigenen Token. Kein Token wird pro
GraphQL-Aufruf neu angefordert oder an andere Prozesse verteilt. Neustart verwirft
den Cache; es gibt keine Refresh-Tokens, Generationen, Tokendateien oder gemeinsame
rotierende Kette und keine Koordination zwischen Hosts.

Der Client prüft die Tokenantwort (Bearer, exakt `read write`, positive gültige TTL
bis 30 Tage) und erneuert beim nächsten Zugriff spätestens 120 Sekunden vor Ablauf.
Workspace/App werden vor jeder Nutzanfrage und nach Neubeschaffung geprüft. Eine
401 auf diese reine Identitätsabfrage erlaubt genau einen neuen Token und einen
Identitäts-Nachtest. Eine 401 auf eine Nutzanfrage invalidiert den Cache und wird
zurückgegeben; erst der nächste Aufruf beschafft neu. **Keine Nutzanfrage, insbesondere
keine Mutation, wird innerhalb dieses Auth-Pfads erneut gesendet.** Journal-Recovery
entscheidet über unklare Kommentarergebnisse. 429/Rate-Limit, 5xx und verlorene
Antworten verursachen keine automatische Token- oder Mutations-Wiederholung. Fehler der Tokenbeschaffung werden im
Laufzeitcache 30 Sekunden gehalten, damit parallele Aufrufer den Auth-Dienst nicht
mit identischen fehlgeschlagenen Beschaffungen belasten.
Tokenendpoint und GraphQL sind fest an `api.linear.app` gebunden; Redirects und
automatische HTTP-Retries sind abgeschaltet. Fehlertexte geben keine HTTP-Secret-
Antwort oder Exceptiondetails aus; API-Antworten und Journaltexte werden redigiert.

Das Projektsecret wird erst im Auth-/MCP-Prozess gelesen; der Codex-Host erhält
aus der Datei kein Secret.
Für eine extern bereitgestellte Secretvariable bleibt die bestehende
MCP-Vererbung über `env_vars` (nur der Name) unterstützt. Modell-Shells schließen
Secretvariablen aus und erhalten `SYMPHONY_LINEAR_SECRET_ACCESS=denied`. Damit
scheitert auch ein erneuter EnvFile-/Mix-/Launcher-Aufruf beim Secretzugriff.
`scripts/mix-gate` erhält diese Sperre auch bei `mix run`; nur die Testfixtures
heben sie für ihre synthetischen Quellen ausdrücklich auf.
Workspace-/Lifecycle-Hooks, Git-/Cleanup-Helfer, SSH-Transport und fachliche
Lock-Helfer erhalten dieselbe Sperre. Shell-Snapshots und Codex-Hooks bleiben im
App-Kontext deaktiviert. Die gebundene MCP-Konfiguration gibt nur dem vorgesehenen
MCP den vertrauenswürdigen Zugriff auf die gebundene Projektdatei; ein bereits gesperrter Aufruf hebt ihn nicht
wieder auf. Berechtigte Operator-Helfer nutzen denselben Auth-Pfad.
Der Worktree-Helfer übernimmt im App-Modus ausschließlich die bekannten nicht
geheimen App-/Scope-/Assignee- und Modellwerte; Secret und API-Key werden nicht
kopiert. Testprojektscope und persönliche Zuständigkeit bleiben erhalten, MCP
behält die ursprüngliche Projektquelle. Der bisherige vollständige Kopiervertrag
bleibt für Legacy erhalten.
Diese Grenze schützt die unterstützten Lade-/Startpfade; sie ist keine
Dateisystemisolation gegen beliebige Programme mit den Rechten des Betreibers.
Secrets dürfen deshalb auch nicht über allgemeine Shell-Startdateien nachgeladen
werden.

## Gebundene Ressourcen und Schreibwege

Jeder reguläre Start erstellt einen eigenständigen Release-Checkout aus dem
aktuellen Arbeitsstand einschließlich gestagter Löschungen, Umbenennungen und
Datei-/Verzeichniswechsel. Ignorierte Dateien werden nicht übernommen. Ein
bestätigtes Update erfolgt dort vor Build und Aktivierung. `autoupdate` verändert
keinen bereits versiegelten Stand. Das Manifest `.symphony-release.json` enthält
Code-, Helfer-, Skill-, Build- und Workflowhashes. Spätere CLI-/MCP-Kinder prüfen
die unveränderlichen Dateien und verwenden `mix run --no-compile` im selben
Release. Eine andere Installation ersetzt weder dessen Build noch seine Links.

Reguläre Releases registrieren keine globalen Ticketbefehle. Ein manueller
Start erfolgt aus dem Fachprojektroot über den absoluten `sym-codex`-Pfad der
gewünschten Installation plus Ticket-ID. Vorhandene globale Befehle bleiben
an ihre bisherige Installation gebunden. Beim Sourcing in Bash gibt der
Release-Kindprozess seine gewählten Projekt-/Worktree-/Release-Verzeichnisse
über eine temporäre Datei unter dem ignorierten `.symphony/installations/` zurück. Die Eltern-Shell übernimmt
Worktree und Venv, entfernt die Datei und erhält den Codex-Rückgabecode.
Die Datei enthält ausschließlich Pfade; ihr Verweis wird vor Codex entfernt.

Der lokale Standard `codex.command: sym-codex --observer` wird im Release auf
dessen eigenen Helfer aufgelöst. Ohne Release-Variable, etwa beim direkten
`mise exec -- bin/symphony`, wird der Helfer aus dem ermittelten Symphony-Checkout
absolut gebunden. Ein globaler Link ist nicht erforderlich. Im App-Modus gilt dies auch für den
Schema-Default `codex app-server`; nur diese Standardaufrufe erhalten nach dem
Shell-Login den geprüften lokalen Toolchain-PATH. Andere konfigurierte Kommandos
und ein explizites `SYMPHONY_CODEX_COMMAND` bleiben unverändert; deren Betreiber
verantworten die Bindung der verwendeten Helfer. SSH verwendet das dort
konfigurierte Kommando und benötigt dort erreichbare Helfer.

Legacy-Laufzeit bleibt mit Python 3.10 möglich. Das vollständige Entwicklungsgate
prüft auch App-Code und benötigt unabhängig vom gewählten Modus Python 3.11+.
Ein angenommenes Update unter Legacy-Python 3.10 wird vor dem Pull sichtbar
zurückgestellt; der vorhandene Stand startet weiter. Keine App-Tests entfallen.

Lokale Workflowänderungen bleiben nachladbar. Wechsel von Auth-Modus, Bindung
oder menschlichem Scope benötigen einen Neustart nach Ende aktiver Turns.
Ein Konfigurationshash bindet App-Kinder an denselben Vertrag; EnvFile-Laden kann
ihn nicht durch persönliche Einstellungen ersetzen. Für bewusste Änderungen
immer eine neue lokale Konfiguration vorbereiten und den bisherigen Lauf beenden.

Der App-Codex-Kontext enthält vor dem Workerstart kopierte Skill-Inhalte samt
referenzierten Dateien. Repo-Symphony-Skills haben Vorrang. Andere globale und
projektseitige Skills werden beim Kindstart deaktiviert; persönliche MCP-Server
und Plugins werden ausgeschlossen. Nur der gebundene `symphony_linear`-MCP wird
aktiviert. Die OpenAI-Anmeldung bleibt an ihrer bisherigen Credential-Referenz;
Linear-Tokens bleiben ausschließlich im Speicher ihrer jeweiligen Client-Laufzeit.
Codex-Sessions bleiben unter `state_root/codex/<installation_id>` releaseübergreifend
erhalten. Vorhandene Sessions werden bei einer Migration ausdrücklich übernommen.
Parallele erste Worker dürfen dieselben Session-Verknüpfungen anlegen; ein
bereits vorhandener Link wird nur mit identischem Ziel akzeptiert. Direkte
Observer-Starts übergeben den ermittelten Fachprojektroot auch ohne geerbte
Projektvariablen an ihren erforderlichen Linear-MCP.

Der Merge-Watch-Helper hat aus der App-Modell-Shell keinen Auth-Zugriff. Nach
seinen GitHub-Prüfungen liefert er Exit `8`; das Merge-Gate bleibt offen. Der
Hauptagent liest anschließend die aktuellen Labels über den gebundenen
Linear-Toolzugriff und prüft das gegebenenfalls erforderliche menschliche
Approval auf dem unveränderten PR-Head. Dispatch-Labels ersetzen diesen
Live-Lookup nicht. Legacy behält den lokalen Tracker-Refresh.

Tracker, dynamisches `linear_graphql`, MCP, Mix-Fallback und Dialogantworten benutzen
denselben `Linear.Client`. Kommentar-IDs und API-Fassungen werden unabhängig von
den durch das Modell angeforderten Feldern erfasst. GraphQL wird strukturell
geparst, inklusive Alias, Fragment, Variablen, Inline-Input und Teilerfolgen.
Ausgelassene optionale Eingabefelder bleiben ausgelassen; explizites `null` und
Variablendefaults bleiben erhalten. Ticketkennungen als `issueId` werden vor
der Schreibabsicht lesend zur kanonischen Issue-ID aufgelöst; ein fehlgeschlagener
Lookup verhindert den Write. Frühere Kennungen im Journal bleiben über die
zurückgelesene Issue-Kennung abgleichbar.
`bodyData` wird beim Vergleich als JSON normalisiert, weil Linear JSON-Input
und eine serialisierte String-Ausgabe verwendet. Updates von `body`, `bodyData`,
`quotedText`, `resolvingUserId` und `resolvingCommentId` werden anhand ihrer
zurückgelesenen Werte bestätigt. Andere Update-Felder, etwa Abonnementsteuerung,
werden vor HTTP mit `invalid_comment_mutation` abgewiesen, da ihr Erfolg nach
einer verlorenen Antwort nicht über den Kommentar nachgewiesen werden kann.
Eine App-Anfrage darf jede Kommentar-ID höchstens einmal verändern.
Mehrere aliased Writes derselben ID werden vor HTTP und Intent-Persistenz mit
`invalid_comment_mutation` abgewiesen: Nach verlorener Batch-Antwort könnte nur
die letzte Fassung abgeglichen werden. Solche Updates einzeln nacheinander senden.
Eine vom Auth-Cache unabhängige hostlokale Journalsperre schützt Abgleich,
Schreibabsicht, HTTP und Bestätigung gegen parallele Clients. Die bestehende
Issue-Sperre bleibt separat. Eine Schreibabsicht wird vor HTTP synchron persistiert, die Bestätigung danach
atomar ergänzt. Bei Updates werden Autor und Issue vorher geprüft. `:ok`-Aufrufer
und Memory-Adapter behalten ihren Vertrag.

Das Journal enthält Workspace, Issue, Kommentar-ID, Ausgabeart, Installation,
Autor, Lauf/Phase, beabsichtigte und bestätigte Fassung. Historische Belege behalten
bei einem kontrollierten App-Wechsel im selben Workspace ihre gespeicherte
Autorenbindung. Sie werden gegen diesen Autor abgeglichen und nicht der neuen
App zugeschrieben; neue Writes und Updates benötigen weiterhin die aktuelle
App-Identität. Ein Neustart gleicht offene
Schreibabsichten per ID/Autor/Fassung ab. Ungeklärte Ausgänge stoppen weitere
Kommentarwrites sichtbar; eine bereits erfolgreiche Ausgabe wird nicht blind neu
angelegt. Die Fehlerantwort nennt die betroffenen IDs. Diese IDs zurücklesen und
den vorhandenen Kommentar weiterführen, nicht erneut ohne ID anlegen.
Der Recovery-Nachweis bleibt auch nach einem anderen Issue-Schreibvorgang und
bei neuen Lauf-/Tool-IDs wirksam. Ein inhaltlich identischer Create nach einer
Recovery wird deshalb mit der bestehenden Kommentar-ID zurückgewiesen.
Eindeutige Ablehnungen vor Ausführung (GraphQL-Parse-/Schemafehler oder
`RATELIMITED`, jeweils ohne Daten und ohne Feldpfad, sowie HTTP 401/429 ohne Daten) erhalten einen dauerhaften
`rejected`-Beleg, bei 401/429 auch für leere oder textuelle Antwortbodies.
Das erfasst auch den von Linear dokumentierten
[HTTP-400-Rate-Limit-Response](https://linear.app/developers/rate-limiting)
und den entsprechenden GraphQL-Fehler bei HTTP 403.
Auch die vorgeschaltete Identitätsprüfung erhält diese Rate-Limit-Klassifikation
bei HTTP 400; dynamisches Tool und MCP geben sie als `rate_limited` weiter.
Ein korrigierter späterer Aufruf darf dann schreiben.
Transportfehler, unbekannte Fehler und Teilerfolge bleiben abzugleichen.
`CommentJournal.classify/2` liefert für ungeklärte App-Ausgaben `:pending` statt
`:foreign`; allgemeine Kommentarverarbeitung ist weiterhin nicht enthalten.

## Optionale spätere Workpad-Übergabe und Rückfall

Vor der Übergabe beide betroffenen Umfänge an Turn-Grenzen anhalten. Ein neuer
Issue-Lock koordiniert nur aktualisierte lokale Worker; er stoppt keinen alten
Worker. Worktree-/Git-Stand, Session, nicht geheime Konfiguration und vollständigen
Workpad-Stand sichern. Zugangsdaten bleiben im bisherigen geschützten Speicher.
Die ausgewählten nicht geheimen Dateien in ein separates Sicherungsverzeichnis
kopieren und ihre Pfade sowie SHA-256-Prüfsummen protokollieren. Private
Envdateien und Zugangsdaten gehören nicht in diese Übergabesicherung.

Ein nicht geheimes Übergabe-JSON enthält `binding: {workspace_id}`,
`issue_id`, `target_user` und `backup: {turns_stopped: true, files: {...}}`.
`files` referenziert die tatsächlich angelegten Sicherungen. Beide Aufrufe nutzen
denselben gebundenen Projektroot und dieselbe interne Issue-ID. Der Operator-Helfer
ergänzt `state_root` intern als `.symphony/state` dieses Projekts; das JSON kann
keinen anderen Zustandspfad auswählen. Die Referenzversion des alten
Workers muss `## Symphony Workpad (historisch, inaktiv)` als inaktiv erkennen.
`release_root` bezeichnet den geprüften Release-Pfad, `transfer_json` die
vorbereitete Übergabedatei.

```bash
# Autorisiert gewählte alte Identität in einer eigenen Legacy-Konfiguration:
"$release_root/scripts/linear-app" begin "$transfer_json"
"$release_root/scripts/linear-app" retire "$transfer_json"
# Danach explizit die App-Workflowdatei und deren lokale Source-Konfiguration wählen:
"$release_root/scripts/linear-app" activate "$transfer_json"
"$release_root/scripts/linear-app" ready "$transfer_json"
```

`begin` speichert die Übergabe, bevor Linear verändert wird. `retire` ist nur dem
bisherigen Autor erlaubt und erhält Inhalt/ID/Autor mit Nachfolgerreferenz.
`activate` ist ausschließlich dem Zielautor erlaubt: vorab persistierte UUID,
vollständiger bisheriger Stand, Vorgängerreferenz, eigener API-Autor, genau ein
aktives Workpad, erfolgreiches späteres Edit und Readback. Erst dann wird die
aktive ID gespeichert und das Issue freigegeben. Ein Abbruch in jeder Zwischenphase
hält das Issue gesperrt; denselben Schritt mit derselben Konfiguration wiederholen.
Ein wiederholtes `activate` überschreibt keinen inzwischen fortgeschriebenen Stand.

Der Rückfall benutzt dieselben Schritte in Gegenrichtung: App-Autor deaktiviert
sein Workpad, anschließend führt die ausdrücklich ausgewählte Legacy-Identität
den aktuellen Stand fort. Kein persönlicher Zugang im App-Schreibpfad. Bei einem frischen Issue ohne Workpad oder
Übergabehistorie bleibt der reguläre Erstkontakt-Bootstrap für Anlage und
Phasenreihenfolge zuständig. Bei vorhandener Übergabehistorie wird kein fehlender
Marker automatisch ersetzt. Fremde oder mehrere aktive Workpads stoppen
den Lauf; die aktive ID bleibt dauerhaft gespeichert. Unveränderte alte Installationen bleiben bei ihrer bisherigen Auswahl.

## Quellen

- [Linear OAuth2 Client Credentials](https://linear.app/developers/oauth-2-0-authentication#client-credentials-tokens)
- [Linear App-Akteur](https://linear.app/developers/oauth-actor-authorization)
- [Codex-Konfigurationsreferenz](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Codex-Umgebungsregeln](https://learn.chatgpt.com/docs/config-file/config-advanced)
- [Codex-MCP-Umgebungsreferenzen](https://learn.chatgpt.com/docs/extend/mcp)
- [Codex-Skill-Suchorte](https://learn.chatgpt.com/docs/build-skills)

Die praktische Abnahme benötigt einen ausdrücklich benannten Testumfang und
Nachweise am tatsächlich getesteten Commit. Administrative Schritte und
Live-Ergebnisse getrennt von den synthetischen Tests protokollieren.

## Lokaler synthetischer Vererbungsnachweis

Mit installiertem Codex lässt sich die tatsächliche Shell-/MCP-Grenze ohne Modellturn
und ohne echte API oder Credentials separat prüfen:

```bash
python3 test/support/linear_app/codex_secret_boundary.py
python3 test/support/linear_app/codex_secret_boundary.py --project
```

Der Test nutzt einen isolierten temporären Codex-Kontext, einen synthetischen
MCP-Server und künstliche Sentinels. Bestehende Root- oder Projektdateien werden nicht geladen. Die Projektvariante
startet den tatsächlichen MCP-Bootstrap und prüft einen abgewiesenen Secretzugriff
über einen echten Codex-Shell-Kindprozess. Er prüft
`command/exec`, den echten MCP-Start sowie Argumente, RPC-Ausgaben, Logs und
Sessionartefakte. Die reguläre Elixir-/Python-Suite prüft zusätzlich Auth, Hooks,
Schreibwege, Journal und Ressourcenisolation mit synthetischen Werten.
