import asyncio
import importlib.util
import io
import os
from pathlib import Path
import sys
import unittest
from contextlib import redirect_stdout
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("land_app_gate", REPO / ".codex/skills/symphony-land/land_watch.py")
land = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = land
SPEC.loader.exec_module(land)


class AppLabelGateTest(unittest.IsolatedAsyncioTestCase):
    async def test_addressed_commented_review_summary_does_not_require_new_reviewer_action(self):
        review = {"id": 17, "state": "COMMENTED", "body": "Bitte Fehlerpfad prüfen",
                  "submitted_at": "2026-09-12T10:00:00Z", "user": {"login": "human"}}
        reply = {"body": "[codex] Fehlerpfad korrigiert und validiert.",
                 "created_at": "2026-09-12T11:00:00Z", "user": {"login": "author"}}
        with self.assertRaises(SystemExit):
            land.raise_on_human_feedback([], [], [review], None)
        land.raise_on_human_feedback([reply], [], [review], None)
        for changed in [dict(review, state="CHANGES_REQUESTED"),
                        dict(review, submitted_at="2026-09-12T12:00:00Z")]:
            with self.assertRaises(SystemExit):
                land.raise_on_human_feedback([reply], [], [changed], None)
        earlier_request = dict(review, state="CHANGES_REQUESTED", submitted_at="2026-09-12T09:00:00Z")
        with self.assertRaises(SystemExit):
            land.raise_on_human_feedback([reply], [], [earlier_request, review], None)
        later_approval = dict(review, state="APPROVED", submitted_at="2026-09-12T12:00:00Z")
        land.raise_on_human_feedback([reply], [], [earlier_request, review, later_approval], None)

    async def test_app_watch_hands_live_label_gate_to_the_bound_tool_without_claiming_completion(self):
        pr = land.PrInfo(1, "https://example.invalid/pull/1", "a" * 40, "MERGEABLE", "CLEAN")
        evidence = land.MergePreflightEvidence("symphony/PRO-1", pr.head_sha, True, pr)
        env = {"SYMPHONY_LINEAR_AUTH_MODE": "app", "SYMPHONY_LINEAR_SECRET_ACCESS": "denied", "SYMPHONY_ISSUE_IDENTIFIER": "PRO-1"}
        output = io.StringIO()
        with mock.patch.dict(os.environ, env), redirect_stdout(output), \
             mock.patch.object(land, "require_merge_preflight", mock.AsyncMock(return_value=evidence)), \
             mock.patch.object(land, "get_pr_info", mock.AsyncMock(return_value=pr)), \
             mock.patch.object(land, "wait_for_codex", mock.AsyncMock()), \
             mock.patch.object(land, "wait_for_checks", mock.AsyncMock()), \
             mock.patch.object(asyncio, "create_subprocess_exec", mock.AsyncMock(side_effect=AssertionError("forbidden child"))) as refresh:
            with self.assertRaises(SystemExit) as result:
                await land.watch_pr()
            self.assertEqual(result.exception.code, 8)
            refresh.assert_not_called()
        self.assertIn(pr.head_sha, output.getvalue())
        self.assertIn("Merge gate incomplete", output.getvalue())
        self.assertIn("PRO-1", output.getvalue())

    async def test_app_refresh_never_starts_a_mix_child_or_accepts_the_dispatch_snapshot(self):
        with mock.patch.dict(os.environ, {"SYMPHONY_LINEAR_AUTH_MODE": "app", "SYMPHONY_ISSUE_IDENTIFIER": "PRO-1"}), \
             mock.patch.object(asyncio, "create_subprocess_exec", mock.AsyncMock(side_effect=AssertionError("forbidden child"))) as child:
            for call in (land.current_issue_labels([]), land.current_issue_labels(["backend"])):
                with self.assertRaisesRegex(land.LabelRefreshError, "bound Linear tool"):
                    await call
            child.assert_not_called()

    async def test_missing_app_issue_identity_does_not_fall_back_to_snapshot(self):
        with mock.patch.dict(os.environ, {"SYMPHONY_LINEAR_AUTH_MODE": "app", "SYMPHONY_ISSUE_IDENTIFIER": ""}):
            with self.assertRaises(land.LabelRefreshError):
                await land.current_issue_labels([])
