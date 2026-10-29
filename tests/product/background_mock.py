#!/usr/bin/env python3
"""Owned-loopback acceptance for instance-owned background services.

Build interface: python3 tests/product/background_mock.py /absolute/path/thin

Everything is an owned fixture: a temporary HOME/project, a literal 127.0.0.1
chat server, an inline fake key, an owned `python3 -u` service per job, and
bounded process groups. No real API, no user configuration, no installs.

Two cases, because the two semantics differ:

* print: one real `thin --print` App instance, six synchronous `bash
  background=true` starts. Each start is proven by the service's own bound
  socket (port 0 reported through its marker file, never guessed) before the
  fixture lets the next model round proceed. Later rounds run list, logs,
  status, one stop (that socket closes, the five siblings still answer),
  repeat stop and an unknown-id query. `--print` exit must cancel and join
  every remaining service, so all six PIDs must be gone afterwards.
* pty: one interactive App instance and two separate user turns. The service
  started in turn 1 must still answer on its socket after that task finished,
  and turn 2 manages it (status/logs/stop). This is the cross-task keep-alive
  proof; a per-task owner or an exit-time-only cleanup cannot pass it.

No fixed concurrency limit is asserted anywhere: six services are alive at the
same time because all six really run, not because a counter allowed them.
"""
import errno
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import re
import select
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

ACK = b'\x1b[?25h'
# A complete frame releases synchronized display and then shows the cursor
# (src/ui/terminal.zig); exit and resize-recovery bytes reuse the bare
# cursor-show, so frame completion needs the release marker as well.
SYNC_BEGIN = b'\x1b[?2026h'
FRAME_END = b'\x1b[?2026l' + ACK
CSI = re.compile(rb'\x1b\[([0-9;?]*)([@-~])')

# Real idle composer decorations, as rendered by src/ui/presentation.zig's
# `prompt()`: `> ` with no model selected, and `(model) 0.0%> ` /
# `(model) L1.6%> ` / `(model) high> ` once one is. The slot in front of the
# marker is a transient effort-confirmation level name or the retained context
# (`?%`, `>100%`, `N.N%`), optionally prefixed by the low-price `L`. The busy
# marker replaces the `>` with the non-ASCII activity spinner, which this bounded
# VT subset never stores, so a busy composer can never reach the same shape.
_VALUE_SLOT = (r'(?:L?(?:\?%|>100%|[0-9]+\.[0-9]%|off|minimal|low|medium|high|'
               r'xhigh|max|\?))')
_IDLE_COMPOSER = re.compile(
    r'^(?:> |(?:\([^)]*\) )?' + _VALUE_SLOT + r'> )$')


