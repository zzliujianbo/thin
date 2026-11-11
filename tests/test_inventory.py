"""Offline protocol tests for the Zig test inventory client; no Zig binary is run."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

TOOL = Path(__file__).resolve().parent / 'tools' / 'list_tests.py'

# An owned protocol peer, not a test runner. Records every received command.
STUB = r'''#!/usr/bin/env python3
import os, struct, sys, time
from pathlib import Path
p = Path(os.environ['STUB_DIR'])
(p / 'pid').write_text(str(os.getpid()))
commands = sys.stdin.buffer.read(16)
(p / 'commands').write_bytes(commands)
mode = os.environ['STUB_MODE']
sys.stderr.write('PRIVATE_STUB_DIAGNOSTIC\n')
sys.stderr.flush()
def msg(tag, body):
    sys.stdout.buffer.write(struct.pack('<II', tag, len(body)) + body)
    sys.stdout.buffer.flush()
msg(0, b'0.17.0')
if mode == 'hang':
    time.sleep(30)
elif mode == 'flood':
    sys.stdout.buffer.write(b'x' * 4096)
    sys.stdout.buffer.flush()
elif mode == 'oversize':
    sys.stdout.buffer.write(struct.pack('<II', 3, 64 * 1024 * 1024 + 1))
    sys.stdout.buffer.flush()
elif mode == 'truncated':
    sys.stdout.buffer.write(struct.pack('<II', 3, 12) + b'abc')
    sys.stdout.buffer.flush()
elif mode == 'bad_offset':
    msg(3, struct.pack('<IIII', 4, 1, 99, 0) + b'\0hi\0')
elif mode == 'bad_sizes':
    msg(3, struct.pack('<II', 4, 999999999))
else:
    table = b'\0alpha\0beta\0'
    body = struct.pack('<II', len(table), 3)
    body += struct.pack('<III', 1, 7, 1) + struct.pack('<III', 0, 0, 0) + table
    msg(3, body)
'''


class InventoryProtocolTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.stub = self.directory / 'peer'
        self.stub.write_text(STUB, encoding='utf-8')
        self.stub.chmod(0o700)
        self.output = self.directory / 'inventory.json'

    def invoke(self, mode, timeout='2'):
        env = os.environ.copy()
        env.update(STUB_DIR=str(self.directory), STUB_MODE=mode)
        return subprocess.run(
            [sys.executable, str(TOOL), str(self.stub), '--timeout', timeout,
             '--output', str(self.output)],
            capture_output=True, text=True, env=env, timeout=8,
        )

    def assert_owned_peer_gone(self):
        pid = int((self.directory / 'pid').read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def assert_metadata_only(self):
        self.assertEqual(bytes.fromhex('04000000000000000000000000000000'),
                         (self.directory / 'commands').read_bytes())

    def test_inventory_and_no_test_execution(self):
        result = self.invoke('valid')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_metadata_only()
        self.assert_owned_peer_gone()
        inventory = json.loads(self.output.read_text(encoding='utf-8'))
        self.assertEqual(inventory['names'], ['alpha', 'beta', 'alpha'])
        self.assertEqual((inventory['count'], inventory['unique_count']), (3, 2))
        self.assertNotIn('PRIVATE_STUB_DIAGNOSTIC', result.stderr)
        self.assertNotIn('alpha', result.stdout)

    def test_timeout_kills_and_reaps_owned_peer(self):
        result = self.invoke('hang', '0.3')
        self.assertNotEqual(result.returncode, 0)
        self.assert_metadata_only()
        self.assert_owned_peer_gone()
        self.assertFalse(self.output.exists())
        self.assertNotIn('PRIVATE_STUB_DIAGNOSTIC', result.stderr)

    def test_malformed_and_length_errors_are_nonzero(self):
        for mode in ('oversize', 'truncated', 'bad_offset', 'bad_sizes'):
            with self.subTest(mode=mode):
                result = self.invoke(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assert_metadata_only()
                self.assert_owned_peer_gone()
                self.assertFalse(self.output.exists())
                self.assertNotIn('PRIVATE_STUB_DIAGNOSTIC', result.stderr)

    def test_actual_output_limit_kills_and_reaps_peer(self):
        spec = importlib.util.spec_from_file_location('list_tests', TOOL)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with patch.dict(os.environ, STUB_DIR=str(self.directory), STUB_MODE='flood'):
            with patch.object(module, 'MAX_OUTPUT', 1024):
                with self.assertRaises(ValueError):
                    module.inventory(str(self.stub), 2)
        self.assert_metadata_only()
        # inventory runs in this test process, so waitpid proves it was reaped.
        pid = int((self.directory / 'pid').read_text())
        with self.assertRaises(ChildProcessError):
            os.waitpid(pid, os.WNOHANG)
        self.assert_owned_peer_gone()

    def test_invalid_timeout_is_nonzero(self):
        result = self.invoke('valid', '0')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.directory / 'pid').exists())
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
