#!/usr/bin/env python3
"""Exercise real sandboxed processes. No keychain or personal provider data is used."""
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys

probe, bridge = map(lambda p: str(Path(p).resolve()), sys.argv[1:3])
token = 'synthetic-sandbox-transport-token'
env = dict(os.environ)
for key in ('M3MCP_SOCKET_DIR', 'M3MCP_TRUSTED_CLIENT_CDHASH'):
    env.pop(key, None)
env['M3MCP_TOKEN'] = token
server = subprocess.Popen([probe, bridge], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, env=env)
try:
    ready, _, _ = select.select([server.stdout], [], [], 15)
    assert ready, 'sandboxed server did not become ready'
    line = server.stdout.readline().strip()
    assert line.startswith('READY '), (line, server.stderr.read() if server.poll() is not None else '')
    endpoint = line.removeprefix('READY ')
    p = subprocess.run([bridge, '--check-connection'], capture_output=True, text=True, env=env, timeout=15)
    assert p.returncode == 0 and p.stdout.strip() == 'M3MCP_CONNECTION_OK', (p.returncode, p.stdout, p.stderr)
    print('PASS: externally launched sandbox helper authenticates to sandboxed server')
    p = subprocess.run([bridge, '--check-connection'], capture_output=True, text=True,
                       env=dict(env, M3MCP_TOKEN=token+'wrong'), timeout=15)
    assert p.returncode == 0 and p.stdout.strip() == 'M3MCP_CONNECTION_FAILED', (p.returncode, p.stdout)
    print('PASS: same helper with wrong token is rejected')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(10)
        client.connect(endpoint)
        client.sendall(('POST /tools/source_status HTTP/1.1\r\nHost: localhost\r\n'
                        f'Authorization: Bearer {token}\r\nContent-Length: 2\r\n\r\n{{}}').encode())
        response = client.recv(4096)
        assert response.startswith(b'HTTP/1.1 403 '), response
    print('PASS: foreign executable is rejected despite correct token')
    assert Path(endpoint).stat().st_mode & 0o777 == 0o600
    assert Path(endpoint).parent.stat().st_mode & 0o777 == 0o700
    print('PASS: private socket and parent permissions retained')
finally:
    server.stdin.close()
    try:
        server.wait(timeout=5)
    except subprocess.TimeoutExpired:
        server.terminate()
        server.wait(timeout=5)