class Screen:
    """Bounded VT subset used to read the real composer/footer state."""

    def __init__(self, columns):
        self.columns = columns
        self.grid = [[' '] * columns for _ in range(24)]
        self.history = []
        self.row = self.col = 0
        self.pending = b''

    def down(self):
        if self.row == 23:
            self.history.append(''.join(self.grid.pop(0)))
            assert len(self.history) < 2048
            self.grid.append([' '] * self.columns)
        else:
            self.row += 1

    def feed(self, data):
        self.pending += data
        data = self.pending
        i = 0
        while i < len(data):
            b = data[i]
            if b == 27:
                m = CSI.match(data, i)
                if not m:
                    if data[i:i + 2] == b'\x1b[' or i + 1 == len(data):
                        break
                    i += 2
                    continue
                args, final = m.groups()
                assert final not in (b'H', b'f', b'J', b'r'), 'fullscreen operation'
                assert not (final in (b'h', b'l') and any(x in args.split(b';') for x in (b'?1049', b'?1047', b'?47')))
                n = int(args) if args.isdigit() else 1
                if final == b'A': self.row = max(0, self.row - n)
                elif final == b'B': self.row = min(23, self.row + n)
                elif final == b'C': self.col = min(self.columns - 1, self.col + n)
                elif final == b'D': self.col = max(0, self.col - n)
                elif final == b'K': self.grid[self.row][self.col:] = [' '] * (self.columns - self.col)
                elif final == b'M':
                    for _ in range(n):
                        self.grid.pop(self.row)
                        self.grid.append([' '] * self.columns)
                i = m.end()
                continue
            i += 1
            if b == 13: self.col = 0
            elif b == 10: self.down()
            elif b == 8: self.col = max(0, self.col - 1)
            elif 32 <= b < 127:
                self.grid[self.row][self.col] = chr(b)
                self.col = min(self.columns - 1, self.col + 1)
            # Non-ASCII activity glyphs are not readable as footer state.
        self.pending = data[i:]

    def tail(self, rows=2):
        """Bounded diagnostic view of the newest rows (never a pass oracle)."""
        return [''.join(row).rstrip() for row in self.grid[-rows:]]

    def idle(self):
        """True only on the cursor row of a settled, empty composer.

        The live tail floats at the terminal's existing cursor row, so it owns
        that row and not necessarily the physical bottom: read the cursor, never
        `grid[-1]`. A stale completed prompt further up, a transcript row that
        merely ends with `>`, a modal editor line (Search>/Settings>/
        Address>/Provider>/API key>) and the busy spinner are all rejected.
        """
        if not 0 <= self.row < len(self.grid):
            return False
        column = min(max(self.col, 0), self.columns)
        line = ''.join(self.grid[self.row])
        if line[column:].strip():
            return False  # Editor text follows the decoration: not empty.
        return _IDLE_COMPOSER.match(line[:column]) is not None

KEY = 'owned-loopback-background-fixture-key'
MODEL = 'fixture-model'
PRINT_PROMPT = 'background-print-proof start six owned services'
PRINT_ANSWER = 'background-print-final-answer-marker'
PTY_START_PROMPT = 'background-pty-start-marker'
PTY_MANAGE_PROMPT = 'background-pty-manage-marker'
PTY_FIRST_ANSWER = 'background-pty-first-answer-marker'
PTY_FINAL_ANSWER = 'background-pty-final-answer-marker'
SERVICES = 6
PRINT_STOPPED = 2
ID_PATTERN = re.compile(r'^[0-9a-f]+-[0-9]+$')
BOUND = 2 * 1024 * 1024

# Owned service: binds 127.0.0.1:0, reports pid/port through an owned marker
# file, prints one bounded startup line, then answers each request with its own
# identity. Nothing here reads project, HOME or application state.
SERVICE_SOURCE = '''\
import ctypes, os, socket, sys
marker, tag = sys.argv[1], sys.argv[2]
parent = os.getppid()
if sys.platform.startswith('linux'):
    PR_SET_PDEATHSIG = 1
    SIGKILL = 9
    if ctypes.CDLL(None, use_errno=True).prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) != 0:
        raise SystemExit('service: pdeathsig registration failed')
    # Registering after a parent death would leave an orphan serving forever.
    if os.getppid() != parent or parent <= 1:
        raise SystemExit('service: parent already gone before pdeathsig')
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', 0))
srv.listen(16)
port = srv.getsockname()[1]
print('SERVICE-%s-READY %d' % (tag, port), flush=True)
tmp = marker + '.tmp'
with open(tmp, 'w') as handle:
    handle.write('%d %d\\n' % (os.getpid(), port))
os.replace(tmp, marker)
while True:
    conn, _ = srv.accept()
    try:
        conn.recv(4096)
        body = ('SERVICE-%s-OK' % tag).encode()
        conn.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Length: ' + str(len(body)).encode()
                     + b'\\r\\nConnection: close\\r\\n\\r\\n' + body)
    except OSError:
        pass
    finally:
        conn.close()
'''


