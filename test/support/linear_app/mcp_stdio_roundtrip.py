"""Real UTF-8 stdio roundtrip, using only an injected in-memory Linear client."""
import base64
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys

body = ' \tSymphony · Grüße über tatsächliche Änderungen 😀 🧪 e\u0301\n"zitiert" \\ /\r\n\u0000\b\f\t \n'
helper = Path(__file__).with_suffix('.exs')
env = {k: v for k, v in os.environ.items() if not k.startswith(('LINEAR_', 'SYMPHONY_'))}
env['ERL_FLAGS'] = '+S 2:2'
command = sys.argv[1:] + [str(helper), base64.b64encode(body.encode()).decode()]

with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                      stderr=subprocess.PIPE, env=env, bufsize=0) as child:
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)

    def response():
        line = bytearray()
        while not line.endswith(b'\n'):
            assert selector.select(15), 'MCP stdout timeout'
            byte = child.stdout.read(1)
            assert byte, 'MCP stdout closed'
            line.extend(byte)
        # A single UTF-8 JSON line, including the nested tool JSON text.
        return json.loads(line.decode('utf-8'))

    def send(value, escaped=True):
        wire = (json.dumps(value, ensure_ascii=escaped) + '\n').encode('utf-8')
        # Split literal UTF-8 inside a multibyte code point too.
        split = wire.index('ü'.encode()) + 1 if not escaped else len(wire) // 2
        child.stdin.write(wire[:split])
        child.stdin.write(wire[split:])

    def call(ident, query, variables, escaped=True):
        send({'jsonrpc': '2.0', 'id': ident, 'method': 'tools/call',
              'params': {'name': 'linear_graphql', 'arguments': {'query': query, 'variables': variables}}}, escaped)
        result = response()
        assert result['id'] == ident and result['result']['isError'] is False, result
        content = result['result']['content']
        assert len(content) == 1 and content[0]['type'] == 'text'
        assert json.loads(content[0]['text']) == {'data': {'body': body}}, result

    try:
        send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'})
        assert response()['result']['serverInfo']['name'] == 'symphony-linear'
        send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'})
        assert response()['result']['tools'][0]['name'] == 'linear_graphql'
        for ident, escaped in [(3, True), (5, False)]:
            call(ident, 'mutation Create($body: String!) { fixtureCreate(body: $body) { body } }', {'body': body}, escaped)
            call(ident + 1, 'query { fixture { body } }', {})
        child.stdin.close()
        assert child.wait(timeout=10) == 0
        assert child.stdout.read() == b''
        assert child.stderr.read() == b''
        print('UTF-8 stdio: escaped and literal input, exact backend body and readback, framing and EOF passed')
    finally:
        selector.close()
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)
