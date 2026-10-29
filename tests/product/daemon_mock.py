#!/usr/bin/env python3
"""Owned daemon/session acceptance: daemon process, PTY clients, offline approval.

Build interface: python3 tests/product/daemon_mock.py /absolute/path/thin

Everything here is an owned fixture, never a stub of the product:

* a temporary HOME/projects/XDG_RUNTIME_DIR tree (0700) created by this script,
* one literal 127.0.0.1 Chat/SSE server whose responses are gated by this script,
* an inline fake key inside the owned config (0600), no environment credential,
* real `thin` processes: one `--daemon` Popen, real PTY `--connect`/`--attach`
  clients, a real foreground `thin`, real `--resume` clients,
* one owned background service per daemon-reclaim case (bound 127.0.0.1:0, its
  own pid/port marker file) so SIGTERM convergence is observed on a real port.

Isolation rules:
* HOME, XDG_RUNTIME_DIR, XDG_CONFIG_HOME/CACHE/STATE/DATA and TMPDIR are inside
  the owned workspace; the fixture never reads /root/.thin or any user config.
* Only loopback HTTP is used; nothing listens on or touches a real SSH port.
* Only PIDs this script created are signalled. Teardown never calls pkill, never
  scans the whole process table, and never re-signals an already reaped PID.
* No product wire/private AF_UNIX message format is asserted: the private
  endpoint layout and IPC framing stay backend-owned. Cases are black-box CLI
  + PTY, with session IDs read from the public `.thin/sessions/<32hex>.session`
  names or from the public `/ls` display.

Coverage (one case per user-visible requirement):
1. missing service: `--connect`/`--attach` fail explicitly with no spawned
   service and no inference; plain `thin` is not a daemon; mode conflicts are
   rejected by the CLI before any UI/session exists.
2. daemon start, PTY `--connect`, `/cd` into an owned project, real inference
   POST gated by this script, SIGKILL of the front-end process (not Ctrl-C),
   then release: the daemon worker finishes, exactly one request was made, and
   `--attach <id>` replays the completed result without new inference.
3. two project sessions really run in parallel (both requests gated at once),
   each bash `pwd` proves its own root, a failed `/cd` keeps the previous
   launcher directory, `/ls --running` reflects live sessions, and repeated
   reconnects create no extra empty session.
4. one writable console: a second `--attach` without `--takeover` is refused
   and does not displace the controller; explicit `--takeover` replaces it and
   a stale controller's Ctrl-C cannot cancel the running task.
5. ownership boundaries: foreground-created session attached by a daemon client
   (takeover view only, no owner migration) and daemon-created session attached
   by an explicit `--takeover` client while the daemon console still holds the
   writable lease; after the source owner closes, `--resume` sends no HTTP,
   re-executes no tool and cannot steal the writer lock.
6. an offline dangerous `rm -rf` stays pending with no client (the owned
   directory survives), and a reattached console sees the full approval popup,
   approves it explicitly, and the side effect happens exactly once.
7. daemon SIGTERM cancels workers and owned background services: daemon, worker
   and service PIDs converge, the service port closes, no stale endpoint keeps
   accepting, and artifact permissions stay private (0700/0600). The owned
   service of this case exits only after a delay following TERM, so the daemon
   must wait for the worker's own cleanup budget instead of killing that worker
   in a fixed short grace.

Nothing here is claimed to pass: this file is pre-written against the approved
CLI/ownership contract and is only executed by the merged backend/UI/CLI.
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
import shlex
import signal
import socket
import stat as stmod
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

ACK = b'\x1b[?25h'
SYNC_BEGIN = b'\x1b[?2026h'
FRAME_END = b'\x1b[?2026l' + ACK
CSI = re.compile(rb'\x1b\[([0-9;?]*)([@-~])')
HEX32 = re.compile(r'(?<![0-9a-f])[0-9a-f]{32}(?![0-9a-f])')
SESSION_NAME = re.compile(r'^([0-9a-f]{32})\.session$')
CONTEXT_PREFIX = '[Context material'

KEY = 'owned-daemon-fixture-key-never-logged'
REDACTED_KEY = '<owned-fake-key>'
DIAG_BOUND = 6144
DIAG_TAIL_LINES = 8
DIAG_TAIL_CHARS = 480
ANSI_TEXT = re.compile(r'\x1b\[[0-9;?]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-~]')
MODEL = 'fixture-model'
BOUND = 4 * 1024 * 1024
CONTROLLER_TIMEOUT = 90

DETACH_PROMPT = 'daemon-detach-prompt-marker'
DETACH_ANSWER = 'daemon-detach-answer-marker'
PAR_A_PROMPT = 'daemon-parallel-a-prompt'
PAR_B_PROMPT = 'daemon-parallel-b-prompt'
PAR_A_ANSWER = 'daemon-parallel-a-answer'
PAR_B_ANSWER = 'daemon-parallel-b-answer'
CONTROLLER_PROMPT = 'daemon-controller-prompt'
CONTROLLER_ANSWER = 'daemon-controller-answer'
FG_PROMPT = 'daemon-foreground-owner-prompt'
FG_ANSWER = 'daemon-foreground-owner-answer'
DB_PROMPT = 'daemon-created-prompt'
DB_ANSWER = 'daemon-created-answer'
APPROVAL_PROMPT = 'daemon-approval-prompt'
APPROVAL_ANSWER = 'daemon-approval-answer'
SERVICE_PROMPT = 'daemon-owned-service-prompt'
SERVICE_ANSWER = 'daemon-owned-service-answer'

# This owned service finishes its own work for a while after SIGTERM. Only the
# reclaim case writes it, so no other case gains a sleep, and the daemon must
# wait for the worker that is cleaning the service up instead of killing that
# worker on a fixed short grace. 3.5s is deliberately longer than the old
# 2s shutdown grace plus the 1s TERM->KILL grace of the worker.
SERVICE_STOP_DELAY = 3.5
# Per-case limits of case 7 only: the worker needs its own grace (`cleanup_grace_ms`)
# to release the service, and `cleanup_timeout_ms` must leave a KILL upgrade
# strictly after the service's delay (min(grace, timeout/2) > 3.5s), so the
# observable outcome is the worker waiting, never a silent early kill.
SERVICE_LIMITS = {'cleanup_grace_ms': 4000, 'cleanup_timeout_ms': 12000}

SERVICE_SOURCE = '''\
import os, signal, socket, sys, time
marker, tag = sys.argv[1], sys.argv[2]

def _stopping(signum, frame):
    time.sleep(@STOP_DELAY@)
    os._exit(0)

signal.signal(signal.SIGTERM, _stopping)
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
'''.replace('@STOP_DELAY@', repr(SERVICE_STOP_DELAY))

SERVICE_SCRIPT = 'owned_service.py'
SERVICE_MARKER = 'daemon-svc.marker'


# ---------------------------------------------------------------------------
# Bounded VT subset: the product runs a main-buffer TUI, never alt screen.
# ---------------------------------------------------------------------------

# Real idle composer decorations, as rendered by src/ui/presentation.zig's
# `prompt()`: `> ` with no model selected, and `(model) 0.0%> ` /
# `(model) L1.6%> ` / `(model) high> ` / `0.0%> ` once one is. The slot in front
# of the marker is a transient effort-confirmation level name or the retained
# context (`?%`, `>100%`, `N.N%`), optionally prefixed by the low-price `L`.
# The busy marker replaces the `>` with the non-ASCII activity spinner, which
# this bounded VT subset never stores, so a busy composer can never reach the
# same shape.
_VALUE_SLOT = (r'(?:L?(?:\?%|>100%|[0-9]+\.[0-9]%|off|minimal|low|medium|high|'
               r'xhigh|max|\?))')
_IDLE_COMPOSER = re.compile(
    r'^(?:> |(?:\([^)]*\) )?' + _VALUE_SLOT + r'> )$')


class Screen:
    def __init__(self, columns, rows=30):
        self.columns = columns
        self.rows = rows
        self.grid = [[' '] * columns for _ in range(rows)]
        self.history = []
        self.row = self.col = 0
        self.pending = b''

    def down(self):
        if self.row == self.rows - 1:
            self.history.append(''.join(self.grid.pop(0)))
            assert len(self.history) < 4096
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
                assert not (final in (b'h', b'l') and
                            any(x in args.split(b';') for x in (b'?1049', b'?1047', b'?47')))
                n = int(args) if args.isdigit() else 1
                if final == b'A':
                    self.row = max(0, self.row - n)
                elif final == b'B':
                    self.row = min(self.rows - 1, self.row + n)
                elif final == b'C':
                    self.col = min(self.columns - 1, self.col + n)
                elif final == b'D':
                    self.col = max(0, self.col - n)
                elif final == b'K':
                    self.grid[self.row][self.col:] = [' '] * (self.columns - self.col)
                elif final == b'M':
                    for _ in range(n):
                        self.grid.pop(self.row)
                        self.grid.append([' '] * self.columns)
                i = m.end()
                continue
            i += 1
            if b == 13:
                self.col = 0
            elif b == 10:
                self.down()
            elif b == 8:
                self.col = max(0, self.col - 1)
            elif 32 <= b < 127:
                self.grid[self.row][self.col] = chr(b)
                self.col = min(self.columns - 1, self.col + 1)
        self.pending = data[i:]

    def text(self):
        rows = self.history[-400:] + [''.join(row) for row in self.grid]
        return '\n'.join(rows)

    def tail(self, rows=4):
        return [''.join(row).rstrip() for row in self.grid[-rows:]]

    def idle(self):
        """True only on the cursor row of a settled, empty composer.

        §3.3 floats the composer at the current tail location, so it owns the
        cursor row and not necessarily the physical bottom row: read the cursor,
        never `grid[-1]`. A stale completed prompt further up, a transcript row
        that merely ends with `>`, a modal editor line (Search>/Settings>/
        Address>/Provider>/API key>) and the busy spinner are all rejected.
        """
        if not 0 <= self.row < self.rows:
            return False
        column = min(max(self.col, 0), self.columns)
        line = ''.join(self.grid[self.row])
        if line[column:].strip():
            return False  # Editor text follows the decoration: not empty.
        return _IDLE_COMPOSER.match(line[:column]) is not None


# ---------------------------------------------------------------------------
# Owned children: PTY clients and the headless daemon
# ---------------------------------------------------------------------------

class Child:
    def __init__(self, app, args, cwd, env, label, log_dir=None,
                 pty_mode=True, columns=110, rows=30):
        self.label = label
        self.pty_mode = pty_mode
        self.capture = bytearray()
        self.screen = Screen(columns, rows) if pty_mode else None
        self.master = self.slave = None
        self.logs = []
        self.baseline = None
        command = [app] + list(args)
        if pty_mode:
            self.master, self.slave = pty.openpty()
            fcntl.ioctl(self.slave, termios.TIOCSWINSZ,
                        struct.pack('HHHH', rows, columns, 0, 0))
            self.baseline = termios.tcgetattr(self.slave)

            def child_setup():
                os.setsid()
                fcntl.ioctl(0, termios.TIOCSCTTY, 0)

            self.proc = subprocess.Popen(command, cwd=str(cwd), stdin=self.slave,
                                         stdout=self.slave, stderr=self.slave,
                                         preexec_fn=child_setup, env=env)
        else:
            assert log_dir is not None
            out = open(str(Path(log_dir) / (label + '.out.log')), 'w+b')
            err = open(str(Path(log_dir) / (label + '.err.log')), 'w+b')
            self.logs = [out, err]
            self.proc = subprocess.Popen(command, cwd=str(cwd), stdin=subprocess.DEVNULL,
                                         stdout=out, stderr=err, env=env,
                                         start_new_session=True)

    # -- output ------------------------------------------------------------
    def _absorb(self, data):
        if not data:
            return
        self.capture.extend(data)
        assert len(self.capture) <= BOUND, '%s pty output bound' % self.label
        self.screen.feed(data)

    def _read(self):
        try:
            data = os.read(self.master, 65536)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            data = b''
        self._absorb(data)
        return bool(data)

    def pump(self, seconds):
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or self.master is None:
                return
            ready, _, _ = select.select([self.master], [], [], min(0.05, remaining))
            if ready:
                self._read()

    def drain(self):
        if self.master is None:
            return
        while True:
            ready, _, _ = select.select([self.master], [], [], 0)
            if not ready:
                return
            self._read()

    def text(self):
        return self.capture.decode('utf-8', 'replace')

    def screen_text(self):
        assert self.screen is not None
        return self.screen.text()

    def log_text(self):
        chunks = []
        for handle in self.logs:
            handle.flush()
            try:
                size = os.fstat(handle.fileno()).st_size
                handle.seek(0)
                chunks.append(handle.read(min(size, 256 * 1024)).decode('utf-8', 'replace'))
            except OSError:
                pass
        return '\n'.join(chunks)

    # -- frames ------------------------------------------------------------
    def mark(self):
        return len(self.capture)

    def frame_after(self, offset, marker=b''):
        tail = bytes(self.capture[offset:])
        end = tail.rfind(FRAME_END)
        if end < 0 or tail.rfind(SYNC_BEGIN) > end:
            return False
        if marker and tail.rfind(marker) < 0:
            return False
        return True

    def idle_after(self, offset, marker=b''):
        return self.frame_after(offset, marker) and self.screen.idle()

    def frames(self):
        return self.capture.count(FRAME_END)

    # -- driving -----------------------------------------------------------
    def pump_until(self, predicate, label, timeout=30, guard=None):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if guard is not None:
                guard()
            if predicate():
                return
            ready, _, _ = select.select([self.master], [], [],
                                        min(0.05, max(0.0, deadline - time.monotonic())))
            if ready:
                self._read()
            if self.proc.poll() is not None and not predicate():
                self.drain()
                raise AssertionError(
                    '%s exited early during %s (code %r); tail=%r' %
                    (self.label, label, self.proc.returncode,
                     self.screen.tail() if self.screen else self.log_text()[-800:]))
        raise AssertionError('%s wait expired: %s; exit=%r screen=%r' %
                             (self.label, label, self.proc.poll(),
                              self.screen.tail() if self.screen else self.log_text()[-800:]))

    def send(self, data):
        assert self.master is not None
        offset = 0
        while offset < len(data):
            try:
                offset += os.write(self.master, data[offset:])
            except OSError as error:
                if error.errno in (errno.EINTR, errno.EAGAIN):
                    continue
                raise

    def send_line(self, text):
        assert '\n' not in text and '\r' not in text
        self.send(text.encode() + b'\r')

    # -- lifecycle ---------------------------------------------------------
    def kill(self):
        """SIGKILL this exact owned child; used to simulate a dropped front end."""
        if self.proc.poll() is None:
            self.proc.kill()

    def terminate(self):
        if self.proc.poll() is None:
            self.proc.terminate()

    def wait(self, timeout=20):
        return self.proc.wait(timeout=timeout)

    def wait_exit(self, label, timeout=20):
        try:
            return self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise AssertionError('%s did not exit during %s' % (self.label, label))

    def assert_termios_restored(self):
        assert self.slave is not None
        assert termios.tcgetattr(self.slave) == self.baseline, \
            '%s did not restore terminal attributes' % self.label

    def close(self):
        if self.master is not None:
            try:
                os.close(self.master)
            except OSError:
                pass
            self.master = None
        if self.slave is not None:
            try:
                os.close(self.slave)
            except OSError:
                pass
            self.slave = None
        for handle in self.logs:
            try:
                handle.close()
            except OSError:
                pass
        self.logs = []

    def cleanup(self):
        # Never signal a reaped PID: poll() is the only ownership proof here.
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        self.close()


# ---------------------------------------------------------------------------
# Wire helpers
# ---------------------------------------------------------------------------

def message_text(message):
    text = message.get('content')
    if isinstance(text, list):
        text = ''.join(part.get('text', '') for part in text if isinstance(part, dict))
    return text if isinstance(text, str) else ''


def real_users(body):
    """Only canonical user turns; environment/Memory context is not a turn."""
    out = []
    for message in body.get('messages') or []:
        if message.get('role') != 'user':
            continue
        text = message_text(message)
        if text.startswith(CONTEXT_PREFIX):
            continue
        out.append(text)
    return out


def tool_history(body):
    calls, results = [], {}
    for message in body.get('messages') or []:
        for call in message.get('tool_calls') or []:
            calls.append({'id': call['id'], 'name': call['function']['name'],
                          'arguments': call['function']['arguments']})
        if message.get('role') == 'tool':
            results[message.get('tool_call_id')] = message.get('content')
    return calls, results


def tool_call(call_id, name, args):
    return {'kind': 'tool', 'calls': [{'id': call_id, 'name': name, 'args': args}]}


def text_answer(text):
    return {'kind': 'text', 'text': text}


# ---------------------------------------------------------------------------
# Owned 127.0.0.1 Chat/SSE model server with gateable plans
# ---------------------------------------------------------------------------

class ModelFixture:
    def __init__(self, plan):
        self.plan = plan
        self.bodies = []
        self.lock = threading.Lock()
        self.failed = None
        self.url = None
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            # HTTP/1.0 with Connection: close: the SSE body is closed after
            # [DONE] instead of relying on chunk framing this fixture omits.
            def log_message(self, *_):
                pass

            def do_GET(self):
                outer.failed = AssertionError('unexpected metadata/network GET')
                self.send_error(500)

            def do_POST(self):
                outer.handle(self)

        class Server(http.server.ThreadingHTTPServer):
            daemon_threads = True
            allow_reuse_address = True

        self.server = Server(('127.0.0.1', 0), Handler)
        self.url = 'http://127.0.0.1:%d/v1' % self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def start(self):
        self.thread.start()
        return self.url

    def check(self):
        if self.failed is not None:
            raise self.failed

    def stop(self):
        try:
            self.server.shutdown()
        finally:
            self.server.server_close()
            self.thread.join(timeout=10)

    def snapshot(self):
        with self.lock:
            return list(self.bodies)

    def count(self, prompt=None):
        bodies = self.snapshot()
        if prompt is None:
            return len(bodies)
        return sum(1 for body in bodies if prompt in real_users(body))

    def wait_prompt(self, prompt, timeout=30, progress=None):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if progress is not None:
                progress()
            self.check()
            if self.count(prompt) > 0:
                return
            time.sleep(0.02)
        raise AssertionError('model never received %r' % prompt)

    def handle(self, handler):
        try:
            length = int(handler.headers['Content-Length'])
            assert length <= 512 * 1024, 'request byte bound'
            body = json.loads(handler.rfile.read(length))
            assert handler.path.endswith('/chat/completions'), 'chat wire only: %r' % handler.path
            assert handler.headers.get('Authorization') == 'Bearer ' + KEY, 'owned key header'
            assert body.get('model') == MODEL, 'owned model id'
            assert body.get('stream') is True, 'all model requests must stream'
            assert body.get('messages'), 'messages required'
            assert body.get('tools'), 'real inference POST declares the product tool schema'
            with self.lock:
                self.bodies.append(body)
            value = self.plan(body)
            self.emit(handler, value)
        except Exception as error:  # noqa: BLE001 - runner reports it
            self.failed = error
            try:
                handler.send_error(500)
            except Exception:  # noqa: BLE001
                pass

    def emit(self, handler, value):
        handler.send_response(200)
        handler.send_header('Content-Type', 'text/event-stream')
        handler.send_header('Cache-Control', 'no-cache')
        handler.send_header('Connection', 'close')
        handler.close_connection = True
        handler.end_headers()
        if value['kind'] == 'tool':
            delta = {'tool_calls': []}
            for index, call in enumerate(value['calls']):
                delta['tool_calls'].append({
                    'index': index, 'id': call['id'], 'type': 'function',
                    'function': {'name': call['name'],
                                 'arguments': json.dumps(call['args'])}})
            finish = 'tool_calls'
        else:
            delta, finish = {'content': value['text']}, 'stop'
        frames = [
            {'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]},
            {'choices': [{'index': 0, 'delta': {}, 'finish_reason': finish}],
             'usage': {'prompt_tokens': 120, 'completion_tokens': 8, 'total_tokens': 128}},
        ]
        for frame in frames:
            handler.wfile.write(b'data: ' + json.dumps(frame).encode() + b'\n\n')
        handler.wfile.write(b'data: [DONE]\n\n')


# ---------------------------------------------------------------------------
# Owned workspace, config and case harness
# ---------------------------------------------------------------------------

def assert_screen_idle_contract():
    """Direct Screen regression, run by each fixture entry point before spawning.

    A drifting shared idle parser must fail here instead of timing out a 30s
    latency/request-count wait: the composer floats at the current terminal
    location, so idle is a cursor-row property, not a physical-bottom property.
    """
    def state(lines, cursor_row, total_rows=8, columns=40):
        screen = Screen(columns, total_rows)
        for index, line in enumerate(lines):
            screen.grid[index][:len(line)] = list(line)
        screen.row = cursor_row
        screen.col = len(lines[cursor_row])
        return screen

    # Floating tail: the composer row is written above the physical bottom.
    assert state(['(fixture-model) 0.0%> '], 0).idle(), 'floating configured composer'
    assert state(['> '], 0).idle(), 'floating unconfigured composer'
    assert state(['(fixture-model) L1.6%> '], 0).idle(), 'low-price composer'
    assert state(['(fixture-model) high> '], 0).idle(), 'effort confirmation composer'
    # Bottom placement keeps working.
    assert state([''] * 7 + ['(fixture-model) 0.0%> '], 7).idle(), 'bottom composer'
    # A stale completed prompt above a busy cursor row is not idle.
    assert not state(['> ', '(fixture-model) 0.0% '], 1).idle(), 'stale prompt above busy'
    # Modal editor lines, approval choices, body rows and drafts never imply idle.
    assert not state(['Search> '], 0).idle(), 'search line'
    assert not state(['Settings> '], 0).idle(), 'settings line'
    assert not state(['Address> '], 0).idle(), 'proxy address line'
    assert not state(['Provider> '], 0).idle(), 'provider line'
    assert not state(['API key> '], 0).idle(), 'secret line'
    assert not state(['> Allow once                Deny'], 0).idle(), 'approval choice row'
    assert not state(['rm -rf protected-owned-dir >'], 0).idle(), 'body row ending in >'
    assert not state(['(fixture-model) 0.0%> draft'], 0).idle(), 'filled composer'


def write_config(home, url, limits=None):
    path = Path(home) / '.thin' / 'config.json'
    path.parent.mkdir(parents=True, exist_ok=True)
    base_limits = {
        'low_price_input': False, 'safety_tokens': 100,
        'request_timeout_ms': 60000, 'task_timeout_ms': 120000,
        'command_timeout_ms': 10000, 'cleanup_grace_ms': 300,
        'cleanup_timeout_ms': 5000,
    }
    config = {
        'memory': {'auto': False},
        'llm': {'default': 'owned/' + MODEL, 'providers': {'owned': {
            'base_url': url,
            'api_key': KEY,
            'models': {MODEL: {'protocol': 'chat', 'context_tokens': 32768}},
        }}},
        # Per-case overrides stay inside this case's own owned HOME.
        'limits': dict(base_limits, **(limits or {})),
    }
    payload = (json.dumps(config) + '\n').encode()
    path.write_bytes(payload)
    path.chmod(0o600)
    return path, payload


class Workspace:
    def __init__(self, root):
        self.root = Path(root)
        self.home = self.root / 'home'
        self.runtime = self.root / 'runtime'
        self.config_home = self.root / 'config'
        self.cache_home = self.root / 'cache'
        self.state_home = self.root / 'state'
        self.data_home = self.root / 'data'
        self.tmp = self.root / 'tmp'
        self.logs = self.root / 'logs'
        self.project_a = self.root / 'project-a'
        self.project_b = self.root / 'project-b'
        for directory in (self.home, self.runtime, self.config_home, self.cache_home,
                          self.state_home, self.data_home, self.tmp, self.logs,
                          self.project_a, self.project_b):
            directory.mkdir(parents=True, exist_ok=True)
            directory.chmod(0o700)

    def env(self):
        assert str(self.home) != '/root' and Path(self.home).is_dir()
        return {
            'PATH': '/usr/bin:/bin:/usr/local/bin',
            'HOME': str(self.home),
            'XDG_RUNTIME_DIR': str(self.runtime),
            'XDG_CONFIG_HOME': str(self.config_home),
            'XDG_CACHE_HOME': str(self.cache_home),
            'XDG_STATE_HOME': str(self.state_home),
            'XDG_DATA_HOME': str(self.data_home),
            'TMPDIR': str(self.tmp),
            'LANG': 'C.UTF-8',
            'LC_ALL': 'C.UTF-8',
            'TERM': 'xterm-256color',
        }


def bounded_tail(text, lines=DIAG_TAIL_LINES, limit=DIAG_TAIL_CHARS):
    """Bounded, control-free tail of fixture output: never raw ANSI, never unbounded."""
    text = ANSI_TEXT.sub('', text).replace('\r\n', '\n').replace('\r', '')
    text = ''.join(ch for ch in text if ch == '\n' or ch >= ' ')
    rows = [row for row in text.split('\n') if row.strip()][-lines:]
    text = '\n'.join(row[:200] for row in rows)
    return text[-limit:]


def child_log_tail(child, limit=4096):
    """Read the tail of this child's own stdio logs (inside the owned tree only)."""
    chunks = []
    for handle in list(child.logs):
        name = getattr(handle, 'name', None)
        if not isinstance(name, str):
            continue
        try:
            size = os.path.getsize(name)
            with open(name, 'rb') as reader:
                reader.seek(max(0, size - limit))
                chunks.append(reader.read(limit).decode('utf-8', 'replace'))
        except OSError:
            continue
    return '\n'.join(chunks)


