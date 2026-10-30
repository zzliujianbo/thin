#!/usr/bin/env python3
"""Owned real-emulator resize regression: requires installed tmux, no packages.
python3 tests/product/resize_viewport_mock.py /absolute/path/to/thin [--wrap|--local-command]
Uses only an owned foreground tmux server/socket, HOME/project and loopback.
Checks visible cells/cursor, not pixels or every physical terminal emulator.
Resize is passive by contract: the tmux/SSH client owns reflow of already
displayed cells, so this fixture no longer waits for an automatic viewport
restoration. It requires no repaint on size alone and then a fresh frame at the
new dimensions, with the draft preserved, on the next real edit.
"""
import http.server
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata


def _cell_width(character):
    if unicodedata.combining(character):
        return 0
    return 2 if unicodedata.east_asian_width(character) in ('W', 'F') else 1


def _take_cells(text, columns):
    """Prefix of `text` whose rendered width fits `columns` terminal cells."""
    if columns <= 0:
        return ''
    width = 0
    for index, character in enumerate(text):
        step = _cell_width(character)
        if width + step > columns:
            return text[:index]
        width += step
    return text


def _logical_editor(rows, caret_column):
    """One logical composer line from visible soft-wrapped rows.

    The first row carries the ASCII `%> ` decoration and later rows repeat that
    width as indentation, so the divider is removed instead of being read as
    draft text. The last row is cut at the real caret cell before extraction:
    cells to its right are terminal padding or stale cells, never draft. Rows
    are joined without a newline because this fixture's draft has no hard line
    breaks, and trailing padding is dropped.
    """
    first = rows[0]
    marker = first.find('%>')
    if marker < 0:
        return None
    decoration = marker + 3
    if not first[:decoration].isascii():
        return None
    parts = []
    for index, raw in enumerate(rows):
        if index == len(rows) - 1:
            # A soft wrap that exactly fills its row captures the empty caret
            # row as ''. It belongs to the editor, adds no input characters and
            # must not discard the preceding rows; only that exact blank shape
            # at the decoration column is accepted.
            if not raw.strip() and caret_column == decoration:
                continue
            line = _take_cells(raw, caret_column)
        else:
            line = raw
        if len(line) < decoration or (index != 0 and line[:decoration].strip()):
            return None
        parts.append(line[decoration:].rstrip(' '))
    return ''.join(parts)


def _check_editor_helper():
    prefix = '(fixture-model) ?%> '
    pad = ' ' * len(prefix)
    assert _take_cells('世界🙂abc', 3) == '世' and _take_cells('世界🙂abc', 6) == '世界🙂'
    assert _logical_editor([prefix + 'abc', pad + 'def'], len(pad) + 3) == 'abcdef'
    assert _logical_editor([prefix + '世界-', pad + 'END'], len(pad) + 3) == '世界-END'
    typed = _logical_editor([prefix + '世界-', pad + 'ENDQ'], len(pad) + 4)
    assert typed.endswith('世界-END' + 'Q'), typed
    restored = _logical_editor([prefix + '世界-', pad + 'END'], len(pad) + 3)
    assert restored.endswith('世界-END') and 'Q' not in restored, restored
    assert _logical_editor([prefix + '世界-', pad + 'END' + 'X'], len(pad) + 3) == '世界-END'
    assert _logical_editor([prefix + '世界-', pad + 'END'], len(pad) + 1) == '世界-E'
    assert _logical_editor([prefix + '世界🙂', pad + 'x'], len(pad) + 7) == '世界🙂x'
    # Exactly-full wrap: the captured caret row is blank, not indented.
    assert _logical_editor([prefix + 'ENDQ', ''], len(prefix)) == 'ENDQ'
    assert _logical_editor([prefix + 'ENDQ', pad], len(pad)) == 'ENDQ'
    assert _logical_editor([prefix + 'ENDQ', ''], len(prefix) - 1) is None
    assert _logical_editor([prefix + 'ENDQ', ''], len(prefix) + 1) is None
    assert _logical_editor([prefix + 'ENDQ', 'X'], len(prefix)) is None


