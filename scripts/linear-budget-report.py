#!/usr/bin/env python3
"""Aggregate opted-in, header-based Linear measurements without reading credentials."""
import argparse
import collections
import json
import math
import re
import hashlib
from pathlib import Path

BASELINE = "65927695ab49a2113121632177267c44bfb5a768"
PHASES = ["cold_start", "idle", "active", "burst", "reconcile", "outage", "checkpoint"]
HEADER = re.compile(r"x-(?:complexity|rate-?limit-(?:(?:requests|endpoint-requests|complexity)-)?(?:limit|remaining|reset))\Z")


def safe_headers(headers):
    result = {}
    for key, value in headers.items():
        if HEADER.fullmatch(key):
            number = float(value)
            if not math.isfinite(number) or number < 0:
                raise ValueError("invalid numeric header")
            result[key] = value
    return result


def summarize(lines):
    groups = collections.defaultdict(lambda: {"requests": 0, "complexity": 0.0, "complexity_samples": 0, "headers_last": {}})
    for line in lines:
        marker = "Linear request measurement="
        if marker not in line:
            continue
        try:
            record = json.loads(line.split(marker, 1)[1])
            key = str(record["workspace_id"]) + "/" + str(record["kind"])
            if record["requests"] != 1:
                raise ValueError("invalid request counter")
            group = groups[key]
            group["requests"] += 1
            headers = safe_headers(record["headers"])
            group["headers_last"] = headers
            if "x-complexity" in headers:
                group["complexity"] += float(headers["x-complexity"])
                group["complexity_samples"] += 1
        except (KeyError, ValueError, TypeError) as error:
            raise ValueError("unvollständige Budgetmessung") from error
    return dict(groups)


def capture(lines, operator_attestation=None):
    """Validate one bounded capture, retaining every observed header sample."""
    records = [json.loads(line.split("Budget capture=", 1)[1])
               for line in lines if "Budget capture=" in line]
    if not records or records[0].get("event") != "start" or records[-1].get("event") != "finish":
        raise ValueError("unvollständiger Capture: Start/Finish fehlt")
    if [r.get("sequence") for r in records] != list(range(len(records))):
        raise ValueError("unvollständiger Capture: Sequenzlücke/Duplikat")
    if any(sum(row.get("event") == event for row in records) != 1 for event in ("start", "finish")):
        raise ValueError("mehrdeutiger Capture: Start/Finish")
    meta = records[0]["metadata"]
    if meta["variant"] not in ("baseline", "feature") or meta["evidence"] not in ("live", "fixture"):
        raise ValueError("ungültige Herkunft")
    if meta["variant"] == "baseline" and meta["revision"] != BASELINE:
        raise ValueError("falscher PRO-715-Baseline-Commit")
    for field in ("source_sha256", "instrumentation_sha256", "workload_sha256"):
        if not re.fullmatch(r"[a-f0-9]{64}", meta[field]):
            raise ValueError("fehlender fester Quellen-/Laststand")
    workspaces = meta["workspace_ids"]
    if not workspaces or len(set(workspaces)) != len(workspaces):
        raise ValueError("Workspace-Liste fehlt/mehrdeutig")
    phases, groups, gaps = {}, {}, []
    totals = {phase: {transport: {workspace: 0 for workspace in workspaces} for transport in ("linear", "relay")}
              for phase in ["setup"] + PHASES}
    current = "setup"
    last_elapsed = -1
    for row in records:
        elapsed = row["elapsed_ms"]
        if elapsed < last_elapsed:
            raise ValueError("nicht monotone Messzeit")
        last_elapsed = elapsed
        event = row["event"]
        if event == "phase_start":
            name = row["phase"]
            if current != "setup" or len(phases) >= len(PHASES) or name != PHASES[len(phases)] or row["duration_ms"] <= 0:
                raise ValueError("falsche Phasenfolge")
            current = name
            phases[name] = {"duration_ms": row["duration_ms"], "start_ms": elapsed}
        elif event == "phase_end":
            if current == "setup" or row["phase"] != current:
                raise ValueError("Phasenende ohne Anfang")
            phase = phases[current]
            actual = elapsed - phase["start_ms"]
            if row["duration_ms"] != phase["duration_ms"] or not phase["duration_ms"] <= actual <= phase["duration_ms"] + 1000:
                raise ValueError("abweichende Messdauer")
            phase["actual_ms"] = actual
            current = "setup"
        elif event == "request":
            detail = row["metadata"]
            if row["phase"] != current or detail["workspace_id"] not in workspaces:
                raise ValueError("fremde Workspace-/Phasenbindung")
            transport = row["transport"]
            if transport not in ("linear", "relay") or row["measurement"]["requests"] != 1:
                raise ValueError("ungültiger HTTP-Zähler")
            key = "/".join([current, transport, detail["workspace_id"], detail["kind"]])
            group = groups.setdefault(key, {"requests": 0, "complexity": 0.0, "complexity_samples": 0,
                                            "statuses": {}, "header_samples": []})
            group["requests"] += 1
            totals[current][transport][detail["workspace_id"]] += 1
            status = str(detail["status"])
            group["statuses"][status] = group["statuses"].get(status, 0) + 1
            headers = safe_headers(detail.get("headers", {}))
            group["header_samples"].append({"elapsed_ms": elapsed, "headers": headers})
            if "x-complexity" in headers:
                group["complexity"] += float(headers["x-complexity"])
                group["complexity_samples"] += 1
            if transport == "linear" and detail["kind"] != "token":
                canonical = {k.replace("x-rate-limit-", "x-ratelimit-") for k in headers}
                expected = {f"x-ratelimit-{family}-{suffix}" for family in ("requests", "endpoint-requests", "complexity")
                            for suffix in ("limit", "remaining", "reset")} | {"x-complexity"}
                if expected - canonical:
                    gaps.append({"sequence": row["sequence"], "missing_headers": sorted(expected - canonical)})
        elif event not in ("start", "finish"):
            raise ValueError("unbekannter Capture-Datensatz")
    if list(phases) != PHASES or current != "setup":
        raise ValueError("unvollständige sieben Messphasen")
    attestation = operator_attestation if operator_attestation is not None else records[-1]["attestation"]
    if "shutdown" in records[-1]:
        if records[-1]["shutdown"] not in ("application_stopped", "supervisor_down"):
            gaps.append({"shutdown": records[-1]["shutdown"]})
        if records[-1].get("recorder_intact") is not True:
            gaps.append({"recorder_intact": False})
    for field in ("all_app_processes_captured", "same_load_completed", "restore_verified"):
        if attestation.get(field) is not True:
            gaps.append({"missing_attestation": field})
    if not attestation.get("external_app_traffic"):
        gaps.append({"missing_attestation": "external_app_traffic"})
    for workspace in workspaces:
        for phase in ("cold_start", "checkpoint"):
            if not any(key.startswith(f"{phase}/linear/{workspace}/") for key in groups):
                gaps.append({"missing_probe": f"{phase}/linear/{workspace}"})
        if meta["variant"] == "feature" and f"idle/relay/{workspace}/poll" not in groups:
            gaps.append({"missing_probe": f"idle/relay/{workspace}/poll"})
    return {"metadata": meta, "phases": phases, "groups": groups, "totals": totals, "gaps": gaps,
            "attestation": attestation, "started_at": records[0]["at"], "finished_at": records[-1]["at"]}


