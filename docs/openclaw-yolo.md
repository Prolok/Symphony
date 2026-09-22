# Optionaler OpenClaw-Ausführungsweg

`OPENCLAW_YOLO_AGENT=po` in der **projektspezifischen** `.symphony/.env.local`
wählt einen vorhandenen lokalen OpenClaw-Agenten für die PO-Sammelläufe.
`LINEAR_YOLO_AGENT`, menschliche Zuständigkeit und Linear-Delegation bleiben
maßgeblich. Der OpenClaw-Wert benötigt eine gültige Linear-YOLO-Bindung;
Agent-IDs bestehen aus Kleinbuchstaben, Ziffern, `_` und `-`.
Ausführungsbindung und Agentenwechsel verlangen einen Dienstneustart.
Ungültiger Reload erhält den zuvor akzeptierten Projektkontext.

Fehlend, leer oder Whitespace erhält den Codex-Ausführungsweg. In diesem Fall
gibt es keine OpenClaw-Aufrufe, Verfügbarkeitsprüfungen oder Zugriffe auf dessen
Konfiguration/Credentials, auch nicht für Retry oder Cleanup. Symphony liest
weiterhin seine eigenen Journale, um früher angenommene Aufträge zu sperren.
Andere Projekte und reguläre AI-/Dialog-Läufe behalten ihren Ausführungsweg.
Installation, Build und Standardgates installieren/starten kein OpenClaw.

## Unterstützte Schnittstelle

Der austauschbare Elixir-Adapter `Yolo.OpenClaw.Adapter` verwendet standardmäßig
`openclaw gateway call`, ohne `--local`, Gatewaystart oder anderen Agenten als
Ersatz. `--port 18789` bindet sämtliche RPCs an den lokalen Standardgateway und
überschreibt eine eventuell konfigurierte Remote-Auswahl; der Toolzugang bleibt
auf demselben Rechner. Andere Gatewayports werden derzeit nicht unterstützt.
Die CLI muss auf dem PATH des Dienstes liegen. Gateway und CLI müssen
zum unterstützten Release **2026.9.4** gehören. Die CLI-Version wird vor jedem
neuen externen Auftrag geprüft; die Gleichheit der Gatewayversion ist Teil der
Betreiberabnahme. Andere Versionen benötigen eine erneute Schnittstellenprüfung.

