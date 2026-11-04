#!/usr/bin/env python3
"""Real checkpoint/menu acceptance with owned PTYs and a loopback Chat server."""
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
import stat
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

from idle_enter_mock import Screen, FRAME_END, SYNC_BEGIN

requests = []
errors = []
selected_id = None
# Screen is an ASCII VT oracle; Unicode title validity is covered by core tests.
MODEL_TITLE = 'Resume summary'
FALLBACK_TITLE = 'seed-two-user'


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        errors.append(AssertionError('unexpected GET'))
        self.send_error(500)

    def do_POST(self):
        try:
            assert self.path == '/v1/chat/completions'
            assert self.headers['Authorization'] == 'Bearer fixture-key'
            size = int(self.headers['Content-Length'])
            assert 0 < size < 524288
            body = json.loads(self.rfile.read(size))
            requests.append(body)
            n = len(requests)
            assert n <= 4, 'unexpected model call'
            messages = body['messages']
            tools = body['tools']
            names = [tool['function']['name'] for tool in tools]
            assert names.count('set_session_title') == 1, 'root title tool schema missing or duplicated'
            schema = next(tool['function'] for tool in tools if tool['function']['name'] == 'set_session_title')
            assert schema['parameters']['type'] == 'object'
            assert schema['parameters']['properties']['title']['type'] == 'string'
            assert 'title' in schema['parameters']['required']
            if n == 4:
                assert self.headers.get('x-opencode-session') == selected_id
                wire = json.dumps(messages)
                assert 'seed-one-user' in wire and 'seed-one-answer' in wire
                assert 'continuation-user' in wire and 'resume-side-effect' in wire
                assert 'seed-two-user' not in wire
                assert any(m.get('role') == 'tool' for m in messages)
                calls = [c for m in messages for c in m.get('tool_calls', [])]
                assert sum(c['function']['name'] == 'set_session_title' for c in calls) == 1
                assert sum(m.get('role') == 'tool' and m.get('tool_call_id') == 'resume-title' for m in messages) == 1
            if n == 1:
                delta = {'role': 'assistant', 'tool_calls': [
                    {'index': 0, 'id': 'resume-tool', 'type': 'function', 'function': {'name': 'bash', 'arguments': json.dumps({'command': 'printf once >> resume-side-effect'})}},
                    {'index': 1, 'id': 'resume-title', 'type': 'function', 'function': {'name': 'set_session_title', 'arguments': json.dumps({'title': MODEL_TITLE}, ensure_ascii=False)}},
                ]}
                finish = 'tool_calls'
            else:
                delta = {'content': {2: 'seed-one-answer', 3: 'seed-two-answer', 4: 'continuation-answer'}[n]}
                finish = 'stop'
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            for event in ({'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]},
                          {'choices': [{'index': 0, 'delta': {}, 'finish_reason': finish}], 'usage': {'prompt_tokens': 100, 'completion_tokens': 5, 'total_tokens': 105}}):
                self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())
            self.wfile.write(b'data: [DONE]\n\n')
        except Exception as exc:
            errors.append(exc)
            if not self.wfile.closed:
                try:
                    self.send_error(500)
                except OSError:
                    pass


