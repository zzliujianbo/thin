#!/usr/bin/env python3
"""Public SSH boundary on Linux. There is no product switch to enable TCP.

OpenSSH login, key management and remote PTYs belong to the separate sshd;
this checks only Thin's CLI and daemon.
"""
from pathlib import Path
import sys
import tempfile

from daemon_mock import Case, assert_no_tcp_listener, run_conflict


def main():
    app = str(Path(sys.argv[1]).resolve(strict=True))
    with tempfile.TemporaryDirectory(prefix='thin-no-ssh-', dir='/tmp') as root:
        case = Case(app, root, 'd')
        ws = case.workspace
        try:
            # Supply a valid-looking listener value (not a missing-operand test).
            run_conflict(app, ws, ['--daemon', '--ssh-listen', '127.0.0.1:2222'], 'SSH listener')
            run_conflict(app, ws, ['--internal-ssh', '1234'], 'retired SSH child')
            assert not list(ws.home.iterdir()) and not list(ws.runtime.iterdir()), 'rejected argv created state'
            daemon = case.start_daemon()
            # start_daemon first waits for a real AF_UNIX connection, then
            # inspect only this owned process tree, not a guessed port.
            assert_no_tcp_listener(daemon.proc.pid)
            assert daemon.proc.poll() is None, 'daemon exited during listener check'
            assert not (ws.home / '.thin/ssh_host_ed25519_key').exists(), 'unexpected SSH host identity'
        finally:
            case.close()
    print('PASS SSH boundary: listener and child options rejected; live AF_UNIX daemon has no TCP listener')


if __name__ == '__main__':
    main()
