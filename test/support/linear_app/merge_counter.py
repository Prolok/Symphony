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
base = "c" * 40
ci_mode = os.environ.get("SYMPHONY_TEST_CI_MODE", "checks")
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
                      "baseRefName": "main", "baseRefOid": base,
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
    if args[1] == "graphql":
        print(json.dumps({"data": {"repository": {"ref": {"name": "main", "target": {"oid": base}, "branchProtectionRule": None}}}}))
        raise SystemExit(0)
    if any("rules/branches" in arg for arg in args):
        payload = [{"ruleset_id": 1, "type": "unknown"}] if ci_mode == "unknown_policy" else []
    elif any("check-runs" in arg for arg in args):
        runs = [] if ci_mode != "checks" else [{"id": 1, "head_sha": head, "app": {"id": 1}, "name": "CI", "status": "completed", "conclusion": "success"}]
        payload = {"total_count": len(runs), "check_runs": runs}
    elif any("check-suites" in arg for arg in args):
        payload = {"total_count": 0, "check_suites": []}
    elif any(arg.endswith("/status") for arg in args):
        sha = base if any(base in arg for arg in args) else head
        payload = {"sha": sha, "total_count": 0, "statuses": []}
    elif any("actions/workflows" in arg for arg in args):
        payload = {} if ci_mode == "incomplete" else {"total_count": 0, "workflows": []}
    elif any("git/trees" in arg for arg in args):
        payload = {"sha": "e" * 40, "truncated": False, "tree": []}
    else:
        payload = []
    print(json.dumps([payload] if "--slurp" in args else payload))
else:
    raise SystemExit("Unexpected controlled command")
