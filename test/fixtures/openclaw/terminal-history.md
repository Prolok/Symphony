# Synthetischer terminaler Historybeleg

`terminal-history.json` enthält ausschließlich erfundene Werte. Die Tests ersetzen
Sitzungsschlüssel und Lauf-ID durch ihre isolierte Journalbindung; kein Livebeleg,
keine persönliche Sitzung, kein kryptografisch authentisiertes Gatewaydokument.

Vertrag: OpenClaw 2026.9.4, Commit
`3a9d69db306cd7f081e06254cb89c4bcc14a7107`:

- [chat.history](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/gateway/server-methods/chat-history-handler.ts):
  `sessionKey`, physische `sessionId`, vollständige Seite, `pendingInputs`,
  `sessionInfo`, `hasActiveRun`, vollständige `activeRunIds`; `inFlightRun`
  entfällt bei Abwesenheit. Historische `sessionId` benötigt `messageId`.
- [Nachrichtenkennung](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/gateway/session-history-tail.ts):
  Die originale Datensatzkennung steht in `__openclaw.id`, nicht in einem
  erfundenen Top-Level-`id`. Offset 0 wird ausdrücklich angefordert.
- [Lifecycle-Projektion](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/gateway/session-utils-display.ts)
  und [Session-Row](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/gateway/session-utils-row.ts):
  echtes `startedAt`/`endedAt`, `status`, `lastRunId`; `hasActiveSubagentRun`
  entfällt ohne Unterlauf. `done`, `failed`, `timeout`, `killed` sind getrennte Ergebnisse.
- [Mirrorattestation](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/extensions/codex/src/app-server/transcript-mirror-attestation.ts):
  strukturierter Terminalbesitz, Mirrorherkunft, Identität und 32-stelliger
  Quellfingerprint. `runTerminal` allein ist kein Beleg für ein Gateway-Laufende.

Diese lesenden Projektionen beweisen keine ursprüngliche Symphony-/Payloadbindung
einer bislang unbekannten physischen Sitzung. Die Herkunft und diese Zuordnung
bestätigt daher ausschließlich der berechtigte Betreiber beim v2-Import.
Tests mutieren Struktur, Identitäten, Aktivität, Lifecycle, Rohbytes und Frische
und prüfen zusätzlich eine direkte frische Gatewayantwort vor dem Journalabschluss.
