# Codex Token Accounting

This document explains how Codex reports token usage through the app-server protocol and how Symphony should account for it.

It is based on the current Codex source in `codex-rs`, especially:

- `app-server/README.md`
- `protocol/src/protocol.rs`
- `app-server/src/bespoke_event_handling.rs`
- `app-server-protocol/src/protocol/v2.rs`
- `exec/src/event_processor_with_jsonl_output.rs`
- `state/src/extract.rs`

## Short Version

- `last_token_usage` means "the latest increment".
- `total_token_usage` means "the cumulative total so far".
- `thread/tokenUsage/updated` is the live streaming notification for token usage.
- `turn/completed` carries final turn state, and turn-level usage is exposed separately from the live thread token stream.
- Symphony accepts explicit `turn/completed` usage only as a fallback completion snapshot when no cumulative token total is present in the same update.
- Generic `usage` fields are event-specific. Do not assume every `usage` payload is a cumulative thread total.

## Primary Source Semantics

Codex defines `TokenUsageInfo` like this:

```rust
pub struct TokenUsageInfo {
    pub total_token_usage: TokenUsage,
    pub last_token_usage: TokenUsage,
    pub model_context_window: Option<i64>,
}
```

The important behavior is in `append_last_usage`:

```rust
pub fn append_last_usage(&mut self, last: &TokenUsage) {
    self.total_token_usage.add_assign(last);
    self.last_token_usage = last.clone();
}
```

That gives the core semantics:

- `last_token_usage`: the newest chunk of usage that was just added
- `total_token_usage`: the accumulated total after adding that chunk

This is the most important accounting rule in the Codex source.

## Event Types

### `codex/event/token_count`

Codex core emits token count events containing `TokenUsageInfo`.

These events can carry:

- `info.total_token_usage`
- `info.last_token_usage`
- `info.model_context_window`

Symphony sees these events wrapped inside the app-server message stream.

Meaning:

- `total_token_usage` is an absolute cumulative snapshot
- `last_token_usage` is the delta that produced that snapshot

### `thread/tokenUsage/updated`

The app-server converts token count events into a dedicated thread-scoped notification:

```rust
let notification = ThreadTokenUsageUpdatedNotification {
    thread_id: conversation_id.to_string(),
    turn_id,
    token_usage,
};
```

`ThreadTokenUsage` is defined as:

```rust
pub struct ThreadTokenUsage {
    pub total: TokenUsageBreakdown,
    pub last: TokenUsageBreakdown,
    pub model_context_window: Option<i64>,
}
```

And it is populated directly from `TokenUsageInfo`:

```rust
impl From<CoreTokenUsageInfo> for ThreadTokenUsage {
    fn from(value: CoreTokenUsageInfo) -> Self {
        Self {
            total: value.total_token_usage.into(),
            last: value.last_token_usage.into(),
            model_context_window: value.model_context_window,
        }
    }
}
```

Meaning:

- `thread/tokenUsage/updated` is the canonical live notification for token usage
- `tokenUsage.total` is an absolute thread total
- `tokenUsage.last` is the latest increment that produced that total

The app-server README is explicit: token usage streams separately via `thread/tokenUsage/updated`.

### `turn/completed`

The app-server README says `turn/completed` carries final turn state and token usage.

There are two important details:

1. The app-server protocol `turn/completed` notification contains a final `turn` object.
2. The `exec` event processor also emits a turn-completed event that includes a `usage` struct.

In the `exec` event processor, the turn-completed usage is built from the most recent captured `total_token_usage`:

```rust
if let Some(info) = &ev.info {
    self.last_total_token_usage = Some(info.total_token_usage.clone());
}
```

Then on turn completion:

```rust
let usage = if let Some(u) = &self.last_total_token_usage {
    Usage {
        input_tokens: u.input_tokens,
        cached_input_tokens: u.cached_input_tokens,
        output_tokens: u.output_tokens,
    }
}
```

Important consequence:

- a turn-completed `usage` payload is not the same schema as `ThreadTokenUsage`
- it should be interpreted in the context of the specific event that emitted it
- it must not be blindly mixed with `thread/tokenUsage/updated` accounting

### Generic `usage`

Codex uses the word `usage` in multiple places.

That does not mean all `usage` maps have the same semantics.

Examples:

- `thread/tokenUsage/updated.tokenUsage.total`: absolute cumulative thread total
- `thread/tokenUsage/updated.tokenUsage.last`: latest delta
- turn-completed `usage`: event-specific completion usage payload

Rule:

- never classify a `usage` map by name alone
- classify it by event type and payload path

## What The Metrics Mean

### Absolute totals

These are safe high-water-mark style counters:

- `info.total_token_usage`
- `tokenUsage.total` on `thread/tokenUsage/updated`

Use these when you want:

- live dashboard totals
- stable per-thread accumulation
- recovery after missed intermediate events

### Deltas

These are incremental additions:

- `info.last_token_usage`
- `tokenUsage.last` on `thread/tokenUsage/updated`

