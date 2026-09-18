import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), REPO / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


test_instance = load("test-instance")


class TestInstancePreflightTest(unittest.TestCase):
    def setUp(self):
        running = patch.object(test_instance, "normal_service_running", return_value=True)
        running.start()
        self.addCleanup(running.stop)
        self.directory = tempfile.TemporaryDirectory(dir=REPO / "tmp")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.fixtures = self.root / "SymphonyTest"
        for name in test_instance.PROJECTS:
            (self.fixtures / name / ".symphony").mkdir(parents=True)
        self.source = self.root / "source"
        self.source.mkdir()
        self.git("init", "-q")
        (self.source / "code").write_text("first")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
        self.manifest = {
            "project_root": str(self.fixtures), "workspace_root": str(self.root / "worktrees"), "fixtures_idle": True,
            "projects": {
                name: {"workspace": workspace, "workspace_id": str(index) * 8 + "-1111-1111-1111-111111111111",
                       "project_id": str(index + 2) * 8 + "-1111-1111-1111-111111111111", "slug_id": "slug-" + name,
                       "teams": [{'id': 'team-' + workspace, 'key': 'PRO' if workspace == 'prolok' else 'PRI'}],
                       "verified_at": time.time()}
                for index, (name, workspace) in enumerate(test_instance.PROJECTS.items(), 1)
            },
            "main_instance": {"pid": os.getpid(), "started": test_instance.process_started(os.getpid()),
                              "sha": "a" * 40, "verified_at": time.time(),
                              "projects": [{"workspace_id": "separate", "project_id": "main",
                                            "root": str(self.root / "main"), "workspace_root": str(self.root / "main-worktrees")}]}
        }
        self.path = self.root / "manifest.json"
        self.write_manifest()
        revision = test_instance.source(self.source)
        self.env = {"SYMPHONY_TEST_MANIFEST": str(self.path), "SYM_PROJECT_ROOT": str(self.fixtures),
                    "SYMPHONY_TEST_EXPECTED_SHA": revision["sha"], "SYMPHONY_TEST_EXPECTED_SOURCE": revision["source_sha256"]}

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.source), *args], stderr=subprocess.DEVNULL)

    def write_manifest(self):
        self.path.write_text(json.dumps(self.manifest))

    def check(self):
        return test_instance.preflight("development", self.source, self.env)

    def test_explicit_option_matrix(self):
        for args in ([], ["--yolo", "--port", "4001"]):
            self.assertIsNone(test_instance.instance_name(args))
        for args in (["--test-instance", "dev"], ["--test-instance=dev"]):
            self.assertEqual(test_instance.instance_name(args), "dev")
        for args in (["--test-instance"], ["--test-instance="], ["--test-instance", "../main"],
                     ["--test-instance", "dev", "--test-instance=dev"]):
            with self.subTest(args=args), self.assertRaises(ValueError):
                test_instance.instance_name(args)

    def test_source_changes_are_detected_without_exposing_contents(self):
        self.assertFalse(self.check()["source"]["dirty"])
        (self.source / "code").write_text("changed")
        with self.assertRaises(ValueError):
            self.check()
        self.env["SYMPHONY_TEST_EXPECTED_SOURCE"] = test_instance.source(self.source)["source_sha256"]
        self.assertTrue(self.check()["source"]["dirty"])
        (self.source / "new").write_text("addition")
        with self.assertRaises(ValueError):
            self.check()

    def test_only_the_public_dummy_may_be_discovered_and_bound(self):
        self.assertEqual(set(self.check()['manifest']['projects']), {'symphony-test'})
        original = self.manifest['projects']
        for projects in ({}, dict(original, unknown=original['symphony-test'])):
            self.manifest['projects'] = projects
            self.write_manifest()
            with self.assertRaises(ValueError):
                self.check()
        self.manifest['projects'] = original
        self.write_manifest()
        project = self.fixtures / 'symphony-test'
        project.rename(self.root / 'missing')
        with self.assertRaises(ValueError):
            self.check()

    def test_verified_disjoint_team_is_allowed_in_dummy_workspace(self):
        fixture = self.manifest['projects']['symphony-test']
        fixture['teams'] = [{'id': 'pro-id', 'key': 'PRO'}]
        fixture['verified_at'] = time.time()
        main = self.manifest['main_instance']['projects'][0]
        main.update(workspace_id=fixture['workspace_id'], team_key='QAI', team_id='qai-id')
        main.pop('project_id')
        self.write_manifest()
        self.assertEqual(self.check()['manifest'], self.manifest)

    def test_team_overlap_and_incomplete_or_stale_membership_fail_closed(self):
        fixture = self.manifest['projects']['symphony-test']
        main = self.manifest['main_instance']['projects'][0]
        main.update(workspace_id=fixture['workspace_id'], team_key='QAI', team_id='qai-id')
        main.pop('project_id')
        original = dict(fixture)
        for change in ({'teams': []}, {'teams': None}, {'teams': [{'key': 'PRO'}]},
                       {'teams': [{'id': 'p', 'key': 'PRO'}, {'id': 'p', 'key': 'OTHER'}]},
                       {'teams': [{'id': 'p', 'key': 'PRO'}, {'id': 'other', 'key': 'PRO'}]},
                       {'teams': [{'id': 'qai-id', 'key': 'QAI'}]},
                       {'teams': original['teams'] + [{'id': 'qai-id', 'key': 'QAI'}]},
                       {'verified_at': time.time() - 3601}, {'verified_at': time.time() + 600}):
            fixture.clear()
            fixture.update(original, **change)
            self.write_manifest()
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.check()
        fixture.clear()
        fixture.update(original)
        main.pop('team_id')
        self.write_manifest()
        with self.assertRaises(ValueError):
            self.check()

    def test_discovery_rejects_aliases_extra_code_and_collector_project(self):
        for relative in ("Symphony/.symphony", ".symphony", "extra/.symphony"):
            path = self.fixtures / relative
            path.mkdir(parents=True)
            with self.subTest(relative=relative), self.assertRaises(ValueError):
                self.check()
            path.rmdir()
        original = self.fixtures / "symphony-test"
        original.rename(self.root / "elsewhere")
        original.symlink_to(self.root / "elsewhere", target_is_directory=True)
        with self.assertRaises(ValueError):
            self.check()

    def test_main_evidence_rejects_overlap_restart_missing_and_stale_inventory(self):
        main = dict(self.manifest["main_instance"])
        workspace = self.manifest["projects"]["symphony-test"]["workspace_id"]
        project = self.manifest["projects"]["symphony-test"]["project_id"]
        for patch in ({"projects": [{"root": str(self.fixtures / "symphony-test")}]}, {"projects": []}, {"projects": [{"workspace_id": workspace, "project_id": project}]},
                      {"projects": [{"workspace_id": workspace, "team_key": "PRO"}]},
                      {"started": "a previous process"}, {"verified_at": time.time() - 7200}):
            if "projects" in patch:
                patch["projects"] = [dict(main["projects"][0], **scope) for scope in patch["projects"]]
                for scope in patch["projects"]:
                    if scope.get("team_key"):
                        scope.pop("project_id", None)
            self.manifest["main_instance"] = dict(main, **patch)
            self.write_manifest()
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                self.check()

    def test_cleanup_uses_original_build_stamp_after_source_change_and_main_loss(self):
        revision=self.check()['source']
        stamp=self.source/'_build/symphony-source.json'
        stamp.parent.mkdir()
        stamp.write_text(json.dumps(revision))
        (self.source/'code').write_text('continued development')
        with self.assertRaises(ValueError):self.check()
        self.env['SYMPHONY_TEST_RUN_STAGE']='cleanup'
        with patch.object(test_instance,'normal_service_running',return_value=False):
            self.assertEqual(self.check()['source'],revision)
        stamp.write_text(json.dumps(dict(revision,sha='f'*40)))
        with self.assertRaises(ValueError):self.check()

    def test_actual_direct_escript_rejects_invalid_and_duplicate_names_before_lock(self):
        env=dict(os.environ,SYMPHONY_ROOT_DIR=str(REPO),SYMPHONY_WORKFLOW_FILE=str(REPO/'WORKFLOW.md'),
                 MISE_TRUSTED_CONFIG_PATHS=str(REPO/'mise.toml'))
        for flags in (['--test-instance','../main'],['--test-instance','a','--test-instance','b'],['--test-instance']):
            result=subprocess.run(['mise','exec','--',str(REPO/'bin/symphony'),*flags],cwd=REPO,env=env,
                                  capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,1,result.stdout+result.stderr)
            self.assertIn('--test-instance',result.stderr)
            self.assertNotIn('Symphony läuft bereits',result.stderr)

    def test_separate_checkout_survives_removal_of_source_and_preserves_sha(self):
        accepted = self.check()["source"]
        independent = self.root / "merged"
        subprocess.run(["git", "clone", "-q", str(self.source), str(independent)], check=True)
        self.source.rename(self.root / "removed-source")
        result = test_instance.preflight("acceptance", independent, self.env)
        self.assertEqual(result["source"]["sha"], accepted["sha"])
        self.assertEqual(result["source"]["source_sha256"], accepted["source_sha256"])


if __name__ == "__main__":
    unittest.main()