def service_command(tag):
    # exec keeps the service as Thin's direct child, so pdeathsig kills it.
    return 'exec python3 -u owned_service.py svc-%s.marker %s' % (tag, tag)


# ---------------------------------------------------------------------------
# Canonical chat history helpers (the wire carries only chat completions here)
# ---------------------------------------------------------------------------

def tool_history(body):
    calls, results = [], {}
    for message in body['messages']:
        for call in message.get('tool_calls') or []:
            calls.append({'id': call['id'], 'name': call['function']['name'],
                          'arguments': call['function']['arguments']})
        if message.get('role') == 'tool':
            results[message['tool_call_id']] = message['content']
    return calls, results


def real_users(body):
    out = []
    for message in body['messages']:
        if message.get('role') != 'user':
            continue
        text = message.get('content')
        if isinstance(text, list):
            text = ''.join(part.get('text', '') for part in text)
        # Environment/Memory reference material is user-role context, never a turn.
        if isinstance(text, str) and not text.startswith('[Context material'):
            out.append(text)
    return out


def calls_after_last_user(body):
    messages = body['messages']
    start = 0
    for index, message in enumerate(messages):
        if message.get('role') != 'user':
            continue
        text = message.get('content')
        if isinstance(text, str) and text.startswith('[Context material'):
            continue
        start = index
    sliced = dict(body)
    sliced['messages'] = messages[start:]
    return tool_history(sliced)


def message_text(message):
    text = message.get('content')
    if isinstance(text, list):
        text = ''.join(part.get('text', '') for part in text if isinstance(part, dict))
    return text if isinstance(text, str) else ''


def require_first_turn_closed(body):
    """Prove turn 1 really finished before the manage turn exists.

    A queued steering message also adds a user row, so a two-user history alone
    is not proof. The start tool call must have its paired tool result and the
    assistant reply after that result must carry the first answer.
    """
    messages = body['messages']
    start = None
    for index, message in enumerate(messages):
        if message.get('role') == 'user' and message_text(message) == PTY_START_PROMPT:
            start = index
            break
    assert start is not None, 'first user turn missing from the second request'
    manage_index = None
    for index in range(start + 1, len(messages)):
        message = messages[index]
        if message.get('role') == 'user' and PTY_MANAGE_PROMPT in message_text(message):
            manage_index = index
            break
    assert manage_index is not None, 'manage user turn missing from the second request'
    assert start < manage_index, 'manage turn must start after the first user turn'
    call_id, result_at = None, None
    for index in range(start + 1, manage_index):
        message = messages[index]
        for call in message.get('tool_calls') or []:
            assert call_id is None, 'first turn must issue exactly one bash call'
            assert call['function']['name'] == 'bash', 'first turn must start the service'
            call_id = call['id']
        if message.get('role') == 'tool' and message.get('tool_call_id') == call_id:
            result_at = index
    assert call_id is not None, 'first turn never issued its bash call'
    assert result_at is not None, 'first turn bash call has no paired tool result'
    for message in messages[result_at + 1:manage_index]:
        if message.get('role') == 'assistant' and PTY_FIRST_ANSWER in message_text(message):
            return
    raise AssertionError('first answer never followed the paired bash result')


def parse_json(text, label):
    assert isinstance(text, str), '%s result must be tool text' % label
    assert len(text) <= 256 * 1024, '%s result must stay bounded' % label
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        raise AssertionError('%s result must be one JSON object, got %r' % (label, text[:96]))
    assert isinstance(value, dict), '%s result must be a JSON object' % label
    return value


def tool_call(index, name, args, prefix='bg'):
    """One canonical tool call with an explicit id namespace.

    The call id must be unique across the whole App instance, not just within
    one task, so unrelated tasks in one instance use their own `prefix`.
    """
    return {'kind': 'tool', 'id': '%s%d' % (prefix, index), 'name': name, 'args': args}