Geprüfte Quelle: offizielles Tag `v2026.9.4`, Commit
[`3a9d69db306cd7f081e06254cb89c4bcc14a7107`](https://github.com/openclaw/openclaw/tree/3a9d69db306cd7f081e06254cb89c4bcc14a7107).
Das ist ein Quellnachweis, kein Beleg für eine lokale Installation.

| Operation | Vertrag und verwendeter Beleg |
| --- | --- |
| Vorprüfung | `--version`, anschließend `agents.list`; exakt konfigurierte ID erforderlich |
| Start | Externes `agent`: `agentId`, `sessionKey`, `idempotencyKey`, vollständige `message`, `timeout`, `deliver=false`; kein `cwd` oder interner/plugin-eigener Principal |
| Annahme | Antwort `runId` gleich Auftrags-ID und `status=accepted`; noch kein Arbeitsabschluss |
| Nichtstart | Typisierte erste Gateway-Fehlerantwort mit belegtem Vorab-Grund; eigener Ablehnungsbeleg, kein erfundenes `endedAt` |
| Beobachtung | `agent.wait` mit derselben `runId`; `timeout` ohne Endbeleg bleibt ungeklärt |
| Abbruch | `sessions.abort` mit Sitzungsschlüssel **und** `runId`; Bestätigung ersetzt keinen Endbeleg |
| Ende | Passende `runId`, terminaler Status und `endedAt`; `yielded`/`pendingError` sind kein Ende |

Schemas: [Agent-RPC](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/packages/gateway-protocol/src/schema/agent.ts),
[Sitzungen](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/packages/gateway-protocol/src/schema/sessions.ts).
Die Zuordnung `idempotencyKey` → `runId` und die begrenzte Ergebnisvorhaltung
sind im [Gateway-Quellcode](https://github.com/openclaw/openclaw/tree/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/gateway/agent-turn)
geprüft. Ein abgelaufener Cache beweist keine Nichtausführung.

Der [Preflight](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/gateway/agent-turn/agent-request-preflight.ts)
reserviert `cwd` für plugin-eigene Unteragenten, obwohl das Feld im Schema steht.
Die unveränderte Fixture unter `test/fixtures/openclaw` sichert diese Grenze mit
Quellhash. Symphony weist das Arbeitsverzeichnis über die Werkzeugausführung nach.

Fehler heißen unter anderem `openclaw_requires_linear_yolo_agent`,
`openclaw_binary_missing`, `openclaw_gateway_unavailable`,
`openclaw_agent_not_found`, `openclaw_version_unsupported` oder
`openclaw_invalid_response`. Rohes CLI-stderr und Credentials werden nicht
in Prompt oder Logs übernommen. Kein Fehler startet einen Ersatzlauf.

## Auftrag, Werkzeuge und Wissen

Jeder Auftrag enthält den gesamten versionierten `WORKFLOW_YOLO_AGENT.md`,
Vertragsversion, Workflow-Hash, Projekt-/Linear-Bindung, beide Agentenidentitäten,
Mitglieder mit Anforderungen/Abhängigkeiten, Kommentarquellen, Aktionsjournale,
Startmodus und menschliches Übergabeziel. Der Payload erhält zusätzlich einen
SHA-256-Hash. Der projektspezifische `sym-yolo-review` wird nur nach Prüfung von Projekt,
Commit und Dateiinhalt eingebettet. Seine Bindung (`review_contract`, Version 1)
und der [Prüf-/Lernvertrag](../WORKFLOW_YOLO_AGENT.md#review-gemeinsame-fachliche-schlussabnahme)
sind für Review-Übergaben verpflichtend und für Codex/OpenClaw identisch.
Fehlende oder abweichende Bindung ist keine gültige Abnahme; referenzierte Dateien
werden aus demselben Checkout gelesen. Fachwissen aus Memory darf ergänzen,
den versionierten Projektprüfmaßstab jedoch nicht ersetzen.

Eigene Sitzungsschlüssel enthalten Projektkennung, OpenClaw-Agent, Aufgabenbereich
und Lauf-ID. Normale Agentengespräche werden nicht wiederverwendet. OpenClaw
behält seinen Agenten-/Wissenskontext; die Wissensverfügbarkeit in **diesem**
Sitzungstyp muss live nachgewiesen werden.

Ein temporärer lokaler MCP-Zugang bindet Projekt, Laufgeneration und Mitglieder
serverseitig. Der Agent ruft über sein vorhandenes `exec` das mitgelieferte
`scripts/sym-yolo-tool.py` mit Bindungsdatei und JSON-RPC auf stdin auf.
Das `exec`-Arbeitsverzeichnis muss der Prüfcheckout sein; der Prompt enthält
alternativ ein gequotetes `cd -- /ABS/CHECKOUT && python3 ...`. Der Helfer misst
physisches cwd, Git-Root, HEAD und Sauberkeit bei jedem Aufruf. Die Bridge
vergleicht Projekt, Lauf, Sitzung, Checkout und SHA, prüft den Git-Stand selbst
erneut und speichert den Nachweis mit dem Payloadhash vor dem Werkzeugdispatch.
Falscher Wissensworkspace, fremde Generation, abweichende SHA und schmutziger oder
unzugänglicher Checkout sperren den Zugriff. Eine bloße Promptbehauptung genügt nicht.
`tools/list` und `tools/call` erreichen denselben Symphony-Dispatcher wie Codex:
`linear_graphql`, `symphony_comments`, `symphony_yolo_action`,
`symphony_yolo_complete` und `symphony_test`. Bestehende Frische-, Schreib- und
Testexecutorgrenzen bleiben wirksam; ein Werkzeugname allein erteilt keine
zusätzliche Berechtigung. Nach Abbruch, Transportunsicherheit oder Wiederaufnahme
ist die alte Schreibbindung gesperrt. Die lokale Bindungsdatei gehört nur diesem
Lauf und enthält keine Linear-Credentials; sie darf nicht ausgegeben werden.
Die Bridge empfängt vollständige JSON-Zeilen bis 1 MiB; ihr Empfangspuffer ist
ebenfalls darauf begrenzt, damit größere Workpads nicht vor dem JSON-Parser
abgeschnitten und fälschlich als ungültige Laufbindung behandelt werden.

Delegationsfreigabe und Eskalationsgrenze gelten ausführungswegneutral gemäß
[PO-Laufvertrag](../WORKFLOW_YOLO_AGENT.md#laufvertrag); der CLI-Modus ist keine
zusätzliche Aktivierungsfreigabe. Finale Produktabnahme folgt den
[Phasenpflichten](../WORKFLOW.md#phasenpflichten-und-betreiberübergaben).
Der ausdrücklich geforderte Live-Nachweis vor Aktivierung dieses optionalen
Ausführungswegs bleibt ein eigenständiges früheres Gate.

Der Betreiber muss für den gewählten Agenten prüfen und dokumentieren:

- Vorhandenes lokales `exec` und Python 3; Zugriff auf den Symphony-Helfer,
  Loopback und den konfigurierten Workspace-Root. Ein restriktiver OpenClaw-
  Sandboxpfad darf den Prüfcheckout nicht still durch den Wissensworkspace ersetzen.
- Freigegebene Wissensquellen, insbesondere Verfügbarkeit von Memory in der
  eigenen Symphony-Sitzung. Keine private Symphony-Envdatei als Wissensquelle.
- Widersprüche in Agentenanweisungen, einschließlich eines vorhandenen
  `symphony-product-owner`: Ablauf aus dem übergebenen Workflow, keine zweite
  Ticketsteuerung, keine parallelen Unteragenten, keine direkten Linear-Schreibwege,
  kein automatisches `Review` → `Fertig`. Konflikte als offene Live-Abnahme
  dokumentieren; Agentenkonfiguration und Berechtigungen bleiben unverändert.
- LinearBridge-Mentions bleiben Beratung; allein Symphony autorisiert Aktionen.

PO-/Abnahme-Checkouts liegen detached unter `workspace.root/yolo/<Gruppe>/<Lauf>`
auf der aktuellen `origin/main`-SHA. Auftragsartefakte liegen getrennt unter
`workspace.root/yolo-runs/<Lauf>`; die Clean-Checkout-Prüfung bleibt wirksam.

## Unsicherheit, Wiederaufnahme und Cleanup

Vor Versand wird eine unveränderliche Auftragsabsicht mit Agent, Sitzung,
Mitgliedern, Payload-Hash und Checkout/SHA synchron gespeichert. Eine Gruppe
behält Mitgliederleases, lokale Sperren und einen gemeinsamen Kapazitätsplatz
bis zum bestätigten externen Ende oder belegten Nichtstart. Beim Neustart werden Reservierungen aus dem
Symphony-Journal rekonstruiert; alte Werkzeuge bekommen keine neue Schreibfreigabe.
Die Wiederaufnahme beobachtet denselben Auftrag und fordert dessen gezielten
Abbruch an. Sie sendet den Arbeitsauftrag **niemals erneut**.

Verlorene Annahme, Prozessabbruch, Gateway-/Verbindungsverlust oder fehlender
Endbeleg bleiben reserviert. Nach einer Stunde wird Abbruch verlangt. Auch ein
bestätigter Abbruchaufruf gibt den Platz erst nach einem Endbeleg frei.
Nach Deaktivierung oder Agentenwechsel erfolgen keine Zugriffe auf den alten
Agenten; die lokale Reservierung verhindert den konkurrierenden Codex-Ersatzlauf.
Eine ungeklärte Reservierung muss mit dem ursprünglichen Agenten/Gateway und
seiner Lauf-ID abgeglichen werden. Fehlender Verlauf oder Wartezeit rechtfertigen
weder Journal-Löschung noch einen neuen Auftrag. Ist kein Endbeleg mehr verfügbar,
bleibt eine sichtbare Betreiberklärung erforderlich.

`openclaw-rpc.py` akzeptiert ausschließlich JSON-Fehler auf stdout aus dem
geprüften CLI-Pfad: Exit 1, `ok=false`, `error.type=gateway_request_error`,
`code=INVALID_REQUEST`, `retryable=false` und den exakten Vorab-Grund
`cwd is reserved for plugin-owned subagent runs` oder `cwd must be absolute`.
Die erste Antwort wird ohne `--expect-final` angefordert. Maximal 16 KiB Fehler-JSON
werden auf Vertragsversion 1, Methode, Phase, Code, erlaubten Grund und SHA-256
der konkreten Anfrageparameter reduziert. Zusatzfelder und stderr werden verworfen.
Textfehler älterer CLI-Builds, allgemeines `INVALID_REQUEST`, verlorene Antworten
und Timeouts bleiben `unknown`; daraus folgt keine Freigabe.

Eine belegte Ablehnung wird `rejected`, entzieht Werkzeuge und beendet den lokalen
Beobachter ohne `agent.wait`. Annahme-/Werkzeugbelege sperren spätere Nichtstartbefunde.
Nichtterminale Ausführungsbelege bewahren die bestehende Werkzeugfreigabe;
bereits entzogene Freigaben oder angeforderte Abbrüche werden dadurch nicht aufgehoben.
Verspätete Poll-/Cancel-Antworten öffnen terminale Generationen nicht wieder.
Vor dem Folgeauftrag wird der vollständige alte Datensatz synchron unter
`<Gruppenjournal>.history/` archiviert; erst danach wird das aktuelle Journal atomar
ersetzt. Ein Abbruch dazwischen lässt den alten Datensatz lesbar und den Archivschritt
wiederholbar. Nichtstart markiert keine PO-Entscheidung als verarbeitet; der bestehende
Retryabstand bleibt erhalten. Dashboard und Lifecycle nennen bei Unsicherheit die
Betreiberklärung und nach Ablehnung die freigegebene Reservierung.

Neue Kommentare werden vor Aktionen und Abschluss frisch abgeglichen. Entzogene
Mitglieder verlieren ihre Schreibberechtigung; Gesamtentzug fordert Abbruch an.
Ein externer Erfolg allein speichert keine verarbeitete Beobachtung: bestätigte
Mitgliedsentscheidungen, Aktionsjournale, aktuelle Eingänge und unveränderter
Checkout werden zusätzlich geprüft. Teilfortschritt bleibt in den Journaleinträgen.
Lifecycle-Logs nennen Projekt, Issue-ID/-Kennung, Lauf und Sitzung.

Die Toolbindung wird nach regulärem Ende entfernt; Auftrags-/Journalbelege bleiben
erhalten. Isoliertes Test-Cleanup verweigert das Entfernen eines Checkouts, solange
ein externer Auftrag darauf ungeklärt ist. Ein lokaler Prozesskill gilt nie als
OpenClaw-Abbruch. Keine automatische Bereinigung des Wissensworkspace.

## Gezielte Betreiber-Recovery eines Altauftrags

Nur der Betreiber importiert Originalbelege; Worker verändern weder produktive
Journale noch laufende Tickets. Dienst und Befehl müssen den obigen Journalvertrag
verwenden. Die operative Aktivierung bleibt separat koordiniert; OpenClaw-Konfiguration,
Agentenrechte und Wissensworkspace bleiben unverändert. Der Befehl startet keinen
Symphony-Dienst und sendet keinen Agentenauftrag.
Diese explizite Betreiberaktion greift auf das ursprüngliche Gateway zu, auch
wenn der automatische OpenClaw-Ausführungsweg inzwischen deaktiviert wurde.

Der Betreiber korreliert die ursprüngliche `agent`-Anfrage und ihre konkrete
Vorab-Ablehnung über die originale RPC-Anfragekennung. Ein zeitlich naher Logeintrag,
fehlende Sitzung oder Timeout reicht nicht. Die Prüfunterlagen müssen aktive/fremde
Ausführung derselben Lauf-/Sitzungsbindung ausschließen. Quellen außerhalb öffentlicher
Logs aufbewahren; keine Credentials in das Paket kopieren. `source_file` und
`execution_source_file` sind lokale Originalbelege bzw. der belegreferenzierende
Betreiberbericht. Der Befehl prüft deren SHA-256; die inhaltliche Zuordnung bestätigt
der benannte Betreiber mit diesem Paket:

```json
{
  "version": 1,
  "binding": {
    "id": "ORIGINAL-RUN-ID", "group": "incoming", "project_id": "/ABS/PROJEKT",
    "agent": "po", "linear_agent_id": "ORIGINAL-LINEAR-AGENT-ID",
    "linear_workspace_id": "ORIGINAL-LINEAR-WORKSPACE-ID",
    "session_id": "ORIGINAL-SESSION-KEY", "payload_sha256": "ORIGINAL-PAYLOAD-SHA256",
    "workspace": "/ABS/ORIGINAL-PRUEFCHECKOUT", "sha": "ORIGINAL-CHECKOUT-SHA",
    "members": [{"id": "ORIGINAL-ISSUE-ID", "identifier": "PRO-810", "state": "Backlog"}]
  },
  "gateway_version": "2026.9.4",
  "request": {
    "request_id": "ORIGINAL-RPC-ID", "method": "agent", "run_id": "ORIGINAL-RUN-ID",
    "session_id": "ORIGINAL-SESSION-KEY", "agent": "po",
    "payload_sha256": "ORIGINAL-PAYLOAD-SHA256", "cwd": "/ABS/ORIGINAL-PRUEFCHECKOUT"
  },
  "response": {
    "request_id": "ORIGINAL-RPC-ID", "phase": "pre_acceptance",
    "code": "INVALID_REQUEST", "reason": "cwd_reserved"
  },
  "execution_check": {
    "run_id": "ORIGINAL-RUN-ID", "session_id": "ORIGINAL-SESSION-KEY",
    "no_active_or_foreign_execution": true, "basis": "correlated_original_rejection",
    "checked_at": "AKTUELLER-ISO8601-ZEITPUNKT-MIT-ZEITZONE"
  },
  "source_file": "originalbeleg.txt", "source_sha256": "64-HEX-ZEICHEN",
  "execution_source_file": "betreiberpruefung.txt", "execution_source_sha256": "64-HEX-ZEICHEN",
  "reviewer": "Tilo"
}
```

`binding` enthält diese Felder vollständig und unverändert aus genau dem Originalauftrag,
einschließlich **aller** Mitglieder. Der Originalbeleg muss den exakten Gatewaytext
`cwd is reserved for plugin-owned subagent runs` tragen; `cwd_reserved` normalisiert
diesen Grund. Die originale RPC-Kennung darf das OpenClaw-Format `Sequenz:UUID`
enthalten. Keine frei erfundene oder aus gekürzten Logs ergänzte Kennung verwenden. Fehlende Korrelation hält
die Reservierung geschlossen. Die Ausführungsprüfung darf beim ersten Anwenden
höchstens fünf Minuten alt sein. Quellpfade beziehen sich auf das Paketverzeichnis.

Aus der aktivierten Symphony-Installation mit deren ursprünglicher öffentlicher
Projekt-/Workflow-Konfiguration ausführen:

```sh
mise exec -- mix openclaw.recover --project /ABS/PROJEKT --evidence /ABS/recovery.json
mise exec -- mix openclaw.recover --project /ABS/PROJEKT --evidence /ABS/recovery.json --apply
```

Der erste Aufruf ist ein Trockenlauf. Beide prüfen unter derselben Journalsperre
Generation, Bindung, fehlende Annahme-/Werkzeug-/Completion-/Aktionsbelege, den
ursprünglichen Agenten und einen frischen `agent.wait`-Gegenbefund. Aktiver oder
fremder Lauf, tatsächlicher Endbeleg und nicht erreichbares Gateway verweigern
diese Nichtstart-Recovery. Ein Timeout ist nur die widerspruchsfreie Gegenprüfung;
die Freigabe beruht auf dem korrelierten Original-Ablehnungsbeleg. Vorhandene
Aktionsbelege derselben Mitglieder werden konservativ gesperrt.

`--apply` speichert Ablehnungsbeleg, Betreiber-/Quellhashes und den vorherigen
Fehlerzustand atomar. Der Beobachter liest das Ergebnis und endet; Mitgliederleases
und Kapazität fallen über den bestehenden Lifecycle frei. Identisches erneutes
Anwenden bleibt wirkungslos, auch nach einem Folgeauftrag: Das Archiv wird gelesen,
die neue Generation bleibt unverändert. Ein geändertes Paket ist keine identische
Wiederholung. Kein Journal-Löschen, globaler Lease-Reset, manuelles `completed`
oder erfundenes `endedAt`.

Abnahmebeleg: Quell-/Paketstand, korrelierte Originalquelle, Trockenlauf, identische
Anwendung/Wiederholung, erhaltene Historie und anschließende reguläre Verarbeitung
der incoming-Gruppe. Für PRO-810 bleibt dies separate Betreiberarbeit.

### Angenommene und ausgeführte Altaufträge: terminaler Originalimport

Ein verlorener `agent.wait`-Cache kann auch einen tatsächlich ausgeführten Auftrag
betreffen. Dafür gibt es den getrennten Pakettyp `version: 2`,
`kind: terminal_original`. Version 1 bleibt ausschließlich Nichtstart vor Annahme.
Version 2 verlangt bereits journalisierte Annahme **und** Ausführung, Zustand
`unknown` oder `cancel_pending` und entzogene Schreibberechtigung. Ausführung wird
durch einen Werkzeug-/Checkoutnachweis oder eine korrelierte laufende
Gatewayantwort mit `startedAt` beziehungsweise `status=running` belegt.

**Automatische Grenze:** Altjournale kennen den ursprünglichen Sitzungsschlüssel,
aber keine unabhängig belegte physische OpenClaw-`sessionId`. Die öffentliche
Historyprojektion liefert weder die vollständige Symphony-Auftragsbindung noch
deren Payloadhash. Deshalb erfolgt keine automatische Freigabe aus nachträglich
gelesenem Verlauf. Der Betreiber bestätigt anhand seiner unveränderten Originalquellen,
dass Projekt, beide Agenten, Laufgeneration, physische Sitzung und gesamte
Journalbindung zusammengehören. Keine privaten Hostdateien oder neuen Gatewayrechte
werden vorausgesetzt. Kann er diese Herkunft nicht belegen, bleibt der Auftrag reserviert.
Ein Hash schützt die Zuordnung der vorgelegten Bytes; er authentisiert deren Herkunft
nicht. Frei erzeugte JSON-Belege sind keine Originalquellen.

Der unterstützte enge Quellvertrag ist `chat.history` aus OpenClaw 2026.9.4
([Handler](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/gateway/server-methods/chat-history-handler.ts),
[Lifecycle](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/gateway/session-utils-display.ts),
[Mirrorbesitz](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/extensions/codex/src/app-server/transcript-mirror-attestation.ts)).
`source_file` enthält die originale terminale Historyantwort als JSON-Objekt,
`execution_source_file` eine aktuelle, ebenfalls unveränderte Antwort derselben
Sitzung. Anders als bei Version 1 wird deren Struktur maschinell geprüft; ein
Betreiberbericht als Text genügt nicht. Keine Nachrichtendaten in das Paket,
Workpad oder öffentliche Logs kopieren; Originaldateien geschützt aufbewahren.

Die beiden Antworten müssen folgende Bedingungen erfüllen:

- `sessionKey` und `sessionInfo.key` entsprechen dem originalen Agentenschlüssel;
  beide `sessionId` entsprechen der belegten physischen Sitzung;
  `sessionInfo.lastRunId` entspricht exakt der Journalgeneration.
- Vollständige einzelne Seite: `offset=0`, `hasMore=false`, `totalMessages` entspricht
  der Anzahl vorgelegter Nachrichten. Fehlende, gekürzte oder mehrseitige Verläufe
  werden nicht zusammengeraten. Der Import führt keine zusätzlichen Seitenabrufe aus.
- Die letzte Nachricht ist der über `__openclaw.id` benannte, eindeutig vorkommende Assistant-Datensatz
  mit `__openclaw.runId`, `runTerminal=true`, `mirrorOrigin=codex-app-server`,
  `mirrorIdentity` und `mirrorSourceFingerprint`. Nur ein Terminalbesitzer dieses
  Laufs ist erlaubt. Finaltext, Zeitstempel einer Nachricht und ein isolierter
  `runTerminal`-Marker ersetzen diesen Vertrag nicht.
- Der Lifecycle enthält echtes `startedAt` und `endedAt` in Unix-Millisekunden
  sowie `status=done`, `failed`, `timeout` oder `killed`. Daraus werden ausschließlich
  die technischen Ergebnisse `completed`, `failed` oder `cancelled` gespeichert.
- `hasActiveRun=false`, vollständige `activeRunIds=[]`, leere `pendingInputs`
  einschließlich `total=0`, kein `inFlightRun`, kein aktiver Unterlauf und keine
  yielded-/pendingError-Ausführung. Fehlende Pflichtfelder sind unbekannt.
  Nur die im Release ausdrücklich bei Abwesenheit ausgelassenen Felder
  `inFlightRun` und `hasActiveSubagentRun` dürfen fehlen.

Paketbeispiel; `binding` enthält **alle** oben für Version 1 gezeigten Felder
unverändert aus dem Originaljournal, keine Ersatzwerte:

```json
{
  "version": 2,
  "kind": "terminal_original",
  "gateway_version": "2026.9.4",
  "binding": { "...": "vollständige Originalbindung wie oben" },
  "physical_session_id": "ORIGINALE-PHYSISCHE-SITZUNGS-ID",
  "message_id": "ORIGINALE-TERMINALE-NACHRICHTEN-ID",
  "source_file": "terminal-history.json",
  "source_sha256": "SHA256-DER-ORIGINALBYTES",
  "execution_source_file": "current-history.json",
  "execution_source_sha256": "SHA256-DER-AKTUELLEN-ORIGINALBYTES",
  "checked_at": "AKTUELLER-ISO8601-ZEITPUNKT-MIT-ZEITZONE",
  "reviewer": "berechtigter-betreiber"
}
```

Aufruf und Trockenlauf/`--apply` entsprechen Version 1. Paket maximal 32 KiB,
jede Quelldatei maximal 1 MiB. Beim erstmaligen Anwenden darf `checked_at` weder
in der Zukunft noch mehr als fünf Minuten zurückliegen. Unter der Journalsperre
werden aktuelle Originalbindung, fehlender flüchtiger Endbeleg (`agent.wait`)
und eine direkte frische `chat.history`-Antwort geprüft. Dieser eine Historyabruf
ist auf 200 Nachrichten, 1 MiB angeforderte Historybytes und den bestehenden
RPC-/Transporttimeout (10/15 Sekunden) begrenzt. Er fragt die **aktuelle** Sitzung
des originalen Agentenschlüssels ab; eine inzwischen ersetzte Sitzung verweigert
den Abschluss. Identität, Lifecycle und terminaler Nachrichtendigest müssen
übereinstimmen. Kein zusätzlicher Hintergrundpoll und kein Auftrag/Abbruch durch
den Import. Gatewayausfall, aktive/fremde Arbeit oder ein nun vorhandener
flüchtiger Endbeleg verweigern diesen Import; reguläre Terminalantworten werden
weiter vom bestehenden Beobachter behandelt.

Fehler unterscheiden unter anderem `openclaw_terminal_source_invalid`,
`openclaw_terminal_history_missing`, `openclaw_terminal_history_incomplete`,
`openclaw_terminal_identity_mismatch`, `openclaw_terminal_activity_conflict`,
`openclaw_terminal_end_missing`, `openclaw_terminal_record_invalid` und
`openclaw_terminal_counterproof_conflict`. Kein Fehler gibt Plätze frei.
`--apply` speichert technisches Ende, Beleg-/Nachrichtenhash, Referenz,
Betreiber und Vorzustand atomar im bestehenden Journal. Die Wiederholung desselben
Pakets bleibt auch nach Archivierung wirkungslos; neue Generationen und fremde
Mitglieder bleiben geschützt. Speicherversagen hält die Reservierung geschlossen.

Der wiederaufgenommene Beobachter liest dieses Ende; lokale Mitgliederleases,
Gruppe und gemeinsamer Platz werden über dessen normalen Lifecycle freigegeben.
Annahme-/Ausführungs-/Checkoutbelege und Completion-/Aktionsjournale bleiben
erhalten. Kein Import reaktiviert alte Schreibbindungen, wiederholt PO-Entscheidungen
oder verändert Linear. Reguläre Disposition prüft Status und Delegation frisch.
Ein technisches `completed` ist keine fachliche Produktfreigabe.

Status-API und Dashboards unterscheiden die Belegung von aktiver Modellarbeit:
`status=reserved` beim Issue, `external.reserved`, `resumed`, `execution_state`,
`missing_evidence`, ursprüngliche Gruppe/Status und aktueller Linear-Status mit
`current_state_known`. Fehlende Tickets werden im bestehenden Coordinator-Tick
gebündelt nachgelesen; fehlgeschlagene Abfragen ergeben unbekannten Status.
Bei belegter Annahme oder Ausführung lautet `missing_evidence` auf
`terminal_original_required`; andernfalls auf
`terminal_or_pre_acceptance_original_required`, damit die bestehende
Vorab-Ablehnungs-Recovery sichtbar bleibt. Die Anzeige ersetzt keinen Beleg und
macht den Betreiberimport nicht zur Voraussetzung regulärer Terminalantworten.
Abbruchanforderungen und nachträglich beobachtete Annahme/Ausführung aktualisieren
die Anzeige auch bei weiteren Timeouts ohne Endbeleg. Unveränderte Beobachtungen
erzeugen keine zusätzlichen Ereignisse.
`counts.running` zählt aktive Einträge, `reserved` reservierte Ticketeinträge,
`reserved_slots` eindeutige reservierte Gruppenplätze. Die Liste `running` enthält
aus Kompatibilitätsgründen weiterhin alle Belegungen; Konsumenten müssen das
Reservierungsmerkmal beachten. Nach Lifecycle-Ende verschwindet der Eintrag.

### Nachweis der Altauftrags-Recovery im isolierten Testprojekt

Die Tests mit `terminal-history.json` sind vollständig synthetisch. Sie belegen
Parser, Konkurrenz, Journal, echten lokalen Beobachter/WorkerCapacity und
HTTP-/LiveView-/Terminaldarstellung, jedoch keinen externen OpenClaw-Lauf.
Für die frühe Produktprüfung am gebundenen Kandidatenstand im bereits freigegebenen
`Prolok/symphony-test` dokumentiert die autorisierte Betreiberrolle:

1. Quell-/Paketstand, Testinstanz, Original-Lauf-/Sitzungsbindung, Annahme und
   Ausführung. Ausschließlich den flüchtigen Endbeleg dieses Testlaufs kontrolliert
   verlieren lassen; keine produktive Gatewayinstanz neu starten.
2. Wiederaufgenommene Reservierung bei aktuellem Linear-Status über API/UI;
   gesperrte Mitglieder und einen belegten gemeinsamen Platz nachweisen.
3. Originaldateien und v2-Paket geschützt ablegen, Hashes/Prüfer referenzieren;
   Trockenlauf lässt Journal und Belegung unverändert. Anwendung speichert
   tatsächliches Ende, Wiederholung verändert nichts.
4. API/UI nach Freigabe, unveränderten fachlichen Status, erhaltene Historie und
   genau eine nachfolgende reguläre Aufnahme mit neuer Lauf-ID nachweisen.
   Aktive/fremde Gegenprobe muss reserviert bleiben. Transportsimulationen und
   echte Gatewaybelege im Ergebnis getrennt kennzeichnen.

Der bestehende gebundene Routineexecutor ersetzt dieses Szenario nur, wenn er
genau diese Nachweise unterstützt. Fehlende fällige Testbereitstellung wird im
Workpad als Betreiberpflicht übergeben, ohne neue persönliche Nutzerabnahme.

## Standardtests und separater Live-Nachweis

Im expliziten OpenClaw-Livetest fragt der Testrunner den Linear-Abnahmestand
höchstens alle 15 Sekunden ab (sonst 3 Sekunden), um die zusätzlichen lesenden
Betreiberabfragen zu begrenzen. Identitätsprüfung, Fehlerklassifikation und das
gesamte Retrybudget des Laufs bleiben unverändert. Das Intervall steht im Ergebnisbeleg.

`make check`, `make all` und ExUnit verwenden keine echte OpenClaw-Installation.
Testbuilds sperren die echte Prozessgrenze; `scripts/mix-gate` entfernt geerbte
Agentenwahl und setzt zusätzlich `SYMPHONY_OPENCLAW_TEST_DENY=1`. Python-Gates
setzen dieselbe Sperre. Aktivierte Testfälle injizieren Antworten und verwenden
temporäre Bindungen, lokale Sockets sowie simulierte Prozesse, keine persönlichen
Agentendateien/Gateways. Ein fehlendes Binary überspringt keinen Test.

Vor **erstmaliger produktiver Aktivierung** führt Tilo außerhalb der Gates einen
Live-Nachweis auf seinem Rechner aus. Es gelten vollständig die Voraussetzungen
des [isolierten Testbetriebs](linear-app.md#isolierter-testbetrieb): eigenes
freigegebenes Manifest für `Prolok/symphony-test`, disjunkter Projektbereich,
exklusive Entscheidungshoheit, Testtickets und dokumentierter Quellstand.
Nur dort zunächst `LINEAR_YOLO_AGENT` und `OPENCLAW_YOLO_AGENT` konfigurieren.
Für Review muss auch das Dummy-Projekt einen passenden versionierten
`.codex/skills/sym-yolo-review/SKILL.md` im gemergten Prüfstand besitzen;
die Bereitstellung erfolgt im zuständigen Projekt über dessen reguläres PR-Verfahren.

```sh
scripts/openclaw-live-test --execute-live --agent po -- \
  --checkout /ABS/PRUEFCHECKOUT --source-mode development \
  --test-instance openclaw-proof --manifest /ABS/manifest.json \
  --run-id openclaw-incoming --expected-sha COMMIT --expected-source SOURCE_SHA256 \
  --port 4099 --timeout 600 --result-dir /ABS/BELEGE/incoming \
  --scenario po_incoming
```

Quellkennung: `python3 scripts/test-instance.py source /ABS/PRUEFCHECKOUT`.
Mit eigener neuer Laufkennung anschließend `--scenario po_handoff` und
`--openclaw-knowledge-question 'Nichtgeheime Fachfrage aus der freigegebenen Wissensbasis'`
ausführen. Die erwartete Antwort vorher separat dokumentieren; sie gehört nicht
in die Frage. Der Review-Agent nennt Antwort und Quelle im Übergabebericht.
Nach Merge kann `--source-mode merged` den tatsächlichen gemergten Stand belegen.
`po_aggregation`/`po_followup` bei Bedarf ebenfalls ausdrücklich auswählen.

`result.json` muss reale Agent-/Sitzungs-/Payloadbelege, tatsächliche PO-Aktionen,
Prüf-SHA, `checkout_proof` (physischer Root, saubere SHA, Projekt/Lauf/Payload),
passenden terminalen Gatewaybeleg, `cleanup`, `main_preserved` und
`originals_preserved` enthalten. Danach `po_incoming` mit neuer Laufkennung und
neuem Ergebnisverzeichnis im selben Testprojekt wiederholen; zusätzlich
`--openclaw-previous-incoming-result /ABS/BELEGE/incoming/result.json` übergeben.
Der Runner verlangt denselben Quell-/Projektstand, einen bestandenen bereinigten
Live-Vorläufer und neue Agentenlauf-/Sitzungskennungen. Er speichert dessen Hash
unter `openclaw.subsequent_incoming` als Nachweis weiterer Eingangsarbeit nach Freigabe.
Zusätzlich Gateway-/CLI-Version und Agentenanweisungsprüfung beilegen sowie die
Fachantwort im **Review-Sitzungsschlüssel** gegen die erwartete Antwort prüfen.
Das automatische Resultat kennzeichnet diese fachliche Betreiberbewertung als
`operator_evidence_required`; ein technischer Pass ersetzt sie nicht.
Simulationen und Live-Belege mit eigenem Quellstand getrennt ausweisen.
Ohne diese positiven Belege bleibt die produktive Aktivierung offen. Standardentwicklung
benötigt keine lokale OpenClaw-Installation. Ticketseitige Live-/Recoverygates
bleiben vor Test-Handoff beziehungsweise Merge bindend, soweit sie gemäß den
[Phasenpflichten](../WORKFLOW.md#phasenpflichten-und-betreiberübergaben)
ausdrücklich dort fällig sind.

Bei Fehlern denselben Auftrag erhalten. Der vorhandene isolierte Runner unterstützt
`--resume --cleanup-only` mit unveränderten Lauf-/Quellparametern; dies ist nur
Cleanup, kein nachträglicher Pass. Unbestätigtes externes Ende verhindert Cleanup.

## Projektintegration und Lernrückkopplung

Die gemeinsame Schnittstelle wird durch `test/fixtures/yolo_review` und simulierte
Codex-/OpenClaw-Läufe nachgewiesen, unabhängig von den Projektpaketen. Tilo/Pai
richten lokale Agentenanweisungen und Rechte separat im eigenen Zuständigkeitsbereich
auf diesen Vertrag aus; Repository-Worker ändern keine privaten Agentdateien.
Die erstmalige Aktivierung behält den oben beschriebenen Live-Nachweis.
Bei der nächsten bereits freigegebenen lokalen Nutzung gehören Projekt, Lauf,
gemergte SHA, Skillpfad/-Hash, tatsächliche Prüfungen, Einschränkungen und begründete
Folgeentscheidungen in den bestehenden Ergebnisbeleg.

Danach integrieren die zuständigen Projektbetreiber QuantInvest/QuantAI bei ohnehin
freigegebenen Aufgaben mit demselben Vertrag. Kein zusätzliches Pilotprojekt/-ticket
oder neue Startfreigabe. Der PO wertet die nächsten etwa zehn bereits freigegebenen
Produkttickets anhand ihrer Workpads knapp aus: ungeplante Eingriffe, vermeidbare
Folgefehler, wiederkehrende Fehlerklassen und unnötige Wiederholungen. Gewollte
Nicht-YOLO-Freigaben zählen nicht als Störung. Künftige Skillverbesserungen nur bei
wiederverwendbarer Prüflücke und positivem Aufwand/Nutzen über reguläre Fix-/PR-
Verfahren vorschlagen; Einzelregressionen und neue Anforderungen getrennt behandeln.
Fixes erhalten ihre eigene Pipeline/Abnahme; der Ursprung wird nach bestätigten
Folgeanlagen sofort an den Menschen übergeben und dafür nicht erneut abgenommen.
