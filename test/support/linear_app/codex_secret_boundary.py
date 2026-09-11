"""Offline actual-Codex inheritance check; no model turn, credentials or live API."""
import importlib.util,json,os,selectors,shutil,subprocess,sys,tempfile,time
from pathlib import Path
repo=Path(__file__).resolve().parents[3]
project_mode='--project' in sys.argv
runtime=[]
if project_mode:
 elixir=subprocess.check_output(['mise','which','elixir'],cwd=repo,text=True).strip()
 erl=subprocess.check_output(['mise','which','erl'],cwd=repo,text=True).strip()
 runtime=[elixir]
 for path in sorted((repo/'_build/dev/lib').glob('*/ebin')): runtime+=['-pa',str(path)]
spec=importlib.util.spec_from_file_location('context',repo/'scripts/codex-app-context.py')
context=importlib.util.module_from_spec(spec);spec.loader.exec_module(context)
with tempfile.TemporaryDirectory(prefix='pro676-sentinel-') as tmp:
 root=Path(tmp);release=root/'release';target=release/'.symphony/codex';target.mkdir(parents=True)
 (target/'config.toml').write_text('[shell_environment_policy.set]\nSYMPHONY_SENTINEL_CREDENTIAL="restored-by-old-config"\n[features]\nhooks=true\nshell_snapshot=true\n');(target/'skills.json').write_text('[]');(release/'.symphony-release.json').write_text('{}')
 project=root/'project';project.mkdir();(project/'.git').mkdir()
 secret_name='SYMPHONY_SENTINEL_CREDENTIAL';sentinel='synthetic-pro676-value-8b2961'
 mcp=release/'sym-codex-mcp'
 mcp.write_text('#!'+sys.executable+'\n'+'''import json,os,sys
from pathlib import Path
Path(os.environ['PROBE_FILE']).write_text(json.dumps({'present':bool(os.environ.get('SYMPHONY_SENTINEL_CREDENTIAL'))}))
for line in sys.stdin:
 r=json.loads(line)
 if 'id' not in r: continue
 result={'protocolVersion':'2025-06-18','capabilities':{'tools':{}},'serverInfo':{'name':'synthetic','version':'1'}} if r['method']=='initialize' else {'tools':[]}
 print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':result}),flush=True)
''');mcp.chmod(0o755)
 env={'PATH':os.environ['PATH'],'HOME':str(root),'CODEX_HOME':str(target),'SYMPHONY_LINEAR_CLIENT_SECRET_ENV':secret_name,secret_name:sentinel,'SYMPHONY_RELEASE_ROOT':str(release),'PROBE_FILE':str(root/'mcp-result.json'),'SHELL':'/bin/sh','TMPDIR':str(root)}
 if project_mode:
  app_root=root/'symphony-root';app_root.mkdir()
  (project/'.symphony').mkdir()
  private=project/'.symphony/.env.local'
  values={'LINEAR_APP_CLIENT_ID':'client','LINEAR_APP_WORKSPACE_ID':'workspace','LINEAR_APP_USER_ID':'app','LINEAR_APP_INSTALLATION_ID':'synthetic'}
  (release/'.symphony/root-config.json').write_text(json.dumps({'root':str(app_root),'values':{'SYM_CODEX_MODEL':'synthetic'}}))
  (release/'WORKFLOW.md').write_text((repo/'WORKFLOW.md').read_text())
  private.write_text(''.join(name+'='+value+'\n' for name,value in values.items())+'LINEAR_ASSIGNEE=human@example.invalid\nLINEAR_PROJECT_SLUG=synthetic-project\nLINEAR_APP_SECRET='+sentinel+'\n');private.chmod(0o600)
  env.pop(secret_name);secret_name='LINEAR_APP_SECRET'
  env['PATH']=str(Path(erl).parent)+':'+str(Path(elixir).parent)+':'+env['PATH']
  env.update(SYMPHONY_LINEAR_CLIENT_SECRET_ENV=secret_name,SYMPHONY_ROOT_DIR=str(app_root),SYMPHONY_PROJECT_ROOT=str(project),SYMPHONY_SOURCE_REPO=str(release),SYMPHONY_WORKFLOW_FILE=str(release/'WORKFLOW.md'))
  mcp.write_text('#!'+sys.executable+'\nimport os\nargs='+repr(runtime+['-r',str(repo/'test/support/linear_app/project_mcp_helper.exs'),'-e','SymphonyElixir.Codex.MCPServer.main()'])+'\nos.execv(args[0],args)\n')
 args=context.launch_config(release,target,project,root,environment=env)
 args+=['--config','mcp_servers.symphony_linear.env_vars='+json.dumps([secret_name,'PROBE_FILE']), '--config','cli_auth_credentials_store="file"','--config','model_provider="synthetic"','--config','model="synthetic"','--config','model_providers.synthetic={name="synthetic",base_url="http://127.0.0.1:1",wire_api="responses",requires_openai_auth=false}','--config','analytics.enabled=false','--config','features.remote_plugin=false','--config','shell_environment_policy.inherit="all"']
 assert sentinel not in json.dumps(args)
 p=subprocess.Popen([shutil.which('codex'),*args,'app-server'],cwd=project,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
 transcript=[]
 def rpc(i,method,params):
  p.stdin.write(json.dumps({'id':i,'method':method,'params':params})+'\n');p.stdin.flush()
  selector=selectors.DefaultSelector();selector.register(p.stdout,selectors.EVENT_READ)
  deadline=time.monotonic()+30
  while time.monotonic()<deadline:
   if not selector.select(1):
    if p.poll() is not None: raise RuntimeError('codex exited: '+p.stderr.read())
    continue
   line=p.stdout.readline();transcript.append(line)
   r=json.loads(line)
   if r.get('id')==i:
    if 'error' in r: raise RuntimeError(json.dumps(r))
    return r['result']
  raise RuntimeError('RPC timeout '+method)
 try:
  rpc(1,'initialize',{'clientInfo':{'name':'symphony-synthetic','version':'1'},'capabilities':{'experimentalApi':True}})
  p.stdin.write(json.dumps({'method':'initialized'})+'\n');p.stdin.flush()
  result=rpc(2,'command/exec',{'command':[sys.executable,'-c',"import os; print('present' if 'SYMPHONY_SENTINEL_CREDENTIAL' in os.environ else 'absent')"],'cwd':str(project),'sandboxPolicy':{'type':'dangerFullAccess'},'timeoutMs':5000})
  print('shell result',result)
  assert result['stdout'].strip()=='absent'
  if project_mode:
   command=runtime+['-e','IO.puts(inspect(SymphonyElixir.EnvFile.linear_secret("LINEAR_APP_SECRET")))']
   denied=rpc(20,'command/exec',{'command':command,'cwd':str(project),'sandboxPolicy':{'type':'dangerFullAccess'},'timeoutMs':15000})
   assert 'linear_secret_access_denied' in denied['stdout'], denied
   print('actual model-shell project secret reload denied')
  result=rpc(3,'thread/start',{'cwd':str(project),'approvalPolicy':'never','sandbox':'danger-full-access','model':'synthetic','modelProvider':'synthetic'})
  print('thread started without model turn; configured hooks/snapshots overridden')
  rpc(4,'mcpServerStatus/list',{})
  deadline=time.monotonic()+10
  while not (root/'mcp-result.json').exists() and time.monotonic()<deadline: time.sleep(.05)
  assert json.loads((root/'mcp-result.json').read_text())=={'present':True}
 finally:
  p.terminate()
  try: p.wait(timeout=5)
  except subprocess.TimeoutExpired: p.kill();p.wait()
 all_output=''.join(transcript)+p.stderr.read()
 assert sentinel not in all_output
 for path in root.rglob('*'):
  if path.is_file() and not (project_mode and path == private): assert sentinel.encode() not in path.read_bytes(), str(path)
 print('PASS: actual Codex shell excludes sentinel; actual MCP receives it; argv, RPC, logs and session artifacts contain no value')
