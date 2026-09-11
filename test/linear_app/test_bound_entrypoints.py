import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('release', REPO / 'scripts/installation-release.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class BoundEntrypointsTest(unittest.TestCase):
    def test_mcp_and_operator_keep_separate_source_workflow_and_frozen_mix_context(self):
        with tempfile.TemporaryDirectory(dir=REPO / '_build') as temporary:
            root = Path(temporary)
            runtime, project = root / 'release', root / 'project'
            (runtime / 'scripts').mkdir(parents=True)
            project.mkdir()
            workflow = project / 'app.md'
            workflow.write_text('synthetic workflow')
            for name in ('sym-codex-mcp', 'scripts/linear-app', 'scripts/installation-release.py'):
                shutil.copy2(REPO / name, runtime / name)
            runner = runtime / 'scripts/mix-runtime'
            runner.write_text('''#!/usr/bin/env python3
import json,os,sys
print(json.dumps({'args':sys.argv[1:],'source':os.environ['SYMPHONY_SOURCE_REPO'],
'workflow':os.environ['SYMPHONY_WORKFLOW_FILE'],'binding':os.environ['SYMPHONY_LINEAR_BINDING_HASH'],
'root':os.environ['SYMPHONY_ROOT_DIR']}))
''')
            runner.chmod(0o755)
            (runtime / '.symphony-release.json').write_text(json.dumps({'files': {}}))
            (runtime / '.symphony').mkdir()
            original_root = root / 'original-symphony'
            (runtime / '.symphony/root-config.json').write_text(json.dumps({'root': str(original_root), 'values': {}}))
            env = {key: value for key, value in os.environ.items() if not key.startswith(('SYMPHONY_', 'LINEAR_'))}
            env.update(SYMPHONY_RELEASE_ROOT=str(runtime), SYMPHONY_SOURCE_REPO=str(project),
                       SYMPHONY_WORKFLOW_FILE=str(workflow), SYMPHONY_LINEAR_AUTH_MODE='app',
                       SYMPHONY_LINEAR_BINDING_HASH='synthetic-binding')
            for with_project_binding in (False, True):
                if with_project_binding:
                    env['SYMPHONY_PROJECT_ROOT'] = str(project)
                for command in ([runtime / 'sym-codex-mcp'], [runtime / 'scripts/linear-app', 'identity']):
                    result = subprocess.run(command, cwd=project, env=env, capture_output=True, text=True, check=True)
                    data = json.loads(result.stdout)
                    self.assertEqual(data['args'][:5], ['mix', str(runtime), 'run', '--no-compile', '--no-start'])
                    self.assertEqual(data['source'], str(project))
                    self.assertEqual(data['workflow'], str(workflow))
                    self.assertEqual(data['binding'], 'synthetic-binding')
                    self.assertEqual(data['root'], str(original_root))

    def test_direct_observer_derives_app_context_before_starting_codex(self):
        with tempfile.TemporaryDirectory(dir=REPO / '_build') as temporary:
            root = Path(temporary)
            runtime, project = root / 'release', root / 'project'
            (runtime / 'scripts').mkdir(parents=True)
            project.mkdir()
            subprocess.run(['git', 'init', '-q', '-b', 'main', str(project)], check=True)
            for name in ('sym-codex', 'sym-codex-mcp', 'scripts/installation-release.py'):
                shutil.copy2(REPO / name, runtime / name)
            for name in ('WORKFLOW.md', 'mix.exs'):
                (runtime / name).write_text('')
            (runtime / '.symphony-release.json').write_text(json.dumps({'files': {}}))
            runner = runtime / 'scripts/mix-runtime'
            runner.write_text('''#!/usr/bin/env python3
import json,os,sys
project=os.environ.get('SYMPHONY_SOURCE_REPO') or sys.argv[-1]
if 'linear_runtime_env' in ' '.join(sys.argv):
    env={'SYMPHONY_LINEAR_AUTH_MODE':'app','SYMPHONY_LINEAR_CLIENT_SECRET_ENV':'SYMPHONY_TEST_SECRET','SYMPHONY_LINEAR_BINDING_HASH':'observer-binding',
         'SYMPHONY_CODEX_STATE_ROOT':project+'/state',
         'SYMPHONY_RUN_ID':'observer-run','SYMPHONY_PHASE':''}
    print('SYM_CODEX_CONTEXT_V3\\n'+json.dumps(env)+'\\n\\n\\nSYM_CODEX_PROMPT_V1')
elif 'MCPServer.main' in ' '.join(sys.argv):
    print('mcp-project='+os.environ['SYMPHONY_SOURCE_REPO'])
else:
    print(os.environ['SYMPHONY_SOURCE_REPO']+'/worktrees')
''')
            runner.chmod(0o755)
            (runtime / 'scripts/codex-app-context.py').write_text("import os,subprocess\nprint('app='+os.environ['SYMPHONY_LINEAR_BINDING_HASH'])\nsubprocess.run([os.environ['SYMPHONY_RELEASE_ROOT']+'/sym-codex-mcp'],check=True)\n")
            env = {key: value for key, value in os.environ.items() if not key.startswith('SYMPHONY_')}
            env.update(SYMPHONY_RELEASE_ROOT=str(runtime), SYMPHONY_SOURCE_REPO=str(project),
                       SYMPHONY_WORKFLOW_FILE=str(runtime / 'WORKFLOW.md'))
            result = subprocess.run([runtime / 'sym-codex', '--observer'], cwd=project, env=env,
                                    text=True, capture_output=True, check=True)
            self.assertIn('app=observer-binding', result.stdout)

            del env['SYMPHONY_SOURCE_REPO']
            result = subprocess.run([runtime / 'sym-codex', '--observer'], cwd=project, env=env,
                                    text=True, capture_output=True, check=True)
            self.assertIn('mcp-project='+str(project), result.stdout)
            env['SYMPHONY_SOURCE_REPO'] = str(project)

            # A worker's CWD must not replace the already bound project root.
            foreign = root / 'worker'
            foreign.mkdir()
            subprocess.run(['git', 'init', '-q', '-b', 'main', str(foreign)], check=True)
            (project / '.venv/bin').mkdir(parents=True)
            (project / '.venv/bin/activate').write_text('export SYNTHETIC_BOUND_PROJECT=preserved\n')
            (runtime / 'scripts/codex-app-context.py').write_text("import os\nprint('project='+os.environ.get('SYNTHETIC_BOUND_PROJECT','lost'))\n")
            env.update(SYMPHONY_LINEAR_AUTH_MODE='app', SYMPHONY_LINEAR_ENV_DIR=str(project / '.symphony'),
                       SYMPHONY_LINEAR_BINDING_HASH='observer-binding')
            result = subprocess.run([runtime / 'sym-codex', '--observer'], cwd=foreign, env=env,
                                    text=True, capture_output=True, check=True)
            self.assertIn('project=preserved', result.stdout)
