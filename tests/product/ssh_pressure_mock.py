#!/usr/bin/env python3
"""Connection-admission pressure must not stop a daemon-owned task.
Runs ONLY an owned daemon with a lowered fd limit, private keys and loopback mock.
The process executor must distinguish a clean launch failure from lost ownership.
"""
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time

from daemon_mock import (Case, Child, wait_daemon_socket, wait_checkpoint, text_answer,
                         stop_daemon, assert_screen_idle_contract)
from ssh_mock import SshChild, run, settled


def check(app):
    assert_screen_idle_contract()
    root = Path(tempfile.mkdtemp(prefix='thin-ssh-pressure-'))
    root.chmod(0o700)
    case = Case(app, root, 'd')
    ws = case.workspace
    env = ws.env()
    gate = threading.Event()
    case.state['gate'] = gate
    sockets = []
    peak_fds = 0
    banners = 0
    attempted = 0
    answer = 'ssh-pressure-owned-task-completed'
    prompt = 'ssh-pressure-owned-task'

    def plan(model, _, body):
        assert model.count() == 1, 'unexpected extra inference'
        assert gate.wait(45), 'pressure fixture gate timed out'
        return text_answer(answer)

    try:
        case.start_model(plan)
        keydir = ws.home / '.thin'
        keydir.chmod(0o700)
        key = root / 'login-key'
        assert run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],env).returncode == 0
        auth = keydir / 'authorized_keys'
        auth.write_bytes(Path(str(key)+'.pub').read_bytes()); auth.chmod(0o600)
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1',0)); port=reservation.getsockname()[1]
        address='127.0.0.1:%d' % port
        # The wrapper execs in place: the owned Popen PID remains the daemon PID.
        wrapper=('import os,resource,sys; '
                 'resource.setrlimit(resource.RLIMIT_NOFILE,(64,64)); '
                 'os.execv(sys.argv[1],[sys.argv[1],"--daemon","--ssh-listen",sys.argv[2],"--no-model-auto-refresh"])')
        case.daemon=Child('/usr/bin/python3',['-c',wrapper,app,address],ws.home,env,'daemon-limited',ws.logs,False)
        case.children.append(case.daemon)
        wait_daemon_socket(case)
        host=keydir/'ssh_host_ed25519_key'
        public=run(['ssh-keygen','-y','-P','','-f',str(host)],env)
        assert public.returncode==0
        known=root/'known_hosts';known.write_bytes(('[127.0.0.1]:%d ' % port).encode()+public.stdout);known.chmod(0o600)
        argv=['-F','/dev/null','-o','IdentityAgent=none','-o','IdentitiesOnly=yes',
              '-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',
              '-o','UserKnownHostsFile='+str(known),'-o','GlobalKnownHostsFile=/dev/null',
              '-o','ConnectTimeout=5','-o','LogLevel=ERROR','-tt','-i',str(key),'-p',str(port),'thin@127.0.0.1']
        client=SshChild('/usr/bin/ssh',argv,ws.home,env,'task-client',ws.logs,True,100,30)
        case.children.append(client)
        client.pump_until(lambda:settled(client),'SSH ready',20)
        mark=client.mark();client.send_line('/cd '+str(ws.project_a))
        client.pump_until(lambda:settled(client, mark, b'Launcher directory:'),'select project',20)
        client.send_line(prompt)
        case.wait_prompt(prompt)
        assert case.model.count()==1

        # Keep started handshakes open. With 64 daemon fds, its per-child pipes
        # exhaust descriptors before the independent 32-pending policy limit.
        # No socket targets anything except this one owned ephemeral port.
        deadline=time.monotonic()+6
        for _ in range(48):
            if time.monotonic()>=deadline: break
            attempted+=1
            try:
                s=socket.create_connection(('127.0.0.1',port),.15)
                sockets.append(s);s.settimeout(.1)
                try:
                    if s.recv(256).startswith(b'SSH-2.0-'): banners+=1
                except (TimeoutError,ConnectionError): pass
            except (TimeoutError,ConnectionError): pass
            client.pump(.005)
            try: peak_fds=max(peak_fds,len(list(Path('/proc/%d/fd' % case.daemon.proc.pid).iterdir())))
            except OSError: pass
            if case.daemon.proc.poll() is not None: break
        assert case.daemon.proc.poll() is None, 'connection admission failure stopped daemon and its task'
        assert peak_fds>=58 and attempted>=20 and banners>=4, 'fixture did not reach fd pressure'
        for s in sockets: s.close()
        sockets.clear()
        gate.set()
        checkpoint=wait_checkpoint(ws.project_a,answer,timeout=35)
        assert checkpoint.is_file() and case.model.count()==1
        # Resource refusal must recover, not merely keep a broken listener alive.
        recovered=SshChild('/usr/bin/ssh',argv,ws.home,env,'recovered-client',ws.logs,True,100,30)
        case.children.append(recovered)
        recovered.pump_until(lambda:settled(recovered),'SSH admission recovered',20,case.model.check)
        recovered.send_line('/exit')
        assert recovered.wait_exit('recovered connection exit',20)==0
        assert case.model.count()==1
        case.model.check()
        stop_daemon(case)
        print('PASS ssh admission-resource-isolation: attempts=%d banners=%d peak_fds=%d requests=1 recovered=1' % (attempted,banners,peak_fds),flush=True)
    finally:
        for s in sockets: s.close()
        case.close()
        print('SSH_PRESSURE_ARTIFACTS '+str(root),flush=True)


if __name__=='__main__':
    check(str(Path(sys.argv[1]).resolve()))