def require_id(receipt, label):
    assert isinstance(receipt, dict), '%s receipt must be a JSON object' % label
    value = receipt.get('id')
    assert isinstance(value, str) and ID_PATTERN.match(value), \
        '%s must return an instance id, got %r' % (label, value)
    assert len(value) <= 64 and '\0' not in value, '%s id must be bounded' % label
    return value


def require_rejected(text, label):
    """Unknown/foreign ids are explicit errors, never an empty success."""
    assert isinstance(text, str) and text, '%s must be tool text' % label
    assert len(text) <= 4096, '%s error text must stay bounded' % label
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        parsed = text
    if isinstance(parsed, str):
        assert re.match(r'^[A-Za-z][A-Za-z0-9_]*$', parsed), \
            '%s must be a bare error name, got %r' % (label, text[:96])
        return
    assert isinstance(parsed, dict), '%s must be an encoded error object' % label
    flatten = json.dumps(parsed)
    assert 'SERVICE-' not in flatten, '%s leaked service output' % label
    assert parsed.get('is_error') is True or parsed.get('status') in ('failed', 'rejected') \
        or 'error' in parsed, '%s must be an explicit error, got %r' % (label, text[:96])


# ---------------------------------------------------------------------------
# Owned 127.0.0.1 model server
# ---------------------------------------------------------------------------

class Model(http.server.BaseHTTPRequestHandler):
    plan = None
    failed = None
    requests = 0

    def log_message(self, *_):
        pass

    def do_GET(self):
        type(self).failed = AssertionError('unexpected metadata/network GET')
        self.send_error(500)

    def do_POST(self):
        try:
            size = int(self.headers['Content-Length'])
            assert size <= 512 * 1024, 'request byte bound'
            body = json.loads(self.rfile.read(size))
            assert self.headers.get('Authorization') == 'Bearer ' + KEY, 'owned key header'
            assert body.get('stream') is True, 'all model requests must stream'
            assert body.get('tools'), 'background turns declare tools'
            type(self).requests += 1
            value = type(self).plan(body)
            if value['kind'] == 'tool':
                delta = {'tool_calls': [{'index': 0, 'id': value['id'], 'type': 'function',
                                         'function': {'name': value['name'],
                                                      'arguments': json.dumps(value['args'])}}]}
                finish = 'tool_calls'
            else:
                delta, finish = {'content': value['text']}, 'stop'
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            frames = [
                {'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]},
                {'choices': [{'index': 0, 'delta': {}, 'finish_reason': finish}],
                 'usage': {'prompt_tokens': 100, 'completion_tokens': 5, 'total_tokens': 105}},
            ]
            for frame in frames:
                self.wfile.write(b'data: ' + json.dumps(frame).encode() + b'\n\n')
            self.wfile.write(b'data: [DONE]\n\n')
        except Exception as error:  # noqa: BLE001 - reported by the runner
            type(self).failed = error
            try:
                self.send_error(500)
            except Exception:  # noqa: BLE001
                pass


# ---------------------------------------------------------------------------
# Owned service liveness probes (real sockets, never sleeps as proof)
# ---------------------------------------------------------------------------

class Owned:
    def __init__(self, project):
        self.project = project
        self.alive = {}

    def marker(self, tag):
        return self.project / ('svc-%s.marker' % tag)

    def probe(self, tag):
        pid, port = self.alive[tag]
        with socket.create_connection(('127.0.0.1', port), timeout=2) as conn:
            conn.sendall(b'GET / HTTP/1.0\r\n\r\n')
            reply = conn.recv(4096)
        assert ('SERVICE-%s-OK' % tag).encode() in reply, 'service %s did not answer' % tag
        assert Path('/proc/%d' % pid).exists(), 'service %s pid disappeared' % tag
        return pid, port

    def wait_ready(self, tag, deadline=8.0):
        """Boundedly wait for the service's own bound port, then probe it."""
        until = time.monotonic() + deadline
        while time.monotonic() < until:
            try:
                text = self.marker(tag).read_text()
            except OSError:
                text = ''
            fields = text.split()
            if len(fields) == 2 and fields[0].isdigit() and fields[1].isdigit():
                self.alive[tag] = (int(fields[0]), int(fields[1]))
                try:
                    return self.probe(tag)
                except OSError:
                    pass
            time.sleep(0.02)
        raise AssertionError('service %s never bound an owned loopback socket' % tag)

    def wait_stopped(self, tag, deadline=10.0):
        pid, port = self.alive[tag]
        until = time.monotonic() + deadline
        while time.monotonic() < until:
            if not Path('/proc/%d' % pid).exists():
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=0.5):
                        pass
                except OSError:
                    return
            time.sleep(0.02)
        raise AssertionError('stopped service %s still owns pid/socket' % tag)


