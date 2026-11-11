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
selected_ids = []
continuation_sessions = []
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
            assert n <= 6, 'unexpected model call'
            messages = body['messages']
            tools = body['tools']
            names = [tool['function']['name'] for tool in tools]
            assert names.count('set_session_title') == 1, 'root title tool schema missing or duplicated'
            schema = next(tool['function'] for tool in tools if tool['function']['name'] == 'set_session_title')
            assert schema['parameters']['type'] == 'object'
            assert schema['parameters']['properties']['title']['type'] == 'string'
            assert 'title' in schema['parameters']['required']
            if n >= 4:
                actual = self.headers.get('x-opencode-session')
                continuation_sessions.append(actual)
                assert actual == selected_ids[n - 4]
                wire = json.dumps(messages)
                if n in (4, 6):
                    assert 'seed-one-user' in wire and 'seed-one-answer' in wire
                    assert ('continuation-user' if n == 4 else 'return-a-user') in wire
                    assert 'resume-side-effect' in wire and 'seed-two-user' not in wire
                    assert any(m.get('role') == 'tool' for m in messages)
                    calls = [c for m in messages for c in m.get('tool_calls', [])]
                    assert sum(c['function']['name'] == 'set_session_title' for c in calls) == 1
                    assert sum(m.get('role') == 'tool' and m.get('tool_call_id') == 'resume-title' for m in messages) == 1
                else:
                    assert 'seed-two-user' in wire and 'seed-two-answer' in wire
                    assert 'probe-b-user' in wire and 'seed-one-user' not in wire
            if n == 1:
                delta = {'role': 'assistant', 'tool_calls': [
                    {'index': 0, 'id': 'resume-tool', 'type': 'function', 'function': {'name': 'bash', 'arguments': json.dumps({'command': 'printf once >> resume-side-effect'})}},
                    {'index': 1, 'id': 'resume-title', 'type': 'function', 'function': {'name': 'set_session_title', 'arguments': json.dumps({'title': MODEL_TITLE}, ensure_ascii=False)}},
                ]}
                finish = 'tool_calls'
            else:
                delta = {'content': {2: 'seed-one-answer', 3: 'seed-two-answer', 4: 'continuation-answer',
                                     5: 'probe-b-answer', 6: 'return-a-answer'}[n]}
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
    def __init__(self, app, home, project, runtime, *, args=(), home_literal=None):
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 120, 0, 0))
        self.screen = Screen(120)
        self.data = bytearray()
        self.pending = b''
        def setup():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        self.child = subprocess.Popen([app, *args, '--no-model-auto-refresh'], cwd=project,
            stdin=self.slave, stdout=self.slave, stderr=self.slave, preexec_fn=setup,
            env={'PATH': '/usr/bin:/bin', 'HOME': home_literal or str(home), 'XDG_RUNTIME_DIR': str(runtime),
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
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='thin-resume-menu-', dir='/tmp') as tmp:
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
            selected_ids[:] = [ids[0], ids[1], ids[0]]
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

                # Set only checkpoint mtimes to make the menu's initial row
                # deterministic, without altering its serialized history.
                def newest(session_id):
                    now = time.time_ns()
                    for item in ids:
                        stamp = now if item == session_id else now - 10_000_000_000
                        os.utime(sessions / f'{item}.session', ns=(stamp, stamp))

                def default_resume(title, phase, notice):
                    mark = len(term.data)
                    term.send(b'/resume\r')
                    term.pump(lambda: len(term.data) > mark and term.data.endswith(FRAME_END) and
                              term.data.rfind(SYNC_BEGIN) >= mark and
                              any(''.join(row).lstrip().startswith(f'> {title}') for row in term.screen.grid),
                              f'{phase} default selection fresh complete frame')
                    mark = len(term.data)
                    term.send(b'\r')  # separate input read after the complete selection frame
                    term.pump(lambda: notice.encode() in term.data[mark:] and term.idle() and
                              not any(''.join(row).lstrip().startswith(f'> {title}') for row in term.screen.grid),
                              f'{phase} result and menu closed')

                newest(ids[0])
                default_resume(MODEL_TITLE, 'same-current no-op', 'Already attached')
                assert len(requests) == 4 and marker.read_text() == 'once'
                newest(ids[1])
                default_resume(FALLBACK_TITLE, 'switch to B', 'Conversation restored; prior tools are NOT rerun')
                assert len(requests) == 4 and marker.read_text() == 'once'
                term.send(b'probe-b-user\r')
                term.pump(lambda: any('probe-b-answer' in line for line in term.lines()) and term.idle(),
                          'explicit B continuation')
                assert len(requests) == 5 and marker.read_text() == 'once'
                newest(ids[0])
                default_resume(MODEL_TITLE, 'return to live A', 'Conversation restored; prior tools are NOT rerun')
                assert len(requests) == 5 and marker.read_text() == 'once'
                term.send(b'return-a-user\r')
                term.pump(lambda: any('return-a-answer' in line for line in term.lines()) and term.idle(),
                          'explicit return-to-A continuation')
                # Three seed POSTs and exactly three explicit continuation POSTs;
                # switching, listing and same-current no-op never infer.
                assert len(requests) == 6 and continuation_sessions == selected_ids
                assert marker.read_text() == 'once'
                assert {i: (sessions / f'{i}.title').read_bytes() for i in ids} == titles_before
                term.send(b'\x04')
                term.pump(lambda: term.child.poll() is not None, 'restored launcher clean exit')
                assert term.child.wait() == 0
                assert {i: (sessions / f'{i}.title').read_bytes() for i in ids} == titles_before
            finally:
                term.close()
        trailing_home_connect(app, server)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
    assert not errors, 'resume-menu mock recorded an unexpected HTTP or handler failure'
    print('PASS resume-menu: foreground and trailing-HOME connect A-B-A, full history, no replay, six POSTs and zero GETs each')


def trailing_home_connect(app, server):
    """Real --connect launcher keeps using canonical HOME when returning to A."""
    requests.clear()
    selected_ids.clear()
    continuation_sessions.clear()
    with tempfile.TemporaryDirectory(prefix='thin-resume-connect-', dir='/tmp') as tmp:
        home, runtime = (Path(tmp) / name for name in ('home', 'r'))
        (home / '.thin').mkdir(parents=True)
        runtime.mkdir(mode=0o700)
        config = {'memory': {'auto': False}, 'limits': {'low_price_input': False},
                  'llm': {'default': 'local/fixture-model',
                  'providers': {'local': {'kind': 'opencode_zen', 'base_url': f'http://127.0.0.1:{server.server_port}/v1',
                  'api_key_env': 'THIN_FIXTURE_KEY', 'models': {'fixture-model': {'protocol': 'chat', 'context_tokens': 32768}}}}}}
        config_path = home / '.thin/config.json'
        config_path.write_text(json.dumps(config))
        config_path.chmod(0o600)
        sessions = home / '.thin/sessions'
        ids = []
        for number in (1, 2):
            term = Terminal(app, home, home, runtime)
            try:
                term.pump(term.idle, f'connect seed-{number} startup')
                word = ('one', 'two')[number - 1]
                term.send(f'seed-{word}-user\r'.encode())
                term.pump(lambda: any(f'seed-{word}-answer' in line for line in term.lines()) and term.idle(),
                          f'connect seed-{number} answer')
                term.send(b'\x04')
                term.pump(lambda: term.child.poll() is not None, f'connect seed-{number} exit')
                assert term.child.wait() == 0
            finally:
                term.close()
            current = {p.stem for p in sessions.glob('*.session') if re.fullmatch(r'[0-9a-f]{32}', p.stem)}
            new = current - set(ids)
            assert len(new) == 1
            ids.append(new.pop())
        assert len(requests) == 3
        selected_ids[:] = [ids[0], ids[1], ids[0]]
        titles_before = {i: (sessions / f'{i}.title').read_bytes() for i in ids}
        marker = home / 'resume-side-effect'
        assert marker.read_text() == 'once'
        home_literal = str(home) + '/'
        env = {'PATH': '/usr/bin:/bin', 'HOME': home_literal, 'XDG_RUNTIME_DIR': str(runtime),
               'LANG': 'C.UTF-8', 'TERM': 'xterm-256color', 'THIN_FIXTURE_KEY': 'fixture-key',
               'NO_PROXY': '*', 'no_proxy': '*'}
        daemon = subprocess.Popen([app, '--daemon', '--no-model-auto-refresh'], cwd=home, env=env,
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  start_new_session=True)
        term = None
        try:
            deadline = time.monotonic() + 15
            socket = runtime / 'thin/daemon.sock'
            while not socket.is_socket() and time.monotonic() < deadline:
                assert daemon.poll() is None, 'owned daemon exited before publishing its socket'
                time.sleep(.02)
            assert socket.is_socket(), 'owned daemon did not publish its socket'
            term = Terminal(app, home, home, runtime, args=('--connect',), home_literal=home_literal)
            term.pump(term.idle, 'trailing-HOME connect startup')

            def select(session_id, title, phase):
                now = time.time_ns()
                for item in ids:
                    stamp = now if item == session_id else now - 10_000_000_000
                    os.utime(sessions / f'{item}.session', ns=(stamp, stamp))
                mark = len(term.data)
                term.send(b'/resume\r')
                term.pump(lambda: len(term.data) > mark and term.data.endswith(FRAME_END) and
                          term.data.rfind(SYNC_BEGIN) >= mark and
                          any(''.join(row).lstrip().startswith(f'> {title}') for row in term.screen.grid),
                          f'{phase} selection')
                mark = len(term.data)
                term.send(b'\r')
                term.pump(lambda: b'Conversation restored; prior tools are NOT rerun' in term.data[mark:] and
                          term.idle() and not any(''.join(row).lstrip().startswith(f'> {title}') for row in term.screen.grid),
                          f'{phase} restored')

            select(ids[0], MODEL_TITLE, 'trailing-HOME A')
            assert len(requests) == 3 and marker.read_text() == 'once'
            term.send(b'continuation-user\r')
            term.pump(lambda: any('continuation-answer' in line for line in term.lines()) and term.idle(), 'trailing-HOME A continuation')
            select(ids[1], FALLBACK_TITLE, 'trailing-HOME B')
            assert len(requests) == 4 and marker.read_text() == 'once'
            term.send(b'probe-b-user\r')
            term.pump(lambda: any('probe-b-answer' in line for line in term.lines()) and term.idle(), 'trailing-HOME B continuation')
            select(ids[0], MODEL_TITLE, 'trailing-HOME live return to A')
            assert len(requests) == 5 and marker.read_text() == 'once'
            term.send(b'return-a-user\r')
            term.pump(lambda: any('return-a-answer' in line for line in term.lines()) and term.idle(), 'trailing-HOME return A continuation')
            assert len(requests) == 6 and continuation_sessions == selected_ids
            assert marker.read_text() == 'once'
            assert {i: (sessions / f'{i}.title').read_bytes() for i in ids} == titles_before
            term.send(b'\x04')
            term.pump(lambda: term.child.poll() is not None, 'trailing-HOME connect exit')
            assert term.child.wait() == 0
        finally:
            if term is not None:
                term.close()
            if daemon.poll() is None:
                daemon.terminate()
                try:
                    daemon.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait(timeout=3)


if __name__ == '__main__':
    main(os.path.abspath(sys.argv[1]))
