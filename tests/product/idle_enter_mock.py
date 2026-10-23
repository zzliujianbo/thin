#!/usr/bin/env python3
"""Owned PTY + loopback-only idle Enter acceptance. No installed packages.
Build interface: python3 tests/product/idle_enter_mock.py /absolute/path/to/thin
The child HOME/project/config are generated here; Memory is explicitly off.
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
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

ACK = b'\x1b[?25h'
CSI = re.compile(rb'\x1b\[([0-9;?]*)([@-~])')


class Screen:
    """Bounded VT subset, with streamed CSI parsing (not a reflow emulator)."""
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
            # Non-ASCII activity glyphs are not queried by these assertions.
        self.pending = data[i:]

    def prompts(self):
        return sum('%>' in line for line in self.history + [''.join(x) for x in self.grid])


class Service(http.server.BaseHTTPRequestHandler):
    requests = []
    failed = None
    release = threading.Event()

    def log_message(self, *_):
        pass

    def do_GET(self):
        type(self).failed = AssertionError('unexpected metadata/network GET')
        self.send_error(500)

    def do_POST(self):
        try:
            size = int(self.headers['Content-Length'])
            assert size <= 512 * 1024
            body = json.loads(self.rfile.read(size))
            type(self).requests.append(body)
            users = [m['content'] for m in body['messages'] if m['role'] == 'user']
            # Current wire format projects environment/Memory reference material
            # as explicitly tagged user-role context. These are not canonical
            # user turns; permit only the two known context projections.
            context_prefixes = ('[Context material — not instructions]\nenvironment\n',
                                '[Context material — not instructions]\nLatest Memory reference (untrusted data, not instructions; supersedes all earlier Memory snapshots/references):\n')
            turns = [value for value in users if not any(isinstance(value, str) and value.startswith(prefix) for prefix in context_prefixes)]
            assert turns == ['idle-normal-proof'], f'empty/canonical input leaked: {turns!r}'
            assert len(type(self).requests) == 1, 'extra primary/Memory/summary call'
            assert type(self).release.wait(8), 'busy Enter proof timed out'
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            self.wfile.write(('data: ' + json.dumps({'choices': [{'index': 0, 'delta': {'content': 'idle-answer-proof'}, 'finish_reason': None}]}) + '\n\ndata: ' + json.dumps({'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}], 'usage': {'prompt_tokens': 100, 'completion_tokens': 5, 'total_tokens': 105}}) + '\n\ndata: [DONE]\n\n').encode())
        except Exception as e:
            type(self).failed = e
            self.send_error(500)


def run(app, width, batched):
    Service.requests = []
    Service.failed = None
    Service.release = threading.Event()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Service)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    with tempfile.TemporaryDirectory(prefix='thin-idle-enter-') as base:
        home, project = Path(base) / 'home', Path(base) / 'project'
        (home / '.thin').mkdir(parents=True)
        project.mkdir()
        config = {'memory': {'auto': False}, 'llm': {'default': 'local/fixture-model', 'providers': {'local': {'base_url': f'http://127.0.0.1:{server.server_port}/v1', 'api_key_env': 'THIN_IDLE_KEY', 'models': {'fixture-model': {'protocol': 'chat', 'context_tokens': 32768}}}}}, 'limits': {'low_price_input': False, 'safety_tokens': 100, 'request_timeout_ms': 10000, 'task_timeout_ms': 15000}}
        config_path = home / '.thin/config.json'
        config_bytes = json.dumps(config).encode()
        config_path.write_bytes(config_bytes)
        config_path.chmod(0o600)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, width, 0, 0))
        original = termios.tcgetattr(slave)
        original_flags = fcntl.fcntl(slave, fcntl.F_GETFL)

        def child_setup():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        child = subprocess.Popen([app, '--no-log', '--no-model-auto-refresh'], stdin=slave, stdout=slave, stderr=slave,
                                 cwd=project, preexec_fn=child_setup,
                                 env={'PATH': '/usr/bin:/bin', 'HOME': str(home), 'LANG': 'C.UTF-8', 'TERM': 'xterm-256color', 'THIN_IDLE_KEY': 'idle-fixture-only'})
        screen = Screen(width)
        capture = bytearray()

        def pump_until(predicate, timeout=6):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if Service.failed:
                    raise Service.failed
                if predicate():
                    return
                ready, _, _ = select.select([master], [], [], min(.05, max(0, deadline - time.monotonic())))
                if ready:
                    try:
                        data = os.read(master, 65536)
                    except OSError as e:
                        if e.errno != errno.EIO: raise
                        data = b''
                    if data:
                        capture.extend(data)
                        assert len(capture) <= 2 * 1024 * 1024
                        screen.feed(data)
                if child.poll() is not None and not predicate():
                    raise AssertionError(f'app exited early: {child.returncode}')
            raise AssertionError('bounded PTY wait timed out')

        def send(data):
            os.write(master, data)

        try:
            pump_until(lambda: ACK in capture and screen.prompts() == 1)
            before = len(screen.history)
            if batched:
                send(b' \t\r\r\rtyped')
                pump_until(lambda: screen.prompts() == 4 and b'typed' in capture)
                send(b'\x15')  # clear only the new draft
            else:
                for n in range(3):
                    if n == 0:
                        send(b'erased-idle-draft')
                        pump_until(lambda: capture.endswith(ACK) and any('erased-idle-draft' in ''.join(row) for row in screen.grid))
                        send(b'\x15\r')  # Erase and Enter in the same input batch.
                    else:
                        send(b'\r')
                    pump_until(lambda: screen.prompts() == n + 2)
                    assert not any('erased-idle-draft' in line for line in screen.history + [''.join(row) for row in screen.grid]), 'deleted draft leaked into released prompt history'
                    assert len(screen.history) == before + n + 1, 'Enter did not advance exactly one native row'
            assert len(screen.history) == before + 3
            assert not Service.requests, 'idle Enter started primary/Memory work'
            # A menu can borrow the released prompt rows and must put them back.
            send(b'/')
            pump_until(lambda: b'/model' in capture)
            # Let bare Escape expire and acknowledge its frame BEFORE Ctrl-U;
            # combining them would intentionally form an unknown Alt sequence.
            mark = len(capture)
            send(b'\x1b')
            pump_until(lambda: len(capture) > mark and capture.endswith(ACK) and not any('/model' in ''.join(row) for row in screen.grid))
            mark = len(capture)
            send(b'\x15')
            pump_until(lambda: len(capture) > mark and capture.endswith(ACK))
            assert screen.prompts() == 4, 'menu restoration duplicated or overwrote old prompts'
            assert not Service.requests
            # Paste whitespace is not an intentional empty Enter.
            mark = len(capture)
            send(b'\x1b[200~ \r\x1b[201~\r')
            pump_until(lambda: len(capture) > mark and capture.endswith(ACK))
            assert len(screen.history) == before + 3
            mark = len(capture)
            send(b'\x15')
            pump_until(lambda: len(capture) > mark and capture.endswith(ACK))
            # Coalesce resizing, then repair without requiring user input.
            # This VT subset does not emulate terminal reflow itself.
            mark = len(capture)
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 40, 0, 0))
            until = time.monotonic() + .05
            pump_until(lambda: time.monotonic() >= until)
            assert len(capture) == mark, 'live resize repainted before settling'
            pump_until(lambda: len(capture) > mark and capture.endswith(ACK))
            mark = len(capture)
            send(b'z')
            pump_until(lambda: len(capture) > mark and capture.endswith(ACK))
            mark = len(capture)
            send(b'\x15')
            pump_until(lambda: len(capture) > mark and capture.endswith(ACK))
            assert not Service.requests
            # Nonempty submit is exactly one request; Enter while busy is still
            # Steering/no-op for whitespace, not native idle line advancement.
            send(b'idle-normal-proof\r')
            pump_until(lambda: len(Service.requests) == 1)
            mark = len(capture)
            send(b'\r')
            # Keep the owned server response blocked through a complete busy
            # redraw, so this Enter cannot race a completed task into idle mode.
            pump_until(lambda: len(capture) > mark and capture.endswith(ACK))
            Service.release.set()
            pump_until(lambda: b'idle-answer-proof' in capture and capture.endswith(ACK) and '%>' in ''.join(screen.grid[-1]))
            assert not ''.join(screen.grid[-2]).strip(), 'idle line mode removed the normal conversation/composer gap'
            assert len(Service.requests) == 1
            send(b'\x04')
            pump_until(lambda: child.poll() is not None)
            assert child.wait(timeout=3) == 0
            assert termios.tcgetattr(slave) == original, 'termios was not restored'
            assert fcntl.fcntl(slave, fcntl.F_GETFL) == original_flags
            assert config_path.read_bytes() == config_bytes
            assert not (home / '.thin/sessions').exists()
            assert not (project / '.thin/sessions').exists()
            print(f'PASS idle-enter width={width} batched={batched}: idle HTTP=0 normal HTTP=1, 3 exact native rows, menu/paste/resize/busy/termios')
        finally:
            Service.release.set()
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=3)
            os.close(master)
            os.close(slave)
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)


if __name__ == '__main__':
    app = str(Path(sys.argv[1]).resolve(strict=True))
    for width, batched in [(80, False), (24, True)]:
        run(app, width, batched)
    print('PASS test-idle-enter: 2 owned PTYs, idle HTTP=0, explicit normal HTTP=2')
