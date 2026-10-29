#!/usr/bin/env python3
"""Owned PTY + loopback-only idle Enter acceptance. No installed packages.
Build interface: python3 tests/product/idle_enter_mock.py /absolute/path/to/thin
The child HOME/project/config are generated here; Memory is explicitly off.
The PTY starts on 23 owned shell rows, so the floating tail's first composer is on
the physical bottom; only then does an empty Enter advance native scrollback, and
only then does the exact-three-native-rows oracle mean what it asserts.
Resize is passive here: dimensions change, old frame authority is dropped and the
application must not repaint on size alone. The next real edit draws the fresh
frame at the new width.
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
# A complete frame releases synchronized display and then shows the cursor
# (src/ui/terminal.zig); exit and resize-recovery bytes reuse the bare
# cursor-show, so frame completion needs the release marker as well.
SYNC_BEGIN = b'\x1b[?2026h'
FRAME_END = b'\x1b[?2026l' + ACK
# A resize may only release interrupted controls (CAN, SGR reset, sync release,
# cursor show). Anything else is interface payload and fails below.
CONTROL_RELEASE = re.compile(rb'\x18|\x1b\[\?2026[lh]|\x1b\[\?25[hl]|\x1b\[0m')
CSI = re.compile(rb'\x1b\[([0-9;?]*)([@-~])')

ROWS = 24

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


def cells(raw):
    """Display cells of one styled frame line.

    Callers pass frame bytes with their SGR/CSI styling still in place, so the
    escapes are stripped here. UTF-8 byte length is not a cell count: combining
    marks occupy no cell, an ASCII or other single-cell glyph one, and an East
    Asian wide/fullwidth glyph two. Nothing here needs a third-party width table.
    """
    return sum(0 if unicodedata.combining(ch) else 2 if unicodedata.east_asian_width(ch) in ('W', 'F') else 1
               for ch in CSI.sub(b'', raw).decode('utf-8'))


def seed_rows(rows=ROWS):
    """Owned, nonblank fixture rows that leave the cursor on the physical bottom.

    The live tail floats at the terminal's existing cursor row, so an empty
    Enter only advances native scrollback from the physical bottom. These short
    shell-sentinel rows are written to the owned slave PTY before the child
    starts and reach the screen through the ordinary capture path; they are
    fixture setup, never product blank padding.
    """
    return b''.join(b'IDLE-SEED-%02d\r\n' % number for number in range(1, rows))


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

    def editor_tail(self):
        """Actual text of the cursor row up to the caret, decoration included.

        `idle()` deliberately rejects a nonempty editor, so it can never stand in
        for a real edit. Reading the cursor row (never `grid[-1]`) keeps a stale
        prompt or a transcript row from being mistaken for the live editor.
        """
        if not 0 <= self.row < len(self.grid):
            return ''
        column = min(max(self.col, 0), self.columns)
        return ''.join(self.grid[self.row])[:column]

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
        # The foreground starts its own AF_UNIX worker under $XDG_RUNTIME_DIR/thin.
        # An owned short base keeps sockets inside this fixture instead of the
        # shared /tmp/thin-<uid> fallback. It is removed by the parent context.
        runtime = Path(base) / 'r'
        runtime.mkdir(mode=0o700)
        assert runtime.is_absolute() and (runtime.stat().st_mode & 0o777) == 0o700, 'owned runtime must be an absolute 0700 directory'
        assert len(str(runtime)) + 14 + 32 + 5 <= 107, 'AF_UNIX socket path budget exceeded'
        (home / '.thin').mkdir(parents=True)
        project.mkdir()
        config = {'memory': {'auto': False}, 'llm': {'default': 'local/fixture-model', 'providers': {'local': {'base_url': f'http://127.0.0.1:{server.server_port}/v1', 'api_key_env': 'THIN_IDLE_KEY', 'models': {'fixture-model': {'protocol': 'chat', 'context_tokens': 32768}}}}}, 'limits': {'low_price_input': False, 'safety_tokens': 100, 'request_timeout_ms': 10000, 'task_timeout_ms': 15000}}
        config_path = home / '.thin/config.json'
        config_bytes = json.dumps(config).encode()
        config_path.write_bytes(config_bytes)
        config_path.chmod(0o600)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, width, 0, 0))
        original = termios.tcgetattr(slave)
        original_flags = fcntl.fcntl(slave, fcntl.F_GETFL)
        # Physical-bottom precondition for the native-row oracle below. The live
        # tail floats at the terminal's existing cursor row, so an empty Enter
        # can only advance native scrollback once that row is the real bottom.
        # These owned shell rows are emitted through the slave PTY, so the
        # ordinary capture path below parses exactly the bytes the kernel
        # delivered. Fixture setup only; never product blank padding.
        os.write(slave, seed_rows())

        def child_setup():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        child = subprocess.Popen([app, '--no-log', '--no-model-auto-refresh'], stdin=slave, stdout=slave, stderr=slave,
                                 cwd=project, preexec_fn=child_setup,
                                 env={'PATH': '/usr/bin:/bin', 'HOME': str(home), 'XDG_RUNTIME_DIR': str(runtime), 'LANG': 'C.UTF-8', 'TERM': 'xterm-256color', 'THIN_IDLE_KEY': 'idle-fixture-only'})
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

        def settled(marker=b''):
            """True only when the newest completed frame ends on the cursor-row composer.

            `marker` must already be on screen and inside that same completed frame,
            so a body-only half frame followed by a stale idle footer cannot pass.
            """
            end = capture.rfind(FRAME_END)
            if end < 0 or capture.rfind(SYNC_BEGIN) > end:
                return False
            if marker:
                position = capture.find(marker)
                if position < 0 or position > end:
                    return False
            return screen.idle()

        def send(data):
            os.write(master, data)

        def edited(mark, text):
            """A fresh complete frame after `mark` whose cursor-row editor ends with `text`.

            `settled()` must not be used here: it requires an empty editor, so it
            would either reject the edit or, worse, accept an old idle row. The
            newest complete frame must begin after the mark and nothing newer may
            still be mid-write, because an unfinished frame owns no authority.
            """
            end = capture.rfind(FRAME_END)
            if end < 0:
                return False
            begin = capture.rfind(SYNC_BEGIN, 0, end)
            if begin < mark:
                return False  # Only a frame begun before the mark is stale; equal is fresh.
            if capture.find(SYNC_BEGIN, end) >= 0:
                return False  # A newer frame is still unfinished.
            return screen.editor_tail().endswith(text)

        try:
            pump_until(lambda: settled() and screen.prompts() == 1)
            assert b'IDLE-SEED-01' in capture, 'fixture seed rows never reached the owned parser'
            assert screen.row == len(screen.grid) - 1, 'fixture precondition: ready composer is not on the physical bottom row'
            # Baseline only after the ACKed ready composer: earlier seed/startup
            # scrolls must not be counted as idle Enter rows.
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
            # Paste whitespace is not an intentional empty Enter. A floating tail
            # also scrolls for unrelated reasons (the menu above), so this guard is
            # scoped to the paste itself: total prompt rows (visible + native) must
            # not grow, and nothing may be released into native scrollback after
            # the snapshot. Unrelated native row movement stays permitted.
            paste_prompts = screen.prompts()
            paste_history = len(screen.history)
            mark = len(capture)
            send(b'\x1b[200~ \r\x1b[201~\r')
            pump_until(lambda: len(capture) > mark and capture.endswith(ACK))
            assert screen.prompts() == paste_prompts, 'paste whitespace appended or duplicated a prompt row'
            assert not any('%>' in line for line in screen.history[paste_history:]), 'paste whitespace released a native prompt row'
            assert not Service.requests, 'paste whitespace started primary/Memory work'
            mark = len(capture)
            send(b'\x15')
            pump_until(lambda: len(capture) > mark and capture.endswith(ACK))
            # Resize is passive: the new dimensions are taken, the old frame
            # authority is dropped and only interrupted controls are released.
            mark = len(capture)
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 40, 0, 0))
            until = time.monotonic() + .05
            pump_until(lambda: time.monotonic() >= until)
            assert CONTROL_RELEASE.sub(b'', bytes(capture[mark:])) == b'', 'live resize repainted before settling'
            frames = capture.count(FRAME_END)
            mark = len(capture)
            # The removed debounce used to repair after 150ms; crossing that bound
            # must still produce no frame and no payload: saving waits for a real
            # edit or new server content, never for elapsed time.
            until = time.monotonic() + .22
            pump_until(lambda: time.monotonic() >= until)
            assert CONTROL_RELEASE.sub(b'', bytes(capture[mark:])) == b'', 'resize-only idle emitted interface payload'
            assert capture.count(FRAME_END) == frames, 'resize-only idle drew a complete frame'
            # The next real edit draws a fresh frame at the new width, and the
            # cursor-row editor must actually hold the typed cell.
            mark = len(capture)
            send(b'z')
            pump_until(lambda: len(capture) > mark and edited(mark, 'z'))
            frame_end = capture.rfind(FRAME_END)
            drawn = bytes(capture[capture.rfind(SYNC_BEGIN, 0, frame_end):frame_end])
            assert max((cells(line) for line in drawn.replace(b'\r', b'\n').split(b'\n')), default=0) <= 40, 'fresh frame ignored the resized width'
            # Clearing the edit returns to the same empty ready composer.
            mark = len(capture)
            send(b'\x15')
            pump_until(lambda: len(capture) > mark and settled())
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
            pump_until(lambda: settled(b'idle-answer-proof'))
            assert screen.row >= 1 and not ''.join(screen.grid[screen.row - 1]).strip(), 'idle line mode removed the normal conversation/composer gap'
            assert len(Service.requests) == 1
            send(b'\x04')
            pump_until(lambda: child.poll() is not None)
            assert child.wait(timeout=3) == 0
            assert termios.tcgetattr(slave) == original, 'termios was not restored'
            assert fcntl.fcntl(slave, fcntl.F_GETFL) == original_flags
            assert config_path.read_bytes() == config_bytes
            assert not (home / '.thin/sessions').exists()
            assert not (project / '.thin/sessions').exists()
            print(f'PASS idle-enter width={width} batched={batched}: idle HTTP=0 normal HTTP=1, 3 exact native rows, menu/paste/passive-resize/busy/termios')
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
