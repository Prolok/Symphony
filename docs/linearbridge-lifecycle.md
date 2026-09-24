# Symphony → LinearBridge Lifecycle v1

Der Produzent projiziert ausschließlich den vorhandenen OpenClaw-PO-Auftrag.
Der Consumer verwaltet Prioritätsmarker in Linear. Das Protokoll überträgt
keine Codingaufträge und startet keine Modellrunde.

## Optionale Einrichtung

`tracker.openclaw_linear_bridge` im zentralen Workflow, ohne geheime Werte:

```yaml
tracker:
  openclaw_linear_bridge:
    producer_id: symphony-example
    consumer_account_id: account-example
    key_id: producer-key-example
    secret_env: SYMPHONY_LINEAR_BRIDGE_KEY
    gateway_port: 18789
```

Die drei IDs sind ASCII-Slugs (1–128 Zeichen, Buchstaben/Ziffern, danach auch
`_.-`). `secret_env` ist optional und verwendet den dargestellten Standard.
Andere Namen müssen `SYMPHONY_LINEAR_BRIDGE_[A-Z0-9_]+` entsprechen. Keine
Env-Expansion, Inline-Schlüssel oder unbekannten Felder. Der separate
Base64-kodierte HMAC-Schlüssel liegt ausschließlich im vorhandenen geschützten
Dienstzugriff; alle Variablen dieses Präfixes werden vor öffentlichen
Projektkontexten, Hooks, Worker- und CLI-Kindprozessen entfernt. Der
Secret-Access-Deny-Vertrag gilt auch hier. Kein App-/Relay-/Gatewaycredential
wiederverwenden. Konfigurationsänderungen verlangen einen Dienstneustart.

`gateway_port` ist optional (Standard `18789`) und akzeptiert ausschließlich
eine Ganzzahl von 1 bis 65535. Für einen separat bereitgestellten lokalen
Testconsumer beispielsweise `19892` setzen. Nur der Lifecycle-RPC verwendet
diesen Port über das vorhandene CLI-Argument `--port`; dieses erzwingt im
unterstützten OpenClaw-Release das lokale Loopbackziel, auch bei abweichender
Remote-/Env-Konfiguration. Agent-, Status-, History-, Abbruch- und
Benachrichtigungsaufrufe bleiben auf `18789`. Keine URL-/Host-/Credentialoption,
kein automatischer Rückfall auf den Standardport bei fehlendem Consumer.
Gatewayauthentisierung bleibt beim bestehenden autorisierten CLI-Zugang;
der Port ersetzt keine Authentisierung oder Consumerbindung.

Ohne Option oder ohne `OPENCLAW_YOLO_AGENT`: keine Consumer- oder Schlüsselzugriffe.
Bereits gespeicherte Snapshots bleiben bei Deaktivierung offen. Mit Option und fehlendem
Schlüssel/Consumer: PO-Ausführung bleibt unabhängig; Zustellung bleibt
dauerhaft offen, mit `OpenClaw LinearBridge delivery=pending` und
Issue-/Session-/Auftragsbezug im Log. Kein Installieren, Pairing oder Erweitern
von Berechtigungen. Der Consumer muss vorher separat eingerichtet sein.

Nur neu angelegte Originalaufträge erhalten die konfigurierte Bridgebindung.
Bestehende Altjournale werden beim Aktivieren nicht rückwirkend interpretiert.
Die gesamte Bindung einschließlich lokalem Gatewayport, Empfänger und Schlüsselreferenz bleibt für
die Generation unveränderlich. Nach einem Konfigurationswechsel bleiben nicht
passende alte Zustellungen offen (`openclaw_bridge_binding_changed`).
Alte Bridgejournale ohne Portfeld bedeuten weiterhin ausschließlich `18789`;
ein expliziter Standardport ist dazu gleichwertig. Die ursprüngliche Bindung
wiederherzustellen erlaubt den bestehenden Retry mit denselben Snapshotbytes;
Journale nicht zum Umleiten editieren. Der lokale Port gehört nur zur
Zustellkonfiguration, nicht zum v1-Wire-Schema oder zu dessen Snapshot-Hashes.

