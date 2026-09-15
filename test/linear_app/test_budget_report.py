import importlib.util
import json
from pathlib import Path
import unittest
import copy
import hashlib
import tempfile


SPEC = importlib.util.spec_from_file_location(
    "budget_report", Path(__file__).resolve().parents[2] / "scripts/linear-budget-report.py"
)
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)


class BudgetReportTests(unittest.TestCase):
    def line(self, workspace, kind, headers):
        return "debug Linear request measurement=" + json.dumps(
            {"workspace_id": workspace, "kind": kind, "headers": headers, "requests": 1}
        )

    def test_counts_requests_and_complexity_samples_separately_without_secrets(self):
        result = REPORT.summarize([
            "unrelated log entry",
            self.line("one", "candidates", {"x-complexity": "17", "authorization": "secret"}),
            self.line("one", "candidates", {"x-ratelimit-requests-remaining": "100"}),
            self.line("two", "comments", {"x-complexity": "2.5"}),
        ])
        self.assertEqual(result["one/candidates"]["requests"], 2)
        self.assertEqual(result["one/candidates"]["complexity_samples"], 1)
        self.assertEqual(result["one/candidates"]["complexity"], 17)
        self.assertEqual(result["two/comments"]["complexity"], 2.5)
        self.assertNotIn("secret", json.dumps(result))

    def test_missing_or_malformed_measurements_do_not_become_zero_complexity(self):
        self.assertEqual(REPORT.summarize([]), {})
        for line in ["Linear request measurement={", self.line("w", "read", {"x-complexity": "bad"})]:
            with self.assertRaisesRegex(ValueError, "unvollständige Budgetmessung"):
                REPORT.summarize([line])

    def fixture(self, variant="baseline", evidence="fixture"):
        rows = [{"event": "start", "metadata": {
            "variant": variant, "evidence": evidence, "revision": REPORT.BASELINE,
            "source_sha256": "a" * 64, "instrumentation_sha256": "b" * 64,
            "workload_sha256": "c" * 64, "workspace_ids": ["one", "two"]}}]
        headers = {f"x-ratelimit-{family}-{suffix}": "100"
                   for family in ("requests", "endpoint-requests", "complexity")
                   for suffix in ("limit", "remaining", "reset")}
        headers["x-complexity"] = "3"
        for phase in REPORT.PHASES:
            rows.append({"event": "phase_start", "phase": phase, "duration_ms": 1000})
            for workspace in ("one", "two"):
                rows.append({"event": "request", "phase": phase, "transport": "linear",
                             "measurement": {"requests": 1}, "metadata": {
                                 "workspace_id": workspace, "kind": "read", "status": 200, "headers": headers.copy()}})
                if variant == "feature":
                    rows.append({"event": "request", "phase": phase, "transport": "relay",
                                 "measurement": {"requests": 1}, "metadata": {
                                     "workspace_id": workspace, "kind": "poll", "status": 200}})
            rows.append({"event": "phase_end", "phase": phase, "duration_ms": 1000})
        rows.append({"event": "finish", "attestation": {
            "all_app_processes_captured": True, "same_load_completed": True,
            "restore_verified": True, "external_app_traffic": "none"}})
        elapsed = 0
        for index, row in enumerate(rows):
            if row["event"] == "phase_end":
                elapsed += 1000
            row.update(sequence=index, elapsed_ms=elapsed, at="2026-09-15T07:00:00Z")
        return rows

    def captured(self, rows):
        return REPORT.capture(["Budget capture=" + json.dumps(row) for row in rows])

    def test_seven_phases_and_relay_headers_are_preserved_and_fixtures_never_pass(self):
        before, after = self.captured(self.fixture()), self.captured(self.fixture("feature"))
        result = REPORT.compare(before, after)
        self.assertFalse(result["evidence_complete"])
        self.assertEqual(before["gaps"], [])
        self.assertEqual(list(before["phases"]), REPORT.PHASES)
        self.assertEqual(after["groups"]["idle/relay/one/poll"]["requests"], 1)
        self.assertEqual(before["totals"]["idle"]["relay"]["one"], 0)
        group = before["groups"]["checkpoint/linear/two/read"]
        self.assertEqual(group["complexity"], 3)
        self.assertEqual(group["header_samples"][0]["headers"]["x-complexity"], "3")

    def test_missing_header_probe_or_restore_never_means_complete_evidence(self):
        baseline = self.captured(self.fixture(evidence="live"))
        for change in ("header", "restore", "probe"):
            rows = self.fixture("feature", "live")
            if change == "header":
                rows[2]["metadata"]["headers"].pop("x-complexity")
            elif change == "restore":
                rows[-1]["attestation"]["restore_verified"] = False
            else:
                for row in rows:
                    if row["event"] == "request" and row["phase"] == "idle" and row["transport"] == "relay":
                        row["metadata"]["kind"] = "register"
            after = self.captured(rows)
            self.assertTrue(after["gaps"])
            self.assertFalse(REPORT.compare(baseline, after)["evidence_complete"])

    def test_truncation_duplicates_wrong_baseline_and_mismatched_workload_fail(self):
        rows = self.fixture()
        for damaged in (rows[:-1], rows + [rows[-1]], []):
            with self.assertRaises(ValueError):
                self.captured(damaged)
        wrong = copy.deepcopy(rows)
        wrong[0]["metadata"]["revision"] = "wrong"
        with self.assertRaisesRegex(ValueError, "Baseline"):
            self.captured(wrong)
        before, after = self.captured(rows), self.captured(self.fixture("feature"))
        after["metadata"]["workload_sha256"] = "d" * 64
        with self.assertRaisesRegex(ValueError, "vergleichbarer"):
            REPORT.compare(before, after)

    def test_nonfinite_complexity_is_rejected(self):
        for value in ("NaN", "inf", "-1"):
            with self.assertRaises(ValueError):
                REPORT.summarize([self.line("one", "read", {"x-complexity": value})])

    def test_mismatched_window_and_truncated_phase_fail(self):
        rows = self.fixture()
        rows[4]["elapsed_ms"] = 999
        with self.assertRaisesRegex(ValueError, "Messdauer"):
            self.captured(rows)
        rows = self.fixture()
        rows[-2]["event"] = "finish"
        with self.assertRaises(ValueError):
            self.captured(rows)

    def test_live_evidence_completeness_is_only_a_review_prerequisite(self):
        result = REPORT.compare(self.captured(self.fixture(evidence="live")),
                                self.captured(self.fixture("feature", "live")))
        self.assertTrue(result["evidence_complete"])
        self.assertEqual(result["acceptance"], "requires_operator_evidence_review")

    def test_launcher_shutdown_needs_post_restore_attestation_bound_to_capture(self):
        rows = self.fixture("feature", "live")
        rows[-1].update(attestation={}, shutdown="application_stopped", recorder_intact=True)
        self.assertTrue(self.captured(rows)["gaps"])
        attestation = self.fixture()[-1]["attestation"]
        lines = ["Budget capture=" + json.dumps(row) for row in rows]
        self.assertEqual(REPORT.capture(lines, attestation)["gaps"], [])
        for field, value in (("shutdown", "startup_error"), ("recorder_intact", False)):
            damaged = copy.deepcopy(rows)
            damaged[-1][field] = value
            result = REPORT.capture(["Budget capture=" + json.dumps(row) for row in damaged], attestation)
            self.assertTrue(result["gaps"])
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[2] / "_build") as directory:
            capture = Path(directory) / "capture.jsonl"
            capture.write_text("\n".join(lines))
            public = Path(directory) / "attestation.json"
            attestation["capture_sha256"] = hashlib.sha256(capture.read_bytes()).hexdigest()
            public.write_text(json.dumps(attestation))
            self.assertEqual(REPORT.read_attestation(public, capture), attestation)
            capture.write_text(capture.read_text() + "\n")
            with self.assertRaisesRegex(ValueError, "gehört nicht"):
                REPORT.read_attestation(public, capture)
