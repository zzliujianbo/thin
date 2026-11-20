#!/usr/bin/env python3
"""Real checkpoint/menu acceptance with owned PTYs and a loopback Chat server."""
from contextlib import closing, contextmanager
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
import stat
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

from daemon_mock import assert_live_project, children_of, runtime_sockets, wait_checkpoint, wait_pids_gone
from idle_enter_mock import Screen, FRAME_END, SYNC_BEGIN

requests = []
errors = []
selected_ids = []
continuation_sessions = []
# Screen is an ASCII VT oracle; Unicode title validity is covered by core tests.
FIRST_TITLE = 'seed-one-user'
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
            actual = self.headers.get('x-opencode-session', '')
            assert re.fullmatch(r'[0-9a-f]{32}', actual), 'missing original session ID'
            requests.append(actual)
            n = len(requests)
            assert n <= 6, 'unexpected model call'
            messages = body['messages']
            tools = body['tools']
            names = [tool['function']['name'] for tool in tools]
            assert names.count('set_session_title') == 0, 'title tool must be removed'
            if n >= 4:
                continuation_sessions.append(actual)
                assert actual == selected_ids[n - 4]
                wire = json.dumps(messages)
                assert 'unsolicited-turn' not in wire and f'/resume {selected_ids[1]}' not in wire, 'management input leaked into history'
                if n in (4, 6):
                    assert 'seed-one-user' in wire and 'seed-one-answer' in wire
                    assert 'continuation-user' in wire
                    if n == 6:
                        assert 'continuation-answer' in wire and 'return-a-user' in wire
                    assert 'resume-side-effect' in wire and 'seed-two-user' not in wire
                    assert any(m.get('role') == 'tool' for m in messages)
                    calls = [c for m in messages for c in m.get('tool_calls', [])]
                    assert sum(c['function']['name'] == 'bash' for c in calls) == 1
                    assert sum(m.get('role') == 'tool' and m.get('tool_call_id') == 'resume-tool' for m in messages) == 1
                else:
                    assert 'seed-two-user' in wire and 'seed-two-answer' in wire
                    assert 'probe-b-user' in wire and 'seed-one-user' not in wire
            if n == 1:
                delta = {'role': 'assistant', 'tool_calls': [
                    {'index': 0, 'id': 'resume-tool', 'type': 'function', 'function': {'name': 'bash', 'arguments': json.dumps({'command': 'printf once >> resume-side-effect'})}},
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
    def __init__(self, app, home, project, runtime, *, home_literal=None):
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 120, 0, 0))
        self.screen = Screen(120)
        self.data = bytearray()
        self.pending = b''
        def setup():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        self.child = subprocess.Popen([app], cwd=project,
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


def seed(app, home, project, runtime, title, answer, owner):
    with closing(Terminal(app, home, project, runtime)) as term:
        term.pump(term.idle, f'{title} startup')
        before = len(requests)
        term.send((title + '\r').encode())
        term.pump(lambda: any(answer in line for line in term.lines()) and term.idle(), f'{title} answer')
        ident = wait_checkpoint(project, title).stem
        assert requests[before:] and set(requests[before:]) == {ident}, 'seed header/checkpoint mismatch'
        assert_live_project(home, project, ident, owner)
        term.send(b'\x04')
        term.pump(lambda: term.child.poll() is not None, f'{title} exit')
        assert term.child.wait() == 0
    assert read_title(project / '.thin/sessions', ident) == title
    return ident


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
            # Only our loopback URL has credentials, so it cannot claim any
            # official metadata source. Keep rejecting unexpected GETs.
            config = {'llm': {'default': 'local/fixture-model',
                      'providers': {'local': {'kind': 'opencode_zen', 'base_url': f'http://127.0.0.1:{server.server_port}/v1',
                      'api_key_env': 'THIN_FIXTURE_KEY', 'models': {'fixture-model': {'protocol': 'chat', 'context_tokens': 32768}}}}}}
            config_path = home / '.thin/config.json'
            config_path.write_text(json.dumps(config))
            config_path.chmod(0o600)
            sessions = project / '.thin/sessions'
            ids = [seed(app, home, project, runtime, title, answer, 'foreground')
                   for title, answer in ((FIRST_TITLE, 'seed-one-answer'), (FALLBACK_TITLE, 'seed-two-answer'))]
            assert {p.stem for p in sessions.glob('*.session')} == set(ids) and len(set(ids)) == 2
            assert len(requests) == 3
            selected_ids[:] = [ids[0], ids[1], ids[0]]
            assert read_title(sessions, ids[0]) == FIRST_TITLE
            assert read_title(sessions, ids[1]) == FALLBACK_TITLE
            titles_before = {i: (sessions / f'{i}.title').read_bytes() for i in ids}
            marker = project / 'resume-side-effect'
            assert marker.read_text() == 'once'
            term = Terminal(app, home, project, runtime)
            try:
                term.pump(term.idle, 'fresh launcher startup composer')
                term.send(b'/resume\r')
                term.pump(lambda: all(any(title in line for line in term.lines()) for title in (FIRST_TITLE, FALLBACK_TITLE)) and term.data.endswith(FRAME_END),
                          'first resume menu contains both titles')
                lines = term.lines()
                assert next(i for i, line in enumerate(lines) if FALLBACK_TITLE in line) < next(i for i, line in enumerate(lines) if FIRST_TITLE in line)
                assert not any(session_id in line for session_id in ids for line in lines)
                mark = len(term.data)
                term.send(b'\x1b')
                term.pump(lambda: len(term.data) > mark and term.idle() and
                          not any(FIRST_TITLE in ''.join(row) for row in term.screen.grid),
                          'Escape returns to current composer')
                assert len(requests) == 3
                mark = len(term.data)
                term.send(b'/resume\r')
                term.pump(lambda: len(term.data) > mark and all(any(title in ''.join(row) for row in term.screen.grid) for title in (FIRST_TITLE, FALLBACK_TITLE)) and term.data.endswith(FRAME_END),
                          'reopened resume menu contains both titles')
                arrow_mark = len(term.data)
                selection_deadline = time.monotonic() + 15
                term.send(b'\x1b[B')
                term.pump(lambda: len(term.data) > arrow_mark and term.data.endswith(FRAME_END) and
                          term.data.rfind(SYNC_BEGIN) >= arrow_mark and
                          any(''.join(row).lstrip().startswith(f'> {FIRST_TITLE}') for row in term.screen.grid),
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
                default_resume(FIRST_TITLE, 'same-current no-op', 'Already attached')
                assert len(requests) == 4 and marker.read_text() == 'once'
                newest(ids[1])
                default_resume(FALLBACK_TITLE, 'switch to B', 'Conversation restored; prior tools are NOT rerun')
                assert len(requests) == 4 and marker.read_text() == 'once'
                term.send(b'probe-b-user\r')
                term.pump(lambda: any('probe-b-answer' in line for line in term.lines()) and term.idle(),
                          'explicit B continuation')
                assert len(requests) == 5 and marker.read_text() == 'once'
                newest(ids[0])
                default_resume(FIRST_TITLE, 'return to live A', 'Conversation restored; prior tools are NOT rerun')
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
            other = Path(tmp) / 'other-project'
            other.mkdir(mode=0o700)
            # Same HOME/index, different cwd: the two genuine foreground saves
            # above are visible in their own cwd but not from this empty one.
            with closing(Terminal(app, home, other, runtime)) as term:
                term.pump(term.idle, 'foreign foreground startup')
                mark = len(term.data)
                term.send(b'/resume\r')
                term.pump(lambda: b'No saved sessions' in term.data[mark:] and term.idle(),
                          'empty foreground cwd excludes both foreign checkpoints')
                term.send(b'\x04')
                term.pump(lambda: term.child.poll() is not None, 'empty foreground exit')
                assert term.child.wait() == 0 and len(requests) == 6
            daemon_roundtrip(app, home, project, other, runtime, ids)
            assert marker.read_text() == 'once'
            assert {i: (sessions / f'{i}.title').read_bytes() for i in ids} == titles_before
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
    assert not errors, 'resume-menu mock recorded an unexpected HTTP or handler failure'
    print('PASS resume-menu: foreground cwd-only, daemon cross-project live/cold, original A-B-A IDs, no replay, six POSTs and zero GETs each')


@contextmanager
def owned_daemon(app, home, runtime):
    env = {'PATH': '/usr/bin:/bin', 'HOME': str(home) + '/', 'XDG_RUNTIME_DIR': str(runtime),
           'LANG': 'C.UTF-8', 'TERM': 'xterm-256color', 'THIN_FIXTURE_KEY': 'fixture-key',
           'NO_PROXY': '*', 'no_proxy': '*'}
    control = runtime / 'thin/daemon.sock'
    daemon = subprocess.Popen([app, '--daemon'], cwd=home, env=env, start_new_session=True,
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            assert daemon.poll() is None, 'owned daemon exited before becoming ready'
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                probe.settimeout(.3)
                try:
                    probe.connect(str(control))
                except (FileNotFoundError, ConnectionRefusedError):
                    time.sleep(.02)
                    continue
                creds = probe.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize('3i'))
                assert struct.unpack('3i', creds)[0] == daemon.pid, 'wrong daemon at control endpoint'
                break
        else:
            raise AssertionError('owned daemon never accepted connections')
        yield daemon.pid
        assert daemon.poll() is None, 'owned daemon exited unexpectedly'
    finally:
        if daemon.poll() is None:
            workers = children_of(daemon.pid)
            daemon.terminate()
            try:
                code = daemon.wait(timeout=30)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait(timeout=3)
                raise
            assert code in (0, -signal.SIGTERM, 128 + signal.SIGTERM)
            wait_pids_gone(workers)
            assert not runtime_sockets(runtime), 'old runtime still contains sockets'


def daemon_roundtrip(app, home, project, other, runtime, foreground_ids):
    requests.clear()
    selected_ids.clear()
    continuation_sessions.clear()
    titles = ('daemon-' + FIRST_TITLE, 'daemon-' + FALLBACK_TITLE)
    marker = other / 'resume-side-effect'
    home_literal = str(home) + '/'

    def select(term, index, phase):
        # Wait for the actual popup, not titles in scrollback. A checkpoint-less
        # live worker may also have a (short-ID) row; don't assume default order.
        def lines():
            return [''.join(row).strip() for row in term.screen.grid]

        def candidate(line):
            return line.removeprefix('> ').partition(' ')[0]

        def selection():
            for line in lines():
                if line.startswith('> '):
                    label = candidate(line)
                    if label in titles or re.fullmatch(r'[0-9a-f]{8}', label):
                        return label
            return None

        mark = len(term.data)
        term.send(b'/resume\r')
        term.pump(lambda: term.data.endswith(FRAME_END) and term.data.rfind(SYNC_BEGIN) >= mark and
                  selection() is not None and
                  all(any(candidate(line) == title and line.removeprefix('> ') != title
                          for line in lines()) for title in titles),
                  f'{phase} fresh picker frame')
        rows = lines()
        forbidden = {FIRST_TITLE, FALLBACK_TITLE, *foreground_ids, *(ident[:8] for ident in foreground_ids)}
        assert not any(candidate(line) in forbidden for line in rows), f'{phase}: foreground session listed'
        for title, cwd in zip(titles, projects):
            row, = [line for line in rows if candidate(line) == title and line.removeprefix('> ') != title]
            # The time column may clip; require an unambiguous project on this very row.
            assert re.search(r'(?<![\w.-])' + re.escape(cwd.name) + r'(?![\w.-])', row), (phase, row)
        seen = set()
        while selection() != titles[index]:
            previous = selection()
            assert previous and previous not in seen, f'{phase}: could not select {titles[index]}'
            seen.add(previous)
            mark = len(term.data)
            term.send(b'\x1b[B')
            term.pump(lambda: term.data.endswith(FRAME_END) and term.data.rfind(SYNC_BEGIN) >= mark and
                      selection() not in (None, previous), f'{phase} Down selection')
        mark = len(term.data)
        term.send(b'\r')
        term.pump(lambda: b'Conversation restored; prior tools are NOT rerun' in term.data[mark:] and
                  term.idle(), f'{phase} restored')

    # Keep the genuine foreground checkpoints in the same HOME/index. B even
    # shares their project, so filtering on the project alone cannot pass.
    with owned_daemon(app, home, runtime) as first_pid:
        projects = (other, project)
        ids = [seed(app, home, cwd, runtime, title, answer, 'daemon') for cwd, title, answer in
               zip(projects, titles, ('seed-one-answer', 'seed-two-answer'))]
        assert len(set(ids + foreground_ids)) == 4
        checkpoints = [cwd / '.thin/sessions' / f'{ident}.session' for cwd, ident in zip(projects, ids)]
        selected_ids[:] = [ids[0], ids[1], ids[0]]
        with closing(Terminal(app, home, project, runtime, home_literal=home_literal)) as term:
            term.pump(term.idle, 'warm daemon launcher ready')
            select(term, 0, 'warm cross-project A')
            term.pump(lambda: any('seed-one-answer' in line for line in term.lines()) and term.idle(),
                      'warm cross-project history')
            term.send(b'\x04')
            term.pump(lambda: term.child.poll() is not None, 'warm launcher exit')
            assert term.child.wait() == 0
        records = [next((home / '.thin/session-index').glob(f'*/{ident}.json')) for ident in ids]
        owners = {json.loads(path.read_bytes())['pid'] for path in records}
        assert len(owners) == 2 and owners <= children_of(first_pid), 'old owners not live before restart'
        assert len(requests) == 3 and marker.read_text() == 'once'

    wait_pids_gone(owners | {first_pid})
    # Reboot-style restart: keep HOME, index and projects, not the runtime root.
    cold_runtime = runtime.with_name('r-cold')
    cold_runtime.mkdir(mode=0o700)
    with owned_daemon(app, home, cold_runtime) as second_pid:
        assert second_pid != first_pid
        with closing(Terminal(app, home, project, cold_runtime, home_literal=home_literal)) as term:
            term.pump(term.idle, 'cold daemon launcher ready')
            select(term, 0, 'cold cross-project A')
            # Neither retired shortcut may switch away from A or submit a turn.
            # The next POST independently checks A's original session ID and history.
            for command, notice in ((f'/resume {ids[1]}', b'Usage: /resume'),
                                    ('/new unsolicited-turn', b'Usage: /new')):
                mark = len(term.data)
                term.send((command + '\r').encode())
                term.pump(lambda: notice in term.data[mark:] and term.idle(), f'{notice.decode()} rejection')
            assert len(requests) == 3 and marker.read_text() == 'once'
            term.send(b'continuation-user\r')
            term.pump(lambda: any('continuation-answer' in line for line in term.lines()) and term.idle(), 'trailing-HOME A continuation')
            select(term, 1, 'cold B')
            assert len(requests) == 4 and marker.read_text() == 'once'
            term.send(b'probe-b-user\r')
            term.pump(lambda: any('probe-b-answer' in line for line in term.lines()) and term.idle(), 'trailing-HOME B continuation')
            select(term, 0, 'live return to cross-project A')
            assert len(requests) == 5 and marker.read_text() == 'once'
            term.send(b'return-a-user\r')
            term.pump(lambda: any('return-a-answer' in line for line in term.lines()) and term.idle(), 'trailing-HOME return A continuation')
            assert len(requests) == 6 and continuation_sessions == selected_ids
            assert marker.read_text() == 'once'
            for cwd, path in zip(projects, checkpoints):
                assert_live_project(home, cwd, path.stem, 'daemon')
            mark = len(term.data)
            term.send(b'/new\r')
            term.pump(lambda: b'New session; previous session keeps running' in term.data[mark:] and term.idle(),
                      'empty new session ready')
            term.send(b'\x04')
            term.pump(lambda: term.child.poll() is not None, 'trailing-HOME connect exit')
            assert len(requests) == 6, '/new must not send an implicit prompt'
            assert term.child.wait() == 0
    assert len(requests) == 6 and marker.read_text() == 'once'
    for path, title, answer in zip(checkpoints, titles, ('return-a-answer', 'probe-b-answer')):
        assert read_title(path.parent, path.stem) == title
        assert answer.encode() in path.read_bytes(), 'continuation not saved to original checkpoint'
    assert not list((home / '.thin/sessions').glob('*.session')), 'HOME was used as a project'
    assert {p.stem for p in checkpoints[0].parent.glob('*.session')} == {ids[0]}
    assert {p.stem for p in checkpoints[1].parent.glob('*.session')} == {*foreground_ids, ids[1]}


if __name__ == '__main__':
    main(os.path.abspath(sys.argv[1]))
