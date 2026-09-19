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
| Start | `agent`: `agentId`, `sessionKey`, `idempotencyKey`, vollständige `message`, `cwd`, `timeout`, `deliver=false` |
| Annahme | Antwort `runId` gleich Auftrags-ID und `status=accepted`; noch kein Arbeitsabschluss |
| Beobachtung | `agent.wait` mit derselben `runId`; `timeout` ohne Endbeleg bleibt ungeklärt |
| Abbruch | `sessions.abort` mit Sitzungsschlüssel **und** `runId`; Bestätigung ersetzt keinen Endbeleg |
| Ende | Passende `runId`, terminaler Status und `endedAt`; `yielded`/`pendingError` sind kein Ende |

Schemas: [Agent-RPC](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/packages/gateway-protocol/src/schema/agent.ts),
[Sitzungen](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/packages/gateway-protocol/src/schema/sessions.ts).
Die Zuordnung `idempotencyKey` → `runId` und die begrenzte Ergebnisvorhaltung
sind im [Gateway-Quellcode](https://github.com/openclaw/openclaw/tree/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/gateway/agent-turn)
geprüft. Ein abgelaufener Cache beweist keine Nichtausführung.

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
SHA-256-Hash. Der projektspezifische `sym-yolo-review` aus dem Prüfcheckout wird
eingebettet, sofern vorhanden; seine referenzierten Dateien liegen im Checkout.

Eigene Sitzungsschlüssel enthalten Projektkennung, OpenClaw-Agent, Aufgabenbereich
und Lauf-ID. Normale Agentengespräche werden nicht wiederverwendet. OpenClaw
behält seinen Agenten-/Wissenskontext; die Wissensverfügbarkeit in **diesem**
Sitzungstyp muss live nachgewiesen werden.

Ein temporärer lokaler MCP-Zugang bindet Projekt, Laufgeneration und Mitglieder
serverseitig. Der Agent ruft über sein vorhandenes `exec` das mitgelieferte
`scripts/sym-yolo-tool.py` mit Bindungsdatei und JSON-RPC auf stdin auf.
`tools/list` und `tools/call` erreichen denselben Symphony-Dispatcher wie Codex:
`linear_graphql`, `symphony_comments`, `symphony_yolo_action`,
`symphony_yolo_complete` und `symphony_test`. Bestehende Frische-, Schreib- und
Testexecutorgrenzen bleiben wirksam; ein Werkzeugname allein erteilt keine
zusätzliche Berechtigung. Nach Abbruch, Transportunsicherheit oder Wiederaufnahme
ist die alte Schreibbindung gesperrt. Die lokale Bindungsdatei gehört nur diesem
Lauf und enthält keine Linear-Credentials; sie darf nicht ausgegeben werden.

Der Betreiber muss für den gewählten Agenten prüfen und dokumentieren:

- Vorhandenes lokales `exec` und Python 3; Zugriff auf den Symphony-Helfer,
  Loopback und den konfigurierten Workspace-Root. Ein restriktiver OpenClaw-
  Sandboxpfad darf den Prüfcheckout nicht still durch den Wissensworkspace ersetzen.
- Freigegebene Wissensquellen, insbesondere Verfügbarkeit von Memory in der
  eigenen Symphony-Sitzung. Keine private Symphony-Envdatei als Wissensquelle.
- Widersprüche in Agentenanweisungen, einschließlich eines vorhandenen
  `symphony-product-owner`: Ablauf aus dem übergebenen Workflow, keine zweite
  Ticketsteuerung, keine parallelen Unteragenten, keine direkten Linear-Schreibwege,
  kein automatisches `Review` → `Fertig`. Notwendige Anpassungen protokollieren.
- LinearBridge-Mentions bleiben Beratung; allein Symphony autorisiert Aktionen.

PO-/Abnahme-Checkouts liegen detached unter `workspace.root/yolo/<Gruppe>/<Lauf>`
auf der aktuellen `origin/main`-SHA. Auftragsartefakte liegen getrennt unter
`workspace.root/yolo-runs/<Lauf>`; die Clean-Checkout-Prüfung bleibt wirksam.

## Unsicherheit, Wiederaufnahme und Cleanup

Vor Versand wird eine unveränderliche Auftragsabsicht mit Agent, Sitzung,
Mitgliedern, Payload-Hash und Checkout/SHA synchron gespeichert. Eine Gruppe
behält Mitgliederleases, lokale Sperren und einen gemeinsamen Kapazitätsplatz
bis zum bestätigten externen Ende. Beim Neustart werden Reservierungen aus dem
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

## Standardtests und separater Live-Nachweis

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
Prüf-SHA, `cleanup`, `main_preserved` und `originals_preserved` enthalten.
Zusätzlich Gateway-/CLI-Version und Agentenanweisungsprüfung beilegen sowie die
Fachantwort im **Review-Sitzungsschlüssel** gegen die erwartete Antwort prüfen.
Das automatische Resultat kennzeichnet diese fachliche Betreiberbewertung als
`operator_evidence_required`; ein technischer Pass ersetzt sie nicht.
Simulationen und Live-Belege mit eigenem Quellstand getrennt ausweisen.
Ohne diese positiven Belege bleibt die produktive Aktivierung offen; reguläre
Entwicklung und Merge benötigen keine lokale OpenClaw-Installation.

Bei Fehlern denselben Auftrag erhalten. Der vorhandene isolierte Runner unterstützt
`--resume --cleanup-only` mit unveränderten Lauf-/Quellparametern; dies ist nur
Cleanup, kein nachträglicher Pass. Unbestätigtes externes Ende verhindert Cleanup.