Für die isolierte Integration richtet der zuständige Betreiber den Consumer
mit passender Produzenten-/Accountbindung und vorhandenem autorisiertem Zugang
auf dem gewählten lokalen Port ein, bevor Symphony neue Testaufträge erzeugt.
Die Testinstanz erhält diese Workflowoption vor ihrem Start. Symphony startet
oder installiert den Consumer nicht und verändert keine OpenClaw-Konfiguration.
Ein bereits journalisierter Produktionsauftrag kann durch einen Portwechsel
nicht zum Testauftrag werden. Backlog- und Zwei-Mitglieder-Reviewlauf müssen
über den echten Transport samt Markeränderungen und Cleanup separat belegt
werden; aufzeichnende Testtransporte sind nur synthetische Nachweise.

## Implementierungsstand der Recoverybelege

Der Betreiberpfad unterstützt belegte Vorab-Ablehnung, Originalterminal und
die technische Stilllegung neuer, schreibgesperrter Unterbrechungen gemäß
[OpenClaw-Recovery](openclaw-yolo.md). `Recovery.retire/4` prüft dafür die
Originalbindung, eine frische inaktive Sitzung, den Eingabestand und entweder
eine bestätigte Abbruchquittung oder das belegte Ende des Originallaufs.
`Journal.transition/2` erfasst den Stilllegungsbeleg mit dem Bridge-Snapshot.
Ein bloßer Abbruchversuch oder ein Timeout ohne diese Belege bleibt offen.

## Wire-Vertrag

**Transport:** neuer Consumer-RPC `linearbridge.symphony.lifecycle.v1` über den bereits vorhandenen lokalen Aufruf `openclaw gateway call <method> --params <JSON> --json --timeout 10000 --port <gateway_port>` (Standard `18789`). Der LinearBridge-Consumer registriert ihn über öffentliche `api.registerGatewayMethod(method, handler, {scope: "operator.write"})`; bestehende autorisierte Gatewayverbindung verwenden, keine neue Geräteberechtigung. Kein HTTP-Server, Prompt-Parsing, agent-Aufruf oder Modell im Consumerpfad.

Die Portauswahl verwendet den bestehenden `localPortOverride` des
[Gatewayclients](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/gateway/call.ts)
und dessen
[Zielauflösung](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/gateway/connection-details.ts).

**Quellen:** OpenClaw 2026.9.4, Commit `3a9d69db306cd7f081e06254cb89c4bcc14a7107`: [öffentliche Plugin-API](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/plugins/plugin-api.types.ts), [Gateway-Router/Scopeprüfung](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/gateway/server-methods.ts), [Handlervertrag](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/gateway/server-methods/shared-types.ts), [Agent-RPC](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/packages/gateway-protocol/src/schema/agent.ts). Repoquellen: `lib/symphony_elixir/yolo/openclaw.ex`, `openclaw/gateway.ex`, `openclaw/journal.ex`, `openclaw/recovery.ex`, `ProjectContext.load/4`; Stilllegungen werden aus dem vorhandenen Journalbeleg projiziert. Öffentliche Schnittstelle ist belegt; Registrierung, Schlüssel und isolierte Consumerinstanz sind Bereitstellungsarbeit im Gegenprojekt.

**Authentisierungsgrenze:** Gatewayauthentisierung transportiert die Meldung; eine Producer-ID im JSON allein ist keine Autorisierung. Zusätzlich HMAC-SHA256 mit separatem installations-/produzentengebundenem Schlüssel (mindestens 32 zufällige Bytes, Base64-Konfiguration). Keine Wiederverwendung von Linear-App-/Relay-/Gatewaycredentials. Schlüssel nur beim vertrauenswürdigen Symphony-Dienst und Consumer; weder Modelle noch Prompts, Journale, Logs oder CLI-Umgebung erhalten ihn. Signieren erfolgt im Dienst vor dem vorhandenen geheimnisbereinigten Transport.

Wire-Params, geschlossenes Objekt:
```json
{"version":1,"key_id":"producer-key-example","payload_b64":"BASE64-DER-UTF8-JSON-BYTES","mac":"64-kleine-Hexzeichen"}
```
`mac = hex_lower(HMAC_SHA256(key, UTF8("linearbridge.symphony.lifecycle.v1\n" + key_id + "\n" + payload_b64)))`. Base64 nach RFC 4648 mit Padding; `key_id` ist ein nichtleerer ASCII-Slug ohne Zeilenumbruch. Die exakt gespeicherten UTF-8-Bytes werden signiert und wiederholt; keine sprachübergreifende JSON-Kanonisierung erforderlich. Payload maximal 256 KiB, geschlossene v1-Objekte, doppelte JSON-Schlüssel und unbekannte Versionen ablehnen. Authprüfung zeitkonstant vor jeder Wirkung.