class Terminal:
    def __init__(self, app, home, project, runtime):
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 120, 0, 0))
        self.screen = Screen(120)
        self.data = bytearray()
        self.pending = b''
        def setup():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        self.child = subprocess.Popen([app, '--no-model-auto-refresh'], cwd=project,
            stdin=self.slave, stdout=self.slave, stderr=self.slave, preexec_fn=setup,
            env={'PATH': '/usr/bin:/bin', 'HOME': str(home), 'XDG_RUNTIME_DIR': str(runtime),
                 'LANG': 'C.UTF-8', 'TERM': 'xterm-256color', 'THIN_FIXTURE_KEY': 'fixture-key',
                 'NO_PROXY': '*', 'no_proxy': '*'})

    def lines(self):
        return self.screen.history + [''.join(row) for row in self.screen.grid]

    def send(self, data):
        os.write(self.master, data)

    def pump(self, predicate, phase, *, deadline=None):
        if deadline is None:
            deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if errors:
                raise errors[0]
            if predicate():
                return
            readable, _, _ = select.select([self.master], [], [], .05)
            if readable:
                try:
                    data = os.read(self.master, 65536)
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
                    data = b''
                self.data.extend(data)
                assert len(self.data) < 2 * 1024 * 1024
                # Respond to the terminal's cursor position query, including split reads.
                self.pending += data
                query = b'\x1b[6n'
                while query in self.pending:
                    before, self.pending = self.pending.split(query, 1)
                    self.screen.feed(before)
                    self.send(f'\x1b[{self.screen.row + 1};{self.screen.col + 1}R'.encode())
                keep = max((n for n in range(1, len(query)) if self.pending.endswith(query[:n])), default=0)
                self.screen.feed(self.pending[:-keep] if keep else self.pending)
                self.pending = self.pending[-keep:] if keep else b''
            if self.child.poll() is not None and not predicate():
                raise AssertionError(f'{phase}: PTY exited prematurely (code={self.child.returncode})')
        editor = self.screen.editor_tail()[:120].replace('fixture-key', '[redacted]')
        screen = [''.join(row).rstrip()[:120].replace('fixture-key', '[redacted]')
                  for row in self.screen.grid if ''.join(row).strip()][-8:]
        raise AssertionError(f'{phase}: PTY phase timed out (POST={len(requests)}, '
                             f'cursor={self.screen.row},{self.screen.col}, '
                             f'frame_complete={self.data.endswith(FRAME_END)}, editor={editor!r}, '
                             f'screen={screen!r})')

    def idle(self):
        return self.data.endswith(FRAME_END) and self.screen.idle(clear_below=True)

    def close(self):
        try:
            if self.child.poll() is None:
                try:
                    os.killpg(self.child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    self.child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(self.child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    self.child.wait(timeout=3)
        finally:
            os.close(self.master)
            os.close(self.slave)


def read_title(sessions, session_id):
    path = sessions / f'{session_id}.title'
    info = path.lstat()
    assert stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode)
    assert stat.S_IMODE(info.st_mode) == 0o600
    assert 0 < info.st_size <= 256
    assert (sessions / f'{session_id}.session').is_file()
    return path.read_bytes().decode('utf-8')


def main(app):
    global selected_id
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='thin-resume-menu-') as tmp:
            home, project, runtime = (Path(tmp) / n for n in ('home', 'project', 'r'))
            (home / '.thin').mkdir(parents=True)
            project.mkdir()
            runtime.mkdir(mode=0o700)
            # The local mock has no real price evidence; production defaults are unchanged.
            config = {'memory': {'auto': False}, 'limits': {'low_price_input': False},
                      'llm': {'default': 'local/fixture-model',
                      'providers': {'local': {'kind': 'opencode_zen', 'base_url': f'http://127.0.0.1:{server.server_port}/v1',
                      'api_key_env': 'THIN_FIXTURE_KEY', 'models': {'fixture-model': {'protocol': 'chat', 'context_tokens': 32768}}}}}}
            config_path = home / '.thin/config.json'
            config_path.write_text(json.dumps(config))
            config_path.chmod(0o600)
            sessions = project / '.thin/sessions'
            ids = []
            for number in (1, 2):
                term = Terminal(app, home, project, runtime)
                try:
                    term.pump(term.idle, f'seed-{number} startup composer')
                    term.send(f'seed-{("one", "two")[number - 1]}-user\r'.encode())
                    answer = f'seed-{("one", "two")[number - 1]}-answer'
                    term.pump(lambda: answer in '\n'.join(term.lines()) and term.idle(),
                              f'seed-{number} complete answer')
                    term.send(b'\x04')
                    term.pump(lambda: term.child.poll() is not None, f'seed-{number} clean exit')
                    assert term.child.wait() == 0
                finally:
                    term.close()
                current = {p.stem for p in sessions.glob('*.session') if re.fullmatch(r'[0-9a-f]{32}', p.stem)}
                new = current - set(ids)
                assert len(new) == 1
                ids.append(new.pop())
            assert len(requests) == 3
            selected_id = ids[0]
            assert read_title(sessions, ids[0]) == MODEL_TITLE
            assert read_title(sessions, ids[1]) == FALLBACK_TITLE
            titles_before = {i: (sessions / f'{i}.title').read_bytes() for i in ids}
            marker = project / 'resume-side-effect'
            assert marker.read_text() == 'once'
            term = Terminal(app, home, project, runtime)
            try:
                term.pump(term.idle, 'fresh launcher startup composer')
                term.send(b'/resume\r')
                term.pump(lambda: all(any(title in line for line in term.lines()) for title in (MODEL_TITLE, FALLBACK_TITLE)) and term.data.endswith(FRAME_END),
                          'first resume menu contains both titles')
                lines = term.lines()
                assert next(i for i, line in enumerate(lines) if FALLBACK_TITLE in line) < next(i for i, line in enumerate(lines) if MODEL_TITLE in line)
                assert not any(session_id in line for session_id in ids for line in lines)
                mark = len(term.data)
                term.send(b'\x1b')
                term.pump(lambda: len(term.data) > mark and term.idle() and
                          not any(MODEL_TITLE in ''.join(row) for row in term.screen.grid),
                          'Escape returns to current composer')
                assert len(requests) == 3
                mark = len(term.data)
                term.send(b'/resume\r')
                term.pump(lambda: len(term.data) > mark and all(any(title in ''.join(row) for row in term.screen.grid) for title in (MODEL_TITLE, FALLBACK_TITLE)) and term.data.endswith(FRAME_END),
                          'reopened resume menu contains both titles')
                arrow_mark = len(term.data)
                selection_deadline = time.monotonic() + 15
                term.send(b'\x1b[B')
                term.pump(lambda: len(term.data) > arrow_mark and term.data.endswith(FRAME_END) and
                          term.data.rfind(SYNC_BEGIN) >= arrow_mark and
                          any(''.join(row).lstrip().startswith(f'> {MODEL_TITLE}') for row in term.screen.grid),
                          'Down selects older checkpoint in a fresh complete frame', deadline=selection_deadline)
                term.send(b'\r')
                term.pump(lambda: any('seed-one-answer' in line for line in term.lines()) and term.idle(),
                          'selected checkpoint full history arrives', deadline=selection_deadline)
                assert len(requests) == 3 and marker.read_text() == 'once'
                term.send(b'continuation-user\r')
                term.pump(lambda: any('continuation-answer' in line for line in term.lines()) and term.idle(),
                          'normal prompt continues restored history')
                assert len(requests) == 4 and marker.read_text() == 'once'
                assert {i: (sessions / f'{i}.title').read_bytes() for i in ids} == titles_before
                term.send(b'\x04')
                term.pump(lambda: term.child.poll() is not None, 'restored launcher clean exit')
                assert term.child.wait() == 0
                assert {i: (sessions / f'{i}.title').read_bytes() for i in ids} == titles_before
            finally:
                term.close()
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
    assert not errors, 'resume-menu mock recorded an unexpected HTTP or handler failure'
    print('PASS resume-menu: real checkpoints, ordered menu, cancel, full history, no replay, continuation')


if __name__ == '__main__':
    main(os.path.abspath(sys.argv[1]))
