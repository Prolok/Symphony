OpenClaw 2026.9.4, commit `3a9d69db306cd7f081e06254cb89c4bcc14a7107`, MIT (LICENSE).

`agent-request-preflight.ts`: unchanged upstream `src/gateway/agent-turn/agent-request-preflight.ts`, SHA256 `64d6f0a61befd62a40921d602129b113524c7308285c34db588654e80ff38c28`. `preflight.cjs` executes its cwd checks with an external CLI principal. This is a boundary regression, not a complete gateway/live run.

`request-error.txt`: unchanged `formatGatewayClientRequestErrorJson` from `src/gateway/call.ts` at the same commit. `src/cli/gateway-cli/register.ts:94-120` writes this object to stdout and exits 1 in JSON mode. Text/stderr-only errors do not provide this typed provenance and remain unknown.