# ---------------------------------------------------------------------------
# Planned model replies
# ---------------------------------------------------------------------------

def print_plan(owned, state):
    def plan(body):
        calls, results = tool_history(body)
        done = len(calls)
        if 0 < done <= SERVICES:
            receipt = parse_json(results[calls[done - 1]['id']], 'bash')
            state['ids'].append(require_id(receipt, 'bash background start'))
            owned.wait_ready(str(done - 1))
        if done < SERVICES:
            return tool_call(done, 'bash', {'command': service_command(str(done)), 'background': True})
        if done == SERVICES:
            return tool_call(done, 'background', {'action': 'list', 'limit': 20})
        if done == SERVICES + 1:
            listed = parse_json(results[calls[done - 1]['id']], 'background list')
            flattened = json.dumps(listed)
            for identity in state['ids']:
                assert identity in flattened, 'list lost a started service'
            return tool_call(done, 'background', {'action': 'logs', 'id': state['ids'][PRINT_STOPPED],
                                                  'stdout_offset': 0, 'stderr_offset': 0})
        if state['phase'] == 0:
            logs = parse_json(results[calls[done - 1]['id']], 'background logs')
            if 'SERVICE-%d-READY' % PRINT_STOPPED not in json.dumps(logs):
                state['log_runs'] += 1
                assert state['log_runs'] <= 8, 'service stdout never reached the bounded log ring'
                return tool_call(done, 'background', {'action': 'logs', 'id': state['ids'][PRINT_STOPPED],
                                                      'stdout_offset': 0, 'stderr_offset': 0})
            state['phase'] = 1
            return tool_call(done, 'background', {'action': 'stop', 'id': state['ids'][PRINT_STOPPED]})
        if state['phase'] == 1:
            stopped = parse_json(results[calls[done - 1]['id']], 'background stop')
            assert state['ids'][PRINT_STOPPED] in json.dumps(stopped), 'stop must echo the stopped id'
            owned.wait_stopped(str(PRINT_STOPPED))
            for sibling in range(SERVICES):
                if sibling == PRINT_STOPPED:
                    continue
                owned.probe(str(sibling))
            state['phase'] = 2
            return tool_call(done, 'background', {'action': 'status', 'id': state['ids'][PRINT_STOPPED]})
        if state['phase'] == 2:
            status = parse_json(results[calls[done - 1]['id']], 'background status')
            assert state['ids'][PRINT_STOPPED] in json.dumps(status), 'status must echo the id'
            state['phase'] = 3
            return tool_call(done, 'background', {'action': 'stop', 'id': state['ids'][PRINT_STOPPED]})
        if state['phase'] == 3:
            again = parse_json(results[calls[done - 1]['id']], 'background repeat stop')
            assert state['ids'][PRINT_STOPPED] in json.dumps(again), 'repeat stop must serve the record'
            state['phase'] = 4
            return tool_call(done, 'background', {'action': 'status', 'id': 'deadbeef-4242'})
        if state['phase'] == 4:
            require_rejected(results[calls[done - 1]['id']], 'unknown background id')
            state['phase'] = 5
            return {'kind': 'text', 'text': PRINT_ANSWER}
        raise AssertionError('unexpected extra print-model request')

    return plan


