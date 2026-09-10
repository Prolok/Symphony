"""Hold a host-local workspace/issue lease until the owner's pipe closes."""
import importlib.util
import json
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("state_lock", Path(__file__).with_name("state_lock.py"))
store = importlib.util.module_from_spec(spec)
spec.loader.exec_module(store)

try:
    request = json.loads(sys.stdin.readline())
    identity = json.dumps([request["workspace_id"], request["issue_id"]])
    with store.state_lock("symphony-issue-lease", identity, timeout=0):
        print("locked", flush=True)
        sys.stdin.read()
except Exception:
    print("unavailable", flush=True)