Use these only when:

- no absolute total is available
- you are explicitly handling additive updates

### Context window

`model_context_window` is not spend. It is the model's context limit.

Codex also has logic that can "fill to context window", which sets:

- `total_token_usage.total_tokens = context_window`
- `last_token_usage.total_tokens = delta`

So `total_tokens` can reflect context-window normalization behavior, not just a raw upstream token report.

For Symphony, `model_context_window` should be displayed or logged separately from spend.

## Current Symphony Accounting Strategy

Symphony tracks token totals in the active `Orchestrator` running entry and
publishes them through the terminal dashboard and observability presenter. The
state stores the latest reported input, output and total counters as
`codex_last_reported_*` values, then applies only the positive difference from
the next accepted report. That makes cumulative snapshots safe to replay and
prevents a smaller later report from reducing or double-counting totals.

For each active run, keep:

- `codex_last_reported_input_tokens`
- `codex_last_reported_output_tokens`
- `codex_last_reported_total_tokens`
- `accumulated_total`: the total you expose in UI/API
- `session_id`: combined Codex thread/turn identifier for display and log correlation

### Preferred source order

When a token-related event arrives, Symphony currently accepts these sources in
this order:

1. nested `TokenCountEvent.info.total_token_usage` in app-server
   `codex/event/token_count` payloads
2. `thread/tokenUsage/updated.tokenUsage.total`
3. top-level `tokenUsage.total`
4. explicit `turn/completed` `usage`, but only as a fallback completion snapshot

Ignore these for accounting:

- `thread/tokenUsage/updated.tokenUsage.last`
- `TokenCountEvent.info.last_token_usage`
- generic `usage` maps whose event type or payload path does not prove cumulative or completion semantics

Do not treat generic `params.usage` as equivalent to a cumulative thread total unless the event type makes that meaning explicit.

### Algorithm

#### If an absolute total is present

- Treat it as a thread-level snapshot.
- If it is greater than or equal to the stored `absolute_total`, replace the stored absolute total.
- Set exposed totals from that absolute snapshot.
- Do not add the corresponding delta again.

#### If no absolute total is present

- If the event is explicitly `turn/completed` and carries an integer-like
  `usage` map, treat that map as a completion snapshot.
- Otherwise ignore the event for accounting and keep the last accepted
  high-water mark unchanged.

### Why this matters

If you misclassify a per-turn `usage` payload as an absolute thread total, later turns can appear to stall because a smaller per-turn number is compared against a larger cumulative baseline.

## What Symphony Should And Should Not Do

### Do

- Accept `thread/tokenUsage/updated` for live reporting.
- Treat `tokenUsage.total` as authoritative for thread totals.
- Preserve the latest accepted counters in the running entry so repeated or
  out-of-order snapshots only add positive deltas.
- Carry `session_id` in dashboard/API/log surfaces for correlation.

### Do not

- Do not treat every `usage` map as absolute.
- Do not count `tokenUsage.last` or `last_token_usage` into dashboard totals.
- Do not add turn-completed `usage` on top of already-counted live thread totals; the monotonic delta calculation should only add missing spend.
- Do not reset accounting just because a new turn starts on the same thread.

## Practical Interpretation For Symphony Logs

When reading raw app-server events:

- `codex/event/token_count`
  - useful if you are inspecting nested `info.total_token_usage`
- `thread/tokenUsage/updated`
  - best source for live dashboard and API totals
- `turn/completed`
  - best used as end-of-turn state; Symphony can also use its explicit `usage`
    as a fallback completion snapshot

## Why `total_token_usage` Is The Durable Choice

Codex itself consistently prefers cumulative totals when it needs durable state:

- the state extractor stores `info.total_token_usage.total_tokens`
- the exec event processor caches the last `total_token_usage` and uses that on turn completion

That is a strong signal for Symphony:

- use absolute totals as the main accounting surface
- ignore last/delta values for totals

## Recommended Symphony Documentation Contract

If Symphony documents token reporting externally, the contract should be:

- Live token totals come from Codex thread-scoped cumulative usage.
- Incremental usage may also be emitted, but Symphony does not use it for totals.
- Turn-completed usage is event-specific. Symphony may use explicit
  `turn/completed` usage as a fallback snapshot, never as a fresh additive
  increment.
- Reporting exposes active-run totals with `session_id` correlation, and one
  Codex thread can span multiple turns.

## Implementation Checklist

- Accept `thread/tokenUsage/updated.tokenUsage.total` for live updates
- Accept nested `info.total_token_usage` from `codex/event/token_count`
- Fallback to explicit `turn/completed` `usage` only when no cumulative total was present
- Ignore `last` for totals
- Preserve accepted high-water counters in the running entry and across retries
  that resume the same Codex thread
- Key the retry high-water mark by the stable Codex `thread_id`, not by the
  combined thread/turn `session_id`
- Do not classify generic `usage` by field name alone
- Do not double-count turn-completed usage after live updates
