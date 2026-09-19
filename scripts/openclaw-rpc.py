#!/usr/bin/env python3
"""Private bounded CLI transport. No installation, gateway start or local fallback."""
import json
import os
import shutil
import subprocess
import sys


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
        return 1
    sys.stdout.buffer.write(result.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
