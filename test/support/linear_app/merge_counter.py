#!/usr/bin/env python3
"""Controlled Git/GitHub command endpoints; never makes a network request."""
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
expected_env = os.environ.get("SYMPHONY_TEST_EXPECT_GIT_ENV")
if expected_env and args[:2] != ["rev-parse", "--path-format=absolute"]:
    assert os.environ.get("GH_CONFIG_DIR") == expected_env, "missing project GitHub context"
    assert os.environ.get("GIT_SSH_COMMAND") == "ssh -F " + expected_env, "missing project Git context"
    assert "LINEAR_APP_SECRET" not in os.environ, "Linear secret forwarded"
marker = Path(os.environ["SYMPHONY_TEST_MERGE_COUNTER"])
head = "a" * 40
if Path(sys.argv[0]).name == "gh":
    assert os.environ.get("GH_REPO") == "https://example.invalid/project.git", "wrong project repository"
if Path(sys.argv[0]).name == "git":
    if args[:2] == ["rev-parse", "HEAD"]:
        print(head)
    elif args and args[0] == "ls-remote":
        print(head + "\trefs/heads/symphony/PRO-1")
    elif args and args[0] == "status":
        pass
    elif args == ["remote", "get-url", "origin"]:
        print("https://example.invalid/project.git")
    else:
        print("symphony/PRO-1")
elif args[:2] == ["pr", "view"]:
    print(json.dumps({"number": 1, "url": "https://example.invalid/pull/1", "headRefOid": head,
                      "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "author": {"login": "author"},
                      "state": "MERGED" if marker.exists() else "OPEN", "mergeCommit": {"oid": "b" * 40}}))
elif args[:2] == ["pr", "merge"]:
    rate_limit_once = os.environ.get("SYMPHONY_TEST_MERGE_LIMIT_ONCE")
    if rate_limit_once and not Path(rate_limit_once).exists():
        Path(rate_limit_once).write_text("limited")
        print("HTTP 429 rate limit", file=sys.stderr)
        raise SystemExit(1)
    with marker.open("a") as output:
        output.write(json.dumps(args) + "\n")
elif args and args[0] == "api":
    if any("check-runs" in arg for arg in args):
        print(json.dumps({"total_count": 1, "check_runs": [{"name": "CI", "status": "completed", "conclusion": "success"}]}))
    else:
        print("[]")
else:
    raise SystemExit("Unexpected controlled command")
