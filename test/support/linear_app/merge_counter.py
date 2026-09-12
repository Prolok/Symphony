#!/usr/bin/env python3
"""Controlled Git/GitHub command endpoints; never makes a network request."""
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
marker = Path(os.environ["SYMPHONY_TEST_MERGE_COUNTER"])
head = "a" * 40
if Path(sys.argv[0]).name == "git":
    if args[:2] == ["rev-parse", "HEAD"]:
        print(head)
    elif args and args[0] == "ls-remote":
        print(head + "\trefs/heads/symphony/PRO-1")
    elif args and args[0] == "status":
        pass
    else:
        print("symphony/PRO-1")
elif args[:2] == ["pr", "view"]:
    print(json.dumps({"number": 1, "url": "https://example.invalid/pull/1", "headRefOid": head,
                      "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "author": {"login": "author"},
                      "state": "MERGED" if marker.exists() else "OPEN", "mergeCommit": {"oid": "b" * 40}}))
elif args[:2] == ["pr", "merge"]:
    with marker.open("a") as output:
        output.write(json.dumps(args) + "\n")
elif args and args[0] == "api":
    if any("check-runs" in arg for arg in args):
        print(json.dumps({"total_count": 1, "check_runs": [{"name": "CI", "status": "completed", "conclusion": "success"}]}))
    else:
        print("[]")
else:
    raise SystemExit("Unexpected controlled command")