Consumerkonfiguration bindet `key_id` fest an erlaubten `producer_id`, `consumer_account_id`, Linear-Workspace, Symphony-Projekt und beide Agenten. Account ist eine LinearBridge-Kennung, kein Hostfeld. Consumer prüft sein tatsächlich authentifiziertes Linear-Konto/Workspace sowie die konfigurierte Projektzuordnung aller Mitglieder; keine Ableitung aus Nachrichten. Bei späterem Delegations-/Statuswechsel bleibt die originale Bindung für das Beenden des ursprünglichen Auftrags maßgeblich.

**Payloadschema:** nach Base64-Dekodierung:
- `version`: exakt 1; `producer_id`/`consumer_account_id`: nichtleere konfigurierte IDs; `sequence`: positive Ganzzahl bis 2^53−1, monoton pro Originalauftrag.
- `binding`: alle Felder des folgenden Beispiels verpflichtend. `order_id` = Originaljournal `id` (UUID); `group` = incoming/planning/in_progress/blocker/review. `project_id` ist der kanonische Symphony-Projektroot, **keine Linear-Projekt-UUID**; `workspace` ist der originale Prüfcheckout. `source_sha` = Journal `sha` (Git-SHA); `payload_sha256` = ursprünglicher Auftragshash (64 kleine Hexzeichen).
- `linear_workspace_id`, `linear_agent_id`, sämtliche `issue_ids`: UUIDs. `issue_ids` ist die vollständige nichtleere, aufsteigend sortierte Originalmitgliedermenge; Duplikate/Teilmenge/Erweiterung ablehnen. Keine stillschweigende Korrektur. `openclaw_agent_id` = Journal `agent`.
- `native.runId` = `order_id`; `native.sessionKey` = Journal `session_id` (dieses historische Feld enthält einen **Sitzungsschlüssel**, keine physische sessionId). Vor Annahme sind dies reservierte Zielkennungen, kein Startbeweis. Es wird kein weiteres Host-Generationsfeld vorausgesetzt.
- `observation`: `state` aus intent/accepted/running/unknown/cancel_pending/completed/failed/cancelled/rejected/retired; die fünf dargestellten Booleschen Felder und die drei Belegfelder sind verpflichtend, fehlende Belege als null. `acceptance_observed`/`execution_observed` bleiben monoton. Fehlende historische Flags dürfen keinen erfundenen Nachweis erzeugen.
- `terminal`: null oder diskriminierter Producerbeleg. `kind=gateway`: `{kind,runId,status,endedAt,startedAt?,stopReason?}`, status=ok/error/timeout. `kind=operator_terminal_original`: `{kind,runId,status,state,startedAt,endedAt,evidence_sha256,source_sha256,execution_source_sha256}` aus bestätigtem V2-Recoveryjournal; status=done/failed/timeout/killed, zugehöriger state=completed/failed/cancelled. runId exakt order_id, echte Originalzeiten; yielded/pendingError niemals terminal. kind ist ein Protokollfeld, kein behauptetes Hostfeld.
- `rejection`: null oder `kind=gateway` mit `{kind,method,phase,code,reason,request_sha256,id,session_id,agent,payload_sha256}`; method=agent, phase=pre_acceptance, code=INVALID_REQUEST, reason=cwd_reserved/cwd_not_absolute. Alternativ bestätigte V1-Recovery: `{kind:"operator_pre_acceptance",code,reason,request_id,source_sha256,execution_source_sha256,evidence_sha256}` aus rejection/recovery, reason=cwd_reserved. Keine erfundenen request_sha256; Originalbindung und fehlende Annahme/Ausführung bereits durch Recovery geprüft.
- `retirement`: null oder die Projektion des journalisierten Belegs `{kind,stop_basis,retired_at,history_sha256,physical_session_id,last_run_id,session_end}`; kind=fenced_interruption, stop_basis=abort_acknowledged/terminal_original/terminal_original_history. Die vorhandene Recovery prüft den Beleg vor seiner Journalisierung; die Bridge führt keine eigene History-Recovery aus. session_end enthält die tatsächlich gespeicherten lastRunId/status/startedAt/endedAt. Abweichende physische Folgegenerationen sind kein ursprüngliches Erfolgs-/Enddatum. Für Retirement verlangt der Consumer state=retired, writable=false und cancel_requested=true; fehlende Stilllegung bleibt offen. Dieser technische Ausgang behauptet keinen fachlichen Erfolg.