class Case:
    def __init__(self, app, base, name):
        self.app = app
        self.name = name
        self.workspace = Workspace(Path(base) / name)
        self.children = []
        self.model = None
        self.daemon = None
        self.state = {}

    def start_model(self, plan, limits=None):
        self.model = ModelFixture(lambda body: plan(self.model, self.state, body))
        url = self.model.start()
        write_config(self.workspace.home, url, limits)
        return url

    def spawn(self, args, cwd, label, pty_mode=True):
        child = Child(self.app, args, cwd, self.workspace.env(), label,
                      log_dir=self.workspace.logs, pty_mode=pty_mode)
        self.children.append(child)
        return child

    def client(self, args, cwd, label):
        """Interactive clients always disable the startup metadata refresh."""
        return self.spawn(list(args) + ['--no-model-auto-refresh'], cwd, label, pty_mode=True)

    def start_daemon(self, label='daemon'):
        argvs = ['--daemon', '--no-model-auto-refresh']
        daemon = self.spawn(argvs, self.workspace.home, label, pty_mode=False)
        self.daemon = daemon
        wait_daemon_socket(self)
        return daemon

    def pump_children(self):
        """Answer what a real terminal would answer (DSR/ACK) while waiting."""
        for child in self.children:
            if child.master is not None:
                child.pump(0.005)

    def wait_prompt(self, prompt, timeout=30):
        return self.model.wait_prompt(prompt, timeout, progress=self.pump_children)

    def release_plan_gates(self):
        for value in self.state.values():
            if isinstance(value, threading.Event):
                value.set()

    def assert_no_secret(self):
        for child in self.children:
            text = child.log_text() if not child.pty_mode else \
                child.text() + (child.screen_text() if child.screen else '')
            assert KEY not in text, '%s leaked the owned credential' % child.label

    def report_failure(self):
        """One bounded JSON line of owned evidence; never raises, never leaks."""
        try:
            children = []
            for child in list(self.children)[:12]:
                try:
                    tail = child.screen.text() if child.pty_mode and child.screen \
                        else child_log_tail(child)
                    children.append({'label': child.label, 'exit': child.proc.poll(),
                                     'tail': bounded_tail(tail)})
                except Exception:  # noqa: BLE001 - one child never hides the rest
                    children.append({'label': getattr(child, 'label', '?'),
                                     'exit': None, 'tail': ''})
            try:
                calls = self.model.count() if self.model is not None else None
            except Exception:  # noqa: BLE001 - keep child evidence anyway
                calls = None
            line = json.dumps({
                'case': self.name,
                'modelCalls': calls,
                'children': children,
            }, ensure_ascii=True, sort_keys=True, separators=(',', ':'))
            line = line.replace(KEY, REDACTED_KEY)
            if len(line) > DIAG_BOUND:
                line = json.dumps({'case': self.name, 'truncated': True,
                                   'children': [item['label'] for item in children]},
                                  ensure_ascii=True, sort_keys=True, separators=(',', ':'))
            print('DIAG daemon case failure: ' + line, file=sys.stderr, flush=True)
        except Exception:  # noqa: BLE001 - diagnostics must not mask the failure
            pass

    def close(self):
        # A case failing inside try/finally reaches close() with the real
        # exception still in flight: snapshot bounded evidence before cleanup.
        if sys.exc_info()[0] is not None:
            self.report_failure()
        self.release_plan_gates()
        for child in reversed(self.children):
            if child is self.daemon and child.proc.poll() is None:
                stop_daemon(self)
                child.close()
                continue
            child.cleanup()
        if self.daemon is not None and self.daemon.proc.poll() is None:
            stop_daemon(self)
            self.daemon.close()
        assert_no_live_endpoint(self, timeout=10)
        self.assert_no_secret()
        if self.model is not None:
            self.model.stop()
        for project in (self.workspace.project_a, self.workspace.project_b):
            assert_private_sessions(project)
        assert_private_runtime(self.workspace.runtime)