class OwnedService(http.server.BaseHTTPRequestHandler):
    requests = 0
    failed = None
    allow_history_seed = False

    def log_message(self, *_):
        pass

    def do_GET(self):
        type(self).requests += 1
        self.send_error(500)

    def do_POST(self):
        try:
            length = int(self.headers.get('content-length', '0'))
            assert 0 < length <= 512 * 1024
            body = json.loads(self.rfile.read(length))
            type(self).requests += 1
            assert type(self).allow_history_seed and type(self).requests == 1
            turns = [message.get('content') for message in body.get('messages', []) if message.get('role') == 'user']
            assert turns and turns[-1] == 'wrap-history-seed'
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            chunks = [
                {'choices': [{'index': 0, 'delta': {'content': 'wrap-history-ready'}, 'finish_reason': None}]},
                {'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}], 'usage': {'prompt_tokens': 20, 'completion_tokens': 3, 'total_tokens': 23}},
            ]
            for chunk in chunks:
                self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
            self.wfile.write(b'data: [DONE]\n\n')
        except Exception as exc:
            type(self).failed = exc
            self.send_error(500)


def run(app, wrap=False, local_command=False):
    OwnedService.requests = 0
    OwnedService.failed = None
    OwnedService.allow_history_seed = False
    httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), OwnedService)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='thin-viewport-') as tmp:
            root = Path(tmp)
            home, project = root / 'home', root / 'project'
            (home / '.thin').mkdir(parents=True)
            project.mkdir()
            config = {'memory': {'auto': False}, 'llm': {'default': 'owned/fixture-model', 'providers': {'owned': {'base_url': f'http://127.0.0.1:{httpd.server_port}/v1', 'api_key_env': 'THIN_VIEW_KEY', 'models': {'fixture-model': {'protocol': 'chat', 'context_tokens': 32768}}}}}, 'limits': {'low_price_input': False}}
            cfg = home / '.thin/config.json'
            cfg.write_text(json.dumps(config))
            cfg.chmod(0o600)
            rc = root / 'tmux.conf'
            rc.write_text('set -g status off\nset -g default-terminal xterm-256color\nset -g history-limit 2000\nset -g remain-on-exit on\n')
            # The foreground starts its own AF_UNIX worker under
            # $XDG_RUNTIME_DIR/thin. An owned short base keeps every socket
            # inside this fixture instead of the shared /tmp/thin-<uid> fallback.
            runtime = root / 'r'
            runtime.mkdir(mode=0o700)
            assert runtime.is_absolute() and (runtime.stat().st_mode & 0o777) == 0o700, 'owned runtime must be an absolute 0700 directory'
            assert len(str(runtime)) + 14 + 32 + 5 <= 107, 'AF_UNIX socket path budget exceeded'
            env = {'PATH': '/usr/bin:/bin', 'HOME': str(home), 'XDG_RUNTIME_DIR': str(runtime), 'LANG': 'C.UTF-8', 'TERM': 'xterm-256color', 'THIN_VIEW_KEY': 'owned-fake-only'}
            base = ['tmux', '-S', str(root / 'sock'), '-f', str(rc)]
            # Foreground server remains our reapable child, not a daemon owned
            # by another session. No ambient socket/config or real user TTY.
            server = subprocess.Popen(base + ['-D'], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)

            def tm(*args):
                return subprocess.check_output(base + list(args), env=env, timeout=3, stderr=subprocess.PIPE).decode()

            def wait(predicate, message, timeout=3):
                end = time.monotonic() + timeout
                while not predicate():
                    assert server.poll() is None, 'owned emulator exited early'
                    assert time.monotonic() < end, message
                    time.sleep(.02)

            def caret():
                return tuple(map(int, tm('display-message', '-p', '-t', 'owned:0.0', '#{cursor_y} #{cursor_x}').split()))

            def pane_state(width, height):
                values = tm('display-message', '-p', '-t', 'owned:0.0', '#{pane_width} #{pane_height} #{cursor_y} #{cursor_x} #{cursor_flag} #{pane_dead}').split()
                if values[:2] != [str(width), str(height)]:
                    return None
                return tuple(map(int, values[2:]))

            def lines_now():
                return tm('capture-pane', '-p', '-t', 'owned:0.0').splitlines()

            def visible(width, height, marker=''):
                """An end-position composer is anchored to the physical bottom."""
                state = pane_state(width, height)
                if state is None:
                    return False
                y, _x, flag, dead = state
                if flag != 1 or dead != 0 or y != height - 1:
                    return False
                lines = lines_now()
                if len(lines) != height:
                    return False
                near = '\n'.join(lines[max(0, y - 8):y + 1])
                return '%>' in near and marker in near and sum('%>' in line for line in lines) == 1

            def dimensions(width, height):
                return tm('display-message', '-p', '-t', 'owned:0.0', '#{pane_width} #{pane_height}').split() == [str(width), str(height)]

            def quiet(interval=.22):
                # Longer than the removed 150ms repair debounce: a resize alone
                # must not redraw, fill or replay anything.
                before = tm('capture-pane', '-p', '-t', 'owned:0.0')
                time.sleep(interval)
                return before == tm('capture-pane', '-p', '-t', 'owned:0.0')

            def passive_resize(width, height):
                tm('resize-window', '-t', 'owned:0', '-x', str(width), '-y', str(height))
                wait(lambda: dimensions(width, height), f'resize {width}x{height} not delivered')
                # Exactly one quiescence interval: retrying would hide a one-time
                # repaint behind the following quiet window.
                assert quiet(), f'resize-only {width}x{height} repainted instead of staying passive'

            def composer(width, height):
                """Current logical editor line, located from the real cursor.

                Scrollback is excluded and so are stale composer rows left above
                by an earlier geometry: the client owns reflow of already
                displayed cells, so the nearest `%>` row at or above the cursor is
                the live editor. Its visible rows are soft wraps of one logical
                line, so the ASCII decoration/continuation indent is removed and
                the caret cell bounds the last row instead of terminal padding.
                """
                state = pane_state(width, height)
                if state is None:
                    return None
                y, _x, flag, dead = state
                if flag != 1 or dead != 0 or not 0 <= y < height:
                    return None
                cursor_y, cursor_x = caret()
                if cursor_y != y:
                    return None
                lines = lines_now()
                if len(lines) != height:
                    return None
                rows = [index for index, line in enumerate(lines) if '%>' in line and index <= y]
                if not rows or y - rows[-1] > 7:
                    return None
                return _logical_editor(lines[rows[-1]:y + 1], cursor_x)

            def resume(width, height, marker):
                """A real edit after resize draws the frame at the new size.

                The observation is the current editor region at the real cursor,
                not scrollback or pixels reflowed by the client: the typed Q must
                appear there and disappear again with the preserved draft still
                ending on the physical bottom. Older rows are not replayed.
                """
                tm('send-keys', '-t', 'owned:0.0', '-l', 'Q')
                wait(lambda: (composer(width, height) or '').endswith(marker + 'Q') and caret()[0] == height - 1, f'fresh {width}x{height} editor did not echo the typed cell at bottom')
                tm('send-keys', '-t', 'owned:0.0', 'BSpace')

                def restored():
                    text = composer(width, height)
                    return text is not None and text.endswith(marker) and 'Q' not in text and caret()[0] == height - 1

                wait(restored, f'fresh {width}x{height} frame after BSpace lost the draft')

            _check_editor_helper()
            try:
                wait(lambda: (root / 'sock').exists(), 'owned emulator startup timed out')
                tm('new-session', '-d', '-s', 'owned', '-x', '80', '-y', '24', '-c', str(project), shlex.join([app, '--no-model-auto-refresh']))
                wait(lambda: visible(80, 24), 'initial composer frame not visible at 80x24')
                tm('send-keys', '-t', 'owned:0.0', '-l', 'long-viewport-draft-abcdefghijklmnopqrstuvwxyz-世界-END')
                wait(lambda: visible(80, 24, '世界-END'), 'wide-character draft missing')
                if wrap:
                    history_seed = '!true' if local_command else 'wrap-history-seed'
                    if not local_command:
                        # The ordinary wrap mode uses one owned loopback reply.
                        OwnedService.allow_history_seed = True
                    tm('send-keys', '-t', 'owned:0.0', 'C-u')
                    tm('send-keys', '-t', 'owned:0.0', '-l', history_seed)
                    tm('send-keys', '-t', 'owned:0.0', 'Enter')

                    def history_ready():
                        if not visible(80, 24):
                            return False
                        grid = tm('capture-pane', '-p', '-t', 'owned:0.0').splitlines()
                        empty = all(not line.split('%>', 1)[1].strip() for line in grid if '%>' in line)
                        # A completed command row may legitimately move into
                        # native scrollback while the fresh composer stays on the
                        # live cursor row. Completion is not synonymous with
                        # retaining that row in the current grid.
                        transcript = tm('capture-pane', '-p', '-S', '-200', '-t', 'owned:0.0').splitlines()
                        marker = '> true' if local_command else 'wrap-history-ready'
                        return empty and any(marker in line for line in transcript)

                    wait(history_ready, 'owned history seed did not complete')
                    assert OwnedService.failed is None
                    value = 'wrap-A-' + 'abcdefghij' * 20 + '-WRAP-END'
                    tm('send-keys', '-t', 'owned:0.0', 'C-u')
                    tm('send-keys', '-t', 'owned:0.0', '-l', value)
                    wait(lambda: visible(80, 24, '-WRAP-END'), 'wrapped input end missing')
                    lines = lines_now()
                    prompt_row = next(i for i, line in enumerate(lines) if '%>' in line)
                    assert prompt_row < caret()[0], 'long input did not wrap'
                    ended = caret()
                    tm('send-keys', '-t', 'owned:0.0', 'Up')
                    wait(lambda: caret() == (ended[0] - 1, ended[1]), 'Up did not move to the previous visual input row')
                    tm('send-keys', '-t', 'owned:0.0', 'Down')
                    wait(lambda: caret() == ended, 'Down did not restore the visual input row/column')
                    after_arrows = lines_now()
                    assert sum('%>' in line for line in after_arrows) == 1, 'visual arrows duplicated the composer'
                    draft_row = caret()[0]
                    assert any('-WRAP-END' in line for line in after_arrows[max(0, draft_row - 8):draft_row + 1]), 'visual arrows replaced or clipped the draft'

                    def at_start():
                        lines = tm('capture-pane', '-p', '-t', 'owned:0.0').splitlines()
                        rows = [i for i, line in enumerate(lines) if '%>' in line]
                        if len(rows) != 1:
                            return False
                        cursor = tm('display-message', '-p', '-t', 'owned:0.0', '#{cursor_y} #{cursor_x}').split()
                        return cursor == [str(rows[0]), str(lines[rows[0]].index('%>') + 3)]

                    tm('send-keys', '-t', 'owned:0.0', 'Home')
                    wait(at_start, 'wrapped input Home caret misplaced')
                    tm('send-keys', '-t', 'owned:0.0', 'Up')
                    wait(lambda: at_start() and any('%>' in line and history_seed in line for line in tm('capture-pane', '-p', '-t', 'owned:0.0').splitlines()), 'origin Up did not recall the submitted input')
                    tm('send-keys', '-t', 'owned:0.0', 'Down')
                    wait(lambda: at_start() and any('%>' in line and 'wrap-A-' in line for line in tm('capture-pane', '-p', '-t', 'owned:0.0').splitlines()), 'origin Down did not restore the original multiline draft')
                    start = caret()
                    tm('send-keys', '-t', 'owned:0.0', 'Right')
                    start_right = (start[0], start[1] + 1)
                    wait(lambda: caret() == start_right, 'Right did not leave the exact input origin')
                    tm('send-keys', '-t', 'owned:0.0', 'Up')
                    wait(lambda: caret() == start_right, 'top visual row at nonzero column entered history')
                    tm('send-keys', '-t', 'owned:0.0', '-l', 'X')
                    tm('send-keys', '-t', 'owned:0.0', 'End')
                    wait(lambda: visible(80, 24, '-WRAP-END'), 'redraw from middle cursor corrupted tail')
                    tm('send-keys', '-t', 'owned:0.0', 'C-u')
                    tm('send-keys', '-t', 'owned:0.0', '-l', 'large-' + '世界🙂abcdefghij' * 100 + '-UNICODE-END')
                    wait(lambda: visible(80, 24, '-UNICODE-END'), 'bounded Unicode viewport end missing')
                    lines = lines_now()
                    prompt_row = next(i for i, line in enumerate(lines) if '%>' in line)
                    # Eight rendered composer rows, measured from the real cursor
                    # row instead of an assumed physical bottom.
                    assert 0 <= caret()[0] - prompt_row <= 7, 'composer exceeded eight-row viewport'
                    tm('send-keys', '-t', 'owned:0.0', 'Home')
                    wait(at_start, 'bounded viewport did not follow Home')
                    tm('send-keys', '-t', 'owned:0.0', 'End')
                    wait(lambda: visible(80, 24, '-UNICODE-END'), 'bounded viewport did not follow End')
                    print(f'PASS composer-wrap: seed={"local-command" if local_command else "loopback"}, visible multiline input, visual rows, exact-origin history/draft restore, bounded Unicode viewport')
                # Passive resize stage: the client owns reflow of already displayed
                # cells. Thin takes the new dimensions, drops old-frame authority
                # and resumes on real input; no automatic repair or application
                # reflow of older rows is required. Fresh frames pin the editor.
                marker = '-UNICODE-END' if wrap else '世界-END'
                for width, height in ((80, 40), (80, 8), (80, 24), (40, 24), (80, 24)):
                    passive_resize(width, height)
                for width, height in ((40, 8), (100, 40), (80, 24)):
                    passive_resize(width, height)
                    resume(width, height, marker)
                expected_requests = 1 if wrap and not local_command else 0
                assert OwnedService.requests == expected_requests, 'unexpected resize/draft/helper HTTP'
                assert OwnedService.failed is None, f'owned loopback assertion failed: {OwnedService.failed}'
                assert cfg.read_text() == json.dumps(config), 'resize changed settings'
                tm('send-keys', '-t', 'owned:0.0', 'C-u', 'C-d')

                def exited_cleanly():
                    dead, status, signal, pid = tm('display-message', '-p', '-t', 'owned:0.0', '#{pane_dead}|#{pane_dead_status}|#{pane_dead_signal}|#{pane_pid}').strip().split('|')
                    if dead != '1' or signal not in ('', '0'):
                        return False
                    if status == '0':
                        return True
                    # Some tmux versions leave pane_dead_status empty while the
                    # owned direct child is still an unreaped zombie. Linux
                    # /proc stat field 52 is the raw wait status; zero proves a
                    # normal exit without changing the child topology/timing.
                    try:
                        fields = (Path('/proc') / pid / 'stat').read_text().rsplit(') ', 1)[1].split()
                        return len(fields) >= 50 and int(fields[49]) == 0
                    except (FileNotFoundError, ValueError, IndexError):
                        return False

                wait(exited_cleanly, 'application did not exit cleanly')
                print(f'PASS resize-viewport: passive height/width/ABA without repaint, fresh frame at new dimensions on real input, draft retained, cursor visible, HTTP={OwnedService.requests}, clean exit')
            finally:
                if server.poll() is None:
                    subprocess.run(base + ['kill-server'], env=env, timeout=3, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    try:
                        server.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait(timeout=3)
    finally:
        httpd.shutdown()
        httpd.server_close()
        thread.join(timeout=2)


if __name__ == '__main__':
    try:
        assert len(sys.argv) in (2, 3) and (len(sys.argv) == 2 or sys.argv[2] in ('--wrap', '--local-command'))
        mode = sys.argv[2] if len(sys.argv) == 3 else None
        run(str(Path(sys.argv[1]).resolve()), wrap=mode is not None, local_command=mode == '--local-command')
    except Exception as exc:
        # No config/screen/HTTP body diagnostics, only bounded fixture messages.
        print(f'FAIL resize-viewport: {type(exc).__name__}: {exc}', file=sys.stderr)
        sys.exit(1)
