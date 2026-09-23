#!/usr/bin/env python3
"""Private bounded CLI transport. No installation, gateway start or local fallback."""
import json
import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path


def rejection(args, result):
    """Only a typed first-response error from the pinned CLI is non-acceptance.

    No stderr parsing, substring matching, generic INVALID_REQUEST inference or
    final-response mode. The caller binds the normalized result to these params.
    """
    if (result.returncode != 1 or args[:4] != ["gateway", "call", "agent", "--params"]
            or "--json" not in args or "--expect-final" in args or len(result.stdout) > 16384):
        return None
    try:
        reply = json.loads(result.stdout)
        error = reply["error"]
        params = json.loads(args[4])
        reasons = {"cwd is reserved for plugin-owned subagent runs": "cwd_reserved",
                   "cwd must be absolute": "cwd_not_absolute"}
        if (reply.get("ok") is not False or error.get("type") != "gateway_request_error"
                or error.get("code") != "INVALID_REQUEST" or error.get("message") not in reasons
                or error.get("retryable") is not False
                or not all(isinstance(params.get(k), str) and params[k] for k in
                           ("idempotencyKey", "sessionKey", "agentId"))):
            return None
        return {"symphony_openclaw_rejection": 1, "method": "agent", "phase": "pre_acceptance",
                "code": "INVALID_REQUEST", "reason": reasons[error["message"]],
                "request_sha256": hashlib.sha256(args[4].encode()).hexdigest()}
    except (ValueError, KeyError, TypeError, AttributeError):
        return None


def abort_failure(args, result):
    """Preserve only typed, bounded abort errors, bound to the exact request."""
    if (result.returncode != 1 or args[:4] != ["gateway", "call", "sessions.abort", "--params"]
            or "--json" not in args or len(result.stdout) > 16384):
        return None
    try:
        reply = json.loads(result.stdout)
        error = reply["error"]
        params = json.loads(args[4])
        if (reply.get("ok") is not False or error.get("type") != "gateway_request_error"
                or type(error.get("retryable")) is not bool
                or error.get("code") not in {"INVALID_REQUEST", "UNAVAILABLE", "NOT_LINKED", "OTHER"}
                or not all(isinstance(params.get(k), str) and params[k] for k in ("key", "runId"))):
            return None
        return {"symphony_openclaw_abort_error": 1, "method": "sessions.abort",
                "code": error["code"], "retryable": error["retryable"],
                "reason": "unauthorized" if error.get("message") == "unauthorized" else "request_rejected",
                "request_sha256": hashlib.sha256(args[4].encode()).hexdigest()}
    except (ValueError, KeyError, TypeError, AttributeError):
        return None


def main():
    if os.environ.get("SYMPHONY_OPENCLAW_TEST_DENY") == "1":
        return 126
    binary = shutil.which("openclaw")
    if binary is None:
        return 127
    args = json.loads(sys.stdin.readline())
    owner_rpc = args[:2] == ["gateway", "call"] and len(args) > 2 and args[2] in {"agents.list", "agent", "sessions.abort"}
    try:
        if owner_rpc:
            node = shutil.which("node")
            if node is None:
                return 127
            command = [node, str(Path(__file__).with_name("openclaw-owner-rpc.mjs")), binary]
            result = subprocess.run(command, input=json.dumps(args).encode() + b"\n",
                                    capture_output=True, timeout=12, check=False)
        else:
            result = subprocess.run([binary, *args], capture_output=True, timeout=12, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return 1
    # Errors may contain config/credential diagnostics: never return raw stderr.
    if result.returncode:
        if owner_rpc and result.returncode == 125:
            return 125
        proof = rejection(args, result) or abort_failure(args, result)
        if proof is not None:
            print(json.dumps(proof))
            return 0
        return 1
    sys.stdout.buffer.write(result.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
