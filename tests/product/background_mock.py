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
import contextlib
import errno
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
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
DARWIN = sys.platform == 'darwin'
INTERRUPTS = {signal.SIGTERM, signal.SIGINT}
_controller_interrupted = False
PASS_LINES = (
    'PASS background print: 6 concurrent services, list/logs/status/stop, '
    'repeat stop, unknown id, exit reclaim',
    'PASS background pty: one App instance kept the service across two tasks '
    'and stopped it explicitly',
    'PASS test-background: owned loopback services, no real API',
)

# Owned service: binds 127.0.0.1:0, reports pid/port through an owned marker
# file, prints one bounded startup line, then answers each request with its own
# identity. Only owned marker/lease files are used, never user configuration
# or application state.
SERVICE_SOURCE = '''\
import ctypes, os, socket, sys, time
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
# Only exceptional/final fixture teardown removes this lease. Normal stop/exit
# assertions run before that, so the fallback cannot make broken App cleanup pass.
# The last-resort deadline also bounds an orphan if the runner itself is killed;
# it is deliberately longer than the existing per-case wait budgets combined.
lease = 'owned-service.lease'
until = time.monotonic() + 600
if not os.path.exists(lease):
    raise SystemExit('service: fixture already closed')
srv = socket.socket()
srv.settimeout(0.25)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', 0))
srv.listen(16)
port = srv.getsockname()[1]
print('SERVICE-%s-READY %d' % (tag, port), flush=True)
tmp = marker + '.tmp'
with open(tmp, 'w') as handle:
    handle.write('%d %d\\n' % (os.getpid(), port))
os.replace(tmp, marker)
while os.path.exists(lease) and time.monotonic() < until:
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        continue
    try:
        conn.settimeout(0.5)
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
    # exec keeps the service as Thin's direct child (including Linux pdeathsig).
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

def pid_state(pid):
    """Conservative current-PID observation, not authority to signal that PID.

    kill(pid, 0) sends no signal. ESRCH is corroborated with POSIX ps because
    Darwin may expose zombies differently from live processes. A zombie is
    still present/unreaped, never cleanup success; permissions, query failures
    and inconsistent snapshots are unknown, never evidence of reclamation.
    PID reuse can therefore fail a test conservatively, but cannot kill anyone.
    """
    assert pid > 1, 'owned service must have a positive, non-init pid'
    try:
        os.kill(pid, 0)
        exists = True
    except ProcessLookupError:
        exists = False
    except OSError:
        return 'unknown'
    try:
        result = subprocess.run(
            ['/bin/ps', '-p', str(pid), '-o', 'pid=', '-o', 'stat='],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}, timeout=2, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return 'unknown'
    fields = result.stdout.split()
    if result.returncode == 1 and not fields and not result.stderr.strip():
        return 'unknown' if exists else 'gone'
    if (result.returncode != 0 or len(fields) != 2 or fields[0] != str(pid).encode()
            or not re.fullmatch(rb'[A-Za-z][A-Za-z0-9+<NLsl-]*', fields[1])):
        return 'unknown'
    if fields[1].startswith(b'Z'):
        return 'zombie'
    return 'present' if exists else 'unknown'


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
        assert pid_state(pid) == 'present', 'service %s pid is not provably live' % tag
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
            if (len(fields) == 2 and fields[0].isdigit() and fields[1].isdigit()
                    and int(fields[0]) > 1 and 0 < int(fields[1]) < 65536):
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
            if pid_state(pid) == 'gone':
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=0.5):
                        pass
                except ConnectionRefusedError:
                    return
                except OSError:
                    pass  # Timeout/permissions are not proof that a socket closed.
            time.sleep(0.02)
        raise AssertionError('stopped service %s still owns pid/socket' % tag)

    def cancel(self):
        # Never TERM/KILL a cached service PID: Thin may already have reaped it.
        # A private lease lets only our service code stop itself on failure.
        (self.project / 'owned-service.lease').unlink(missing_ok=True)

    def wait_cleanup(self):
        # A failure can occur after launch but before wait_ready records a PID.
        for marker in self.project.glob('svc-*.marker'):
            fields = marker.read_text().split()
            assert (len(fields) == 2 and fields[0].isdigit() and fields[1].isdigit()
                    and int(fields[0]) > 1 and 0 < int(fields[1]) < 65536), 'invalid owned marker'
            self.alive[marker.name[4:-7]] = (int(fields[0]), int(fields[1]))
        for tag in list(self.alive):
            self.wait_stopped(tag)


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
    (project / 'owned-service.lease').touch(mode=0o600)
    path, payload = write_config(home, url)
    return home, project, path, payload


def owned_env(home, workspace):
    # Both cases avoid shared runtime/config/cache locations. A short /tmp base
    # is selected in main: Darwin sockaddr_un.sun_path is only 104 bytes.
    runtime = workspace / 'runtime'
    runtime.mkdir(mode=0o700, exist_ok=True)
    assert runtime.is_absolute() and (runtime.stat().st_mode & 0o777) == 0o700, 'owned runtime must be an absolute 0700 directory'
    assert len(os.fsencode(runtime)) + 14 + 32 + 5 < 104, 'AF_UNIX socket path budget exceeded'
    return {'PATH': '/usr/bin:/bin', 'HOME': str(home),
            'XDG_RUNTIME_DIR': str(runtime), 'XDG_CONFIG_HOME': str(home / '.config'),
            'XDG_CACHE_HOME': str(home / '.cache'), 'XDG_DATA_HOME': str(home / '.local/share'),
            'XDG_STATE_HOME': str(home / '.local/state'),
            'LANG': 'C.UTF-8', 'TERM': 'xterm-256color'}


class ControllerInterrupted(Exception):
    pass


def on_controller_interrupt(_signum, _frame):
    global _controller_interrupted
    # Repeated watchdog signals must not interrupt cleanup already unwinding.
    if not _controller_interrupted:
        _controller_interrupted = True
        raise ControllerInterrupted()


@contextlib.contextmanager
def ownership_handoff():
    if not DARWIN:
        yield None
        return
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, INTERRUPTS)
    try:
        yield previous
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def restore_child_signals(mask):
    for sig in INTERRUPTS | {signal.SIGHUP, signal.SIGTTOU}:
        signal.signal(sig, signal.SIG_DFL)
    signal.pthread_sigmask(signal.SIG_SETMASK, mask)


def stop_child(child):
    # poll/wait reap the child. Never signal its cached PID/PGID afterwards.
    # Each CLI owns its session; separate worker/service groups are not targets.
    if child is None or child.poll() is not None:
        return
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        if child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        child.wait(timeout=5)


def cleanup(owned, child, fds=()):
    with ownership_handoff():
        owned.cancel()
        try:
            stop_child(child)
        finally:
            try:
                if child is not None:
                    for stream in (child.stdin, child.stdout, child.stderr):
                        if stream is not None:
                            stream.close()
            finally:
                try:
                    for fd in fds:
                        if fd is not None:
                            os.close(fd)
                finally:
                    owned.wait_cleanup()


def run_print(app, workspace, url, start_server=None):
    home, project, config_path, config_bytes = prepare(workspace, 'print', url)
    owned, state = Owned(project), {'ids': [], 'log_runs': 0, 'phase': 0}
    Model.plan = print_plan(owned, state)
    Model.failed = None
    child = None
    try:
        if DARWIN:
            assert threading.active_count() == 1, 'single-threaded preexec controller required'
        with ownership_handoff() as child_mask:
            child = subprocess.Popen(
                [app, '--print', PRINT_PROMPT, '--no-model-auto-refresh'],
                cwd=project, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=owned_env(home, workspace), start_new_session=True,
                preexec_fn=(lambda: restore_child_signals(child_mask)) if DARWIN else None)
        if start_server is not None:
            # Server/request threads inherit blocked interrupts, leaving only
            # the controller main thread eligible for owner cancellation.
            with ownership_handoff():
                start_server()
        out, err = child.communicate(timeout=60)
        if Model.failed:
            raise Model.failed
        stdout, stderr = out.decode('utf-8', 'replace'), err.decode('utf-8', 'replace')
        assert child.returncode == 0, 'print run failed: %s' % stderr[-400:]
        assert PRINT_ANSWER in stdout, 'print final answer missing'
        assert KEY not in stdout and KEY not in stderr, 'credential leaked to local output'
        assert '\x1b' not in stdout, 'headless output carried terminal escapes'
        assert config_path.read_bytes() == config_bytes, 'background starts rewrote the config'
        assert not (home / '.thin' / 'sessions').exists(), 'headless run created a session'
        assert list((project / '.thin' / 'sessions').glob('*.jsonl')), 'accepted headless session not recorded'
        # Exit cleanup: every service must be canceled and joined by App.deinit.
        # This proof precedes the fixture-only lease cancellation in finally.
        for index in range(SERVICES):
            owned.wait_stopped(str(index))
        return {'case': 'print', 'requests': Model.requests, 'services': SERVICES,
                'stopped': state['ids'][PRINT_STOPPED], 'ids': list(state['ids'])}
    finally:
        cleanup(owned, child)


def run_pty(app, workspace, url, start_server=None):
    home, project, config_path, config_bytes = prepare(workspace, 'pty', url)
    owned, state = Owned(project), {'turn': 0, 'phase': 0, 'log_runs': 0, 'pty_id': None}
    Model.plan = pty_plan(owned, state)
    Model.failed = None
    child = None
    master = slave = None
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

    def child_setup():
        if DARWIN:
            # Stay in the controller's session, but own the foreground group.
            signal.signal(signal.SIGTTOU, signal.SIG_IGN)
            os.setpgid(0, 0)
            os.tcsetpgrp(0, os.getpid())
            restore_child_signals(child_mask)
        else:
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    try:
        # Setup/exec failures share the same cleanup as all PTY wait failures.
        with ownership_handoff():
            master, slave = pty.openpty()
        if DARWIN:
            assert os.getsid(0) == os.getpid(), 'private session controller required'
            assert all(not os.isatty(fd) for fd in (0, 1, 2)), 'non-TTY controller stdio required'
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            signal.signal(signal.SIGTTOU, signal.SIG_IGN)
            # Acquire only this just-opened slave; retain it through Thin's exit.
            fcntl.ioctl(slave, 0x20007461, 0)  # Darwin TIOCSCTTY, SDK-verified.
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 90, 0, 0))
        original = termios.tcgetattr(slave)
        original_flags = fcntl.fcntl(slave, fcntl.F_GETFL) if DARWIN else None
        if DARWIN:
            assert threading.active_count() == 1, 'single-threaded preexec controller required'
        with ownership_handoff() as child_mask:
            child = subprocess.Popen([app, '--no-model-auto-refresh'], stdin=slave,
                                     stdout=slave, stderr=slave, cwd=project, preexec_fn=child_setup,
                                     env=owned_env(home, workspace))
            # child ownership is established before any fallible parent setup.
            if DARWIN:
                try:
                    os.setpgid(child.pid, child.pid)
                except OSError as error:
                    if error.errno != errno.EACCES:
                        raise
                    assert os.getpgid(child.pid) == child.pid, 'owned child group mismatch'
                os.tcsetpgrp(slave, child.pid)
        if start_server is not None:
            # Darwin forks before any HTTP thread exists; the listener is bound.
            # Block owner interrupts in the new server and its request threads.
            with ownership_handoff():
                start_server()
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
        restored = termios.tcgetattr(slave)
        if DARWIN:
            # Only verified kernel history bits are normalized, not configuration.
            original = list(original)
            restored[3] &= ~termios.PENDIN
            original[3] &= ~termios.PENDIN
            flags = fcntl.fcntl(slave, fcntl.F_GETFL)
            assert (flags & ~0x00010000) == (original_flags & ~0x00010000), \
                'tty flags were not restored'  # Darwin FWASWRITTEN.
        assert restored == original, 'termios was not restored'
        output = capture.decode('utf-8', 'replace')
        assert KEY not in output, 'credential leaked to the terminal'
        assert config_path.read_bytes() == config_bytes, 'interactive run rewrote the config'
        assert list((project / '.thin' / 'sessions').glob('*.jsonl')), 'accepted interactive session not recorded'
    finally:
        cleanup(owned, child, (master, slave))
    return {'case': 'pty', 'requests': Model.requests, 'turns': 2, 'id': state['pty_id']}


def close_model_server(server, thread):
    try:
        if thread.is_alive():
            server.shutdown()
    finally:
        # Darwin uses non-daemon request threads: finish them before the next
        # Python preexec_fn, not merely the serve_forever thread.
        server.server_close()
        if thread.ident is not None:
            thread.join(timeout=5)
            assert not thread.is_alive(), 'owned model server did not stop'


def stop_controller(controller):
    # Only the exact, unreaped controller is signalled, never its whole session.
    if controller.poll() is not None:
        return
    controller.terminate()
    try:
        controller.wait(timeout=12)
    except subprocess.TimeoutExpired:
        if controller.poll() is None:
            controller.kill()
        controller.wait(timeout=5)


def run_controller(app):
    controller = None
    try:
        with ownership_handoff():
            controller = subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), '--owned-controller', app],
                start_new_session=True, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, err = controller.communicate(timeout=420)
        # Never forward captured terminal/model text, exception messages or keys.
        # Failures expose only a strictly parsed type and source line number.
        if controller.returncode != 0:
            for line in err.splitlines():
                match = re.fullmatch(
                    rb'FAIL background controller: ([A-Za-z_][A-Za-z0-9_]{0,79}) line=([0-9]{1,7})', line)
                if match:
                    print('FAIL background controller: %s line=%d'
                          % (match[1].decode('ascii'), int(match[2])), file=sys.stderr)
            raise AssertionError('owned background controller failed')
        assert out.splitlines() == [line.encode('ascii') for line in PASS_LINES], \
            'owned controller did not return the fixed pass evidence'
        for line in PASS_LINES:
            print(line)
    finally:
        if controller is not None:
            with ownership_handoff():
                try:
                    # TERM unwinds controller finally blocks. Allow its owned
                    # Thin cleanup/server teardown 12s before last-resort KILL.
                    stop_controller(controller)
                finally:
                    controller.stdout.close()
                    controller.stderr.close()


def report_safe_failure(error):
    source_line = 0
    trace = error.__traceback__
    while trace is not None:
        if trace.tb_frame.f_code.co_filename == __file__:
            source_line = trace.tb_lineno
        trace = trace.tb_next
    name = type(error).__name__
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,79}', name):
        name = 'Exception'
    print('FAIL background controller: %s line=%d' % (name, source_line), file=sys.stderr)


def main():
    private_controller = DARWIN and len(sys.argv) == 3 and sys.argv[1] == '--owned-controller'
    if private_controller:
        assert os.getsid(0) == os.getpid(), 'private session controller required'
        assert all(not os.isatty(fd) for fd in (0, 1, 2)), 'non-TTY controller stdio required'
        # Handlers are installed before releasing an inherited owner interrupt.
        signal.pthread_sigmask(signal.SIG_UNBLOCK, INTERRUPTS)
    elif len(sys.argv) != 2 or sys.platform not in ('linux', 'darwin'):
        raise SystemExit('usage: python3 tests/product/background_mock.py /absolute/path/thin')
    app = str(Path(sys.argv[2] if private_controller else sys.argv[1]).resolve(strict=True))
    if DARWIN and not private_controller:
        run_controller(app)
        return
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Model)
    if DARWIN:
        server.daemon_threads = False
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    if not DARWIN:
        thread.start()
    url = 'http://127.0.0.1:%d/v1' % server.server_port
    evidence = []
    try:
        with tempfile.TemporaryDirectory(prefix='thin-bg-', dir='/tmp') as base:
            workspace = Path(base)
            evidence.append(run_print(app, workspace, url, thread.start if DARWIN else None))
            print(PASS_LINES[0])
            if DARWIN:
                # Print and PTY remain the same two cases. A fresh loopback
                # listener lets all print handlers join before PTY fork/setup.
                close_model_server(server, thread)
                server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Model)
                server.daemon_threads = False
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                url = 'http://127.0.0.1:%d/v1' % server.server_port
            evidence.append(run_pty(app, workspace, url, thread.start if DARWIN else None))
            print(PASS_LINES[1])
            (workspace / 'evidence.json').write_text(json.dumps({
                'cases': evidence,
                'ownedLoopbackServices': SERVICES,
                'fixedConcurrencyLimit': None,
                'startupReadiness': 'service-bound-socket-probe',
                'echoStoppedServiceIsolated': True,
                'exitCleanupJoined': True,
                'crossTaskKeepAlive': True,
            }, indent=2) + '\n')
        print(PASS_LINES[2])
    finally:
        if DARWIN:
            close_model_server(server, thread)
        else:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


if __name__ == '__main__':
    def interrupted(signum, _frame):
        # A runner watchdog's TERM must unwind the owned-process finally blocks.
        raise SystemExit(128 + signum)

    if DARWIN:
        for sig in INTERRUPTS:
            signal.signal(sig, on_controller_interrupt)
        try:
            main()
        except (Exception, KeyboardInterrupt, SystemExit) as error:
            report_safe_failure(error)
            sys.exit(1)
    else:
        signal.signal(signal.SIGTERM, interrupted)
        main()
