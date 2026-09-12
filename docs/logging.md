# Logging Best Practices

This guide defines logging conventions for Symphony so Codex can diagnose failures quickly.

## Goals

- Make logs searchable by issue and session.
- Capture enough execution context to identify root cause without reruns.
- Keep messages stable so dashboards/alerts are reliable.

## Required Context Fields

When logging issue-related work, include both identifiers:

- `issue_id`: Linear internal UUID (stable foreign key).
- `issue_identifier`: human ticket key (for example `MT-620`).

When logging Codex execution lifecycle events, include:

- `session_id`: combined Codex thread/turn identifier.

## Message Design

- Use explicit `key=value` pairs in message text for high-signal fields.
- Prefer deterministic wording for recurring lifecycle events.
- Include the action outcome (`completed`, `failed`, `retrying`) and the reason/error when available.
- Avoid logging large payloads unless required for debugging.

## Log Sink

Application logs are written through `SymphonyElixir.LogFile` to a rotating
single-line disk log shared by all discovered projects. Its default root is
the service's starting working directory. The relative path is always `log/symphony.log`;
`symphony --logs-root <path>` changes the root in front of that relative path,
so the file is written below `<path>/log/symphony.log`. The handler keeps five
files of up to 10 MiB each and removes the default console handler after disk
logging is configured.

## Scope Guidance

- `AgentRunner`: log start/completion/failure with issue context, plus `session_id` when known.
- `Orchestrator`: log dispatch, retry, terminal/non-active transitions, and worker exits with issue context. Include `session_id` whenever running-entry data has it.
- `Orchestrator`: for Review-(AI)-Handoffs zusätzlich festhalten, ob `spawn_agent`-/`wait_agent`-Signale erfasst wurden, inklusive `recovered_kind`, der getrackten Review-Sub-Agent-Call-/Agent-ID-Anzahlen und der Rohquelle (`source_method`, `source_item_type`, `source_tool`) des erkannten Handoff-Events.
- `Codex.AppServer`: log session start/completion/error with issue context and `session_id`.
- `Codex.AppServer`: log protocol notifications at debug level with `method`,
  `item_type`, `tool`, `call_id` and `jsonrpc_id` when those fields are
  available. Keep the raw protocol payload in the event stream, not in normal
  log messages.

## Checklist For New Logs

- Is this event tied to a Linear issue? Include `issue_id` and `issue_identifier`.
- Is this event tied to a Codex session? Include `session_id`.
- Is the failure reason present and concise?
- Is the message format consistent with existing lifecycle logs?
