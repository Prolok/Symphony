"""Validate live interruption evidence; no transport or authority of its own."""


def active_original(active, run_id):
    digest = active.get("observerDigest")
    digest_matches = isinstance(digest, dict) and digest.get("runId") == run_id
    controller = active.get("lastRunId") == run_id and active.get("activeRunIds") == [run_id]
    embedded = active.get("status") == "running" and digest_matches
    return (
        active.get("hasActiveRun") is True and active.get("status", "running") == "running"
        and (controller or embedded)
        and active.get("lastRunId", run_id) == run_id
        and active.get("activeRunIds", [run_id]) == [run_id]
        and (digest is None or digest_matches)
    )


def verify(proof, fixtures, source, run_id, agent):
    before = proof["before"]
    original = proof["original"]
    current = proof["current"]
    first = proof["first_id"]
    members = {f["id"] for f in fixtures if f.get("po_incoming")}
    remaining = members - {first}
    active = proof["active"]
    retirement = original["retirement"]
    completed = proof["attempt"]["completed"]
    successor = proof["current_attempt"]
    binding = ("id", "group", "project_id", "agent", "session_id", "payload_sha256", "workspace", "sha", "members", "checkout_proof")
    if not (
        proof["source"] == source and proof["run_id"] == run_id
        and len(members) == 3 and len(remaining) == 2
        and before["group"] == current["group"] == "incoming"
        and before["agent"] == current["agent"] == agent
        and before["project_id"] == current["project_id"]
        and before["interruption_contract"] == current["interruption_contract"] == 1
        and before["acceptance_observed"] is True and before["writable"] is True
        and active["key"] == before["session_id"] and active["sessionId"]
        and active_original(active, before["id"]) and proof["active_checked_at"]
        and all(before[k] == original[k] for k in binding)
        and original["state"] == "retired" and original["writable"] is False
        and original["abort_acknowledged"] is True
        and (original.get("terminal") is None or original["terminal"]["runId"] == before["id"])
        and retirement["kind"] == "fenced_interruption" and retirement["retired_at"]
        and retirement["physical_session_id"] == active["sessionId"]
        and retirement["history_sha256"] and isinstance(retirement["retained_inputs"], list)
        and retirement["attempt"] == proof["attempt"]
        and proof["attempt"]["id"] == before["id"] and set(completed) == {first}
        and isinstance(completed[first], str) and completed[first].strip()
        and {m["id"] for m in before["members"]} == members
        and current["id"] != before["id"] and current["session_id"] != before["session_id"]
        and sorted(proof["generation_ids"]) == sorted([before["id"], current["id"]])
        and current["state"] == "completed" and current["writable"] is False
        and {m["id"] for m in current["members"]} == remaining
        and successor["id"] == current["id"] and set(successor["members"]) == remaining
        and set(successor["completed"]) == remaining
        and all(isinstance(v, str) and v.strip() for v in successor["completed"].values())
    ):
        raise ValueError("interruption_chain_unconfirmed")
    # Keep the first decision attached to the retired generation. Only the two
    # unfinished members may supply successful execution receipts for the new one.
    for fixture in fixtures:
        if fixture.get("po_incoming"):
            receipt = fixture["po_receipt"]
            expected = original if fixture["id"] == first else current
            checkout = expected["checkout_proof"]
            if not (fixture["complete"] is True and fixture["observed_state"] == "Verworfen"
                    and (fixture["initial_state"] == "Backlog") == (fixture["id"] == first)
                    and all(receipt[k] == expected[k] for k in ("session_id", "sha", "workspace"))
                    and all(checkout[k] == expected[k] for k in ("id", "project_id", "session_id", "workspace", "sha", "payload_sha256"))
                    and checkout["clean"] is True and checkout["cwd"] == checkout["git_root"] == expected["workspace"]
                    and (fixture["id"] == first or receipt["openclaw"]["id"] == current["id"])):
                raise ValueError("interruption_decision_unconfirmed")
    return [f for f in fixtures if f["id"] != first]
