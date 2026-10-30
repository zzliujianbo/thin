#!/usr/bin/env python3
"""Owned private-wire subscription acceptance (no UI or real API claims).

Unlike daemon_mock's CLI tests, this fixture intentionally tests the private
framing contract: same-process binding, ordered watermarks, push without polls,
slow-reader isolation, takeover and stream-only rejection of mutations.
"""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

from daemon_mock import Case, ModelFixture, session_files, text_answer, wait_sessions, write_config


class Wire:
    def __init__(self, endpoint, slow=False):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(3)
        if slow:
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        self.sock.connect(str(endpoint))
        self.next_id = 0

    def close(self):
        self.sock.close()

    def send(self, op, **fields):
        self.next_id += 1
        raw = json.dumps(dict(v=2, id=self.next_id, op=op, **fields)).encode()
        self.sock.sendall(struct.pack('!I', len(raw)) + raw)
        return self.next_id

    def exact(self, count):
        result = bytearray()
        while len(result) < count:
            chunk = self.sock.recv(count - len(result))
            if not chunk:
                raise EOFError('owned stream closed')
            result.extend(chunk)
        return bytes(result)

    def read(self):
        count, = struct.unpack('!I', self.exact(4))
        assert count <= 1024 * 1024
        return json.loads(self.exact(count))

    def call(self, op, **fields):
        ident = self.send(op, **fields)
        result = self.read()
        assert result['id'] == ident and result['ok'], (op, result)
        return result

    def baseline(self, epoch):
        ident = self.send('watch', epoch=epoch)
        snapshot, baseline = self.read(), self.read()
        assert snapshot['id'] == baseline['id'] == ident
        assert snapshot['stream'] == 'snapshot' and baseline['stream'] == 'baseline'
        assert snapshot['epoch'] == baseline['epoch'] == epoch
        # A fresh viewer's snapshot is CURRENT state: it may be ahead of the
        # ordered baseline cutoff while retained live entries still follow.
        assert snapshot['through'] >= baseline['through'] == baseline['base']
        return baseline['through']

    def eof(self):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                self.read()  # Frames already written before revocation are legal.
            except (EOFError, ConnectionResetError):
                return
        raise AssertionError('revoked stream did not close')


