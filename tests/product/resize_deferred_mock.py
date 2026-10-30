#!/usr/bin/env python3
"""Owned PTY/loopback passive resize invalidation + fresh-ACK acceptance.
No real API/config. Byte-level checks complement emulator viewport acceptance.
A size change only takes the new dimensions, releases interrupted controls and
drops old-frame authority: no automatic repair, no bottom jump, no replay. It
must stay quiescent past the former 150ms debounce; real input or new server
content draws the next complete frame at the new size.
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
import unicodedata

ACK = b'\x1b[?25h'
SYNC_BEGIN = b'\x1b[?2026h'
# A complete frame releases synchronized display and then shows the cursor
# (src/ui/terminal.zig). Exit and resize-rescue bytes reuse the bare cursor-show
# and the bare sync release, so completion needs this exact pair.
FRAME_END = b'\x1b[?2026l' + ACK
# A resize may release interrupted controls only (CAN, SGR reset, sync release,
# cursor show); any interface payload or drawn frame is a failure.
CONTROL_RELEASE = re.compile(rb'\x18|\x1b\[\?2026[lh]|\x1b\[\?25[hl]|\x1b\[0m')
CSI = re.compile(rb'\x1b\[([0-9;?]*)([@-~])')


def cells(raw):
    """Display cells of one styled frame line.

    Callers pass frame bytes with their SGR/CSI styling still in place, so the
    escapes are stripped here. UTF-8 byte length is not a cell count: combining
    marks occupy no cell, an ASCII or other single-cell glyph one, and an East
    Asian wide/fullwidth glyph two. No third-party width table is needed.
    """
    return sum(0 if unicodedata.combining(ch) else 2 if unicodedata.east_asian_width(ch) in ('W', 'F') else 1
               for ch in CSI.sub(b'', raw).decode('utf-8'))


class Service(http.server.BaseHTTPRequestHandler):
    requests = 0
    failed = None
    more = threading.Event()
    finish_gate = threading.Event()

    def log_message(self, *_):
        pass

    def do_GET(self):
        type(self).failed = 'unexpected GET'
        self.send_error(500)

    def do_POST(self):
        cls = type(self)
        try:
            cls.requests += 1
            assert cls.requests == 1 and self.path == '/v1/chat/completions'
            n = int(self.headers['Content-Length'])
            assert 0 < n < 512 * 1024
            body = json.loads(self.rfile.read(n))
            assert not any(k in body for k in ('max_tokens', 'max_completion_tokens', 'max_output_tokens'))
            assert any(m.get('role') == 'user' and m.get('content') == 'resize-stream-proof' for m in body['messages'])
            def event(text):
                return ('data: ' + json.dumps({'choices': [{'index': 0, 'delta': {'content': text}, 'finish_reason': None}]}) + '\n\n').encode()

            def chunk(text):
                self.wfile.write(event(text))
                self.wfile.flush()

            # Unframed HTTP/1.0 SSE is valid. Coalesce header + first event to
            # exercise a buffered body prefix, then withhold the next event.
            self.wfile.write(b'HTTP/1.0 200 OK\r\nContent-Type: text/event-stream\r\n\r\n' + event('before-resize-proof '))
            self.wfile.flush()
            assert cls.more.wait(12), 'stream middle gate timeout'
            chunk('after-resize-proof ')
            assert cls.finish_gate.wait(12), 'stream finish gate timeout'
            self.wfile.write(('data: ' + json.dumps({'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}], 'usage': {'prompt_tokens': 100, 'completion_tokens': 10, 'total_tokens': 110}}) + '\n\ndata: [DONE]\n\n').encode())
            self.wfile.flush()
        except Exception:
            cls.failed = 'loopback stream contract failed'


class OwnedServer(http.server.ThreadingHTTPServer):
    handler_done = threading.Event()

    def handle_error(self, request, client_address):
        Service.failed = 'owned HTTP handler lifecycle failed'

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.handler_done.set()


def run(app):
    server = OwnedServer(('127.0.0.1', 0), Service)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='thin-resize-') as root:
            home, project = Path(root) / 'home', Path(root) / 'project'
            # The foreground starts its own AF_UNIX worker under
            # $XDG_RUNTIME_DIR/thin. An owned short base keeps every socket
            # inside this fixture instead of the shared /tmp/thin-<uid> fallback.
            runtime = Path(root) / 'r'
            runtime.mkdir(mode=0o700)
            assert runtime.is_absolute() and (runtime.stat().st_mode & 0o777) == 0o700, 'owned runtime must be an absolute 0700 directory'
            assert len(str(runtime)) + 14 + 32 + 5 <= 107, 'AF_UNIX socket path budget exceeded'
            (home / '.thin').mkdir(parents=True)
            project.mkdir()
            config = {'memory': {'auto': False}, 'llm': {'default': 'owned/fixture-model', 'providers': {'owned': {'base_url': f'http://127.0.0.1:{server.server_port}/v1', 'api_key_env': 'THIN_RESIZE_KEY', 'models': {'fixture-model': {'protocol': 'chat', 'context_tokens': 32768}}}}}, 'limits': {'low_price_input': False, 'safety_tokens': 100, 'request_timeout_ms': 20000, 'task_timeout_ms': 30000}}
            path = home / '.thin/config.json'
            path.write_text(json.dumps(config))
            path.chmod(0o600)
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
            original = termios.tcgetattr(slave)
            flags = fcntl.fcntl(slave, fcntl.F_GETFL)
            # Acquire only this owned slave as the child's controlling TTY.
            # Do it after exec of a single-threaded launcher, not Python
            # preexec_fn after forking the parent's HTTP server thread.
            launcher = 'import fcntl, os, sys, termios; fcntl.ioctl(0, termios.TIOCSCTTY, 0); os.execv(sys.argv[1], sys.argv[1:])'
            child = subprocess.Popen([sys.executable, '-c', launcher, app, '--no-model-auto-refresh'], stdin=slave, stdout=slave, stderr=slave, cwd=project, start_new_session=True,
                                     env={'PATH': '/usr/bin:/bin', 'HOME': str(home), 'XDG_RUNTIME_DIR': str(runtime), 'LANG': 'C.UTF-8', 'TERM': 'xterm-256color', 'THIN_RESIZE_KEY': 'owned-resize-fake-only'})
            capture = bytearray()

            def pump(duration=.03):
                deadline = time.monotonic() + duration
                while time.monotonic() < deadline:
                    ready, _, _ = select.select([master], [], [], max(0, min(.02, deadline - time.monotonic())))
                    if ready:
                        try:
                            data = os.read(master, 65536)
                        except OSError as e:
                            if e.errno != errno.EIO:
                                raise
                            data = b''
                        capture.extend(data)
                        assert len(capture) < 2 * 1024 * 1024, 'capture bound'
                    assert Service.failed is None, Service.failed

            def wait(predicate, timeout=6, label='frame'):
                deadline = time.monotonic() + timeout
                while not predicate():
                    assert time.monotonic() < deadline, f'bounded PTY predicate timeout: {label}'
                    assert child.poll() is None, f'early child exit ({child.returncode})'
                    pump()

            def key(data):
                before = capture.count(ACK)
                os.write(master, data)
                wait(lambda: capture.count(ACK) > before, label=f'key ACK at fixture line {sys._getframe(1).f_lineno}')

            def last_frame():
                end = capture.rfind(ACK)
                begin = capture.rfind(SYNC_BEGIN, 0, end)
                return CSI.sub(b'', bytes(capture[max(0, begin):end]))

            def complete_frame(position, needle=b''):
                """CSI-stripped body of the first complete frame after `position`.

                A frame owns authority only through its exact sync_end+cursor-show
                sequence: a bare cursor-show can belong to exit/rescue bytes, a
                CAN aborts the payload, and a newer begin proves this frame never
                completed, so the search re-anchors there. The needle is matched
                after CSI stripping because SGR spans may sit between the
                composer decoration and its text; later spinner-only diffs still
                legitimately omit unchanged body text.
                """
                data = bytes(capture)
                begin = data.find(SYNC_BEGIN, position)
                while begin >= 0:
                    end = data.find(FRAME_END, begin + len(SYNC_BEGIN))
                    if end < 0:
                        return None
                    nested = data.find(SYNC_BEGIN, begin + len(SYNC_BEGIN), end)
                    if nested >= 0:
                        begin = nested  # The earlier begin never completed.
                        continue
                    if b'\x18' in data[begin:end]:
                        begin = data.find(SYNC_BEGIN, begin + len(SYNC_BEGIN))
                        continue  # Aborted payload owns no complete frame.
                    body = CSI.sub(b'', data[begin:end])
                    if needle in body:
                        return body
                    begin = data.find(SYNC_BEGIN, end + len(FRAME_END))
                return None

            def press(data, quiet=.1):
                os.write(master, data)
                pump(quiet)
                assert Service.failed is None, Service.failed

            def hold_resize(rows, columns):
                """Resize is passive: dimensions only, nothing is redrawn.

                The owned file byte stream is the strict oracle here: the former
                implementation repaired the screen 150ms after the last resize,
                so passing that bound without a byte is exactly the approved
                contract. A save/rescue frame therefore needs real input or new
                content, never elapsed time.
                """
                start = len(capture)
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
                os.killpg(child.pid, signal.SIGWINCH)
                pump(.05)
                # Only interrupted terminal controls may be released.
                assert CONTROL_RELEASE.sub(b'', bytes(capture[start:])) == b'', 'live resize emitted interface payload'
                mark = len(capture)
                pump(.22)
                # Past the removed debounce the application still must not draw.
                assert CONTROL_RELEASE.sub(b'', bytes(capture[mark:])) == b'', 'resize-only idle emitted a late payload'
                window = bytes(capture[start:])
                assert SYNC_BEGIN not in window, 'resize-only idle drew a frame'
                assert b'\x1b[999B' not in window, 'resize-only idle jumped to the bottom'
                return window

            try:
                wait(lambda: ACK in capture, label='startup ACK')
                pump(.1)
                for size in [(24, 60), (18, 60), (24, 80)]:
                    # A burst, including the ABA return to the original geometry,
                    # changes dimensions only and never restores old authority.
                    hold_resize(*size)
                assert Service.requests == 0
                start = len(capture)
                key(b'x')  # Real input draws the first fresh frame at the new size.
                typed = complete_frame(start, b'> x')
                assert typed is not None, 'real input drew no complete frame with the typed composer cell'
                typed_lines = [line for line in re.split(rb'\r\n|\r|\n', typed) if line.strip()]
                assert typed_lines and typed_lines[-1].rstrip().endswith(b'> x'), 'typed cell is not on the current composer row'
                key(b'\x15/settings\r')
                assert b'Low-price input' in capture
                initial_bytes = path.read_bytes()
                hold_resize(20, 70)  # Passive resize drops the old complete-frame ACK.
                press(b'\r')  # Confirmation arriving before a fresh frame cannot toggle.
                assert path.read_bytes() == initial_bytes, 'stale settings confirmation saved'
                key(b'\r')
                assert json.loads(path.read_text())['limits']['low_price_input'] is True
                key(b'\r')
                assert json.loads(path.read_text())['limits']['low_price_input'] is False
                key(b'\x1b')
                # Another settings frame may ACK before bare Escape expires.
                # Do not merge the next Ctrl-U/text into that pending Escape.
                wait(lambda: b'Settings>' not in last_frame(), label='settings actually closed')
                assert Service.requests == 0
                before = capture.count(ACK)
                os.write(master, b'\x15resize-stream-proof\r')
                wait(lambda: Service.requests == 1, label='stream command submitted')
                wait(lambda: b'before-resize-proof' in capture and capture.count(ACK) > before, label='first stream content')
                pump(.12)
                # Busy with no new data: the size change alone must stay quiet too.
                hold_resize(18, 64)
                start = len(capture)
                Service.more.set()
                wait(lambda: complete_frame(start, b'after-resize-proof') is not None, label='stream continuation')
                resumed = complete_frame(start, b'after-resize-proof')
                assert resumed is not None, 'stream continuation lost content'
                assert b'after-resize-proof' in resumed, 'stream continuation lost content'
                assert max((cells(line) for line in re.split(rb'\r\n|\r|\n', resumed) if line), default=0) <= 64, 'new frame ignored the resized width'
                before = capture.count(ACK)
                pump(.24)
                assert capture.count(ACK) > before, 'animation did not resume after content'
                Service.finish_gate.set()
                # Stable post-finish frames end with the idle marker (SGR allowed).
                start = len(capture)
                wait(lambda: b'%>' in CSI.sub(b'', bytes(capture[start:])) and ACK in capture[start:], label='completed idle frame')
                os.write(master, b'\x04')
                child.wait(timeout=5)
                pump(.05)
                assert child.returncode == 0
                assert termios.tcgetattr(slave) == original, 'termios not restored'
                assert fcntl.fcntl(slave, fcntl.F_GETFL) == flags, 'fd flags not restored'
                assert server.handler_done.wait(2), 'owned HTTP handler did not finish'
                assert Service.requests == 1 and Service.failed is None, Service.failed
                raw = bytes(capture)
                assert not any(x in raw for x in (b'\x1b[2J', b'\x1b[3J', b'\x1b[?1049h', b'\x1b[?1047h'))
                print('PASS resize-deferred: passive width/height/ABA past the former 150ms debounce, no repair/bottom jump/replay, fresh frame on real input at new dimensions, stale Settings ACK denied, busy quiescence then content/animation resumed, primary=1, menu=0, termios/fd restored')
            finally:
                Service.more.set()
                Service.finish_gate.set()
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait(timeout=2)
                os.close(master)
                os.close(slave)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    try:
        assert len(sys.argv) == 2
        run(str(Path(sys.argv[1]).resolve()))
    except Exception as e:
        # Fixed local diagnostics only; never dump screen, config or model body.
        print(f'FAIL resize-deferred: {type(e).__name__}: {e}', file=sys.stderr)
        sys.exit(1)
