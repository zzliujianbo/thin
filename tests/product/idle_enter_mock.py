#!/usr/bin/env python3
"""Owned PTY + loopback-only idle Enter acceptance. No installed packages.
Build interface: python3 tests/product/idle_enter_mock.py /absolute/path/to/thin
The child HOME/project/config are generated here; Memory is explicitly off.
The PTY starts at the top of an empty screen; the composer grows naturally
from its entry position until output reaches the physical bottom.
Resize is passive here: dimensions change, old frame authority is dropped and the
application must not repaint on size alone. The next real edit draws the fresh
frame at the new width.
"""
import ctypes
import errno
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import queue
import platform
import re
import select
import signal
import stat
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
# marker replaces the `>` with one of the known activity spinner glyphs.
_VALUE_SLOT = (r'(?:L?(?:\?%|>100%|[0-9]+\.[0-9]%|off|minimal|low|medium|high|'
               r'xhigh|max|\?))')
_IDLE_COMPOSER = re.compile(
    r'^(?:> |(?:\([^)]*\) )?' + _VALUE_SLOT + r'> )$')
SPINNER_CHARS = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
_BUSY_COMPOSER = re.compile(r'^(?:\([^)]*\) )?' + _VALUE_SLOT + r'[' + SPINNER_CHARS + r'] $')


def bootstrap_composer(screen, ready_seen):
    """Recognize only the unselected startup spinner on the current screen."""
    return (not ready_seen and screen.col == 2 and
            screen.editor_tail() in tuple(ch + ' ' for ch in SPINNER_CHARS))


def _pending_composer_echo(tail, draft, submitted, accepted_seen, selected):
    if not (draft and submitted and not accepted_seen and selected and tail.endswith(draft)):
        return False
    prefix = tail[:-len(draft)]
    return bool(_IDLE_COMPOSER.fullmatch(prefix) or _BUSY_COMPOSER.fullmatch(prefix))


def cells(raw):
    """Display cells of one styled frame line.

    Callers pass frame bytes with their SGR/CSI styling still in place, so the
    escapes are stripped here. UTF-8 byte length is not a cell count: combining
    marks occupy no cell, an ASCII or other single-cell glyph one, and an East
    Asian wide/fullwidth glyph two. Nothing here needs a third-party width table.
    """
    return sum(0 if unicodedata.combining(ch) else 2 if unicodedata.east_asian_width(ch) in ('W', 'F') else 1
               for ch in CSI.sub(b'', raw).decode('utf-8'))


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
            if b == 0xe2:
                remaining = len(data) - i
                if remaining == 1 or (remaining == 2 and 0xa0 <= data[i + 1] <= 0xa3):
                    break
                if (remaining >= 3 and 0xa0 <= data[i + 1] <= 0xa3 and
                        0x80 <= data[i + 2] <= 0xbf):
                    self.grid[self.row][self.col] = data[i:i + 3].decode('utf-8')
                    self.col = min(self.columns - 1, self.col + 1)
                    i += 3
                    continue
            i += 1
            if b == 13: self.col = 0
            elif b == 10: self.down()
            elif b == 8: self.col = max(0, self.col - 1)
            elif 32 <= b < 127:
                self.grid[self.row][self.col] = chr(b)
                self.col = min(self.columns - 1, self.col + 1)
            # Other non-ASCII bytes retain the existing bounded handling.
        self.pending = data[i:]

    def idle(self, clear_below=False):
        """True only on the cursor row of a settled, empty composer.

        A stale completed prompt further up, a transcript row that
        merely ends with `>`, a modal editor line (Search>/Settings>/
        Address>/Provider>/API key>) and the busy spinner are all rejected.
        """
        if clear_below and any(''.join(row).strip() for row in self.grid[self.row + 1:]):
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