def pty_plan(owned, state):
    def plan(body):
        users = real_users(body)
        if users == [PTY_START_PROMPT] and state['turn'] == 0:
            calls, results = calls_after_last_user(body)
            if not calls:
                return tool_call(0, 'bash', {'command': service_command('pty'), 'background': True},
                                 prefix='pty-start-')
            assert calls[0]['name'] == 'bash', 'first task must start the service'
            state['pty_id'] = require_id(parse_json(results[calls[0]['id']], 'bash'), 'bash background start')
            owned.wait_ready('pty')
            state['turn'] = 1
            return {'kind': 'text', 'text': PTY_FIRST_ANSWER}
        assert state['turn'] == 1, 'manage turn before the start turn closed: %r' % (state['turn'],)
        assert users == [PTY_START_PROMPT, PTY_MANAGE_PROMPT], 'unexpected user turns: %r' % (users,)
        require_first_turn_closed(body)
        calls, results = calls_after_last_user(body)
        done = len(calls)
        # The service must still answer after its starting task finished, but a
        # running stop is already in flight once the receipt was parsed.
        if done == 0 or state['phase'] < 2:
            owned.probe('pty')
        if done == 0:
            return tool_call(done, 'background', {'action': 'status', 'id': state['pty_id']},
                             prefix='pty-manage-')
        if state['phase'] == 0:
            status = parse_json(results[calls[done - 1]['id']], 'background status')
            assert state['pty_id'] in json.dumps(status), 'status must echo the started id'
            state['phase'] = 1
            return tool_call(done, 'background', {'action': 'logs', 'id': state['pty_id'],
                                                  'stdout_offset': 0, 'stderr_offset': 0},
                             prefix='pty-manage-')
        if state['phase'] == 1:
            logs = parse_json(results[calls[done - 1]['id']], 'background logs')
            if 'SERVICE-pty-READY' not in json.dumps(logs):
                state['log_runs'] += 1
                assert state['log_runs'] <= 8, 'service stdout never reached the bounded log ring'
                return tool_call(done, 'background', {'action': 'logs', 'id': state['pty_id'],
                                                      'stdout_offset': 0, 'stderr_offset': 0},
                                 prefix='pty-manage-')
            state['phase'] = 2
            return tool_call(done, 'background', {'action': 'stop', 'id': state['pty_id']},
                             prefix='pty-manage-')
        if state['phase'] == 2:
            stopped = parse_json(results[calls[done - 1]['id']], 'background stop')
            assert state['pty_id'] in json.dumps(stopped), 'stop must echo the id'
            owned.wait_stopped('pty')
            state['phase'] = 3
            return {'kind': 'text', 'text': PTY_FINAL_ANSWER}
        raise AssertionError('unexpected extra pty-model request')

    return plan


# ---------------------------------------------------------------------------
# Owned CLI/PTY runs
# ---------------------------------------------------------------------------

def write_config(home, url):
    (home / '.thin').mkdir(parents=True, exist_ok=True)
    config = {
        'memory': {'auto': False},
        'llm': {'default': 'owned/' + MODEL, 'providers': {'owned': {
            'base_url': url,
            'api_key': KEY,
            'models': {MODEL: {'protocol': 'chat', 'context_tokens': 32768}},
        }}},
        'limits': {'low_price_input': False, 'safety_tokens': 100,
                   'request_timeout_ms': 10000, 'task_timeout_ms': 30000,
                   'command_timeout_ms': 8000, 'cleanup_grace_ms': 200,
                   'cleanup_timeout_ms': 4000},
    }
    path = home / '.thin' / 'config.json'
    payload = (json.dumps(config) + '\n').encode()
    path.write_bytes(payload)
    path.chmod(0o600)
    return path, payload


