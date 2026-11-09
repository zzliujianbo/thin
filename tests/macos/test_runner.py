"""Offline checks for the P0 runner's exit and timeout handling."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("darwin_p0_runner", Path(__file__).with_name("run.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def test_success_and_nonzero_exit(self):
        runner.run_owned([sys.executable, "-c", "pass"], timeout=5)
        with self.assertRaises(subprocess.CalledProcessError) as error:
            runner.run_owned([sys.executable, "-c", "raise SystemExit(7)"], timeout=5)
        self.assertEqual(error.exception.returncode, 7)

    def test_cleanup_does_not_signal_after_child_ownership_is_lost(self):
        process = types.SimpleNamespace(pid=12345)
        with mock.patch.object(runner.os, "waitid", side_effect=ChildProcessError), \
                mock.patch.object(runner.os, "killpg") as killpg:
            runner.stop_owned_group(process)
        killpg.assert_not_called()

    def test_timeout_kills_term_ignoring_child_before_reaping_leader(self):
        # The leader exits on TERM, but its child ignores it. The runner must
        # still send the final group KILL before it releases the leader's PID.
        with tempfile.TemporaryDirectory(prefix="thin-p0-runner-test-") as temporary:
            marker = Path(temporary) / "child-pid"
            script = """
import os, signal, sys, time
child = os.fork()
if child == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    with open(sys.argv[1], 'w') as output:
        output.write(str(os.getpid()))
        output.flush()
    while True:
        time.sleep(1)
else:
    while True:
        time.sleep(1)
"""
            with self.assertRaises(subprocess.TimeoutExpired):
                runner.run_owned([sys.executable, "-c", script, str(marker)], timeout=1)
            self.assertTrue(marker.exists(), "child fixture failed to initialize")
            child = int(marker.read_text())
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                status = subprocess.run(["ps", "-o", "stat=", "-p", str(child)],
                                        capture_output=True, text=True, timeout=2)
                if not status.stdout.strip() or status.stdout.strip().startswith("Z"):
                    break  # An orphan zombie cannot execute and is left to init.
                time.sleep(0.02)
            else:
                self.fail("timeout left the owned child executing")
        self.assertFalse(Path(temporary).exists())


if __name__ == "__main__":
    unittest.main()
