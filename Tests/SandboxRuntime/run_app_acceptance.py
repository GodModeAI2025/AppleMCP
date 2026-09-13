#!/usr/bin/env python3
"""Run synthetic acceptance checks against a signed local app (never uploads).

The app must already have read-only grants for the synthetic Mail/Recordings
fixtures. No private token is read: both owned processes get an ephemeral token.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import select
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bundle", required=True, type=Path)
parser.add_argument("--fixtures", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
bundle = args.bundle.resolve(strict=True)
fixtures = args.fixtures.resolve(strict=True)
main = bundle / "Contents/MacOS/M3MCPApp"
helper = bundle / "Contents/Helpers/LocalMCPBridge.app/Contents/MacOS/M3MCPBridge"
for executable in (main, helper):
    assert executable.is_file(), f"Missing executable: {executable}"
processes = subprocess.check_output(["ps", "-axo", "comm="], text=True).splitlines()
for command in processes:
    if command.strip() == str(main) or command.strip().endswith("/LocalMCP-TestFlight.app/Contents/MacOS/M3MCPApp"):
        raise SystemExit("Close the separate TestFlight app before running this check.")
env = os.environ.copy()
env["M3MCP_TOKEN"] = secrets.token_urlsafe(32)
app = bridge = None
buffer = b""
results = {"bundle": str(bundle), "checks": {}, "passed": False}

def rpc(request):
    global buffer
    bridge.stdin.write(json.dumps(request).encode() + b"\n")
    bridge.stdin.flush()
    if "id" not in request:
        return
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            response = json.loads(line)
            if response.get("id") == request["id"]:
                assert "error" not in response, response.get("error")
                return response["result"]
        if select.select([bridge.stdout], [], [], 1)[0]:
            chunk = os.read(bridge.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("Bridge closed before replying")
            buffer += chunk
    raise TimeoutError("MCP response timed out")

def call(identifier, name, arguments):
    result = rpc({"jsonrpc": "2.0", "id": identifier, "method": "tools/call",
                  "params": {"name": name, "arguments": arguments}})
    data = result.get("structuredContent", {})
    assert not result.get("isError") and data.get("ok") is True, name + " failed: " + str(data.get("message"))
    return data

try:
    app = subprocess.Popen([str(main)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)
    assert app.poll() is None, "App failed to start"
    bridge = subprocess.Popen([str(helper)], env=env, stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-11-25", "capabilities": {},
        "clientInfo": {"name": "localmcp-synthetic-acceptance", "version": "1"}}})
    rpc({"jsonrpc": "2.0", "method": "notifications/initialized"})
    catalog = rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    results["tool_count"] = len(catalog["tools"])
    mail = call(3, "mail_search", {"query": "LocalMCP Sandbox-Test", "limit": 1})
    assert mail["items"][0]["title"] == "LocalMCP Sandbox-Test"
    results["checks"]["mail_search"] = True
    voice = call(4, "voicememos_search", {"query": "Synthetic Voice Fixture", "limit": 1})
    item = voice["items"][0]
    assert Path(item["metadata"]["path"]).resolve() == fixtures / "Recordings/fixture-missing.m4a"
    results["checks"]["voicememos_search"] = True
    speech = call(5, "voicememos_transcribe", {"id": item["id"], "language": "de-DE",
        "prefer_stored": False, "timeout_seconds": 90})
    results["speech"] = speech
    assert "synthetische Testaufnahme" in json.dumps(speech, ensure_ascii=False)
    results["checks"]["voicememos_transcribe"] = True
    text = "Unser Testprojekt startet am Montag. Anna erstellt bis Dienstag die Dokumentation. Ben prüft bis Mittwoch die Anwendung. Am Donnerstag besprechen beide die Ergebnisse."
    for identifier, style in enumerate(("summary", "actions", "summary_and_actions", "concise", "key_points"), 6):
        data = call(identifier, "ai_summarize", {"text": text, "style": style})
        output = data["items"][0]["preview"]
        assert data["items"][0]["metadata"]["model"] == "apple-on-device"
        assert output.strip()
        if style == "summary_and_actions":
            assert "Zusammenfassung:" in output and "Aufgaben:" in output
        results["checks"][style] = True
        results[style] = output
    results["passed"] = True
except Exception as error:
    results["error"] = str(error)
finally:
    for process in (bridge, app):
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                results["passed"] = False
                results["cleanup_error"] = "Owned test process did not terminate"
    args.output.write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(results, indent=2, ensure_ascii=False))
raise SystemExit(0 if results["passed"] else 1)