**Semantik und Quittung:** Der erste gültige Snapshot fixiert die gesamte Bindung unter (producer_id, consumer_account_id, order_id). Weitere Snapshots müssen exakt dieselbe Bindung besitzen. intent/Delegation allein setzt keinen Marker. Erst bestätigte native Annahme (auch Warteschlange) oder tatsächlicher Startbeleg aktiviert sämtliche Mitglieder. unknown/timeout/abort-Ack allein löschen nichts. Ein gültiges Originalterminal, belegte Nichtannahme oder bestätigte journalisierte Stilllegung beendet exakt diesen Auftrag. Tool-/Checkoutbeleg belegt Ausführung, keinen Abschluss.

Der Consumer führt pro Issue die Menge offener Auftragskennungen; ein alter Abschluss darf einen neueren/überlappenden Marker nicht löschen. Sequenzen unterhalb der zuletzt gespeicherten werden wirkungslos quittiert; identische Sequenz+Bytes ist wirkungslos, gleiche Sequenz mit anderen Bytes ein Konflikt. Terminale Tombstones dürfen durch keine spätere aktive Meldung wieder geöffnet werden. Keine Altersfrist, die notwendige Restart-Replays nachträglich zur neuen Arbeit macht.

Antwort über denselben authentisierten RPC, geschlossen:
```json
{"version":1,"producer_id":"symphony-example","consumer_account_id":"account-example","order_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","sequence":2,"payload_sha256":"SHA256-DER-DEKODIERTEN-PAYLOAD-BYTES","disposition":"stored"}
```
`disposition` = stored/duplicate/stale; erst nach dauerhafter Consumerübernahme antworten. Antwort-hash bezieht sich auf diesen Snapshot, Bindungs-hash auf den ursprünglichen PO-Payload. Vollständige Echo-/Hashprüfung durch Symphony; fremde/falsch gebundene Antwort bleibt unquittiert. Auth-/Schema-/Bindungskonflikte sind Gatewayfehler ohne Wirkung. Quittung belegt dauerhafte Übernahme durch LinearBridge, **nicht** bereits abgeschlossene Linear-Prioritätsschreibvorgänge; deren Retry und Ergebnisbelege gehören dem Consumer.

**Neutrales Backlog-/incoming-Beispiel**, ohne echte Konten/Schlüssel; Quell-/Payloadhashes sind Fixturewerte, der Projektroot-Hash ist berechnet:
```json
{"version":1,"producer_id":"symphony-example","consumer_account_id":"account-example","sequence":2,"binding":{"order_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","group":"incoming","project_id":"/srv/projects/example","linear_workspace_id":"11111111-1111-4111-8111-111111111111","linear_agent_id":"22222222-2222-4222-8222-222222222222","openclaw_agent_id":"po-example","workspace":"/srv/worktrees/example/po-incoming","source_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","payload_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","issue_ids":["33333333-3333-4333-8333-333333333333"],"native":{"runId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","sessionKey":"agent:po-example:symphony:a31928515822ddc768d58d764ba4562cf31ebb6777f38cfc0ee449e767d59ba1:incoming:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}},"observation":{"state":"accepted","writable":true,"acceptance_observed":true,"execution_observed":false,"cancel_requested":false,"abort_acknowledged":false,"terminal":null,"rejection":null,"retirement":null}}
```

**Zwei-Mitglieder-Yolo-Review-Beispiel:** gleiche vollständige Struktur, eigener Auftrag `bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb`, `group="review"`, `workspace="/srv/worktrees/example/po-review"`, `issue_ids=["33333333-3333-4333-8333-333333333333","44444444-4444-4444-8444-444444444444"]`, native.runId gleich dieser zweiten Auftrags-ID und sessionKey `agent:po-example:symphony:a31928515822ddc768d58d764ba4562cf31ebb6777f38cfc0ee449e767d59ba1:review:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb`. Annahme-Snapshot hat sequence=2 und obige observation. Ein späterer Endsnapshot desselben Auftrags hat sequence=3, state=completed, writable=false, acceptance_observed=true, execution_observed=true, cancel_requested=false, abort_acknowledged=false und `terminal={"kind":"gateway","runId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","status":"ok","startedAt":1800000000000,"endedAt":1800000001000}`; rejection/retirement bleiben null. Alle anderen Bindungsfelder bleiben identisch. Diese synthetischen Zeiten/Hashes behaupten keinen ausgeführten Lauf. Ein Ende des ersten Auftrags lässt den Marker des gemeinsam enthaltenen Mitglieds aus diesem zweiten Auftrag bestehen.


