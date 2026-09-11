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
    with store.state_lock("symphony-issue-lease", identity, timeout=request.get("timeout_ms", 0) / 1000):
        print("locked", flush=True)
        sys.stdin.read()
except store.StateLockError as error:
    print("busy" if str(error) == "binding_busy" else "unavailable", flush=True)
except Exception:
    print("unavailable", flush=True)
