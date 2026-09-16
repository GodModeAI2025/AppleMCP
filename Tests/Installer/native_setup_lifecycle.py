#!/usr/bin/env python3
"""Verify the real release app's consent gate and crash restart in an isolated job.

Requires `swift build -c release` and a logged-in macOS GUI session.
Creates only a disposable bundle/job, never accepts consent or accesses a token.
This complements shell installer tests; it does not prove complete installer or
keychain-upgrade acceptance. Run from any directory with Python 3.
"""
import json, os, pathlib, plistlib, shutil, signal, subprocess, tempfile, time, uuid
repo=pathlib.Path(__file__).resolve().parents[2]
root=pathlib.Path(tempfile.mkdtemp(prefix='lmcp-setup-',dir='/tmp'))
label='de.mobilebox.LocalMCP.SetupProbe.'+uuid.uuid4().hex
job=f'gui/{os.getuid()}/{label}'
app=root/'LocalMCP-Probe.app'; contents=app/'Contents'; binary=contents/'MacOS/M3MCPApp'
receipt=root/'status.json'; attempt=str(uuid.uuid4()); loaded=False
result={'checks':{},'scope':'Actual release app under isolated launchd job; setup remains unaccepted. Not full installer/upgrade acceptance.'}
def run(args): return subprocess.run(args,check=True,capture_output=True,text=True)
try:
 (contents/'MacOS').mkdir(parents=True)
 shutil.copy2(repo/'.build/release/M3MCPApp',binary)
 shutil.copy2(repo/'.build/release/M3MCPBridge',contents/'MacOS/M3MCPBridge')
 info=plistlib.loads((repo/'Sources/M3MCPApp/Resources/Info.plist').read_bytes())
 info['CFBundleIdentifier']=label
 (contents/'Info.plist').write_bytes(plistlib.dumps(info))
 run(['codesign','--force','--sign','-',str(contents/'MacOS/M3MCPBridge')])
 run(['codesign','--force','--sign','-',str(app)])
 env={'LOCALMCP_INSTALL_RECEIPT':str(receipt),'LOCALMCP_INSTALL_ATTEMPT':attempt,'M3MCP_SOCKET_DIR':str(root/'socket'),'M3MCP_TOKEN_KEYCHAIN_SERVICE':label}
 plist=root/'job.plist'
 plist.write_bytes(plistlib.dumps({'Label':label,'ProgramArguments':[str(binary),'-m3mcp.setup.usageRisk.acceptedVersion','0'],'RunAtLoad':True,'KeepAlive':{'SuccessfulExit':False},'EnvironmentVariables':env}))
 run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(plist)]);loaded=True
 deadline=time.monotonic()+30
 while not receipt.exists() and time.monotonic()<deadline: time.sleep(.25)
 data=json.loads(receipt.read_text())
 assert data['attempt']==attempt and data['state']=='setup_required' and data['executable']==str(binary),data
 os.kill(data['pid'],0)
 result['checks']['real_app_reports_setup_required']=True
 time.sleep(15)
 os.kill(data['pid'],0)
 assert not (root/'socket/mcp.sock').exists()
 result['checks']['alive_after_original_readiness_window']=True
 result['checks']['no_listener_before_consent']=True
 original_pid=data['pid']
 os.kill(original_pid, signal.SIGKILL)
 deadline=time.monotonic()+35
 restarted=None
 while time.monotonic()<deadline:
  try:
   candidate=json.loads(receipt.read_text())
   if candidate['pid'] != original_pid:
    os.kill(candidate['pid'],0)
    restarted=candidate
    break
  except (FileNotFoundError, ProcessLookupError, json.JSONDecodeError): pass
  time.sleep(.25)
 assert restarted is not None, 'launchd did not restart failed app'
 assert restarted['state']=='setup_required' and restarted['attempt']==attempt
 assert not (root/'socket/mcp.sock').exists()
 result['checks']['launchd_restarts_failed_real_app']=True
 result['checks']['crash_restart_preserves_consent_gate']=True
 result['receipt_state']=restarted['state'];result['passed']=True
finally:
 if loaded: subprocess.run(['launchctl','bootout',job],capture_output=True)
 shutil.rmtree(root)
print(json.dumps(result,indent=2))