## Dauerhaftigkeit und Zustellungsbelege

`Journal.write/1` und jede wirksame Lifecycleänderung erzeugen unter derselben
Journalsperre den nächsten Snapshot; Snapshot und Zustand werden gemeinsam
atomar geschrieben. Das Journal bewahrt die exakten Payloadbytes als Base64,
ihren SHA256 und die monotone Sequenz. Nur die öffentliche Projektion ändert
die Sequenz; Fehlermeldungen und wiederholte identische Beobachtungen nicht.
Der Signaturschlüssel wird nie ins Journal geschrieben.

Der vorhandene Coordinator stößt je Tick eine begrenzte Zustellung unter einer
separaten projektweiten Lease an (höchstens vier offene Generationen, je ein
Snapshot). Kein Netzwerkaufruf hält die Auftragsjournalsperre. Vor jedem RPC
wird eine 30-Sekunden-Wiederholfrist dauerhaft gespeichert. Verlorene Antworten
und Abstürze vor dem Ack führen ausschließlich zum Replay derselben Bytes.
Eine bestätigte Quittung erlaubt den nächsten Snapshot beim nächsten Tick.
Terminale und archivierte Generationen bleiben zustellbar. Separate
generationengebundene Receipts enthalten die bestätigte Sequenz, den
Snapshot-Hash und die Disposition; sie verändern keine Ausführungsdaten.
Es gibt keine zweite Arbeitsausführung oder Exactly-once-Behauptung.

Das [JSON-Schema](contracts/linearbridge-lifecycle-v1.schema.json) beschreibt
Envelope (`$defs.envelope`), dekodierten Payload (`$defs.payload`) und
Quittung (`$defs.ack`). Zusätzlich verbindlich sind die obigen
Authentisierungs-, Originalbindungs-, Sortier-, Korrelations- und
Zustandsregeln; JSON-Schema allein autorisiert nichts.
Neutrale, synthetische Vollbeispiele:
[incoming](../test/fixtures/openclaw/linear_bridge/incoming.json),
[Review mit zwei Mitgliedern](../test/fixtures/openclaw/linear_bridge/review.json),
[dessen Ende](../test/fixtures/openclaw/linear_bridge/review-completed.json).
Die Gateway-Abortquittung allein bleibt auch bei `abort_acknowledged=true`
nichtterminal. Die Recovery liefert Vorab-Ablehnung, Originalterminal oder
eine nach Inaktivitäts- und Eingabeprüfung journalisierte technische
Stilllegung; deren Projektion bleibt an den Originalauftrag gebunden.

## Isolierter Integrationsnachweis

Die normalen Tests verwenden injizierte Transporte und synthetische Consumer.
Sie ersetzen keinen tatsächlich ausgeführten Producer→LinearBridge-Lauf.
Der Betreiber bindet eine isolierte Consumerinstanz an denselben v1-Vertrag.
Der vorhandene `scripts/openclaw-live-test`-Runner deckt `po_incoming` sowie
`po_handoff` mit einem Reviewmitglied und einem BLOCKER-Mitglied ab. Er
ersetzt den zusätzlichen tatsächlich ausgeführten Reviewauftrag mit zwei
Mitgliedern nicht; diesen stellt der zuständige Betreiber im isolierten
Testprojekt separat bereit und korreliert ihn mit den Journal-/Consumerbelegen.
Keine Produktivinstallation und keine Änderungen an OpenClaw durch den Worker.

Der Beleg nennt Producer-/Consumerquellstand, Gatewayversion, erlaubte öffentliche
Account-/Projekt-/Agentbindung, Originalauftrag, vollständige UUID-Menge,
native runId/sessionKey, signierte Snapshot-Hashes/Sequenzen, Consumerquittungen
und die tatsächlich gelesenen Prioritätsübergänge aller Mitglieder.
Geheimnisse, vollständige Prompts und reale Kundendaten gehören nicht hinein.
Unbekannte Annahme und fehlendes Ende bleiben offen; nachgewiesene Überlappung
darf keinen fremden Marker löschen. Cleanup, `main_preserved` und
`originals_preserved` des isolierten Runners bleiben Pflichtbelege.