def screen_oracle_selfcheck():
    screen = Screen(80)
    frame1 = SYNC_BEGIN + b'\r' + '⠋'.encode() + b' \x1b[0m\x1b[K\r\x1b[2C' + FRAME_END
    frame2 = SYNC_BEGIN + b'\r\x1b[2C' + FRAME_END
    for byte in frame1:
        screen.feed(bytes((byte,)))
    assert screen.editor_tail() == '⠋ ' and bootstrap_composer(screen, False)
    screen.feed(frame2)
    assert screen.editor_tail() == '⠋ ' and bootstrap_composer(screen, False)
    assert not bootstrap_composer(screen, True)
    screen.feed(b'\r\x1b[K\x1b[2C')
    assert not bootstrap_composer(screen, False)
    screen.feed(b'\r' + '⠋'.encode() + b' \x1b[1B\r\x1b[2C')
    assert not bootstrap_composer(screen, False)
    for spinner in SPINNER_CHARS:
        assert _BUSY_COMPOSER.fullmatch('(fixture-model) 0.0%' + spinner + ' ')
    assert not _BUSY_COMPOSER.fullmatch('(fixture-model) 0.0%  ')
    draft = 'stream-proof'
    busy = '(fixture-model) 0.0%⠋ '
    idle = '(fixture-model) 0.0%> '
    assert _pending_composer_echo(busy + draft, draft, True, False, True)
    assert _pending_composer_echo(idle + draft, draft, True, False, True)
    assert not _pending_composer_echo(busy + draft, draft, True, True, True)
    assert not _pending_composer_echo(busy + draft + ' ', draft, True, False, True)
    assert not _pending_composer_echo(busy + draft[:-1], draft, True, False, True)
    assert not _pending_composer_echo(busy + draft, draft, True, False, False)
    print('PASS screen bootstrap oracle self-check')


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

        def child_setup():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        child = subprocess.Popen([app, '--no-model-auto-refresh'], stdin=slave, stdout=slave, stderr=slave,
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
            return screen.idle(clear_below=True)

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
            assert screen.row < len(screen.grid) - 1, 'initial composer jumped to physical bottom'
            # Test the very first menu before Enter has released any prompt rows.
            # Keep logical positions as well as content: filtering blank lines alone
            # would miss a composer displaced by a cleared menu.
            initial_endpoint = len(screen.history) + screen.row
            initial_history = list(screen.history)
            initial_rows = [(i, line) for i, line in enumerate(
                screen.history + [''.join(row) for row in screen.grid]) if line.strip()]
            for _ in range(2):
                mark = len(capture)
                send(b'/')
                pump_until(lambda: b'/model' in capture[mark:] and capture.endswith(FRAME_END) and
                           any('/model' in ''.join(row) for row in screen.grid))
                # Both the initial tail and this root menu fit near the top.
                assert screen.history == initial_history, 'initial menu unexpectedly scrolled history'
                mark = len(capture)
                send(b'\x1b')
                pump_until(lambda: len(capture) > mark and capture.endswith(FRAME_END) and
                           not any('/model' in ''.join(row) for row in screen.grid))
                mark = len(capture)
                send(b'\x15')
                pump_until(lambda: len(capture) > mark and capture.endswith(FRAME_END) and
                           screen.idle(clear_below=True))
                assert len(screen.history) + screen.row == initial_endpoint, 'initial menu changed logical endpoint'
                assert screen.history == initial_history, 'initial menu changed history'
                rows = [(i, line) for i, line in enumerate(
                    screen.history + [''.join(row) for row in screen.grid]) if line.strip()]
                assert rows == initial_rows, 'initial menu changed protected rows'
                assert not Service.requests, 'initial menu started HTTP work'
            # Baseline only after the ACKed ready composer: earlier seed/startup
            # scrolls must not be counted as idle Enter rows.
            before = len(screen.history) + screen.row
            if batched:
                send(b' \t\r\r\rtyped')
                pump_until(lambda: screen.prompts() == 4 and b'typed' in capture)
                clear_mark = len(capture)
                send(b'\x15')  # clear only the new draft
                pump_until(lambda: capture.endswith(FRAME_END) and edited(clear_mark, '') and
                           settled() and screen.prompts() == 4)
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
                    assert len(screen.history) + screen.row == before + n + 1, 'Enter did not advance exactly one native row'
            assert len(screen.history) + screen.row == before + 3
            assert not Service.requests, 'idle Enter started primary/Memory work'
            # Capture before the first open, not after the first restoration.
            menu_endpoint = len(screen.history) + screen.row
            protected_prompts = [line for line in screen.history + [''.join(row) for row in screen.grid]
                                 if '%>' in line]
            assert len(protected_prompts) == 4, 'expected four protected prompts before menu'
            # A menu can borrow the released prompt rows and must put them back.
            mark = len(capture)
            send(b'/')
            pump_until(lambda: b'/model' in capture[mark:] and capture.endswith(FRAME_END) and
                       any('/model' in ''.join(row) for row in screen.grid))
            # Let bare Escape expire and acknowledge its frame BEFORE Ctrl-U;
            # combining them would intentionally form an unknown Alt sequence.
            mark = len(capture)
            send(b'\x1b')
            pump_until(lambda: len(capture) > mark and capture.endswith(ACK) and not any('/model' in ''.join(row) for row in screen.grid))
            mark = len(capture)
            send(b'\x15')
            pump_until(lambda: len(capture) > mark and capture.endswith(FRAME_END) and screen.idle(clear_below=True))
            assert len(screen.history) + screen.row == menu_endpoint, 'first menu changed logical endpoint'
            prompts = [line for line in screen.history + [''.join(row) for row in screen.grid] if '%>' in line]
            assert prompts == protected_prompts and len(prompts) == 4, 'menu restoration changed protected prompts'
            assert not Service.requests
            for _ in range(2):
                mark = len(capture)
                send(b'/')
                pump_until(lambda: b'/model' in capture[mark:] and capture.endswith(FRAME_END))
                mark = len(capture)
                send(b'\x1b')
                pump_until(lambda: len(capture) > mark and capture.endswith(FRAME_END) and
                           not any('/model' in ''.join(row) for row in screen.grid))
                mark = len(capture)
                send(b'\x15')
                pump_until(lambda: len(capture) > mark and capture.endswith(FRAME_END) and screen.idle(clear_below=True))
                assert len(screen.history) + screen.row == menu_endpoint, 'repeated menu crept downward'
                prompts = [line for line in screen.history + [''.join(row) for row in screen.grid]
                           if '%>' in line]
                assert prompts == protected_prompts and len(prompts) == 4, 'repeated menu changed protected prompts'
                assert not Service.requests, 'menu started HTTP work'
            # Paste whitespace is not an intentional empty Enter. The tail can
            # scroll for unrelated reasons (the menu above), so this guard is
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
            resized_columns = 40
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, resized_columns, 0, 0))
            # Resize the bounded canvas, not native history reflow.
            for row in screen.grid:
                row[:] = (row[:resized_columns] + [' '] * resized_columns)[:resized_columns]
            screen.columns = resized_columns
            screen.col = min(screen.col, resized_columns - 1)
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
            assert max((cells(line) for line in drawn.replace(b'\r', b'\n').split(b'\n')), default=0) <= resized_columns, 'fresh frame ignored the resized width'
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
            assert screen.row >= 2 and screen.idle(clear_below=True), 'composer is not a fresh cleared tail'
            # The pending default can clear asynchronously.
            statuses = {
                'Saved thinking level not applied: model capabilities unknown',
                'Default thinking: off; awaiting model capabilities | Saved thinking level not applied: model capabilities unknown',
            }
            clipped_statuses = {status[:resized_columns - 1] for status in statuses}
            assert ''.join(screen.grid[screen.row - 1]).rstrip(' ') in clipped_statuses, 'status is not immediately above the composer'
            assert sum(''.join(row).rstrip(' ') in clipped_statuses for row in screen.grid) == 1, 'status is not unique on screen'
            assert not ''.join(screen.grid[screen.row - 2]).strip(), 'separator above status is not blank'
            assert len(Service.requests) == 1
            send(b'\x04')
            pump_until(lambda: child.poll() is not None)
            assert child.wait(timeout=3) == 0
            assert termios.tcgetattr(slave) == original, 'termios was not restored'
            assert fcntl.fcntl(slave, fcntl.F_GETFL) == original_flags
            assert config_path.read_bytes() == config_bytes
            assert not (home / '.thin/sessions').exists()
            assert list((project / '.thin/sessions').glob('*.jsonl')), 'submitted session not recorded'
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


