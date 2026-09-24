OpenClaw 2026.9.4, commit `3a9d69db306cd7f081e06254cb89c4bcc14a7107`, MIT (LICENSE).

`agent-request-preflight.ts`: unchanged upstream `src/gateway/agent-turn/agent-request-preflight.ts`, SHA256 `64d6f0a61befd62a40921d602129b113524c7308285c34db588654e80ff38c28`. `preflight.cjs` executes its cwd checks with an external CLI principal. This is a boundary regression, not a complete gateway/live run.

`request-error.txt`: unchanged `formatGatewayClientRequestErrorJson` from `src/gateway/call.ts` at the same commit. `src/cli/gateway-cli/register.ts:94-120` writes this object to stdout and exits 1 in JSON mode. Text/stderr-only errors do not provide this typed provenance and remain unknown.

`chat-abort-authorization.ts`: unveränderter Ausschnitt `resolveChatAbortRequester` und `canRequesterAbortChatRun` aus `src/gateway/server-methods/chat-abort-authorization.ts` desselben Commits, SHA256 `c4a1115e2f701f45c1c7a185a219480250934272a1b8515e5b04e059ba7c63cb`. `owner.cjs` führt diese Funktionen mit dem normalen String-Trimming und `operator.admin` als Scopekonstante aus. `owner-rpc-test.mjs` prüft zusätzlich die Symphony-Prozessgrenze ohne installierten Host.

`test/openclaw_owner_integration.mjs` ist ein expliziter SDK-Vertragstest außerhalb der Standardgates: echter öffentlicher Konfigurationszugriff und SDK-Client, synthetisches lokales Tokenprofil mit ungekoppelter Identität/leerem Gerätecache und obige echte Besitzerprüfung am Fixture-Server. Start/Abbruch verwenden dieselbe Verbindung; fremde Sitzung/Besitzer, Doppelstart und Verbindungsverlust bleiben gesperrt. Keine injizierten Gerätezugänge oder Profiländerungen; kein Beleg für vorhandene Betreiberzugänge oder einen echten Agentenabbruch.
