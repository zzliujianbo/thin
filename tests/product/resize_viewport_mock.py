#!/usr/bin/env python3
"""Owned real-emulator resize regression: requires installed tmux, no packages.
python3 tests/product/resize_viewport_mock.py /absolute/path/to/thin [--wrap|--local-command]
Uses only an owned foreground tmux server/socket, HOME/project and loopback.
Checks visible cells/cursor, not pixels or every physical terminal emulator.
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
            env = {'PATH': '/usr/bin:/bin', 'HOME': str(home), 'LANG': 'C.UTF-8', 'TERM': 'xterm-256color', 'THIN_VIEW_KEY': 'owned-fake-only'}
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

            def visible(width, height, marker=''):
                state = tm('display-message', '-p', '-t', 'owned:0.0', '#{pane_width} #{pane_height} #{cursor_y} #{cursor_flag} #{pane_dead}').split()
                if state != [str(width), str(height), str(height - 1), '1', '0']:
                    return False
                lines = tm('capture-pane', '-p', '-t', 'owned:0.0').splitlines()
                tail = lines[-8:]
                return len(lines) == height and any('%>' in line for line in tail) and marker in '\n'.join(tail) and sum('%>' in line for line in lines) == 1

            try:
                wait(lambda: (root / 'sock').exists(), 'owned emulator startup timed out')
                tm('new-session', '-d', '-s', 'owned', '-x', '80', '-y', '24', '-c', str(project), shlex.join([app, '--no-log', '--no-model-auto-refresh']))
                wait(lambda: visible(80, 24), 'initial composer not visible at viewport bottom')
                # Growing height is intentional: raw-byte silence can leave a
                # perfectly valid old composer stranded above an empty bottom.
                for width, height in ((80, 40), (80, 8), (80, 24), (40, 24), (80, 24)):
                    tm('resize-window', '-t', 'owned:0', '-x', str(width), '-y', str(height))
                    wait(lambda: visible(width, height), 'idle viewport did not recover without input')
                tm('send-keys', '-t', 'owned:0.0', '-l', 'long-viewport-draft-abcdefghijklmnopqrstuvwxyz-世界-END')
                wait(lambda: visible(80, 24, '世界-END'), 'wide-character draft missing')
                for width, height in ((40, 8), (100, 40), (80, 24)):
                    tm('resize-window', '-t', 'owned:0', '-x', str(width), '-y', str(height))
                    wait(lambda: visible(width, height, 'END'), 'draft viewport did not recover without input')
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
                        # native scrollback while the fresh composer stays at
                        # the viewport bottom. Completion is not synonymous
                        # with retaining that row in the current 24-cell grid.
                        transcript = tm('capture-pane', '-p', '-S', '-200', '-t', 'owned:0.0').splitlines()
                        marker = '> true' if local_command else 'wrap-history-ready'
                        return empty and any(marker in line for line in transcript)

                    wait(history_ready, 'owned history seed did not complete')
                    assert OwnedService.failed is None
                    value = 'wrap-A-' + 'abcdefghij' * 20 + '-WRAP-END'
                    tm('send-keys', '-t', 'owned:0.0', 'C-u')
                    tm('send-keys', '-t', 'owned:0.0', '-l', value)
                    wait(lambda: visible(80, 24, '-WRAP-END'), 'wrapped input end missing')
                    lines = tm('capture-pane', '-p', '-t', 'owned:0.0').splitlines()
                    assert next(i for i, line in enumerate(lines) if '%>' in line) < 23, 'long input did not wrap'

                    def caret():
                        return tuple(map(int, tm('display-message', '-p', '-t', 'owned:0.0', '#{cursor_y} #{cursor_x}').split()))

                    ended = caret()
                    tm('send-keys', '-t', 'owned:0.0', 'Up')
                    wait(lambda: caret() == (ended[0] - 1, ended[1]), 'Up did not move to the previous visual input row')
                    tm('send-keys', '-t', 'owned:0.0', 'Down')
                    wait(lambda: caret() == ended, 'Down did not restore the visual input row/column')
                    after_arrows = tm('capture-pane', '-p', '-t', 'owned:0.0').splitlines()
                    assert sum('%>' in line for line in after_arrows) == 1, 'visual arrows duplicated the composer'
                    assert any('-WRAP-END' in line for line in after_arrows[-8:]), 'visual arrows replaced or clipped the draft'

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
                    lines = tm('capture-pane', '-p', '-t', 'owned:0.0').splitlines()
                    assert next(i for i, line in enumerate(lines) if '%>' in line) >= 16, 'composer exceeded eight-row viewport'
                    tm('send-keys', '-t', 'owned:0.0', 'Home')
                    wait(at_start, 'bounded viewport did not follow Home')
                    tm('send-keys', '-t', 'owned:0.0', 'End')
                    wait(lambda: visible(80, 24, '-UNICODE-END'), 'bounded viewport did not follow End')
                    print(f'PASS composer-wrap: seed={"local-command" if local_command else "loopback"}, visible multiline input, visual rows, exact-origin history/draft restore, bounded Unicode viewport')
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
                print('PASS resize-viewport: visible idle/draft composer pinned at bottom after height/width/ABA, Unicode retained, cursor visible, HTTP=0, clean exit')
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