def deny_inet_sockets():
    """Child-only seccomp: socket(AF_UNIX, ...) remains available to Thin."""
    nr = {'x86_64': 41, 'aarch64': 198}.get(platform.machine())
    if nr is None or sys.platform != 'linux':
        raise RuntimeError('unsupported seccomp platform')

    class Filter(ctypes.Structure):
        _fields_ = [('code', ctypes.c_ushort), ('jt', ctypes.c_ubyte),
                    ('jf', ctypes.c_ubyte), ('k', ctypes.c_uint32)]

    class Program(ctypes.Structure):
        _fields_ = [('length', ctypes.c_ushort), ('filter', ctypes.POINTER(Filter))]

    # seccomp_data.nr at 0; args[0] (domain) at 16. All other syscalls
    # are allowed, including the AF_UNIX session worker's sockets.
    # Linux x86_64 and asm-generic/aarch64 both assign 425..427 to
    # io_uring_setup/enter/register; prevent socket creation through io_uring.
    insns = (Filter * 9)(Filter(0x20, 0, 0, 0),
                         Filter(0x15, 5, 0, 425), Filter(0x15, 4, 0, 426),
                         Filter(0x15, 3, 0, 427), Filter(0x15, 0, 3, nr),
                         Filter(0x20, 0, 0, 16), Filter(0x15, 1, 0, 1),
                         Filter(0x06, 0, 0, 0x00050000 | errno.EPERM),
                         Filter(0x06, 0, 0, 0x7fff0000))
    program = Program(len(insns), insns)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(38, 1, 0, 0, 0) or libc.prctl(22, 2, ctypes.byref(program), 0, 0):
        raise OSError(ctypes.get_errno(), 'seccomp setup')