def run(app):
    base = Path(tempfile.mkdtemp(prefix='thin-subscribe.', dir='/tmp'))
    base.chmod(0o700)
    case = Case(app, base, 'wire')
    release, flood, sent = threading.Event(), threading.Event(), threading.Event()
    case.state.update(release=release, flood=flood, sent=sent)
    wires = []
    pieces = ['P%03d ' % i for i in range(40)]

    class Fixture(ModelFixture):
        def emit(self, handler, value):
            handler.send_response(200)
            handler.send_header('Content-Type', 'text/event-stream')
            handler.send_header('Connection', 'close')
            handler.close_connection = True
            handler.end_headers()

            def delta(text):
                data = {'choices': [{'index': 0, 'delta': {'content': text}, 'finish_reason': None}]}
                handler.wfile.write(b'data: ' + json.dumps(data).encode() + b'\n\n')
                handler.wfile.flush()

            for piece in pieces:
                delta(piece)
                if release.wait(0.004):
                    return
            assert flood.wait(15), 'test did not open slow subscriber'
            for i in range(160):
                delta(('F%03d ' % i) + 'x' * 8187)
            sent.set()
            assert release.wait(20), 'test did not release completion'
            final = {'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]}
            handler.wfile.write(b'data: ' + json.dumps(final).encode() + b'\n\ndata: [DONE]\n\n')
            handler.wfile.flush()

    def connect(endpoint, slow=False):
        wire = Wire(endpoint, slow)
        wires.append(wire)
        return wire

    try:
        case.model = Fixture(lambda body: text_answer('unused'))
        write_config(case.workspace.home, case.model.start())
        case.start_daemon()
        candidates = list(case.workspace.runtime.rglob('daemon.sock'))
        assert len(candidates) == 1
        supervisor = connect(candidates[0])
        # Legacy create switches are rejected before allocating a worker or
        # touching project history; wire maps BadRequest to protocol.
        before = supervisor.call('list', running_only=False)['sessions']
        sockets_before = sorted(str(path) for path in case.workspace.runtime.rglob('*.sock'))
        request_id = supervisor.send('create', project=str(case.workspace.project_a),
                                     auto_refresh_models=False, logging=False)
        rejected = supervisor.read()
        assert rejected['id'] == request_id and not rejected['ok'] and rejected['err'] == 'protocol', rejected
        assert supervisor.call('list', running_only=False)['sessions'] == before, 'rejected create changed owners'
        assert sorted(str(path) for path in case.workspace.runtime.rglob('*.sock')) == sockets_before, 'rejected create started a worker'
        assert not session_files(case.workspace.project_a), 'rejected create wrote history'
        assert not (case.workspace.project_a / '.thin').exists(), 'rejected create touched project state'
        assert case.model.count() == 0, 'rejected create reached model'
        created = supervisor.call('create', project=str(case.workspace.project_a), auto_refresh_models=False)
        endpoint = created['endpoint']
        assert Path(endpoint).is_relative_to(case.workspace.runtime)
        control = connect(endpoint)
        epoch = control.call('attach')['epoch']
        assert control.call('hello')['watch'] is True
        # Same UID is not enough to borrow a different process's controller.
        script = '''import socket,struct,json,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.settimeout(3);s.connect(sys.argv[1])
b=json.dumps(dict(v=2,id=1,op="watch",epoch=int(sys.argv[2]))).encode()
s.sendall(struct.pack("!I",len(b))+b)
try:
 assert s.recv(1)==b"", "foreign-PID subscription accepted"
except ConnectionResetError:
 pass
s.close()
'''
        checked = subprocess.run([sys.executable, '-c', script, endpoint, str(epoch)],
                                 env=case.workspace.env(), capture_output=True, timeout=5)
        assert checked.returncode == 0, checked.stderr.decode()[-1000:]
        stream = connect(endpoint)
        cursor = stream.baseline(epoch)
        accepted = control.call('submit', epoch=epoch, req=91, kind='prompt', text='owned push subscription')
        assert accepted['accepted']
        text, updates = '', 0
        while not text.endswith(pieces[-1]):
            frame = stream.read()
            assert frame['epoch'] == epoch
            if frame['stream'] == 'snapshot':
                assert frame['through'] == cursor
                continue
            assert frame['stream'] == 'events' and frame['from'] == cursor
            assert frame['through'] > cursor
            cursor = frame['through']
            for event in frame['events']:
                assert event['t'] != 'finished', 'completion gate bypassed'
                if event['t'] == 'text':
                    text += event['v']
                    updates += 1
        assert text == ''.join(pieces) and updates >= 8
        assert case.model.count() == 1 and not release.is_set()
        # Sending a mutation on this stream must close ONLY the stream.
        stream.send('cancel', epoch=epoch)
        stream.eof()
        assert control.call('snapshot')['snapshot']['busy']
        slow = connect(endpoint, slow=True)
        slow.send('watch', epoch=epoch)  # Deliberately never read it.
        flood.set()
        assert sent.wait(15), 'owned model failed to produce flood'
        latencies = []
        for _ in range(12):
            start = time.monotonic()
            control.call('ping')
            latencies.append(time.monotonic() - start)
            time.sleep(0.01)
        assert max(latencies) < 1, latencies
        assert control.call('snapshot')['snapshot']['busy'], 'slow stream canceled the task'
        # Same-process new control gets a NEW epoch; old stream becomes stale.
        replacement = connect(endpoint)
        new_epoch = replacement.call('attach', takeover=True)['epoch']
        assert new_epoch != epoch
        slow.eof()
        control.send('cancel', epoch=epoch)
        rejected = control.read()
        assert not rejected['ok'] and rejected['err'] == 'stale_control'
        fresh = connect(endpoint)
        cursor = fresh.baseline(new_epoch)
        release.set()
        terminal = False
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            frame = fresh.read()
            assert frame['epoch'] == new_epoch
            if frame['stream'] == 'events':
                assert frame['from'] == cursor and frame['through'] > cursor
                cursor = frame['through']
                terminal |= any(e['t'] == 'finished' for e in frame['events'])
            elif frame['stream'] == 'snapshot':
                # Never behind the admitted cursor; ahead is the current state.
                assert frame['through'] >= cursor
                if frame['through'] == cursor and not frame['snapshot']['busy']:
                    assert terminal, 'idle snapshot overtook terminal'
                    break
            else:
                assert frame['stream'] == 'baseline' and frame['through'] == cursor
        else:
            raise AssertionError('no terminal then idle snapshot')
        case.model.check()
        assert case.model.count() == 1
        assert wait_sessions(case.workspace.project_a), 'accepted session missing checkpoint'
        assert list((case.workspace.project_a / '.thin' / 'sessions').glob('*.jsonl')), 'accepted session missing journal'
        print('PASS subscription wire: ' + json.dumps(dict(updates=updates, requests=1,
              max_control_seconds=round(max(latencies), 4), same_pid=True,
              stream_mutation_rejected=True, takeover=True, terminal_before_idle=True)), flush=True)
    except BaseException:
        case.report_failure()
        raise
    finally:
        release.set()
        flood.set()
        for wire in reversed(wires):
            wire.close()
        case.close()
    print('EVIDENCE=' + str(base), flush=True)


if __name__ == '__main__':
    run(str(Path(sys.argv[1]).resolve()))
