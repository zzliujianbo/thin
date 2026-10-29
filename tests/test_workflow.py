"""Pure workflow tests: no Zig, network, credentials, or subprocesses."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("thin_workflow", Path(__file__).with_name("run.py"))
workflow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workflow)


class WorkflowTests(unittest.TestCase):
    def test_forwarding_and_filter_scope(self):
        a = workflow.parse_args(["focus", "--filter", "hello world", "--ssh-include", "/sdk/include", "--ssh-library", "/sdk/libssh.so", "--optimize", "ReleaseSmall", "-j", "2"])
        self.assertEqual(workflow.command_for(a), ["zig", "build", "test-focus", "-j2", "-Doptimize=ReleaseSmall", "--summary", "all", "-Dtest-filter=hello world", "-Dssh-include=/sdk/include", "-Dssh-library=/sdk/libssh.so"])
        for args in (["focus"], ["focus", "--filter", "  "], ["full", "--filter", "x"], ["full", "-j", "0"]):
            with self.subTest(args=args), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                workflow.parse_args(args)
        self.assertEqual(workflow.command_for(workflow.parse_args(["full"]))[:4], ["zig", "build", "test", "-j1"])
        self.assertEqual(workflow.command_for(workflow.parse_args(["streaming"]))[:4], ["zig", "build", "test-streaming", "-j1"])

    def test_evidence_and_failure(self):
        self.assertEqual(workflow.classify(0, "0/0 tests passed", True), "no_positive_test_evidence")
        self.assertEqual(workflow.classify(0, "", True), "no_positive_test_evidence")
        self.assertEqual(workflow.classify(0, "\x1b[32m2/2 tests passed\x1b[0m", True), "passed")
        self.assertEqual(workflow.classify(0, "cached", True), "no_positive_test_evidence")
        self.assertEqual(workflow.classify(0, "+- run test 2 pass (2 total)", True), "no_positive_test_evidence")
        self.assertEqual(workflow.classify(1, "error: undefined symbol: foo", True), "build_or_infrastructure_or_unknown")
        self.assertEqual(workflow.classify(1, "FAIL application acceptance: pty/stream-markdown", False), "fixture_failure")
        self.assertEqual(workflow.classify(1, "prefix FAIL application acceptance: pty/stream-markdown", False), "build_or_infrastructure_or_unknown")
        self.assertEqual(workflow.classify(1, "error: TestExpectedEqual", True), "assertion_failure")
        self.assertEqual(workflow.classify(1, "test focused_root.test_0 failed: error.NoMatchingProductTests\n10/11 tests passed", True), "no_matching_tests")
        self.assertEqual(workflow.classify(1, "test focused_root.test_0 failed: error.NoMatchingProductTests", False), "no_matching_tests")
        self.assertEqual(workflow.classify(1, "error.NoMatchingProductTestsExtra", True), "build_or_infrastructure_or_unknown")
        self.assertEqual(workflow.classify(1, "Build Summary: 21/23 steps succeeded (1 failed); 1592/1593 tests passed (1 failed)\n+- run test 1592 pass, 1 fail (1593 total)", True), "assertion_failure")

    def test_preflight_records_syntax_commands_without_normalization(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.fixture(root)
            (root / "tests" / "example.mjs").write_text("const x = 1;\n")
            calls = []
            def stub(command, **kwargs):
                calls.append(command)
                self.assertNotIn("preexec_fn", kwargs)
                return types.SimpleNamespace(returncode=0, stdout="")
            with mock.patch.object(workflow, "normalized_command", side_effect=AssertionError("preflight normalized")), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(workflow.run(["preflight"], root, stub), 0)
            summary = json.loads(next((root / ".zig-cache" / "workflow").glob("*/summary.json")).read_text())
            self.assertEqual([s["stage"] for s in summary["stages"]], ["python-syntax", "zig-format", "node-syntax"])
            self.assertEqual(calls[-1], ["node", "--check", "tests/example.mjs"])

    def test_normalizer_argument_integrity_and_fail_closed(self):
        command = ["zig", "build", "test-focus", "-Dtest-filter=x; $(bad)", "-Dssh-library=/some path/lib.so"]
        wrapped = workflow.normalized_command(command, euid=0, which=lambda name: "/stub/capsh", limits=(0, workflow.STACK_BYTES))
        self.assertEqual(wrapped, ["/stub/capsh", workflow.CAP_DROP, "--", "-c", 'exec "$@"', "thin-test", *command])
        self.assertEqual(workflow.normalized_command(command, euid=1000, which=lambda _: None, limits=(0, workflow.STACK_BYTES)), command)
        with self.assertRaisesRegex(RuntimeError, "capsh"):
            workflow.normalized_command(command, euid=0, which=lambda _: None, limits=(0, workflow.STACK_BYTES))
        with self.assertRaisesRegex(RuntimeError, "hard limit"):
            workflow.normalized_command(command, euid=0, which=lambda _: "/stub/capsh", limits=(0, workflow.STACK_BYTES - 1))

    def test_missing_normalizer_does_not_invoke_child(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.fixture(root)
            with mock.patch.object(workflow, "normalized_command", side_effect=RuntimeError("capsh missing")), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(workflow.run(["full"], root, lambda *a, **kw: self.fail("child invoked")), 1)
            summary = json.loads(next((root / ".zig-cache" / "workflow").glob("*/summary.json")).read_text())
            self.assertEqual(summary["status"], "build_or_infrastructure_or_unknown")
            self.assertEqual(summary["stages"][0]["exit_code"], 127)


    def fixture(self, root):
        (root / "src").mkdir()
        (root / "tests").mkdir()
        (root / "build.zig").write_text("build")
        (root / "src" / "a.zig").write_text("a")
        (root / "tests" / "a.py").write_text("x = 1\n")

    def test_hash_stable_and_tracks_names_and_bytes(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.fixture(root)
            first = workflow.source_hash(root)
            self.assertEqual(first, workflow.source_hash(root))
            (root / "src" / "a.zig").rename(root / "src" / "b.zig")
            self.assertNotEqual(first, workflow.source_hash(root))

    def test_subprocess_and_mutation_fail_closed(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.fixture(root)
            calls = []
            def stub(command, **kwargs):
                calls.append(command)
                (root / "src" / "a.zig").write_text("changed")
                return types.SimpleNamespace(returncode=0, stdout="1/1 tests passed")
            with mock.patch.object(workflow, "normalized_command", side_effect=lambda command: command), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(workflow.run(["focus", "--filter", "one"], root, stub), 1)
            self.assertEqual(len(calls), 1)
            summary = json.loads(next((root / ".zig-cache" / "workflow").glob("*/summary.json")).read_text())
            self.assertEqual(summary["status"], "source_changed")
            self.assertNotEqual(summary["source_hash_before"], summary["source_hash_after"])

    def test_subprocess_failure_and_zero_evidence(self):
        for returncode, output, expected in [(2, "compiler error", "build_or_infrastructure_or_unknown"), (1, "FAIL application acceptance: pty/stream-markdown", "fixture_failure"), (0, "0/0 tests passed", "no_positive_test_evidence"), (1, "test focused_root.test_0 failed: error.NoMatchingProductTests\n10/11 tests passed", "no_matching_tests")]:
            with tempfile.TemporaryDirectory() as d:
                root = Path(d)
                self.fixture(root)
                def stub(*args, **kwargs):
                    return types.SimpleNamespace(returncode=returncode, stdout=output)
                with mock.patch.object(workflow, "normalized_command", side_effect=lambda command: command), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(workflow.run(["focus", "--filter", "one"], root, stub), 1)
                summary = json.loads(next((root / ".zig-cache" / "workflow").glob("*/summary.json")).read_text())
                self.assertEqual(summary["status"], expected)
                self.assertEqual(summary["stages"][0]["exit_code"], returncode)


if __name__ == "__main__":
    unittest.main()