def first_entry(app, origin, width, auto, response='normal'):
    """First-frame origin/scrollback oracle; never submits a user prompt."""
    with tempfile.TemporaryDirectory(prefix='thin-entry-') as base:
        home, project, runtime = (Path(base) / name for name in ('home', 'project', 'r'))
        (home / '.thin').mkdir(parents=True)
        project.mkdir()
        runtime.mkdir(mode=0o700)
        config = {'memory': {'auto': False}, 'llm': {'default': 'local/fixture-model',
                  'providers': {'local': {'base_url': 'http://127.0.0.1:1/v1',
                  'api_key_env': 'THIN_IDLE_KEY', 'models': {'fixture-model':
                  {'protocol': 'chat', 'context_tokens': 32768}}}}},
                  'limits': {'low_price_input': False, 'safety_tokens': 100,
                             'request_timeout_ms': 10000, 'task_timeout_ms': 15000}}
        config_path = home / '.thin/config.json'
        config_path.write_text(json.dumps(config))
        config_path.chmod(0o600)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, width, 0, 0))
        original = termios.tcgetattr(slave)
        flags = fcntl.fcntl(slave, fcntl.F_GETFL)
        screen = Screen(width)
        history = [f'HISTORY-{i:02d}' for i in range(8)]
        protected = [f'PROTECTED-{i:02d}' for i in range(origin)] + ['ENTRY-MARKER']
        below = [f'DROPPABLE-{i:02d}' for i in range(origin + 1, ROWS)]
        screen.history = [s.ljust(width) for s in history]
        for i, text in enumerate(protected + below):
            screen.grid[i][:len(text)] = text
        screen.row, screen.col = origin, 3
        original_history = screen.history[:]
        query = b'\x1b[6n'
        wire = bytearray()
        pending = b''
        seen = 0
        child = None

        def setup():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
            deny_inet_sockets()

        def receive(data):
            nonlocal pending, seen
            # Hold a possible split query prefix, so it is neither displayed nor
            # answered late after processing subsequent bytes of the same read.
            pending += data
            while pending:
                at = pending.find(query)
                if at >= 0:
                    screen.feed(pending[:at])
                    pending = pending[at + len(query):]
                    seen += 1
                    assert seen == 1, 'query-count'
                    assert screen.row == origin and screen.col == 3, 'query-origin'
                    assert FRAME_END not in wire[:wire.find(query)], 'query-after-frame'
                    if response != 'timeout':
                        reply = f'\x1b[{screen.row + 1};{screen.col + 1}R'.encode()
                        if response == 'fragmented':
                            os.write(master, reply[:2])
                            time.sleep(.005)
                            os.write(master, reply[2:])
                        elif response == 'early':
                            os.write(master, reply + b'\x04trailing')
                        else:
                            os.write(master, reply)
                    continue
                keep = 0
                for n in range(1, min(len(query) - 1, len(pending)) + 1):
                    if pending.endswith(query[:n]):
                        keep = n
                screen.feed(pending[:-keep] if keep else pending)
                pending = pending[-keep:] if keep else b''
                break

        def record(data):
            wire.extend(data)
            assert len(wire) <= 2 * 1024 * 1024, 'capture-size'
            receive(data)

        def drain_final():
            # Child exit can precede observation of its last PTY write.
            fcntl.fcntl(master, fcntl.F_SETFL, fcntl.fcntl(master, fcntl.F_GETFL) | os.O_NONBLOCK)
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                try:
                    data = os.read(master, 65536)
                except OSError as e:
                    if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EIO):
                        return
                    raise
                if not data:
                    return
                record(data)
            raise AssertionError('drain-timeout')

        def no_submission_state():
            root = project / '.thin'
            try:
                info = root.lstat()
            except FileNotFoundError:
                return
            assert stat.S_ISDIR(info.st_mode) and not info.st_mode & 0o077, 'project-private'
            assert all(path.name == 'sessions' for path in root.iterdir()), 'project-state'
            sessions = root / 'sessions'
            info = sessions.lstat()
            assert stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o700, 'sessions-mode'
            locks = 0
            for path in sessions.iterdir():
                info = path.lstat()
                assert stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600, 'session-file-mode'
                if path.name == '.gitignore':
                    assert path.read_bytes() == b'*\n', 'gitignore-content'
                else:
                    assert re.fullmatch(r'[a-f0-9]{32}\.resume-lock', path.name), 'session-file-name'
                    marker = path.read_bytes()
                    assert len(marker) == 33 and marker[:1] in (b'A', b'C') and marker[1:] == bytes(32), 'lock-content'
                    locks += 1
            assert locks <= 1, 'lock-count'

        def pump(predicate, timeout=6):
            start = len(wire)
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if predicate():
                    return
                ready, _, _ = select.select([master], [], [], min(.05, max(0, deadline - time.monotonic())))
                if ready:
                    try:
                        data = os.read(master, 65536)
                    except OSError as e:
                        if e.errno != errno.EIO:
                            raise
                        data = b''
                    if data:
                        record(data)
                        assert len(wire) - start <= 2 * 1024 * 1024, 'phase-size'
                if child.poll() is not None:
                    if predicate():
                        return
                    raise AssertionError('early-exit')
            raise AssertionError('phase-timeout')

        try:
            args = [app] + ([] if auto else ['--no-model-auto-refresh'])
            child = subprocess.Popen(args, stdin=slave, stdout=slave, stderr=slave,
                                     cwd=project, preexec_fn=setup,
                                     env={'PATH': '/usr/bin:/bin', 'HOME': str(home),
                                          'XDG_RUNTIME_DIR': str(runtime), 'LANG': 'C.UTF-8',
                                          'TERM': 'xterm-256color', 'THIN_IDLE_KEY': 'fixture-only'})
            if response == 'early':
                pump(lambda: child.poll() is not None)
            else:
                pump(lambda: FRAME_END in wire and screen.idle())
                # The entry row is protected; a one-row composer or hint plus
                # composer consumes one or two following rows, scrolling only
                # when those actual rows reach the bottom.
                entry_lines = screen.history + [''.join(row) for row in screen.grid]
                entry_index = next(i for i, line in enumerate(entry_lines) if 'ENTRY-MARKER' in line)
                tail_index = len(screen.history) + screen.row
                assert tail_index - entry_index in (1, 2), 'unnatural-entry-height'
                assert screen.row == min(ROWS - 1, origin + tail_index - entry_index), 'entry-jumped'
                if response == 'timeout':
                    mark = len(wire)
                    os.write(master, b'input-proof')
                    pump(lambda: FRAME_END in wire[mark:] and screen.editor_tail().endswith('input-proof'))
                    mark = len(wire)
                    os.write(master, b'\x15')
                    pump(lambda: FRAME_END in wire[mark:] and screen.idle())
                os.write(master, b'\x04')
            pump(lambda: child.poll() is not None)
            assert child.wait(timeout=3) == 0, 'exit-code'
            drain_final()
            assert termios.tcgetattr(slave) == original, 'termios-restore'
            assert fcntl.fcntl(slave, fcntl.F_GETFL) == flags, 'descriptor-restore'
            assert not list(runtime.rglob('*.sock')), 'worker-socket-left'
            no_submission_state()
            if response in ('normal', 'fragmented', 'early', 'timeout'):
                lines = screen.history + [''.join(row) for row in screen.grid]
                assert screen.history[:len(original_history)] == original_history, 'history-prefix'
                markers = history + protected
                positions = []
                for marker in markers:
                    found = [i for i, line in enumerate(lines) if marker in line]
                    assert len(found) == 1, 'protected-count'
                    positions.append(found[0])
                assert positions == sorted(positions) and len(set(positions)) == len(positions), 'protected-order'
                assert all(lines[positions[len(history) + i]] == marker.ljust(width)
                           for i, marker in enumerate(protected)), 'protected-row-changed'
                added = screen.history[len(original_history):]
                assert not any('DROPPABLE-' in line for line in added), 'droppable-history'
                assert all(line.strip() for line in added), 'blank-history'
                entry = positions[-1]
                next_line = next((i for i in range(entry + 1, len(lines)) if lines[i].strip()), None)
                if next_line is not None:
                    assert next_line - entry <= 3, 'entry-gap'
                assert len(added) < 4, 'excess-scroll'
                # Terminal.restore already advanced the cursor for shell output.
                screen.feed(b'SHELL-NEXT-MARKER')
                lines = screen.history + [''.join(row) for row in screen.grid]
                positions = []
                for marker in markers:
                    found = [i for i, line in enumerate(lines) if marker in line]
                    assert len(found) == 1, 'protected-count-after-shell'
                    positions.append(found[0])
                assert positions == sorted(positions) and len(set(positions)) == len(positions), 'protected-order-after-shell'
                assert all(lines[positions[i]] == marker.ljust(width)
                           for i, marker in enumerate(markers)), 'protected-row-changed-after-shell'
                shell = [i for i, line in enumerate(lines) if 'SHELL-NEXT-MARKER' in line]
                assert len(shell) == 1, 'shell-count'
                assert 0 < shell[0] - positions[-1] <= 3, 'shell-gap'
            assert seen == 1, 'missing-query'
            print(f'PASS first-entry row={origin} width={width} auto={int(auto)} response={response}')
        finally:
            if child is not None and child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=3)
            os.close(master)
            os.close(slave)