def compare(before, after):
    if before["metadata"]["variant"] != "baseline" or after["metadata"]["variant"] != "feature":
        raise ValueError("Baseline und Feature vertauscht")
    for field in ("workspace_ids", "workload_sha256", "instrumentation_sha256", "evidence"):
        if before["metadata"][field] != after["metadata"][field]:
            raise ValueError("nicht vergleichbarer Lauf: " + field)
    if any(before["phases"][p]["duration_ms"] != after["phases"][p]["duration_ms"] for p in PHASES):
        raise ValueError("nicht vergleichbare Messdauer")
    return {"schema": 1, "evidence": before["metadata"]["evidence"],
            "evidence_complete": before["metadata"]["evidence"] == "live" and not before["gaps"] and not after["gaps"],
            "acceptance": "requires_operator_evidence_review", "baseline": before, "feature": after}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--compare", type=Path, help="compare baseline capture with feature capture")
    parser.add_argument("--baseline-attestation", type=Path, help="public, hash-bound operator evidence after restore")
    parser.add_argument("--feature-attestation", type=Path, help="public, hash-bound operator evidence after restore")
    args = parser.parse_args()
    with args.log.open(encoding="utf-8") as source:
        if args.compare:
            before = capture(source, read_attestation(args.baseline_attestation, args.log))
            with args.compare.open(encoding="utf-8") as after:
                result = compare(before, capture(after, read_attestation(args.feature_attestation, args.compare)))
        else:
            result = summarize(source)
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    if args.compare and not result["evidence_complete"]:
        raise SystemExit(2)


def read_attestation(path, capture_path):
    if path is None:
        return None
    result = json.loads(path.read_text(encoding="utf-8"))
    if result.get("capture_sha256") != hashlib.sha256(capture_path.read_bytes()).hexdigest():
        raise ValueError("Betreiberbeleg gehört nicht zu diesem Capture")
    return result


if __name__ == "__main__":
    main()