# ---------------------------------------------------------------------------
# Process / endpoint / session helpers
# ---------------------------------------------------------------------------

def runtime_sockets(runtime):
    found = []
    root = Path(runtime)
    if not root.is_dir():
        return found
    for directory, _dirs, files in os.walk(str(root)):
        for name in files:
            path = Path(directory) / name
            try:
                info = os.stat(str(path), follow_symlinks=False)
            except OSError:
                continue
            if stmod.S_ISSOCK(info.st_mode):
                found.append(path)
            if len(found) > 64:
                return found
    return found


def endpoint_accepts(path, timeout=0.3):
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(timeout)
    try:
        probe.connect(str(path))
        return True
    except OSError:
        return False
    finally:
        probe.close()


def wait_daemon_socket(case, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if case.daemon.proc.poll() is not None:
            raise AssertionError('daemon exited during startup (code %r): %s' %
                                 (case.daemon.proc.returncode, case.daemon.log_text()[-1200:]))
        if runtime_sockets(case.workspace.runtime) and \
                any(endpoint_accepts(path) for path in runtime_sockets(case.workspace.runtime)):
            return
        time.sleep(0.02)
    raise AssertionError('daemon never published an owned AF_UNIX endpoint under '
                         'XDG_RUNTIME_DIR: %s' % case.daemon.log_text()[-1200:])


def assert_no_live_endpoint(case, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        live = [path for path in runtime_sockets(case.workspace.runtime)
                if endpoint_accepts(path)]
        if not live:
            return
        time.sleep(0.05)
    raise AssertionError('owned endpoint still accepts connections: %r' %
                         [str(path) for path in runtime_sockets(case.workspace.runtime)])


def children_of(pid):
    """Direct+recursive children of one owned PID only (never a system scan)."""
    out, stack, seen = set(), [pid], 0
    while stack:
        current = stack.pop()
        seen += 1
        assert seen <= 512, 'owned child walk bound'
        task_dir = Path('/proc/%d/task' % current)
        if not task_dir.is_dir():
            continue
        for task in task_dir.iterdir():
            children = task / 'children'
            try:
                text = children.read_text()
            except OSError:
                continue
            for field in text.split():
                if not field.isdigit():
                    continue
                child = int(field)
                if child not in out and child != current:
                    out.add(child)
                    stack.append(child)
    return out


def wait_pids_gone(pids, timeout=20):
    deadline = time.monotonic() + timeout
    pending = set(pids)
    while time.monotonic() < deadline:
        pending = {pid for pid in pending if Path('/proc/%d' % pid).exists()}
        if not pending:
            return
        time.sleep(0.05)
    raise AssertionError('owned child PIDs still alive: %r' % sorted(pending))


def stop_daemon(case, timeout=30):
    daemon = case.daemon
    assert daemon is not None
    if daemon.proc.poll() is not None:
        return daemon.proc.returncode
    kids = children_of(daemon.proc.pid)
    daemon.terminate()
    try:
        code = daemon.proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        daemon.proc.kill()
        daemon.proc.wait(timeout=10)
        raise AssertionError('daemon ignored SIGTERM: %s' % daemon.log_text()[-1200:])
    assert code in (0, -signal.SIGTERM, 128 + signal.SIGTERM), \
        'unexpected daemon SIGTERM exit code %r' % (code,)
    wait_pids_gone(kids, timeout=timeout)
    assert_no_live_endpoint(case, timeout=timeout)
    return code


def session_files(project):
    directory = Path(project) / '.thin' / 'sessions'
    if not directory.is_dir():
        return []
    files = []
    for path in directory.iterdir():
        if SESSION_NAME.match(path.name):
            try:
                if path.is_file():
                    files.append(path)
            except OSError:
                pass
    return sorted(files)


def wait_sessions(project, count=1, timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        files = session_files(project)
        if len(files) >= count:
            return files
        time.sleep(0.05)
    raise AssertionError('project %s never published %d session checkpoint(s)' %
                         (project, count))


def session_id(project, count=1):
    path = wait_sessions(project, count)[count - 1]
    match = SESSION_NAME.match(path.name)
    assert match is not None
    return match.group(1)


def checkpoint_contains(project, marker):
    for path in session_files(project):
        try:
            data = path.read_bytes()
        except OSError:
            continue
        if marker.encode() in data:
            return path
    return None


def wait_checkpoint(project, marker, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        path = checkpoint_contains(project, marker)
        if path is not None:
            return path
        time.sleep(0.05)
    raise AssertionError('checkpoint never contained %r' % marker)


def lock_is_free(project, ident):
    path = Path(project) / '.thin' / 'sessions' / (ident + '.resume-lock')
    assert path.is_file(), 'checkpoint writer lock is missing'
    fd = os.open(str(path), os.O_RDWR)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError as error:
            if error.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
                return False
            raise
    finally:
        os.close(fd)


def assert_private_sessions(project):
    directory = Path(project) / '.thin' / 'sessions'
    if not directory.is_dir():
        return
    assert stmod.S_IMODE(os.stat(str(directory)).st_mode) & 0o077 == 0, \
        'session directory is not private: %o' % stmod.S_IMODE(os.stat(str(directory)).st_mode)
    for path in directory.iterdir():
        try:
            info = os.stat(str(path), follow_symlinks=False)
        except OSError:
            continue
        if stmod.S_ISREG(info.st_mode):
            mode = stmod.S_IMODE(info.st_mode)
            assert mode & 0o077 == 0, 'session artifact %s is not private: %o' % (path, mode)


def assert_private_runtime(runtime):
    root = Path(runtime)
    for directory, subdirs, files in os.walk(str(root)):
        for name in list(subdirs) + list(files):
            path = Path(directory) / name
            try:
                info = os.stat(str(path), follow_symlinks=False)
            except OSError:
                continue
            if not (stmod.S_ISDIR(info.st_mode) or stmod.S_ISREG(info.st_mode) or
                    stmod.S_ISSOCK(info.st_mode)):
                continue
            mode = stmod.S_IMODE(info.st_mode)
            assert mode & 0o077 == 0, 'runtime artifact %s is not private: %o' % (path, mode)


def service_marker(project):
    return Path(project) / SERVICE_MARKER


def wait_service_ready(project, deadline=15.0):
    marker = service_marker(project)
    until = time.monotonic() + deadline
    while time.monotonic() < until:
        try:
            fields = marker.read_text().split()
        except OSError:
            fields = []
        if len(fields) == 2 and fields[0].isdigit() and fields[1].isdigit():
            pid, port = int(fields[0]), int(fields[1])
            with socket.create_connection(('127.0.0.1', port), timeout=2) as conn:
                conn.sendall(b'GET / HTTP/1.0\r\n\r\n')
                reply = conn.recv(4096)
            assert b'SERVICE-daemon-OK' in reply, 'owned service did not answer'
            assert Path('/proc/%d' % pid).exists(), 'owned service pid disappeared'
            return pid, port
        time.sleep(0.02)
    raise AssertionError('owned background service never bound its loopback port')


def wait_service_gone(pid, port, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not Path('/proc/%d' % pid).exists():
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=0.5):
                    pass
            except OSError:
                return
        time.sleep(0.05)
    raise AssertionError('owned background service still owns pid %d or port %d' % (pid, port))


def assert_service_gone_now(pid, port, script):
    """No polling: the owner must already have waited for this service.

    A service that is still running (or still bound) at the moment the daemon
    returned proves the owner abandoned the cleanup: the worker that owned this
    service in its own process group was killed instead of being waited for.
    """
    if Path('/proc/%d' % pid).exists():
        assert not owned_service_process(pid, script), \
            'daemon returned while its owned service pid %d was still running' % pid
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=0.5):
            pass
    except OSError:
        return
    raise AssertionError('daemon returned while its owned service still owned port %d' % port)


def owned_service_process(pid, script):
    """Exact ownership proof: this PID still runs the owned workspace script.

    /proc/<pid>/cmdline is matched argv-by-argv against the absolute path of the
    script this fixture wrote into its own workspace, so neither a recycled PID
    nor any unrelated process that merely mentions the file name can match.
    """
    try:
        raw = Path('/proc/%d/cmdline' % pid).read_bytes()
    except OSError:
        return False
    return str(script).encode() in raw.split(b'\x00')


def kill_service_if_alive(pid, script):
    """Cleanup of the one service PID this fixture read from its own marker.

    The PID is not a Popen child of this script, so ownership is proven before
    any signal: a pidfd is opened first and every TERM/KILL travels through that
    fixed descriptor, which the kernel binds to the original process identity
    (no PID-reuse TOCTOU). Only then is /proc/<pid>/cmdline required to carry the
    exact absolute path of this case's owned script. A process that is already
    gone is a silent no-op; a platform without pidfd records that cleanup could
    not be confirmed and never degrades to a bare PID signal. No process table
    scan and no pkill: only this single owned PID is ever considered.
    """
    if not pid:
        return
    opener = getattr(os, 'pidfd_open', None)
    sender = getattr(signal, 'pidfd_send_signal', None)
    if opener is None or sender is None:
        print('NOTE owned service cleanup unconfirmed for pid %d: pidfd unsupported on '
              'this platform; no bare PID signal attempted' % pid, file=sys.stderr)
        return
    try:
        fd = opener(pid, 0)
    except ProcessLookupError:
        return
    except OSError as error:
        print('NOTE owned service cleanup unconfirmed for pid %d: pidfd_open failed (%r); '
              'no bare PID signal attempted' % (pid, error), file=sys.stderr)
        return
    try:
        if not owned_service_process(pid, script):
            return
        for attempt, sig in ((0, signal.SIGTERM), (1, signal.SIGKILL)):
            try:
                sender(fd, sig)
            except ProcessLookupError:
                return
            except OSError as error:
                print('NOTE owned service cleanup unconfirmed for pid %d: pidfd signal '
                      'failed (%r)' % (pid, error), file=sys.stderr)
                return
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if not Path('/proc/%d' % pid).exists():
                    return
                time.sleep(0.05)
            if attempt:
                print('NOTE owned service pid %d survived SIGKILL' % pid, file=sys.stderr)
    finally:
        os.close(fd)


def annotate(text, label):
    return '%s: %r' % (label, text[-1200:])


def assert_service_error(text, label):
    lower = text.lower()
    assert lower.strip(), '%s produced no diagnostic' % label
    assert any(word in lower for word in
               ('service', 'daemon', 'connect', 'attach', 'session', 'socket', 'endpoint')), \
        annotate(text, label)
    assert any(word in lower for word in
               ('not', 'no ', 'unavailable', 'failed', 'refused', 'missing', 'unable',
                'cannot', 'error', 'thin:')), annotate(text, label)


def run_conflict(app, workspace, args, label):
    """Mode conflicts are rejected by the parser before any TTY/session work."""
    completed = subprocess.run([app] + list(args), cwd=str(workspace.home),
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=workspace.env(), timeout=15)
    output = completed.stdout + completed.stderr
    assert completed.returncode != 0, '%s unexpectedly succeeded' % label
    assert 0 < len(output) <= 8192, '%s diagnostic must be bounded' % label
    text = output.decode('utf-8', 'replace')
    assert 'thin:' in text or 'Invalid' in text or 'Unknown' in text or '--help' in text, \
        annotate(text, label)
    return text


# ---------------------------------------------------------------------------
# Planned replies (each plan asserts the request it is willing to answer)
# ---------------------------------------------------------------------------

def detach_plan(fx, state, body):
    users = real_users(body)
    assert users == [DETACH_PROMPT], 'unexpected request users: %r' % (users,)
    calls, results = tool_history(body)
    assert not calls and not results, 'first turn must not carry tool traffic'
    state['seen'].set()
    assert state['gate'].wait(120), 'gated reply was never released'
    return text_answer(DETACH_ANSWER)


def parallel_plan(fx, state, body):
    users = real_users(body)
    assert len(users) == 1, 'one canonical user turn per request, got %r' % (users,)
    prompt = users[0]
    calls, results = tool_history(body)
    if prompt == PAR_A_PROMPT:
        if not calls:
            state['a1'].set()
            assert state['b1'].wait(40), 'second session never started in parallel'
            return tool_call('par-a-1', 'bash', {'command': 'pwd'})
        assert len(calls) == 1 and calls[0]['id'] == 'par-a-1', 'one pwd call expected'
        result = results.get('par-a-1')
        assert result is not None, 'A tool result missing'
        assert str(state['project_a']) in str(result), 'A ran outside its own root: %r' % (result,)
        assert str(state['project_b']) not in str(result), 'A saw the sibling project root'
        state['a2'].set()
        assert state['release'].wait(60), 'parallel release was never signalled'
        return text_answer(PAR_A_ANSWER)
    if prompt == PAR_B_PROMPT:
        if not calls:
            state['b1'].set()
            assert state['a1'].wait(40), 'first session never started'
            return tool_call('par-b-1', 'bash', {'command': 'pwd'})
        assert len(calls) == 1 and calls[0]['id'] == 'par-b-1', 'one pwd call expected'
        result = results.get('par-b-1')
        assert result is not None, 'B tool result missing'
        assert str(state['project_b']) in str(result), 'B ran outside its own root: %r' % (result,)
        assert str(state['project_a']) not in str(result), 'B saw the sibling project root'
        state['b2'].set()
        assert state['release'].wait(60), 'parallel release was never signalled'
        return text_answer(PAR_B_ANSWER)
    raise AssertionError('unexpected parallel prompt: %r' % (prompt,))


def controller_plan(fx, state, body):
    users = real_users(body)
    assert users == [CONTROLLER_PROMPT], 'unexpected request users: %r' % (users,)
    calls, results = tool_history(body)
    assert not calls and not results, 'single-turn controller proof has no tools'
    state['seen'].set()
    assert state['release'].wait(CONTROLLER_TIMEOUT), 'controller reply was never released'
    return text_answer(CONTROLLER_ANSWER)


def ownership_plan(fx, state, body):
    users = real_users(body)
    assert len(users) == 1, 'unexpected request users: %r' % (users,)
    prompt = users[0]
    calls, results = tool_history(body)
    if prompt == FG_PROMPT:
        if not calls:
            return tool_call('fg-tool-1', 'bash', {'command': 'printf fg-once > fg-tool-marker'})
        assert len(calls) == 1 and calls[0]['id'] == 'fg-tool-1', 'one foreground tool expected'
        assert results.get('fg-tool-1') is not None, 'foreground tool result missing'
        return text_answer(FG_ANSWER)
    if prompt == DB_PROMPT:
        if not calls:
            return tool_call('db-tool-1', 'bash', {'command': 'printf db-once > db-tool-marker'})
        assert len(calls) == 1 and calls[0]['id'] == 'db-tool-1', 'one daemon tool expected'
        assert results.get('db-tool-1') is not None, 'daemon tool result missing'
        return text_answer(DB_ANSWER)
    raise AssertionError('unexpected ownership prompt: %r' % (prompt,))


def approval_plan(fx, state, body):
    users = real_users(body)
    assert users == [APPROVAL_PROMPT], 'unexpected request users: %r' % (users,)
    calls, results = tool_history(body)
    if not calls:
        return tool_call('approval-tool-1', 'bash',
                         {'command': 'rm -rf ' + str(state['victim'])})
    assert len(calls) == 1 and calls[0]['id'] == 'approval-tool-1', 'exactly one approved call'
    assert str(state['victim']) in calls[0]['arguments'], 'approval request changed the command'
    assert results.get('approval-tool-1') is not None, 'approved tool result missing'
    assert not Path(state['victim']).exists(), 'approval did not produce the side effect'
    state['approved'].set()
    return text_answer(APPROVAL_ANSWER)


def service_plan(fx, state, body):
    users = real_users(body)
    assert users == [SERVICE_PROMPT], 'unexpected request users: %r' % (users,)
    calls, results = tool_history(body)
    if not calls:
        return tool_call('svc-1', 'bash',
                         {'command': state['service_cmd'], 'background': True})
    assert len(calls) == 1 and calls[0]['id'] == 'svc-1', 'one background start expected'
    receipt = results.get('svc-1')
    assert receipt is not None, 'background service receipt missing'
    parsed = json.loads(receipt)
    assert isinstance(parsed, dict) and isinstance(parsed.get('id'), str)
    return text_answer(SERVICE_ANSWER)


# ---------------------------------------------------------------------------
# Case 1: no implicit service, no implicit daemon, explicit mode conflicts
# ---------------------------------------------------------------------------

def case_no_service(app, base):
    case = Case(app, base, 'case1-no-service')
    case.state.update({'seen': threading.Event(), 'gate': threading.Event()})
    case.state['gate'].set()
    case.start_model(detach_plan)
    try:
        for args, label in (
            (['--daemon', '--connect'], 'daemon+connect'),
            (['--connect', '--daemon'], 'connect+daemon'),
            (['--daemon', '--attach', '0' * 32], 'daemon+attach'),
            (['--attach', '0' * 32, '--daemon'], 'attach+daemon'),
            (['--connect', '--print', 'x'], 'connect+print'),
            (['--daemon', '--print', 'x'], 'daemon+print'),
            (['--takeover'], 'takeover without attach'),
            (['--attach', 'not-a-session-id'], 'invalid attach id'),
            (['--attach', '0' * 31], 'short attach id'),
            (['--daemon', '--daemon'], 'repeated daemon'),
        ):
            run_conflict(app, case.workspace, args, label)
        assert case.model.count() == 0, 'mode conflicts must not infer'

        # --connect with no service: clear failure, no spawned service.
        connect = case.client(['--connect'], case.workspace.project_a, 'connect-empty')
        connect.pump_until(lambda: connect.proc.poll() is not None, 'connect without service', 25)
        connect.drain()
        assert connect.wait_exit('connect failure') != 0, '--connect must fail without a service'
        assert_service_error(connect.text(), 'connect without service')
        assert case.model.count() == 0, 'failed --connect must not infer'
        assert_no_live_endpoint(case, timeout=3)
        assert session_files(case.workspace.project_a) == [], 'failed --connect created a session'

        # Second attempt must also fail: no service was started behind our back.
        again = case.client(['--connect'], case.workspace.project_a, 'connect-again')
        again.pump_until(lambda: again.proc.poll() is not None, 'second connect failure', 25)
        again.drain()
        assert again.wait_exit('second connect failure') != 0
        assert_no_live_endpoint(case, timeout=3)

        # --attach with no service: explicit failure, no auto-start either.
        attach = case.client(['--attach', '1' * 32], case.workspace.project_a, 'attach-empty')
        attach.pump_until(lambda: attach.proc.poll() is not None, 'attach without service', 25)
        attach.drain()
        assert attach.wait_exit('attach failure') != 0, '--attach must fail without a service'
        assert_service_error(attach.text(), 'attach without service')
        assert_no_live_endpoint(case, timeout=3)
        assert case.model.count() == 0

        # Default thin is ordinary foreground: it exits and leaves no daemon.
        default = case.client([], case.workspace.project_a, 'default-foreground')
        default.pump_until(lambda: default.idle_after(0), 'default interactive idle', 30,
                           guard=case.model.check)
        default.send(b'\x04')
        code = default.wait_exit('default exit', 25)
        default.drain()
        assert code == 0, 'ordinary thin exit status %r' % (code,)
        assert not runtime_sockets(case.workspace.runtime), 'plain thin left a daemon endpoint'
        assert_no_live_endpoint(case, timeout=3)
        assert session_files(case.workspace.project_a) == [], 'empty chat created a session'
        assert case.model.count() == 0, 'plain thin startup inferred'
        return {'case': 'no-service', 'conflicts': 10, 'requests': 0}
    finally:
        case.close()


# ---------------------------------------------------------------------------
# Case 2: client killed mid-task, worker completes, attach replays result
# ---------------------------------------------------------------------------

def case_detach_continues(app, base):
    case = Case(app, base, 'case2-detach')
    case.state.update({'seen': threading.Event(), 'gate': threading.Event()})
    case.start_model(detach_plan)
    project = case.workspace.project_a
    try:
        case.start_daemon()
        client = case.client(['--connect'], project, 'detach-client')
        client.pump_until(lambda: client.idle_after(0), 'connect launcher idle', 30,
                          guard=case.model.check)
        mark = client.mark()
        client.send_line('/cd ' + str(project))
        client.pump_until(lambda: client.idle_after(mark, b'Launcher directory:'), 'launcher cd completed', 20,
                          guard=case.model.check)
        client.send_line(DETACH_PROMPT)
        case.wait_prompt(DETACH_PROMPT)
        assert case.model.count(DETACH_PROMPT) == 1, 'expected exactly one gated request'
        # Drop the front end by killing its process: not Ctrl-C, not /exit.
        client.kill()
        client.wait(10)
        assert case.model.count(DETACH_PROMPT) == 1
        case.state['gate'].set()
        wait_checkpoint(project, DETACH_ANSWER)
        assert case.model.count(DETACH_PROMPT) == 1, 'daemon replayed or repeated the request'
        assert case.daemon.proc.poll() is None, 'daemon exited with the client'

        ident = session_id(project)
        attached = case.client(['--attach', ident], project, 'detach-attach')
        attached.pump_until(
            lambda: attached.idle_after(0, DETACH_ANSWER.encode()),
            'attached completed answer', 40, guard=case.model.check)
        assert case.model.count() == 1, 'attach caused new inference'
        assert DETACH_ANSWER in attached.screen_text(), 'completed answer missing after attach'
        attached.send(b'\x04')
        assert attached.wait_exit('attached exit', 25) == 0
        assert session_files(project)[0].name == ident + '.session'
        return {'case': 'detach', 'id': ident, 'requests': case.model.count()}
    finally:
        case.close()


# ---------------------------------------------------------------------------
# Case 3: parallel project sessions, root isolation, ls, failed /cd
# ---------------------------------------------------------------------------

def ls_view(case, cwd, running=False, at_least=1, timeout=30):
    client = case.client(['--connect'], cwd, 'ls-client-%d' % len(case.children))
    try:
        client.pump_until(lambda: client.idle_after(0), 'ls launcher idle', 30,
                          guard=case.model.check)
        before_text = client.screen_text()
        mark = client.mark()
        client.send_line('/ls --running' if running else '/ls')
        if at_least:
            client.pump_until(lambda: client.frame_after(mark) and
                              len(HEX32.findall(client.screen_text())) >= at_least,
                              'ls listing', timeout, guard=case.model.check)
        else:
            # No absence marker exists; wait for a rendered listing change and a
            # short settled observation window instead of parsing the echo only.
            client.pump_until(lambda: client.frame_after(mark) and
                              client.screen_text() != before_text,
                              'ls listing', timeout, guard=case.model.check)
            client.pump(0.6)
        ids = set(HEX32.findall(client.screen_text()))
        client.send(b'\x04')
        code = client.wait_exit('ls client exit', 20)
        assert code == 0, 'launcher /ls exit status %r' % (code,)
        return ids
    finally:
        client.cleanup()


def case_parallel(app, base):
    case = Case(app, base, 'case3-parallel')
    case.state.update({
        'project_a': case.workspace.project_a,
        'project_b': case.workspace.project_b,
        'a1': threading.Event(), 'b1': threading.Event(),
        'a2': threading.Event(), 'b2': threading.Event(),
        'release': threading.Event(),
    })
    case.start_model(parallel_plan)
    project_a, project_b = case.workspace.project_a, case.workspace.project_b
    try:
        case.start_daemon()
        client_a = case.client(['--connect'], project_a, 'parallel-a')
        client_a.pump_until(lambda: client_a.idle_after(0), 'A launcher idle', 30,
                            guard=case.model.check)
        mark = client_a.mark()
        # A failing /cd must keep the previous launcher directory/connection.
        client_a.send_line('/cd /nonexistent-owned-directory-%d' % os.getpid())
        client_a.pump_until(lambda: client_a.frame_after(mark, b'Directory is not accessible; launcher unchanged'), 'failed cd completed', 20,
                            guard=case.model.check)
        mark = client_a.mark()
        client_a.send_line('/cd ' + str(project_a))
        client_a.pump_until(lambda: client_a.idle_after(mark, b'Launcher directory:'), 'cd to A completed', 20,
                            guard=case.model.check)
        client_a.send_line(PAR_A_PROMPT)
        case.wait_prompt(PAR_A_PROMPT)
        assert case.state['a1'].wait(10), 'A request never reached the model'

        client_b = case.client(['--connect'], project_b, 'parallel-b')
        client_b.pump_until(lambda: client_b.idle_after(0), 'B launcher idle', 30,
                            guard=case.model.check)
        mark = client_b.mark()
        client_b.send_line('/cd ' + str(project_b))
        client_b.pump_until(lambda: client_b.idle_after(mark, b'Launcher directory:'), 'cd to B completed', 20,
                            guard=case.model.check)
        client_b.send_line(PAR_B_PROMPT)
        case.wait_prompt(PAR_B_PROMPT)
        assert case.state['b1'].wait(10), 'B request never reached the model'

        # Both sessions are now executing their second round: real parallelism.
        assert case.state['a2'].wait(30), 'A did not continue in parallel'
        assert case.state['b2'].wait(30), 'B did not continue in parallel'
        running_ids = ls_view(case, project_a, running=True, at_least=2)
        assert len(running_ids) >= 2, '/ls --running hid live sessions: %r' % (running_ids,)

        case.state['release'].set()
        client_a.pump_until(lambda: client_a.idle_after(0, PAR_A_ANSWER.encode()),
                            'A answer', 40, guard=case.model.check)
        client_b.pump_until(lambda: client_b.idle_after(0, PAR_B_ANSWER.encode()),
                            'B answer', 40, guard=case.model.check)
        assert case.model.count(PAR_A_PROMPT) == 2, 'A must run exactly two rounds'
        assert case.model.count(PAR_B_PROMPT) == 2, 'B must run exactly two rounds'

        ids_a = {SESSION_NAME.match(path.name).group(1) for path in wait_sessions(project_a)}
        ids_b = {SESSION_NAME.match(path.name).group(1) for path in wait_sessions(project_b)}
        assert ids_a and ids_b and ids_a.isdisjoint(ids_b), 'project sessions not isolated'
        all_ids = ls_view(case, project_a, running=False, at_least=2)
        assert ids_a | ids_b <= all_ids, '/ls did not list both sessions: %r' % (all_ids,)
        idle_running = ls_view(case, project_a, running=True, at_least=0)
        assert not (ids_a | ids_b) & idle_running, '/ls --running still listed idle sessions'

        before = (len(session_files(project_a)), len(session_files(project_b)))
        for index in range(3):
            reconnect = case.client(['--connect'], project_a, 'reconnect-%d' % index)
            reconnect.pump_until(lambda: reconnect.idle_after(0), 'reconnect idle', 30,
                                 guard=case.model.check)
            reconnect.send(b'\x04')
            assert reconnect.wait_exit('reconnect exit', 25) == 0
        after = (len(session_files(project_a)), len(session_files(project_b)))
        assert before == after, 'reconnects created empty sessions: %r -> %r' % (before, after)
        assert case.model.count() == 4, 'reconnects inferred: %d' % case.model.count()

        client_a.send(b'\x04')
        client_b.send(b'\x04')
        assert client_a.wait_exit('A exit', 25) == 0
        assert client_b.wait_exit('B exit', 25) == 0
        return {'case': 'parallel', 'ids': sorted(ids_a | ids_b),
                'requests': case.model.count()}
    finally:
        case.close()


# ---------------------------------------------------------------------------
# Case 4: one writable console, explicit takeover, stale controller ignored
# ---------------------------------------------------------------------------

def case_controller(app, base):
    case = Case(app, base, 'case4-controller')
    case.state.update({'seen': threading.Event(), 'release': threading.Event()})
    case.start_model(controller_plan)
    project = case.workspace.project_a
    try:
        case.start_daemon()
        first = case.client(['--connect'], project, 'controller-first')
        first.pump_until(lambda: first.idle_after(0), 'first launcher idle', 30,
                         guard=case.model.check)
        mark = first.mark()
        first.send_line('/cd ' + str(project))
        first.pump_until(lambda: first.idle_after(mark, b'Launcher directory:'), 'cd completed', 20, guard=case.model.check)
        busy = first.mark()
        first.send_line(CONTROLLER_PROMPT)
        case.wait_prompt(CONTROLLER_PROMPT)
        # The model receiving the prompt is not the client drawing a busy frame:
        # wait for a frame rendered after the send that is not idle yet.
        first.pump_until(lambda: first.frame_after(busy) and not first.screen.idle(),
                         'controller busy frame', 30, guard=case.model.check)
        ident = session_id(project)

        # No implicit preemption: plain --attach must be refused.
        second = case.client(['--attach', ident], project, 'controller-second')
        second.pump_until(lambda: second.proc.poll() is not None, 'occupancy refusal', 20)
        second.drain()
        code = second.wait_exit('occupancy refusal', 20)
        assert code != 0, 'a second --attach silently replaced the writable console'
        text = second.text().lower()
        assert any(word in text for word in
                   ('use', 'busy', 'occupied', 'attach', 'console', 'controller', 'takeover')), \
            annotate(second.text(), 'occupancy refusal')
        assert case.model.count() == 1, 'refused attach changed inference'
        assert not first.screen.idle(), 'first controller lost its live task'
        assert case.daemon.proc.poll() is None

        # Explicit takeover becomes the only controller.
        third = case.client(['--attach', ident, '--takeover'], project, 'controller-takeover')
        third.pump_until(lambda: third.frame_after(0, CONTROLLER_PROMPT.encode()),
                         'takeover transcript', 30, guard=case.model.check)
        assert case.model.count() == 1, 'takeover inferred'

        # A stale controller's cancellation must not reach the new epoch.
        if first.proc.poll() is None and first.master is not None:
            try:
                first.send(b'\x03')
            except OSError:
                pass
        time.sleep(1.0)
        assert case.model.count() == 1, 'stale cancellation issued a new request'
        assert case.daemon.proc.poll() is None, 'stale cancellation killed the daemon'

        case.state['release'].set()
        third.pump_until(lambda: third.idle_after(0, CONTROLLER_ANSWER.encode()),
                         'takeover completion', 40, guard=case.model.check)
        assert case.model.count() == 1, 'takeover completion repeated inference'
        wait_checkpoint(project, CONTROLLER_ANSWER)
        third.send(b'\x04')
        assert third.wait_exit('takeover exit', 25) == 0
        return {'case': 'controller', 'id': ident, 'requests': case.model.count()}
    finally:
        case.close()


# ---------------------------------------------------------------------------
# Case 5: ownership boundaries + resume without replay or lock stealing
# ---------------------------------------------------------------------------

def case_ownership(app, base):
    case = Case(app, base, 'case5-ownership')
    case.start_model(ownership_plan)
    project_a, project_b = case.workspace.project_a, case.workspace.project_b
    try:
        case.start_daemon()

        # -- foreground creates a session; a daemon client may view it only.
        foreground = case.client([], project_a, 'foreground-owner')
        foreground.pump_until(lambda: foreground.idle_after(0), 'foreground idle', 30,
                              guard=case.model.check)
        foreground.send_line(FG_PROMPT)
        foreground.pump_until(lambda: foreground.idle_after(0, FG_ANSWER.encode()),
                              'foreground answer', 40, guard=case.model.check)
        fg_id = session_id(project_a)
        assert (project_a / 'fg-tool-marker').read_text() == 'fg-once'
        assert case.model.count(FG_PROMPT) == 2, 'foreground tool round count'

        viewer = case.client(['--attach', fg_id, '--takeover'], project_a, 'daemon-viewer')
        viewer.pump_until(lambda: viewer.frame_after(0, FG_ANSWER.encode()),
                          'daemon client view of foreground session', 30,
                          guard=case.model.check)
        assert case.model.count() == 2, 'foreground attach caused inference'

        # Source owner closes: the view dies with it, nothing is promoted.
        foreground.send(b'\x04')
        foreground.wait_exit('foreground owner exit', 30)
        deadline = time.monotonic() + 10
        while viewer.proc.poll() is None and time.monotonic() < deadline:
            viewer.pump(0.05)
        viewer.pump(0.5)
        assert case.model.count() == 2, 'daemon client promoted the foreground session'
        assert (project_a / 'fg-tool-marker').read_text() == 'fg-once', \
            'foreground tool re-executed after owner exit'
        assert lock_is_free(project_a, fg_id), 'foreground writer lock was not released'
        if viewer.proc.poll() is None:
            viewer.send(b'\x04')
            viewer.wait_exit('viewer exit', 20)

        # Foreground --resume shows history without new inference or tools.
        resume_fg = case.client(['--resume', fg_id], project_a, 'foreground-resume')
        resume_fg.pump_until(lambda: resume_fg.idle_after(0, FG_ANSWER.encode()),
                             'foreground resume history', 40, guard=case.model.check)
        assert case.model.count() == 2, 'foreground resume inferred'
        assert (project_a / 'fg-tool-marker').read_text() == 'fg-once'
        resume_fg.send(b'\x04')
        assert resume_fg.wait_exit('foreground resume exit', 25) == 0

        # -- daemon creates a session; another client may view it only by an
        # explicit takeover, because the daemon client still owns the console.
        daemon_client = case.client(['--connect'], project_b, 'daemon-creator')
        daemon_client.pump_until(lambda: daemon_client.idle_after(0), 'daemon launcher idle', 30,
                                 guard=case.model.check)
        mark = daemon_client.mark()
        daemon_client.send_line('/cd ' + str(project_b))
        daemon_client.pump_until(lambda: daemon_client.idle_after(mark, b'Launcher directory:'), 'daemon cd completed', 20,
                                 guard=case.model.check)
        daemon_client.send_line(DB_PROMPT)
        daemon_client.pump_until(lambda: daemon_client.idle_after(0, DB_ANSWER.encode()),
                                 'daemon answer', 40, guard=case.model.check)
        db_id = session_id(project_b)
        assert (project_b / 'db-tool-marker').read_text() == 'db-once'
        before = case.model.count()
        assert before == 4, 'daemon ownership rounds: %d' % before

        plain_attach = case.client(['--attach', db_id, '--takeover'], project_b,
                                   'takeover-attach')
        plain_attach.pump_until(lambda: plain_attach.idle_after(0, DB_ANSWER.encode()),
                                'takeover attach to daemon session', 30, guard=case.model.check)
        assert case.model.count() == before, 'takeover attach inferred'
        daemon_client.send(b'\x04')
        assert daemon_client.wait_exit('daemon client exit', 25) == 0
        plain_attach.send(b'\x04')
        assert plain_attach.wait_exit('plain attach exit', 25) == 0

        # Source owner (daemon) closes: resume must not replay anything.
        stop_daemon(case)
        assert (project_b / 'db-tool-marker').read_text() == 'db-once'
        assert lock_is_free(project_b, db_id), 'daemon stop did not release the writer lock'

        resume_one = case.client(['--resume', db_id], project_b, 'daemon-resume-one')
        resume_one.pump_until(lambda: resume_one.idle_after(0, DB_ANSWER.encode()),
                              'daemon resume history', 40, guard=case.model.check)
        assert case.model.count() == before, 'resume inferred'
        # Second writer must be refused while the first resume holds the lock.
        resume_two = case.client(['--resume', db_id], project_b, 'daemon-resume-two')
        resume_two.pump_until(lambda: resume_two.proc.poll() is not None,
                              'second resume refusal', 25)
        resume_two.drain()
        assert resume_two.wait_exit('second resume refusal', 20) != 0, \
            'second writer silently stole the checkpoint lock'
        assert case.model.count() == before, 'refused resume inferred'
        assert (project_b / 'db-tool-marker').read_text() == 'db-once'
        resume_one.send(b'\x04')
        assert resume_one.wait_exit('daemon resume exit', 25) == 0
        return {'case': 'ownership', 'foreground': fg_id, 'daemon': db_id,
                'requests': case.model.count()}
    finally:
        case.close()


# ---------------------------------------------------------------------------
# Case 6: offline dangerous command needs explicit approval
# ---------------------------------------------------------------------------

def case_offline_approval(app, base):
    case = Case(app, base, 'case6-approval')
    case.state.update({'approved': threading.Event(), 'victim': None})
    project = case.workspace.project_a
    victim = project / 'protected-owned-dir'
    victim.mkdir(parents=True)
    (victim / 'keep.txt').write_text('owned\n')
    case.state['victim'] = victim
    case.start_model(approval_plan)
    try:
        case.start_daemon()
        client = case.client(['--connect'], project, 'approval-client')
        client.pump_until(lambda: client.idle_after(0), 'approval launcher idle', 30,
                          guard=case.model.check)
        mark = client.mark()
        client.send_line('/cd ' + str(project))
        client.pump_until(lambda: client.idle_after(mark, b'Launcher directory:'), 'approval cd completed', 20,
                          guard=case.model.check)
        client.send_line(APPROVAL_PROMPT)
        client.pump_until(lambda: client.frame_after(0, b'Approval #'), 'approval popup', 40,
                          guard=case.model.check)
        assert victim.exists(), 'dangerous command ran before any approval'
        ident = session_id(project)

        # No client connected: the approval must stay pending, never self-grant.
        client.kill()
        client.wait(10)
        time.sleep(2.5)
        assert victim.is_dir() and (victim / 'keep.txt').is_file(), \
            'offline approval was auto-granted'
        assert case.model.count(APPROVAL_PROMPT) == 1, 'offline approval continued inference'

        attached = case.client(['--attach', ident], project, 'approval-attach')
        attached.pump_until(
            lambda: attached.frame_after(0, b'Approval #') and
            b'Allow once' in attached.capture and b'Deny' in attached.capture,
            'full approval popup frame', 40, guard=case.model.check)
        assert victim.exists(), 'reattached popup had already executed the command'
        full_frame = attached.capture.decode('utf-8', 'replace')
        assert 'rm -rf' in full_frame, 'approval preview lost the command'
        assert case.model.count(APPROVAL_PROMPT) == 1, 'popup caused inference'

        # Explicit approval: arrows select the one-shot allow, Enter confirms.
        before = attached.mark()
        attached.send(b'\x1b[A')
        attached.pump_until(
            lambda: attached.frame_after(before) and
            b'> Allow once' in attached.capture[before:],
            'allow-once selection acknowledged', 25, guard=case.model.check)
        attached.send(b'\r')
        attached.pump_until(lambda: attached.idle_after(0, APPROVAL_ANSWER.encode()),
                            'approved completion', 40, guard=case.model.check)
        assert not victim.exists(), 'approved command did not remove the owned directory'
        assert case.model.count(APPROVAL_PROMPT) == 2, 'approved round count'
        body = case.model.snapshot()[-1]
        calls, results = tool_history(body)
        assert len(calls) == 1 and calls[0]['id'] == 'approval-tool-1', 'duplicate execution'
        assert results.get('approval-tool-1') is not None
        attached.send(b'\x04')
        assert attached.wait_exit('approval exit', 25) == 0
        return {'case': 'approval', 'id': ident, 'requests': case.model.count()}
    finally:
        case.close()


# ---------------------------------------------------------------------------
# Case 7: daemon SIGTERM reclaims workers and owned background services
# ---------------------------------------------------------------------------

def case_daemon_reclaim(app, base):
    case = Case(app, base, 'case7-reclaim')
    project = case.workspace.project_a
    script = project / SERVICE_SCRIPT
    script.write_text(SERVICE_SOURCE)
    # Absolute owned path: the cmdline ownership check matches this exactly.
    case.state['service_cmd'] = 'exec python3 -u %s %s daemon' % (
        shlex.quote(str(script)), SERVICE_MARKER)
    case.start_model(service_plan, limits=SERVICE_LIMITS)
    service_pid = None
    try:
        daemon = case.start_daemon()
        client = case.client(['--connect'], project, 'reclaim-client')
        client.pump_until(lambda: client.idle_after(0), 'reclaim launcher idle', 30,
                          guard=case.model.check)
        mark = client.mark()
        client.send_line('/cd ' + str(project))
        client.pump_until(lambda: client.idle_after(mark, b'Launcher directory:'), 'reclaim cd completed', 20,
                          guard=case.model.check)
        client.send_line(SERVICE_PROMPT)
        client.pump_until(lambda: client.idle_after(0, SERVICE_ANSWER.encode()),
                          'service start answer', 40, guard=case.model.check)
        service_pid, service_port = wait_service_ready(project)
        assert case.model.count(SERVICE_PROMPT) == 2
        client.send(b'\x04')
        assert client.wait_exit('reclaim client exit', 25) == 0

        workers = children_of(daemon.proc.pid)
        stopping = time.monotonic()
        code = stop_daemon(case)
        shutdown_seconds = round(time.monotonic() - stopping, 3)
        # The service only exits SERVICE_STOP_DELAY after it was TERM'd by the
        # worker, so a daemon that returned after the old 2s + 1s worker kill
        # window cannot have waited for it.
        assert_service_gone_now(service_pid, service_port, script)
        assert shutdown_seconds > SERVICE_STOP_DELAY - 0.1, \
            'daemon stopped in %.3fs, before the owned service cleanup finished' % shutdown_seconds
        wait_service_gone(service_pid, service_port)
        service_pid = None
        assert case.model.count() == 2, 'SIGTERM injected inference'
        assert no_pid_resignal(daemon.proc.pid), 'stale daemon PID was signalled again'
        return {'case': 'reclaim', 'daemonExit': code, 'workersDiscovered': sorted(workers),
                'servicePortClosed': service_port, 'shutdownSeconds': shutdown_seconds}
    finally:
        if service_pid is not None:
            kill_service_if_alive(service_pid, script)
        case.close()


def no_pid_resignal(pid):
    """Ownership rule check: a reaped daemon PID is never signalled by teardown."""
    return not Path('/proc/%d' % pid).exists()


# ---------------------------------------------------------------------------

def case_streaming(app, base, daemon=False):
    """A fast SSE must stay incremental while its terminal event is withheld."""
    import re
    case = Case(app, base, 'stream-daemon' if daemon else 'stream-foreground')
    release = threading.Event()
    case.state['stream_release'] = release
    sent = []
    count = 1600

    class StreamFixture(ModelFixture):
        def emit(self, handler, value):
            handler.send_response(200)
            handler.send_header('Content-Type', 'text/event-stream')
            handler.send_header('Connection', 'close')
            handler.close_connection = True
            handler.end_headers()
            for index in range(count):
                frame = {'choices': [{'index': 0, 'delta': {'content': 'K%04d ' % index},
                                       'finish_reason': None}]}
                # One monotonic clock covers send-start and PTY observation.
                # Record before flush so an immediately visible byte cannot
                # race ahead of its timestamp in the fixture thread.
                sent.append(time.monotonic())
                handler.wfile.write(b'data: ' + json.dumps(frame).encode() + b'\n\n')
                handler.wfile.flush()
                if release.wait(0.002):
                    return
            assert release.wait(20), 'frontend did not display the stream before completion'
            frame = {'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}],
                     'usage': {'prompt_tokens': 120, 'completion_tokens': count,
                               'total_tokens': 120 + count}}
            handler.wfile.write(b'data: ' + json.dumps(frame).encode() + b'\n\ndata: [DONE]\n\n')
            handler.wfile.flush()

    try:
        case.model = StreamFixture(lambda body: text_answer('unused'))
        write_config(case.workspace.home, case.model.start())
        project = case.workspace.project_a
        if daemon:
            case.start_daemon()
        client = case.client(['--connect'] if daemon else [], project, 'stream-view')
        client.pump_until(lambda: client.idle_after(0), 'stream initial idle', 25,
                          guard=case.model.check)
        if daemon:
            mark = client.mark()
            client.send_line('/cd ' + str(project))
            client.pump_until(lambda: client.idle_after(mark, b'Launcher directory:'), 'stream project completed', 20,
                              guard=case.model.check)
        mark = client.mark()
        client.send_line('Stream the owned sequence without tool calls.')
        deadline = time.monotonic() + 15
        latest = -1
        maximum_lag = 0
        updates = 0
        visible_latency_ms = []
        while time.monotonic() < deadline:
            client.pump(0.002)
            case.model.check()
            visible = [int(value) for value in re.findall(r'K(\d{4})', client.screen_text())]
            current = max(visible, default=-1)
            if current > latest:
                observed = time.monotonic()
                # Every newly covered sequence position gets the observation
                # time, not just the freshest chunk (which hides repaint waits).
                visible_latency_ms.extend((observed - sent[index]) * 1000
                                          for index in range(latest + 1, current + 1))
                updates += 1
                latest = current
            # Enough room for scheduling jitter and a complete terminal frame,
            # but not for the 1024-event eviction/history-replay catch-up path.
            lag = len(sent) - 1 - latest
            maximum_lag = max(maximum_lag, lag)
            assert lag <= 256, 'stream display fell behind by %d events' % lag
            if latest == count - 1:
                break
        assert latest == count - 1, 'stream tail not visible while final event is gated'
        assert updates >= 8, 'stream collapsed into a final bulk repaint'
        ordered_latency = sorted(visible_latency_ms)
        latency = {'p50_ms': round(ordered_latency[len(ordered_latency) // 2], 3),
                   'p95_ms': round(ordered_latency[(len(ordered_latency) * 95 - 1) // 100], 3),
                   'max_ms': round(max(ordered_latency), 3),
                   'samples': len(ordered_latency),
                   'scope': 'SSE send-start to owned PTY observed sequence coverage'}
        print('STREAM_LATENCY ' + json.dumps(latency), flush=True)
        assert latency['p95_ms'] <= 30, 'stream p95 visibility latency exceeded 30ms: %s' % latency
        assert not release.is_set(), 'completion gate opened before incremental visibility'
        release.set()
        client.pump_until(lambda: client.idle_after(mark, b'K1599'), 'stream final idle', 20,
                          guard=case.model.check)
        assert case.model.count() == 1, 'stream recovery repeated inference'
        client.send(b'\x04')
        assert client.wait_exit('stream frontend exit', 20) == 0
        return {'case': 'stream-daemon' if daemon else 'stream-foreground',
                'requests': 1, 'chunks': len(sent), 'visible_updates': updates,
                'max_pending_chunks': maximum_lag, 'tail_before_finish': True,
                'visibility_latency': latency}
    finally:
        release.set()
        case.close()


def main():
    if len(sys.argv) != 2 or sys.platform != 'linux':
        raise SystemExit('usage: python3 tests/product/daemon_mock.py /absolute/path/thin')
    app = str(Path(sys.argv[1]).resolve(strict=True))
    assert_screen_idle_contract()
    results = []
    with tempfile.TemporaryDirectory(prefix='thin-daemon-owned-') as base:
        root = Path(base)
        root.chmod(0o700)
        cases = (
            ('no service and mode conflicts', case_no_service),
            ('daemon detach and attach completion', case_detach_continues),
            ('parallel project sessions', case_parallel),
            ('single console and takeover', case_controller),
            ('ownership boundaries and resume', case_ownership),
            ('offline dangerous approval', case_offline_approval),
            ('daemon SIGTERM reclaim', case_daemon_reclaim),
            ('foreground incremental stream', case_streaming),
            ('daemon incremental stream', lambda app, root: case_streaming(app, root, daemon=True)),
        )
        for label, run_case in cases:
            evidence = run_case(app, root)
            results.append(evidence)
            print('PASS daemon %s: %s' % (label, json.dumps(evidence)))
        (root / 'evidence.json').write_text(json.dumps({'cases': results}, indent=2) + '\n')
    print('PASS test-daemon: owned daemon, PTY attach/takeover, offline approval, '
          'SIGTERM reclaim; no real API, no real SSH port')


if __name__ == '__main__':
    main()
