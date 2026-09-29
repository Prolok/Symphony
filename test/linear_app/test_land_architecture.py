import asyncio
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("land_architecture", REPO / ".codex/skills/symphony-land/land_watch.py")
land = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = land
SPEC.loader.exec_module(land)


class ArchitectureGateTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.old_cwd = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, self.old_cwd)
        self.git("init", "-q")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")

    def git(self, *args):
        return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "test")
        return self.git("rev-parse", "HEAD")

    def write(self, path, content):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content)

    def contract(self, command=None):
        return json.dumps({"command": command or [sys.executable, "-c", "print('ok')"],
                           "timeout_seconds": 1, "architecture_paths": ["docs/architecture/**", "rules/**"]})

    def pr(self, base, head):
        return land.PrInfo(1, "https://example.invalid/pull/1", head, "MERGEABLE", "CLEAN",
                           base_branch="main", base_sha=base)

    async def gate(self, pr, body=""):
        with mock.patch.object(land, "run_gh", mock.AsyncMock(return_value=json.dumps({"body": body}))):
            return await land.architecture_gate(pr)

    async def test_absent_contract_preserves_merge_path_without_github_or_command(self):
        self.write("app.txt", "base")
        base = self.commit()
        self.write("app.txt", "head")
        head = self.commit()
        with mock.patch.object(land, "run_gh", mock.AsyncMock(side_effect=AssertionError("no new gate"))):
            self.assertIsNone(await land.architecture_gate(self.pr(base, head)))

    async def test_unfetched_origin_base_is_loaded_before_contract_is_decided(self):
        self.write("app.txt", "old base")
        old_base = self.commit()
        self.git("branch", "-M", "main")
        origin_dir = tempfile.TemporaryDirectory()
        self.addCleanup(origin_dir.cleanup)
        origin = Path(origin_dir.name) / "origin.git"
        subprocess.run(["git", "init", "--bare", "-q", str(origin)], check=True)
        self.git("remote", "add", "origin", str(origin))
        self.git("push", "-q", "origin", "main")
        worker = Path(origin_dir.name) / "worker"
        subprocess.run(["git", "clone", "-q", "-b", "main", str(origin), str(worker)], check=True)
        subprocess.run(["git", "-C", str(worker), "config", "user.name", "Test"], check=True)
        subprocess.run(["git", "-C", str(worker), "config", "user.email", "test@example.invalid"], check=True)
        (worker / "app.txt").write_text("worker change")
        subprocess.run(["git", "-C", str(worker), "add", "app.txt"], check=True)
        subprocess.run(["git", "-C", str(worker), "commit", "-qm", "worker"], check=True)
        head = subprocess.check_output(["git", "-C", str(worker), "rev-parse", "HEAD"], text=True).strip()

        self.write("app.txt", "new base")
        new_base = self.commit()
        self.git("push", "-q", "origin", "main")
        os.chdir(worker)
        try:
            origin.rename(Path(origin_dir.name) / "offline.git")
            with self.assertRaises(land.ArchitectureError) as error:
                await self.gate(self.pr(new_base, head))
            self.assertEqual(error.exception.reason, "architecture_base_unavailable")
            (Path(origin_dir.name) / "offline.git").rename(origin)
            original_run_git = land.run_git

            async def timed_out_fetch(*args, **kwargs):
                if args[0] == "fetch":
                    raise TimeoutError("simulated fetch timeout")
                return await original_run_git(*args, **kwargs)

            with mock.patch.object(land, "run_git", timed_out_fetch):
                with self.assertRaises(land.ArchitectureError) as error:
                    await self.gate(self.pr(new_base, head))
            self.assertEqual(error.exception.reason, "architecture_base_unavailable")
            self.assertIsNone(await self.gate(self.pr(new_base, head)))
            self.assertEqual(subprocess.run(["git", "cat-file", "-e", f"{new_base}^{{tree}}"],
                                            capture_output=True).returncode, 0)
        finally:
            os.chdir(self.root)

        self.write(land.ARCHITECTURE_CONTRACT, self.contract())
        contract_base = self.commit()
        self.git("push", "-q", "origin", "main")
        os.chdir(worker)
        try:
            with self.assertRaises(land.ArchitectureError) as error:
                await self.gate(self.pr(contract_base, head))
            self.assertEqual(error.exception.reason, "architecture_candidate_stale")
            self.assertEqual(subprocess.run(["git", "cat-file", "-e", f"{contract_base}^{{tree}}"],
                                            capture_output=True).returncode, 0)
        finally:
            os.chdir(self.root)

    async def test_markdown_justification_variants_and_missing_fields(self):
        self.write(land.ARCHITECTURE_CONTRACT, self.contract())
        base = self.commit()
        self.write("rules/check.txt", "new rule")
        head = self.commit()
        fields = ("Änderung: neue Regel", "Grund: Ticketvorgabe", "Alternativen: keine")
        for prefix, suffix in (("- ", ""), ("**", "**"), ("- **", "**")):
            with self.subTest(prefix=prefix):
                body = "## Architekturänderung\n" + "\n".join(prefix + field.replace(":", ":" + suffix, 1) for field in fields)
                self.assertIsNotNone(await self.gate(self.pr(base, head), body))
        with self.assertRaises(land.ArchitectureError) as error:
            await self.gate(self.pr(base, head), "## Architekturänderung\n- **Änderung:** neue Regel\n- **Grund:** Ticket")
        self.assertEqual(error.exception.reason, "architecture_change_unjustified")
        self.assertIn("Alternativen:", str(error.exception))

    async def test_contract_timeout_ceiling_fits_bound_merge_budget(self):
        self.write(land.ARCHITECTURE_CONTRACT, self.contract())
        base = self.commit()
        contract = json.loads(self.contract())
        contract["timeout_seconds"] = 121
        self.write(land.ARCHITECTURE_CONTRACT, json.dumps(contract))
        head = self.commit()
        with self.assertRaises(land.ArchitectureError) as error:
            await self.gate(self.pr(base, head))
        self.assertEqual(error.exception.reason, "architecture_contract_invalid")

    async def test_fetch_timeout_is_bounded(self):
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        fake_git = fake_bin / "git"
        fake_git.write_text("#!/bin/sh\nsleep 10\n")
        fake_git.chmod(0o755)
        with mock.patch.dict(os.environ, {"PATH": f"{fake_bin}:{os.environ['PATH']}"}):
            with self.assertRaisesRegex(TimeoutError, "timed out"):
                await land.run_git("fetch", "origin", "main", timeout_seconds=0.05)

    async def test_bound_merge_runs_architecture_command_once_for_unchanged_pr(self):
        with tempfile.TemporaryDirectory() as counter_dir:
            counter = Path(counter_dir) / "count"
            script = ("from pathlib import Path; p=Path(%r); "
                      "p.write_text(p.read_text()+'x' if p.exists() else 'x')") % str(counter)
            self.write(land.ARCHITECTURE_CONTRACT, self.contract([sys.executable, "-c", script]))
            base = self.commit()
            self.write("app.txt", "candidate")
            head = self.commit()
            self.git("branch", "-M", "symphony/PRO-1")
            origin = Path(counter_dir) / "origin.git"
            subprocess.run(["git", "init", "--bare", "-q", str(origin)], check=True)
            self.git("remote", "add", "origin", str(origin))
            self.git("push", "-q", "origin", "symphony/PRO-1")
            pr = self.pr(base, head)
            evidence = land.MergePreflightEvidence("symphony/PRO-1", head, True, pr)
            summary = land.CheckSummary(False, False, [], {}, no_ci=True)

            async def gh(*args):
                if args[:2] == ("pr", "view") and "body" in args[-1]:
                    return json.dumps({"body": ""})
                if args[:2] == ("pr", "view"):
                    return json.dumps({"state": "MERGED", "mergeCommit": {"oid": "c" * 40}})
                return ""

            async def checks(_pr, done):
                done.set()

            async def merge(candidate, preflight):
                with mock.patch.dict(os.environ, {"SYMPHONY_ISSUE_IDENTIFIER": "PRO-1"}), \
                     mock.patch.object(land, "bound_request", None), \
                     mock.patch.object(land, "require_merge_preflight", mock.AsyncMock(return_value=preflight)), \
                     mock.patch.object(land, "get_pr_info", mock.AsyncMock(return_value=candidate)), \
                     mock.patch.object(land, "run_gh", gh), \
                     mock.patch.object(land, "wait_for_codex", mock.AsyncMock()), \
                     mock.patch.object(land, "wait_for_checks", checks), \
                     mock.patch.object(land, "fetch_review_context", mock.AsyncMock(return_value=([], [], [], None))), \
                     mock.patch.object(land, "collect_ci_summary", mock.AsyncMock(return_value=summary)), \
                     mock.patch.object(land, "current_issue_labels", mock.AsyncMock(return_value=[])), \
                     mock.patch.object(land, "request_bound_checkpoint", return_value={"ok": True, "labels": []}):
                    await land.merge_bound(candidate.head_sha, "PRO-1: Test")

            await merge(pr, evidence)
            self.assertEqual(counter.read_text(), "x")

            slow = json.loads(self.contract([sys.executable, "-c", "import time;time.sleep(2)"]))
            slow["timeout_seconds"] = 0.05
            self.write(land.ARCHITECTURE_CONTRACT, json.dumps(slow))
            base = self.commit()
            self.write("app.txt", "next candidate")
            head = self.commit()
            self.git("push", "-q", "origin", "symphony/PRO-1")
            pr = self.pr(base, head)
            evidence = land.MergePreflightEvidence("symphony/PRO-1", head, True, pr)
            output = io.StringIO()
            with redirect_stdout(output), self.assertRaises(SystemExit) as error:
                await merge(pr, evidence)
            self.assertEqual(error.exception.code, land.ARCHITECTURE_BLOCKER_EXIT)
            self.assertIn("architecture_check_failed: timeout", output.getvalue())

    async def test_invalid_contract_and_check_failure_and_timeout_report_distinct_reason(self):
        self.write("app.txt", "base")
        base = self.commit()
        self.write(land.ARCHITECTURE_CONTRACT, "not json")
        head = self.commit()
        with self.assertRaisesRegex(land.ArchitectureError, "architecture_contract_invalid"):
            await self.gate(self.pr(base, head))
        for command, expected in [([sys.executable, "-c", "print('x'*5000);exit(2)"], "exit 2"),
                                  ([sys.executable, "-c", "import time;time.sleep(2)"], "timeout"),
                                  ([sys.executable, "-c", "import subprocess,sys;subprocess.Popen([sys.executable,'-c','import time;time.sleep(5)']);print('parent exited')"], "timeout")]:
            with self.subTest(expected=expected):
                self.write(land.ARCHITECTURE_CONTRACT, self.contract(command))
                head = self.commit()
                body = "## Architekturänderung\nÄnderung: neue Regel\nGrund: Ticketvorgabe\nAlternativen: keine"
                with self.assertRaises(land.ArchitectureError) as error:
                    await self.gate(self.pr(base, head), body)
                self.assertEqual(error.exception.reason, "architecture_check_failed")
                self.assertIn(expected, str(error.exception))
                self.assertLess(len(str(error.exception)), 2200)
                if "parent exited" in command[-1]:
                    self.assertIn("parent exited", str(error.exception))

    async def test_contract_accepts_additional_fields(self):
        contract = json.loads(self.contract())
        contract["version"] = 1
        self.write(land.ARCHITECTURE_CONTRACT, json.dumps(contract))
        base = self.commit()
        self.write("app.txt", "ordinary change")
        head = self.commit()
        self.assertIsNone(await self.gate(self.pr(base, head)))

    async def test_unjustified_then_justified_contract_change_and_idempotent_pr_marker(self):
        self.write(land.ARCHITECTURE_CONTRACT, self.contract())
        base = self.commit()
        self.write("rules/check.txt", "new rule")
        head = self.commit()
        with self.assertRaises(land.ArchitectureError) as error:
            await self.gate(self.pr(base, head))
        self.assertEqual(error.exception.reason, "architecture_change_unjustified")
        body = "## Architekturänderung\nÄnderung: strengere Regel\nGrund: Ticketvorgabe\nAlternativen: keine"
        change = await self.gate(self.pr(base, head), body)
        self.assertEqual(change.paths, ["rules/check.txt"])
        edited = []
        async def gh(*args):
            edited.append(args)
            return ""
        with mock.patch.object(land, "run_gh", gh):
            await land.mark_architecture_pr(self.pr(base, head), change)
            marked_body = edited[0][-1]
            await land.mark_architecture_pr(self.pr(base, head), land.ArchitectureChange(change.paths, change.justification, marked_body))
        self.assertEqual(len(edited), 1)
        self.assertIn('"paths":["rules/check.txt"]', marked_body)

    async def test_deleted_contract_and_changed_adr_are_architecture_changes(self):
        self.write(land.ARCHITECTURE_CONTRACT, self.contract())
        self.write("docs/architecture/adr/0001.md", "original")
        base = self.commit()
        self.write("docs/architecture/adr/0001.md", "updated")
        head = self.commit()
        changed = await self.gate(self.pr(base, head))
        self.assertEqual(changed.justification, "ADR: docs/architecture/adr/0001.md")
        base = head
        self.git("rm", land.ARCHITECTURE_CONTRACT)
        head = self.commit()
        with self.assertRaises(land.ArchitectureError) as error:
            await self.gate(self.pr(base, head))
        self.assertEqual(error.exception.reason, "architecture_change_unjustified")
        body = "## Architekturänderung\nÄnderung: Vertrag entfernt\nGrund: Ticketvorgabe\nAlternativen: Regel erhalten"
        changed = await self.gate(self.pr(base, head), body)
        self.assertIn(land.ARCHITECTURE_CONTRACT, changed.paths)

    async def test_changed_adr_justifies_rule_when_adr_is_outside_contract_globs(self):
        contract = json.loads(self.contract())
        contract["architecture_paths"] = ["rules/**"]
        self.write(land.ARCHITECTURE_CONTRACT, json.dumps(contract))
        self.write("docs/architecture/adr/0001.md", "old decision")
        base = self.commit()
        self.write("rules/check.txt", "strict rule")
        self.write("docs/architecture/adr/0001.md", "new decision")
        head = self.commit()
        change = await self.gate(self.pr(base, head))
        self.assertEqual(change.paths, ["rules/check.txt"])
        self.assertEqual(change.justification, "ADR: docs/architecture/adr/0001.md")

    async def test_old_globs_still_identify_removed_rule_after_contract_change(self):
        self.write(land.ARCHITECTURE_CONTRACT, self.contract())
        self.write("rules/old.txt", "baseline")
        base = self.commit()
        replacement = json.loads(self.contract())
        replacement["architecture_paths"] = ["new/**"]
        self.write(land.ARCHITECTURE_CONTRACT, json.dumps(replacement))
        self.git("rm", "rules/old.txt")
        head = self.commit()
        body = "## Architekturänderung\nÄnderung: alte Regel entfernt\nGrund: Ticketvorgabe\nAlternativen: alte Regel behalten"
        changed = await self.gate(self.pr(base, head), body)
        self.assertEqual(changed.paths, [land.ARCHITECTURE_CONTRACT, "rules/old.txt"])

    async def test_renaming_a_rule_outside_architecture_paths_counts_the_deleted_path(self):
        self.write(land.ARCHITECTURE_CONTRACT, self.contract())
        self.write("rules/old.txt", "baseline")
        base = self.commit()
        self.git("mv", "rules/old.txt", "outside.txt")
        head = self.commit()
        body = "## Architekturänderung\nÄnderung: Regel verschoben\nGrund: Ticketvorgabe\nAlternativen: alte Stelle behalten"
        changed = await self.gate(self.pr(base, head), body)
        self.assertEqual(changed.paths, ["rules/old.txt"])

    async def test_bound_merge_marks_architecture_then_rechecks_manual_review_label(self):
        base, head = "a" * 40, "b" * 40
        pr = self.pr(base, head)
        evidence = land.MergePreflightEvidence("symphony/PRO-1", head, True, pr)
        change = land.ArchitectureChange([land.ARCHITECTURE_CONTRACT], "PR: ## Architekturänderung", "reason")
        requests = []
        merges = []
        body = "## Architekturänderung\nÄnderung: neue Regel\nGrund: Ticketvorgabe\nAlternativen: keine"

        async def git(*args):
            if args[0] == "status":
                return ""
            return f"{head}\trefs/heads/symphony/PRO-1"

        async def gh(*args):
            if args[:2] == ("pr", "merge"):
                merges.append(args)
                return ""
            if args[:2] == ("pr", "view") and args[-1] == "body":
                return json.dumps({"body": body})
            return json.dumps({"state": "MERGED", "mergeCommit": {"oid": "c" * 40}})

        def checkpoint(operation, **details):
            requests.append((operation, details))
            return {"ok": True, "labels": ["Architekturänderung"]}

        context = ([], [], [], None)
        summary = land.CheckSummary(False, False, [], {}, no_ci=True)
        with mock.patch.dict(os.environ, {"SYMPHONY_ISSUE_IDENTIFIER": "PRO-1"}), \
             mock.patch.object(land, "bound_request", None), \
             mock.patch.object(land, "watch_pr", mock.AsyncMock(return_value=(pr, change))), \
             mock.patch.object(land, "require_merge_preflight", mock.AsyncMock(return_value=evidence)), \
             mock.patch.object(land, "run_git", git), mock.patch.object(land, "run_gh", gh), \
             mock.patch.object(land, "mark_architecture_pr", mock.AsyncMock()) as marker, \
             mock.patch.object(land, "request_bound_checkpoint", checkpoint), \
             mock.patch.object(land, "fetch_review_context", mock.AsyncMock(return_value=context)), \
             mock.patch.object(land, "collect_ci_summary", mock.AsyncMock(return_value=summary)), \
             mock.patch.object(land, "current_issue_labels", mock.AsyncMock(side_effect=[[], ["Architekturänderung"]])):
            await land.merge_bound(head, "PRO-1: Test")
            marker.assert_awaited_once()
            self.assertEqual(marker.await_args.args[1].body, body)
            self.assertEqual([operation for operation, _ in requests], ["architecture", "merge"])
            self.assertEqual(len(merges), 1)

        merges.clear()
        requests.clear()
        with mock.patch.dict(os.environ, {"SYMPHONY_ISSUE_IDENTIFIER": "PRO-1"}), \
             mock.patch.object(land, "bound_request", None), \
             mock.patch.object(land, "watch_pr", mock.AsyncMock(return_value=(pr, change))), \
             mock.patch.object(land, "require_merge_preflight", mock.AsyncMock(return_value=evidence)), \
             mock.patch.object(land, "run_git", git), mock.patch.object(land, "run_gh", gh), \
             mock.patch.object(land, "mark_architecture_pr", mock.AsyncMock()), \
             mock.patch.object(land, "request_bound_checkpoint", checkpoint), \
             mock.patch.object(land, "fetch_review_context", mock.AsyncMock(return_value=context)), \
             mock.patch.object(land, "collect_ci_summary", mock.AsyncMock(return_value=summary)), \
             mock.patch.object(land, "current_issue_labels", mock.AsyncMock(side_effect=[[], ["Architekturänderung", "Requires Manual Review"]])):
            with self.assertRaises(SystemExit):
                await land.merge_bound(head, "PRO-1: Test")
            self.assertEqual(merges, [])
