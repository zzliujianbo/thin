#!/usr/bin/env python3
"""Real product D entry, one daemon-owned loopback listener, no launcher shim.
Temporary HOME, keys and mock inference only. Never changes system SSH/services.
Uses the existing owned terminal/model/cleanup fixture; no product protocol mocks.
"""
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import fcntl
import struct
import termios

from daemon_mock import (Case, Child, Screen, FRAME_END, SYNC_BEGIN, wait_daemon_socket,
                         wait_checkpoint, children_of, stop_daemon, text_answer,
                         assert_screen_idle_contract)

PROMPT = 'ssh-owned-detach-prompt'
ANSWER = 'ssh-owned-completed-answer'


def run(args, env, timeout=15):
    return subprocess.run(args, env=env, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)


def wait(predicate, label, progress=None, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if progress:
            progress()
        if predicate():
            return
        time.sleep(.02)
    raise AssertionError(label)


class SshChild(Child):
    def frame_after(self, offset, marker=b''):
        tail = bytes(self.capture[offset:])
        end = tail.rfind(FRAME_END)
        return end >= 0 and tail.rfind(SYNC_BEGIN) <= end and (not marker or marker in tail[:end])


def settled(c, offset=0, marker=b''):
    """Complete frame after offset that ends on an idle owned composer.

    Readiness is the product's own idle input row (`Screen.idle` reads the
    cursor row, wherever §3.3 floats the composer), never version/banner text
    and never an assumption that the composer owns the physical bottom row.
    """
    return c.frame_after(offset, marker) and c.screen.idle()


def main():
    app = str(Path(sys.argv[1]).resolve())
    assert_screen_idle_contract()
    root = Path(tempfile.mkdtemp(prefix='thin-ssh-'))
    root.chmod(0o700)
    case = Case(app, root, 'd')
    ws = case.workspace
    env = ws.env()
    raw = []
    results = []
    state = {'gate': threading.Event(), 'arrived': threading.Event()}
    case.state.update(state)

    def plan(model, _, body):
        assert model.count() == 1, 'unexpected model replay/call'
        state['arrived'].set()
        assert state['gate'].wait(45), 'fixture task gate deadline'
        return text_answer(ANSWER)

    def passed(name):
        results.append(name)
        print('PASS ssh ' + name, flush=True)

    try:
        case.start_model(plan)
        keydir = ws.home / '.thin'
        keydir.chmod(0o700)
        keys = {}
        for name in ('a', 'b', 'c'):
            path = root / ('key-' + name)
            result = run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(path)], env)
            assert result.returncode == 0, 'fixture key generation failed'
            keys[name] = path

        def authorize(names):
            path = keydir / 'authorized_keys'
            replacement = keydir / 'keys.new'
            replacement.write_text('# owned SSH fixture\n\n' + ''.join(Path(str(keys[n])+'.pub').read_text() for n in names))
            replacement.chmod(0o600)
            replacement.replace(path)

        authorize(['a', 'b'])
        with socket.socket() as reserve:
            reserve.bind(('127.0.0.1', 0))
            port = reserve.getsockname()[1]
        address = '127.0.0.1:%d' % port

        def start(label):
            case.daemon = case.spawn(['--daemon', '--ssh-listen', address, '--no-model-auto-refresh'], ws.home, label, False)
            wait_daemon_socket(case)
            wait(lambda: (keydir / 'ssh_host_ed25519_key').is_file(), 'host identity not published')
            assert case.daemon.proc.poll() is None

        start('daemon')
        host = keydir / 'ssh_host_ed25519_key'
        assert host.stat().st_mode & 0o777 == 0o600
        host_hash = hashlib.sha256(host.read_bytes()).hexdigest()
        public = run(['ssh-keygen', '-y', '-P', '', '-f', str(host)], env)
        assert public.returncode == 0
        known = root / 'known_hosts'
        known.write_bytes(('[127.0.0.1]:%d ' % port).encode() + public.stdout)
        known.chmod(0o600)

        def args(key='a', tty=True, extra=()):
            identity = keys[key] if key in keys else Path(key)
            return ['-F', '/dev/null', '-o', 'IdentityAgent=none', '-o', 'IdentitiesOnly=yes',
                    '-o', 'BatchMode=yes', '-o', 'PreferredAuthentications=publickey',
                    '-o', 'UserKnownHostsFile='+str(known), '-o', 'GlobalKnownHostsFile=/dev/null',
                    '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=5',
                    '-o', 'ConnectionAttempts=1', '-o', 'LogLevel=ERROR',
                    '-tt' if tty else '-T', '-i', str(identity), '-p', str(port)] + list(extra) + ['thin@127.0.0.1']

        def client(key, name):
            c = SshChild('/usr/bin/ssh', args(key), ws.home, env, name, ws.logs, True, 80, 24)
            case.children.append(c)
            c.pump_until(lambda: settled(c), 'real SSH TUI', 20, case.model.check)
            # There is no startup banner to carry the launcher directory. The
            # initial launcher is proven by resolving '.' against it: a relative
            # path can only land on the owned HOME if that is the launcher.
            mark = c.mark()
            c.send_line('/cd .')
            c.pump_until(lambda: settled(c, mark, b'Launcher directory:'), 'initial launcher directory', 20, case.model.check)
            resolved = str(ws.home.resolve())
            headers = [''.join(row).strip() for row in c.screen.grid if 'Launcher directory:' in ''.join(row)]
            assert headers and (resolved in headers[-1] or str(ws.home) in headers[-1]), \
                'initial header must agree with HOME launcher'
            return c

        def normal_exit(c):
            c.send(b'\x04')
            c.pump_until(lambda: c.proc.poll() is not None, 'normal SSH exit', 15)
            assert c.proc.returncode == 0, 'normal SSH exit must be zero (label=%s returncode=%r)' % (c.label, c.proc.returncode)

        # A stalled handshake and a healthy login coexist on the SAME listener.
        slow = socket.create_connection(('127.0.0.1', port), 2)
        raw.append(slow)
        slow.settimeout(2)
        assert slow.recv(1024).startswith(b'SSH-2.0-')
        started = time.monotonic()
        a = client('a', 'key-a')
        b = client('b', 'key-b')
        assert time.monotonic()-started < 10, 'healthy connections blocked by stalled handshake'
        denied = run(['/usr/bin/ssh'] + args('c'), env)
        assert denied.returncode != 0 and b'Permission denied' in denied.stderr
        only_public = root / 'public-only'
        only_public.write_bytes(Path(str(keys['a'])+'.pub').read_bytes())
        unsigned = run(['/usr/bin/ssh'] + args(str(only_public)), env)
        # A public-key file cannot sign. Require real denial evidence and prove
        # that no product session/TUI started: no owned frame, cursor ACK,
        # composer or model decoration may appear on stdout.
        assert unsigned.returncode != 0 and b'Permission denied' in unsigned.stderr
        assert SYNC_BEGIN not in unsigned.stdout and b'\x1b[?25h' not in unsigned.stdout
        assert b'%> ' not in unsigned.stdout and b'(fixture-model)' not in unsigned.stdout
        passed('multi-key-and-signature-required')
        slow.settimeout(13)
        while slow.recv(1024):
            assert time.monotonic()-started < 13, 'handshake lifetime is unbounded'
        slow.close();raw.remove(slow)
        passed('single-listener-slow-handshake-isolation')

        # No server-side PTY. Only our CLIENTS have PTYs.
        def connection_pids():
            found = []
            for pid in children_of(case.daemon.proc.pid):
                try:
                    cmd = Path('/proc/%d/cmdline' % pid).read_bytes().split(b'\0')
                except OSError:
                    continue
                if b'--internal-ssh' in cmd:
                    found.append(pid)
            return found
        assert len(connection_pids()) >= 2
        for pid in connection_pids():
            for fd in Path('/proc/%d/fd' % pid).iterdir():
                try:
                    target = os.readlink(fd)
                except OSError:
                    continue
                assert not target.startswith('/dev/pts/') and target != '/dev/ptmx', 'server allocated PTY'
        passed('ssh-and-tui-same-process-no-server-pty')

        authorize(['b', 'c'])
        revoked = run(['/usr/bin/ssh']+args('a'), env)
        assert revoked.returncode != 0 and b'Permission denied' in revoked.stderr
        mark = a.mark(); a.send_line('/help')
        a.pump_until(lambda: settled(a, mark), 'existing connection survives revocation', 20)
        c = client('c', 'new-key-c')
        normal_exit(c)
        # Invalid current authorization affects new auth, not established views.
        auth = keydir / 'authorized_keys'
        auth.chmod(0o644)
        rejected = run(['/usr/bin/ssh']+args('b'), env)
        assert rejected.returncode != 0 and b'Permission denied' in rejected.stderr
        auth.chmod(0o600)
        passed('rotation-and-unsafe-auth-file-fail-closed')

        for suffix in (['echo', 'SHOULD-NOT-EXECUTE'], ['-s', 'sftp'], []):
            denied = run(['/usr/bin/ssh']+args('b', False)+suffix, env)
            assert denied.returncode != 0 and b'SHOULD-NOT-EXECUTE' not in denied.stdout
        denied = run(['/usr/bin/ssh']+args('b', False, ['-N','-o','ExitOnForwardFailure=yes','-R','0:127.0.0.1:1']), env)
        assert denied.returncode != 0
        passed('reject-exec-sftp-no-pty-forwarding')

        # Real draft + exact width delta, bounded by prompt prefix and margin.
        def draft(c, char):
            rows = [''.join(row) for row in c.screen.grid]
            # Only the current composer owns this draft. Body/status text can
            # contain ordinary x/y letters (e.g. 'context'), which are not input.
            starts = [i for i, row in enumerate(rows) if '(fixture-model)' in row and '> ' in row]
            if not starts:
                return 0, 0
            start = starts[-1]
            rows = [rows[start].split('> ', 1)[1]] + rows[start+1:]
            import re
            runs = [len(x) for row in rows for x in re.findall(char+'+', row)]
            return sum(runs), max(runs, default=0)
        m=b.mark();b.send(b'y'*95)
        b.pump_until(lambda: b.frame_after(m) and draft(b,'y')[0]==95, '80-column draft', 20)
        narrow=draft(b,'y')[1]
        m=b.mark();b.send(b'\x15')
        b.pump_until(lambda: b.frame_after(m) and draft(b,'y')[0]==0, 'clear draft', 20)
        m=b.mark()
        b.screen=Screen(100,35)
        fcntl.ioctl(b.master,termios.TIOCSWINSZ,struct.pack('HHHH',35,100,0,0))
        # Resize is passive: Thin takes the new size, drops old-frame authority and
        # may only release interrupted controls, so there is no automatic frame to
        # wait for. A bounded owned pump must therefore see no complete frame.
        b.pump(.25)
        assert not b.frame_after(m), 'resize-only output drew a frame'
        # The replacement Screen(100,35) replays only the bytes after this point at
        # the new width; neither the fixture nor the product reflows the rows above.
        # The real edit below is what draws the 100-column editor.
        m=b.mark();b.send(b'x'*95)
        b.pump_until(lambda:b.frame_after(m) and draft(b,'x')[0]==95, '100-column draft', 20)
        assert draft(b,'x')[1]==narrow+20
        m=b.mark();b.send(b'\x15')
        b.pump_until(lambda:b.frame_after(m) and draft(b,'x')[0]==0, 'clear resized draft', 20)
        normal_exit(b)
        normal_exit(a)
        passed('resize-and-clean-exit')

        # Kill one owned connection child via pidfd (not a reusable cached PID).
        wait(lambda: not connection_pids(), 'normal connection children not reaped')
        crash = client('b','crash-child')
        owned = connection_pids();assert len(owned)==1
        pidfd=os.pidfd_open(owned[0])
        try: signal.pidfd_send_signal(pidfd,signal.SIGKILL)
        finally: os.close(pidfd)
        crash.pump_until(lambda:crash.proc.poll() is not None, 'crashed SSH child', 15)
        wait(lambda:not connection_pids(), 'crashed child not reaped')
        assert case.daemon.proc.poll() is None
        passed('connection-crash-isolation-and-reap')

        live=client('b','detached-task')
        m=live.mark();live.send_line('/cd '+str(ws.project_a))
        live.pump_until(lambda:settled(live, m, b'Launcher directory:'), 'select project completed',20)
        live.send_line(PROMPT)
        case.wait_prompt(PROMPT)
        live.kill();live.wait();live.close()
        wait(lambda:not connection_pids(), 'disconnected task view not reaped')
        assert not state['gate'].is_set() and case.model.count()==1
        state['gate'].set()
        checkpoint=wait_checkpoint(ws.project_a,ANSWER)
        again=client('b','reattach-task')
        m=again.mark();again.send_line('/cd '+str(ws.project_a))
        again.pump_until(lambda:settled(again, m, b'Launcher directory:'),'reattach project completed',20)
        m=again.mark();again.send_line('/attach '+checkpoint.stem)
        again.pump_until(lambda:settled(again, m, ANSWER.encode()),'canonical answer after detach',30,case.model.check)
        assert case.model.count()==1
        passed('task-detach-checkpoint-reattach-without-replay')

        # Shutdown while views exist; all are owned by the real daemon executor.
        stop_daemon(case)
        again.pump_until(lambda:again.proc.poll() is not None,'daemon shutdown closes SSH',15)
        passed('daemon-shutdown-reclaims-connections-and-workers')
        start('daemon-restart')
        assert hashlib.sha256(host.read_bytes()).hexdigest()==host_hash
        restart=client('b','host-identity-reused');normal_exit(restart)
        stop_daemon(case)
        passed('persistent-host-identity')

        # Bad host key must fail startup and must never be replaced.
        host.write_bytes(b'broken-host-identity\n')
        bad=run([app,'--daemon','--ssh-listen',address,'--no-model-auto-refresh'],env)
        assert bad.returncode != 0 and host.read_bytes()==b'broken-host-identity\n'
        host.unlink();host.symlink_to(keys['a'])
        bad=run([app,'--daemon','--ssh-listen',address,'--no-model-auto-refresh'],env)
        assert bad.returncode != 0 and host.is_symlink()
        host.unlink()
        auth.unlink();os.mkfifo(auth,0o600)
        bad=run([app,'--daemon','--ssh-listen',address,'--no-model-auto-refresh'],env,5)
        assert bad.returncode != 0
        passed('host-corruption-symlink-and-fifo-refusal')
        case.model.check()
    finally:
        for sock in raw:
            sock.close()
        case.close()
        print('SSH_ARTIFACTS '+str(root),flush=True)
    (root/'result.json').write_text(json.dumps({'status':'pass','cases':results,'model_requests':case.model.count()},indent=2)+'\n')
    (root/'result.json').chmod(0o600)
    # A separate owned daemon with an fd budget reaches real launch/admission
    # failures while a model request is already running; no product stubs.
    from ssh_pressure_mock import check as check_pressure
    check_pressure(app)
    print('PASS SSH integrated D: %d cases' % (len(results)+1),flush=True)


if __name__ == '__main__':
    main()