def prepare(workspace, name, url):
    root = workspace / name
    home, project = root / 'home', root / 'project'
    project.mkdir(parents=True)
    (project / 'owned_service.py').write_text(SERVICE_SOURCE)
    path, payload = write_config(home, url)
    return home, project, path, payload


def run_print(app, workspace, url):
    home, project, config_path, config_bytes = prepare(workspace, 'print', url)
    owned, state = Owned(project), {'ids': [], 'log_runs': 0, 'phase': 0}
    Model.plan = print_plan(owned, state)
    Model.failed = None
    child = subprocess.Popen(
        [app, '--print', PRINT_PROMPT, '--no-log', '--no-model-auto-refresh'],
        cwd=project, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env={'PATH': '/usr/bin:/bin', 'HOME': str(home), 'LANG': 'C.UTF-8', 'TERM': 'xterm-256color'},
        start_new_session=True)
    try:
        out, err = child.communicate(timeout=60)
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=5)
    if Model.failed:
        raise Model.failed
    stdout, stderr = out.decode('utf-8', 'replace'), err.decode('utf-8', 'replace')
    assert child.returncode == 0, 'print run failed: %s' % stderr[-400:]
    assert PRINT_ANSWER in stdout, 'print final answer missing'
    assert KEY not in stdout and KEY not in stderr, 'credential leaked to local output'
    assert '\x1b' not in stdout, 'headless output carried terminal escapes'
    assert config_path.read_bytes() == config_bytes, 'background starts rewrote the config'
    assert not (home / '.thin' / 'sessions').exists(), 'headless run created a session'
    assert not (project / '.thin' / 'sessions').exists(), 'background start created a session'
    # Exit cleanup: every service must be canceled and joined by App.deinit.
    for index in range(SERVICES):
        owned.wait_stopped(str(index))
    return {'case': 'print', 'requests': Model.requests, 'services': SERVICES,
            'stopped': state['ids'][PRINT_STOPPED], 'ids': list(state['ids'])}


