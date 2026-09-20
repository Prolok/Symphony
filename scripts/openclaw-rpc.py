#!/usr/bin/env python3
"""Private bounded CLI transport. No installation, gateway start or local fallback."""
import json
import hashlib
import os
import shutil
import subprocess
import sys


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


def main():
    if os.environ.get("SYMPHONY_OPENCLAW_TEST_DENY") == "1":
        return 126
    binary = shutil.which("openclaw")
    if binary is None:
        return 127
    args = json.loads(sys.stdin.readline())
    try:
        result = subprocess.run([binary, *args], capture_output=True, timeout=12, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return 1
    # Errors may contain config/credential diagnostics: never return raw stderr.
    if result.returncode:
        proof = rejection(args, result)
        if proof is not None:
            print(json.dumps(proof))
            return 0
        return 1
    sys.stdout.buffer.write(result.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