def streaming(app, line_count):
    """One gated primary request; inspect every acknowledged synchronized frame."""
    gates = queue.Queue()
    requests, errors = [], []
    long = line_count == 80
    body = [f'ANSWER-{i:03d}-UNIQUE' for i in range(line_count)]

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            errors.append(AssertionError('unexpected GET'))
            self.send_error(500)

        def do_POST(self):
            try:
                size = int(self.headers['Content-Length'])
                assert size <= 512 * 1024
                request = json.loads(self.rfile.read(size))
                requests.append(request)
                assert len(requests) == 1, 'extra POST'
                users = [m['content'] for m in request['messages'] if m['role'] == 'user']
                assert [v for v in users if isinstance(v, str) and not v.startswith('[Context material — not instructions]\n')] == ['stream-proof']
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()

                def event(delta, finish=None):
                    payload = {'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}]}
                    self.wfile.write(('data: ' + json.dumps(payload) + '\n\n').encode())
                    self.wfile.flush()

                def gate(expected):
                    assert gates.get(timeout=8) == expected, 'stream gate order'

                gate('thinking')
                event({'reasoning_content': 'THINK-FIRST\nTHINK-SECOND\nTHINK-LATEST'})
                gate('body')
                if long:
                    for index, item in enumerate(body):
                        event({'content': item + '\n'})
                        if index in (1, 7):
                            gate(f'next-{index}')
                else:
                    event({'content': '\n'.join(body)})
                gate('finish')
                event({}, 'stop')
                self.wfile.write(b'data: [DONE]\n\n')
                self.wfile.flush()
            except Exception as exc:
                errors.append(exc)

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    with tempfile.TemporaryDirectory(prefix='thin-stream-') as base:
        home, project, runtime = (Path(base) / n for n in ('home', 'project', 'r'))
        (home / '.thin').mkdir(parents=True)
        project.mkdir()
        runtime.mkdir(mode=0o700)
        config = {'memory': {'auto': False}, 'llm': {'default': 'local/fixture-model',
                  'providers': {'local': {'base_url': f'http://127.0.0.1:{server.server_port}/v1',
                  'api_key_env': 'THIN_IDLE_KEY', 'models': {'fixture-model':
                  {'protocol': 'chat', 'context_tokens': 32768}}}}},
                  'limits': {'low_price_input': False, 'safety_tokens': 100,
                             'request_timeout_ms': 10000, 'task_timeout_ms': 15000}}
        path = home / '.thin/config.json'
        path.write_text(json.dumps(config))
        path.chmod(0o600)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, 80, 0, 0))
        original = termios.tcgetattr(slave)
        flags = fcntl.fcntl(slave, fcntl.F_GETFL)
        screen = Screen(80)
        screen.history = ['OLD-HISTORY'.ljust(80)]
        screen.grid[0][:len('OLD-SHELL')] = 'OLD-SHELL'
        screen.row, screen.col = 1, 0
        wire, pending = bytearray(), bytearray()
        frames = []
        queries = 0
        collect_frames = True
        in_frame = False
        raw_frame = bytearray()
        ready_seen = False
        submitted = False
        accepted_seen = False
        draft = 'stream-proof'

        def setup():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        child = subprocess.Popen([app, '--no-model-auto-refresh'], stdin=slave, stdout=slave,
                                 stderr=slave, cwd=project, preexec_fn=setup,
                                 env={'PATH': '/usr/bin:/bin', 'HOME': str(home),
                                      'XDG_RUNTIME_DIR': str(runtime), 'LANG': 'C.UTF-8',
                                      'TERM': 'xterm-256color', 'THIN_IDLE_KEY': 'fixture-only',
                                      'NO_PROXY': '*', 'no_proxy': '*'})

        def receive(data):
            nonlocal queries, in_frame, raw_frame, ready_seen, accepted_seen
            wire.extend(data)
            assert len(wire) <= 2 * 1024 * 1024, 'capture-size'
            pending.extend(data)
            # A release alone is not a frame. Retain split prefixes for all
            # delimiters and continue feeding every byte to the VT projection.
            tokens = (b'\x1b[6n', SYNC_BEGIN, FRAME_END)
            while pending:
                candidates = [(pending.find(x), x) for x in tokens]
                candidates = [(i, x) for i, x in candidates if i >= 0]
                if candidates:
                    at, token = min(candidates, key=lambda pair: pair[0])
                    part = bytes(pending[:at])
                    screen.feed(part)
                    if in_frame:
                        raw_frame.extend(part)
                    del pending[:at + len(token)]
                    if token == b'\x1b[6n':
                        screen.feed(token)
                        if in_frame:
                            raw_frame.extend(token)
                        queries += 1
                        assert queries == 1
                        os.write(master, f'\x1b[{screen.row + 1};{screen.col + 1}R'.encode())
                    elif token == SYNC_BEGIN:
                        screen.feed(token)
                        in_frame = True
                        raw_frame = bytearray(token)
                    else:
                        screen.feed(token)
                        if not in_frame:
                            continue
                        raw_frame.extend(token)
                        in_frame = False
                        if collect_frames:
                            line = ''.join(screen.grid[screen.row])
                            caret = screen.col
                            assert not line[caret:].strip(), 'text after composer caret'
                            assert not any(''.join(row).strip() for row in screen.grid[screen.row + 1:]), 'content below composer'
                            idle = screen.idle(clear_below=True)
                            selected = line[:caret].startswith('(fixture-model) ')
                            bootstrap = bootstrap_composer(screen, ready_seen)
                            user_rows = [row for row in screen.history + [
                                ''.join(r) for i, r in enumerate(screen.grid) if i != screen.row
                            ] if draft in row]
                            if user_rows:
                                assert len(user_rows) == 1, 'user row is not unique'
                                accepted_seen = True
                            tail = line[:caret]
                            pending_echo = _pending_composer_echo(tail, draft, submitted, accepted_seen, selected)
                            assert idle or _BUSY_COMPOSER.fullmatch(tail) or bootstrap or pending_echo, 'frame cursor is not empty composer'
                            if idle and selected:
                                ready_seen = True
                            frames.append((screen.row, idle, tuple(''.join(r) for r in screen.grid)))
                    continue
                keep = max((n for token in tokens
                            for n in range(1, len(token)) if pending.endswith(token[:n])), default=0)
                part = bytes(pending[:-keep] if keep else pending)
                screen.feed(part)
                if in_frame:
                    raw_frame.extend(part)
                if keep:
                    del pending[:-keep]
                else:
                    pending.clear()
                break

        def pump(predicate, timeout=8):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if errors:
                    raise errors[0]
                if predicate():
                    return
                ready, _, _ = select.select([master], [], [], min(.05, max(0, deadline - time.monotonic())))
                if ready:
                    try:
                        data = os.read(master, 65536)
                    except OSError as exc:
                        if exc.errno != errno.EIO:
                            raise
                        data = b''
                    if data:
                        receive(data)
                if child.poll() is not None and not predicate():
                    raise AssertionError(f'early exit: {child.returncode}')
            raise AssertionError('stream phase timed out')

        try:
            pump(lambda: ready_seen and not in_frame and screen.idle(clear_below=True)
                 and screen.editor_tail().startswith('(fixture-model) '))
            assert screen.row < ROWS - 1, 'startup jumped to bottom'
            start = len(frames)
            submitted = True
            os.write(master, b'stream-proof\r')
            pump(lambda: len(requests) == 1)
            gates.put('thinking')
            pump(lambda: frames and any('THINK-LATEST' in line for line in frames[-1][2]))
            thinking_frame = frames[-1]
            assert draft not in thinking_frame[2][thinking_frame[0]], 'thinking retained pending draft'
            assert sum(draft in line for line in screen.history + list(thinking_frame[2])) == 1, 'thinking user row is not unique'
            visible = '\n'.join(thinking_frame[2])
            thinking_lines = [line for line in thinking_frame[2] if 'THINK-' in line]
            assert len(thinking_lines) == 1 and thinking_lines[0].strip() == 'THINK-LATEST', 'thinking is not the single latest literal line'
            assert 'THINK-FIRST' not in visible and 'THINK-SECOND' not in visible
            assert re.search(rb'\x1b\[38;5;103m(?:\x1b\[[0-9;]*m)*THINK-LATEST', wire), 'gray literal thinking missing from wire'
            gates.put('body')
            if long:
                pump(lambda: frames and any(body[1] in line for line in frames[-1][2]))
                first_row = frames[-1][0]
                assert thinking_frame[0] <= first_row < ROWS - 1, 'first body stage jumped to bottom'
                gates.put('next-1')
                pump(lambda: frames and any(body[7] in line for line in frames[-1][2]))
                assert first_row < frames[-1][0] < ROWS - 1, 'body did not grow gradually'
                gates.put('next-7')
            pump(lambda: frames and any(body[-1] in line for line in frames[-1][2]))
            gates.put('finish')
            finish_frame = len(frames)
            pump(lambda: len(frames) > finish_frame and screen.idle(clear_below=True) and any(body[-1] in line for line in frames[-1][2]))
            rows = [frame[0] for frame in frames[start:]]
            assert rows and rows == sorted(rows), f'composer moved upward: {rows}'
            if long:
                assert ROWS - 1 in rows and all(r == ROWS - 1 for r in rows[rows.index(ROWS - 1):]), 'bottom did not stick'
            else:
                assert all(r < ROWS - 1 for r in rows), 'short response jumped to bottom'
            lines = screen.history + [''.join(r) for r in screen.grid]
            assert lines[:3] == ['OLD-HISTORY'.ljust(80), 'OLD-SHELL'.ljust(80), ' ' * 80], 'protected entry prefix changed'
            user = [i for i, line in enumerate(lines) if 'stream-proof' in line]
            assert len(user) == 1, 'user row is not unique'
            positions = []
            for marker in body:
                found = [i for i, line in enumerate(lines) if marker in line]
                assert len(found) == 1, f'marker count {marker}: {found}'
                positions.append(found[0])
            assert positions[0] == user[0] + 2 and not lines[user[0] + 1].strip(), 'user/assistant separator is not exactly one blank row'
            assert positions == list(range(positions[0], positions[0] + len(body))), 'body markers are not consecutive and ordered'
            assert not any('THINK-' in line for line in screen.history), 'thinking entered native history'
            allowed_blanks = {2, user[0] + 1}
            assert all(line.strip() or i in allowed_blanks for i, line in enumerate(screen.history)), 'extra blank native padding'
            assert len(requests) == 1
            collect_frames = False
            os.write(master, b'\x04')
            pump(lambda: child.poll() is not None)
            assert child.wait(timeout=3) == 0
            # Drain the child-owned PTY after exit, including its final write.
            fcntl.fcntl(master, fcntl.F_SETFL, fcntl.fcntl(master, fcntl.F_GETFL) | os.O_NONBLOCK)
            while True:
                try:
                    data = os.read(master, 65536)
                except OSError as exc:
                    if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EIO):
                        break
                    raise
                if not data:
                    break
                receive(data)
            assert termios.tcgetattr(slave) == original
            assert fcntl.fcntl(slave, fcntl.F_GETFL) == flags
            assert len(requests) == 1 and not errors
            print(f'PASS natural stream lines={line_count}: one owned primary POST')
        finally:
            gates.put('finish')
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=3)
            os.close(master)
            os.close(slave)
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)


if __name__ == '__main__':
    screen_oracle_selfcheck()
    app = str(Path(sys.argv[1]).resolve(strict=True))
    for width, batched in [(80, False), (24, True)]:
        run(app, width, batched)
    print('PASS test-idle-enter: 2 owned PTYs, idle HTTP=0, explicit normal HTTP=2')
    for origin, width, auto, response in [(0, 80, True, 'normal'),
                                           (12, 80, False, 'normal'),
                                           (23, 80, True, 'normal'),
                                           (12, 120, True, 'fragmented'),
                                           (23, 120, False, 'normal'),
                                           (12, 80, False, 'early'),
                                           (12, 80, True, 'timeout')]:
        first_entry(app, origin, width, auto, response)
    for line_count in (1, 2, 3, 80):
        streaming(app, line_count)