def run_pty(app, workspace, url):
    home, project, config_path, config_bytes = prepare(workspace, 'pty', url)
    # The foreground starts its own AF_UNIX worker under $XDG_RUNTIME_DIR/thin.
    # An owned short base keeps every socket inside this fixture instead of the
    # shared /tmp/thin-<uid> fallback; it is removed with the workspace context.
    runtime = workspace / 'runtime'
    runtime.mkdir(mode=0o700)
    assert runtime.is_absolute() and (runtime.stat().st_mode & 0o777) == 0o700, 'owned runtime must be an absolute 0700 directory'
    assert len(str(runtime)) + 14 + 32 + 5 <= 107, 'AF_UNIX socket path budget exceeded'
    owned, state = Owned(project), {'turn': 0, 'phase': 0, 'log_runs': 0, 'pty_id': None}
    Model.plan = pty_plan(owned, state)
    Model.failed = None
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 90, 0, 0))
    original = termios.tcgetattr(slave)

    def child_setup():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    child = subprocess.Popen([app, '--no-log', '--no-model-auto-refresh'], stdin=slave,
                             stdout=slave, stderr=slave, cwd=project, preexec_fn=child_setup,
                             env={'PATH': '/usr/bin:/bin', 'HOME': str(home),
                                  'XDG_RUNTIME_DIR': str(runtime),
                                  'LANG': 'C.UTF-8', 'TERM': 'xterm-256color'})
    capture = bytearray()
    screen = Screen(90)

    def settled(marker=b''):
        """True only when the newest completed frame is idle and nothing is mid-frame.

        `marker` must already be on screen and inside that same completed frame,
        so a body-only half frame followed by a stale idle footer can never pass.
        """
        end = capture.rfind(FRAME_END)
        if end < 0 or capture.rfind(SYNC_BEGIN) > end:
            return False
        if marker:
            position = capture.find(marker)
            if position < 0 or position > end:
                return False
        return screen.idle()

    def diagnostic(label):
        # Owned fake fixture only: bounded frames, no credential or model text.
        return ('pty wait not satisfied: %s; requests=%d turn=%d phase=%d screen=%r capture=%r'
                % (label, Model.requests, state['turn'], state['phase'],
                   screen.tail(2), bytes(capture[-1200:])))

    def pump_until(predicate, label, timeout=60):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if Model.failed:
                raise Model.failed
            if predicate():
                return
            ready, _, _ = select.select([master], [], [], min(0.05, max(0.0, deadline - time.monotonic())))
            if ready:
                try:
                    data = os.read(master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    data = b''
                if data:
                    capture.extend(data)
                    assert len(capture) <= BOUND, 'pty output bound'
                    screen.feed(data)
            if child.poll() is not None and not predicate():
                raise AssertionError('interactive app exited early during %s: %s'
                                     % (label, child.returncode))
        raise AssertionError(diagnostic(label) + '; bounded wait expired')

    try:
        pump_until(settled, 'initial idle frame')
        os.write(master, PTY_START_PROMPT.encode() + b'\r')
        # An answer fragment is not proof that the first Task settled: the next
        # prompt may only be sent once a completed frame carries the answer and
        # ends on an idle composer, otherwise it becomes steering for that turn.
        pump_until(lambda: settled(PTY_FIRST_ANSWER.encode()), 'first answer settled frame')
        # The first task only sends its final once the service really answered;
        # confirm that marker after the frame, because waiting on it earlier
        # leaves the foreground PTY unread while the app is still writing.
        owned.wait_ready('pty')
        os.write(master, PTY_MANAGE_PROMPT.encode() + b'\r')
        pump_until(lambda: settled(PTY_FINAL_ANSWER.encode()), 'final answer settled frame')
        owned.wait_stopped('pty')
        os.write(master, b'\x04')
        pump_until(lambda: child.poll() is not None, 'exit after Ctrl-D')
        assert child.wait(timeout=10) == 0, 'interactive app exit status'
        assert termios.tcgetattr(slave) == original, 'termios was not restored'
        output = capture.decode('utf-8', 'replace')
        assert KEY not in output, 'credential leaked to the terminal'
        assert config_path.read_bytes() == config_bytes, 'interactive run rewrote the config'
        assert not (project / '.thin' / 'sessions').exists(), 'interactive run created a session'
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
        os.close(master)
        os.close(slave)
    return {'case': 'pty', 'requests': Model.requests, 'turns': 2, 'id': state['pty_id']}


def main():
    if len(sys.argv) != 2 or sys.platform != 'linux':
        raise SystemExit('usage: python3 tests/product/background_mock.py /absolute/path/thin')
    app = str(Path(sys.argv[1]).resolve(strict=True))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Model)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = 'http://127.0.0.1:%d/v1' % server.server_port
    evidence = []
    try:
        with tempfile.TemporaryDirectory(prefix='thin-background-') as base:
            workspace = Path(base)
            evidence.append(run_print(app, workspace, url))
            print('PASS background print: 6 concurrent services, list/logs/status/stop, '
                  'repeat stop, unknown id, exit reclaim')
            evidence.append(run_pty(app, workspace, url))
            print('PASS background pty: one App instance kept the service across two tasks '
                  'and stopped it explicitly')
            (workspace / 'evidence.json').write_text(json.dumps({
                'cases': evidence,
                'ownedLoopbackServices': SERVICES,
                'fixedConcurrencyLimit': None,
                'startupReadiness': 'service-bound-socket-probe',
                'echoStoppedServiceIsolated': True,
                'exitCleanupJoined': True,
                'crossTaskKeepAlive': True,
            }, indent=2) + '\n')
        print('PASS test-background: owned loopback services, no real API')
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


if __name__ == '__main__':
    main()
