#!/usr/bin/env python3
"""Native PKCS#12 and signing-identity regression check on macOS.

Uses disposable keychains and synthetic data only. The temporary signing key
allows codesign solely for this test; production key ACLs are never changed.
This verifies Security.framework identity matching, not the complete app upgrade.
Run: python3 Tests/Installer/native_keychain_roundtrip.py
"""
import os, pathlib, secrets, subprocess, tempfile, re, json
results=[]
def command(args, **kw):
    return subprocess.run(args,check=True,capture_output=True,text=True,timeout=45,**kw)
source=r'''
import Foundation
import Security
let args = CommandLine.arguments
var kc: SecKeychain?
let opened = SecKeychainOpen(args[1], &kc)
guard opened == errSecSuccess, let kc else { print("open",opened); exit(1) }
SecKeychainSetUserInteractionAllowed(false)
var q: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
 kSecAttrService as String:"isolated-localmcp-probe", kSecAttrAccount as String:"probe"]
if args[2] == "create" {
 q[kSecUseKeychain as String] = kc
 q[kSecValueData as String] = Data("synthetic-probe-token".utf8)
 print("create",SecItemAdd(q as CFDictionary,nil))
} else {
 q[kSecMatchSearchList as String] = [kc]
 q[kSecReturnData as String] = true
 var result: CFTypeRef?
 let status = SecItemCopyMatching(q as CFDictionary,&result)
 print("read",status,"matches",(result as? Data) == Data("synthetic-probe-token".utf8))
}
'''
for openssl in ['/usr/bin/openssl','/opt/homebrew/opt/openssl@3/bin/openssl']:
 if not pathlib.Path(openssl).exists(): continue
 with tempfile.TemporaryDirectory(prefix='localmcp-native-keychain-') as td:
  p=pathlib.Path(td); kc=str(p/'probe.keychain-db'); pw=secrets.token_hex(24)
  (p/'password').write_text(pw); (p/'password').chmod(0o600)
  created=False
  try:
   command([openssl,'req','-x509','-newkey','rsa:2048','-sha256','-days','1','-nodes','-keyout',str(p/'key.pem'),'-out',str(p/'cert.pem'),'-subj','/CN=LocalMCP Isolated Test','-addext','basicConstraints=critical,CA:false','-addext','keyUsage=critical,digitalSignature','-addext','extendedKeyUsage=critical,codeSigning'])
   command([openssl,'pkcs12','-export','-macalg','sha1','-certpbe','PBE-SHA1-3DES','-keypbe','PBE-SHA1-3DES','-out',str(p/'identity.p12'),'-inkey',str(p/'key.pem'),'-in',str(p/'cert.pem'),'-passout','file:'+str(p/'password')])
   command(['security','create-keychain','-p',pw,kc]);created=True
   command(['security','unlock-keychain','-p',pw,kc])
   imported=command(['security','import',str(p/'identity.p12'),'-k',kc,'-P',pw,'-T','/usr/bin/codesign']).stdout.strip()
   listing=command(['security','find-identity','-p','codesigning',kc]).stdout
   fingerprint=re.search(r'\b[0-9A-F]{40}\b',listing).group(0)
   steps=[]
   for version in [1,2,3]:
    (p/'main.swift').write_text(source+f'\nprint("build",{version})\n')
    folder=p/('dev' if version == 1 else 'installed'); folder.mkdir(exist_ok=True)
    binary=str(folder/'probe')
    command(['xcrun','swiftc',str(p/'main.swift'),'-o',binary])
    command(['codesign','--force','--sign',fingerprint,'--keychain',kc,'--identifier',('de.mobilebox.LocalMCP.IsolatedProbe' if version < 3 else 'de.mobilebox.UntrustedProbe'),binary])
    dr=command(['codesign','-d','-r-',binary]); requirement=dr.stdout.strip()
    if version==1: steps.append(command([binary,kc,'create']).stdout.strip())
    steps.append(command([binary,kc,'read']).stdout.strip())
   results.append({'openssl':command([openssl,'version']).stdout.strip(),'import':imported,'steps':steps,'requirement':requirement})
  except Exception as e:
   # Do not render command arguments, which contain the disposable transport password.
   results.append({'openssl':openssl,'error_type':type(e).__name__,'stderr':getattr(e,'stderr','')})
  finally:
   if created: subprocess.run(['security','delete-keychain',kc],capture_output=True)
print(json.dumps(results,indent=2))
assert results, "No supported OpenSSL executable found"
for result in results:
 assert "error_type" not in result, "Native roundtrip failed"
 assert "create 0" in result["steps"][0], "Could not create synthetic token"
 assert "read 0 matches true" in result["steps"][1], "Initial read failed"
 assert "read 0 matches true" in result["steps"][2], "Stable identity lost access after rebuild"
 assert "matches false" in result["steps"][3], "Different identity accessed token"
 assert "read 0 " not in result["steps"][3], "Different identity unexpectedly succeeded"
