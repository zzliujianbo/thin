"""Pure workflow tests: no Zig, network, credentials, or subprocesses."""
import contextlib
import importlib.util
import io
import json
import re
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

    def test_group_mappings_and_positive_counts(self):
        for group, step in {"unit": "test-unit", "unit-full": "test-unit-full", "unit-sharded": "test-unit-sharded", "fast": "test-fast", **{f"unit-{g}": f"test-unit-{g}" for g in ("ui", "app", "core", "integration", "daemon")}}.items():
            with self.subTest(group=group):
                self.assertEqual(workflow.command_for(workflow.parse_args([group]))[:4], ["zig", "build", step, "-j1"])
        self.assertEqual(workflow.command_for(workflow.parse_args(["unit-sharded", "-j2"]))[:4], ["zig", "build", "test-unit-sharded", "-j2"])
        self.assertIn("unit-sharded", workflow.COUNTED_GROUPS)
        self.assertEqual(workflow.classify(0, "1948/1962 tests passed (14 skipped)", counted=True), "passed")
        self.assertEqual(workflow.classify(0, "+- run test cached", counted=True), "no_positive_test_evidence")
        self.assertEqual(workflow.classify(0, "+- run test cached"), "no_positive_test_evidence")
        self.assertEqual(workflow.classify(0, "0/0 tests passed", counted=True), "no_positive_test_evidence")

    def test_fresh_shard_evidence(self):
        groups = ('fast', 'ui', 'app', 'core', 'integration', 'daemon')
        nodes = [f'+- run test [{group}] 2 pass (2 total) 1ms' for group in groups]
        six = '\n'.join(nodes) + '\n12/12 tests passed'
        for output in (six + '\n+- run test cached', '\n'.join(nodes[:5]) + '\n15/15 tests passed', six + '\n+- run test 0 pass (0 total)', '\n'.join([nodes[0]] * 6) + '\n6/6 tests passed'):
            with self.subTest(output=output):
                self.assertEqual(workflow.classify(0, output, counted=True, required_runs=6), 'no_positive_test_evidence')
        self.assertEqual(workflow.classify(0, six, counted=True, required_runs=6), 'passed')
        self.assertEqual(workflow.classify(0, six + '\n   +- compile test Debug native cached 25ms', counted=True, required_runs=6), 'passed')
        self.assertEqual(workflow.classify(0, six + '\n+- run node cached'), 'passed')
        self.assertEqual(workflow.classify(0, '2/2 tests passed\n+- run test cached', counted=True), 'no_positive_test_evidence')
        self.assertEqual(workflow.classify(0, '2/2 tests passed\n+- run test 0 pass (0 total)', counted=True), 'no_positive_test_evidence')
        self.assertEqual(workflow.classify(0, '2/2 tests passed\n+- compile test Debug native cached', counted=True), 'passed')
        self.assertEqual(workflow.classify(0, six + '\n' + nodes[0].replace('1ms', '2ms'), counted=True, required_runs=6), 'no_positive_test_evidence')
        for bad in ('[daemon] 0 pass (0 total)', '[daemon] cached', '[unknown] 2 pass (2 total)', '[fast] 2 pass (2 total)'):
            output = '\n'.join(nodes[:5]) + '\n+- run test ' + bad + '\n12/12 tests passed'
            self.assertEqual(workflow.classify(0, output, counted=True, required_runs=6), 'no_positive_test_evidence')
        self.assertEqual(workflow.classify(0, '2/2 tests passed\n+- run test [fast] cached', counted=True), 'no_positive_test_evidence')

    def test_final_summary_excludes_progress_and_diagnostic_trees(self):
        groups = ('fast', 'ui', 'app', 'core', 'integration', 'daemon')
        nodes = [f'+- run test [{group}] 2 pass (2 total) 1ms' for group in groups]
        prefix = '+- run test [integration] w\nfailed command: diagnostic only\n99/99 tests passed\n'
        summary = 'Build Summary: 40/40 steps succeeded; 12/12 tests passed\n'
        output = prefix + summary + '\n'.join(nodes)
        self.assertEqual(workflow.classify(0, output, counted=True, required_runs=6), 'passed')
        for final_nodes in (nodes[:5], nodes[:5] + [nodes[0]], nodes[:5] + ['+- run test [daemon] cached'], nodes[:5] + ['+- run test [daemon] 0 pass (0 total)']):
            with self.subTest(final_nodes=final_nodes):
                self.assertEqual(workflow.classify(0, prefix + summary + '\n'.join(final_nodes), counted=True, required_runs=6), 'no_positive_test_evidence')
        self.assertEqual(workflow.classify(0, prefix + 'Build Summary: 1/1 steps succeeded', counted=True), 'no_positive_test_evidence')
        self.assertEqual(workflow.classify(0, prefix + 'Build Summary: 1/1 steps succeeded', counted=True, required_runs=6), 'no_positive_test_evidence')
        self.assertEqual(workflow.classify(0, 'Build Summary: 99/99 tests passed\n' + output, counted=True, required_runs=6), 'passed')
        self.assertEqual(workflow.classify(1, 'error.NoMatchingProductTests\n' + output, counted=True, required_runs=6), 'no_matching_tests')

    def test_sharded_run_requires_six_fresh_nodes(self):
        for count in (5, 6):
            with self.subTest(count=count), tempfile.TemporaryDirectory() as d:
                root = Path(d)
                self.fixture(root)
                groups = ('fast', 'ui', 'app', 'core', 'integration', 'daemon')
                output = '\n'.join(f'+- run test [{group}] 2 pass (2 total)' for group in groups[:count]) + '\n12/12 tests passed'
                def stub(*args, **kwargs):
                    return types.SimpleNamespace(returncode=0, stdout=output)
                with mock.patch.object(workflow, 'normalized_command', side_effect=lambda command: command), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(workflow.run(['unit-sharded'], root, stub), 0 if count == 6 else 1)

    def test_build_graph_contract_without_building(self):
        source = (Path(__file__).resolve().parent.parent / "build.zig").read_text()
        self.assertIn('generated-tests/{x}/{s}', source)
        self.assertIn('b.root.root_dir.handle.realPathFileAlloc', source)
        self.assertIn('std.hash.Wyhash.hash(0, project_root)', source)
        self.assertIn('run.has_side_effects = true;', source)
        self.assertIn('grouped.step.dependOn(&variant.run.step)', source)
        self.assertIn('.root_source_file = variant.path(b, "src/__test_group_root.zig")', source)
        self.assertNotIn('.root_source_file = variant.path(b, "src/root.zig")', source)
        self.assertIn('if (!std.mem.eql(u8, group, "fast")) addRuntime(b, grouped.root_module, ssh_include, ssh_library);', source)
        self.assertIn('.root_source_file = all.path(b, "src/root.zig")', source)
        self.assertIn('unit.step.dependOn(&all.run.step)', source)
        self.assertIn('pty_driver.step.dependOn(&driver.run.step)', source)
        for artifact in ("presentation_tests", "filesystem_tests", "terminal_tests", "unit", "focused", "rendering", "memory_tests", "http_tests", "proxy_tests", "systemone_tests", "anthropic_tests"):
            with self.subTest(artifact=artifact):
                self.assertIn(f'{artifact}.step.dependOn(&all.run.step)', source)
        self.assertIn('.root_source_file = b.path("src/main.zig")', source)
        self.assertIn('.root_source_file = b.path("src/presentation.zig")', source)
        self.assertIn('b.step("test-unit", "Run the complete unit suite in one process").dependOn(&run_unit.step)', source)
        self.assertIn('b.step("test-unit-full", "Run the complete unit suite in one process").dependOn(&run_unit.step)', source)
        self.assertIn('const sharded = b.step("test-unit-sharded",', source)
        self.assertIn('for ([_][]const u8{ "fast", "ui", "app", "core", "integration", "daemon" })', source)
        self.assertEqual(source.count('const run_group = runTest(b, grouped);'), 1)
        self.assertIn('run_group.step.name = b.fmt("run test [{s}]", .{group});', source)
        self.assertIn('group_step.dependOn(&run_group.step);', source)
        self.assertIn('parallel.dependOn(group_step);', source)
        self.assertIn('const shard_inventory: ?*std.Build.Step.Run = if (target.result.os.tag == .linux)', source)
        self.assertIn('guard.addFileArg(b.path("tests/tools/verify_shards.py"));', source)
        self.assertIn('guard.addArg("--full");\n        guard.addArtifactArg(unit);', source)
        self.assertIn('guard.has_side_effects = true;', source)
        self.assertIn('guard.addArgs(&.{ "--shard", group });\n            guard.addArtifactArg(grouped);', source)
        self.assertIn('const guarded_run = runTest(b, grouped);', source)
        self.assertIn('guarded_run.step.dependOn(&guard.step);', source)
        self.assertIn('sharded.dependOn(&guarded_run.step);', source)
        self.assertNotIn('run_group.step.dependOn(&guard.step)', source)
        self.assertNotIn('guard.step.dependOn(&run_unit.step)', source)
        self.assertNotIn('guard.addArtifactArg(run_unit)', source)
        self.assertNotIn('sharded.dependOn(&run_group.step)', source)
        self.assertIn('test-unit-sharded is Linux-only;', source)
        self.assertIn('test-unit-daemon is Linux-only', source)
        self.assertNotIn('test_all.dependOn(sharded)', source)
        self.assertIn('"discover", "-s", "tests", "-p", "test_*.py"', source)
        self.assertIn('full_prerequisites.dependOn(&workflow_tests.step);', source)
        self.assertNotIn('addOutputDirectoryArg', source)

    def test_entry_local_daemon_latency_isolation(self):
        source = (Path(__file__).resolve().parent.parent / 'build.zig').read_text()
        full = source.split('const full_prerequisites = ', 1)[1].split('for ([_]*std.Build.Step.Compile', 1)[0]
        self.assertTrue(full.startswith('if (target.result.os.tag == .linux)'))
        self.assertIn('} else test_all;', full)
        self.assertIn('const full_daemon = fixture(b, "python3", "tests/product/daemon_mock.py", &.{exe}, &.{});', full)
        self.assertIn('test_all.dependOn(&full_daemon.step);', full)
        self.assertIn('break :gate &full_daemon.step;', full)
        dependencies = re.findall(r'full_prerequisites\.dependOn\(([^)]+)\);', full)
        # Original full inventory, except its daemon is now the downstream gate.
        expected = {'workflow_tests', 'run_unit', 'run_memory', 'run_memory_app', 'run_background', 'run_subscription', 'run_ssh', 'run_subagent', 'run', 'run_presentation', 'run_http', 'run_anthropic', 'run_systemone', 'run_proxy', 'run_app', 'run_idle_enter', 'run_resume_menu', 'run_memory_background', 'run_resize', 'run_settings', 'run_command', 'run_approval_cancel', 'run_tool_preview', 'run_queued'}
        self.assertEqual(set(dependencies), {f'&{name}.step' for name in expected} | {'viewport_step'})
        self.assertEqual(len(dependencies), len(expected) + 1)
        communication = source.split('const communication = ', 1)[1].split('// Root-level offline tooling', 1)[0]
        self.assertIn('if (target.result.os.tag == .linux)', communication)
        self.assertIn('else communication.dependOn(&b.addFail(', communication)
        self.assertIn('const communication_daemon = fixture(b, "python3", "tests/product/daemon_mock.py", &.{exe}, &.{});', communication)
        self.assertEqual(re.findall(r'communication_daemon\.step\.dependOn\(([^)]+)\);', communication), ['&run_subscription.step', '&run_ssh.step'])
        self.assertIn('communication.dependOn(&communication_daemon.step);', communication)
        self.assertNotIn('communication_daemon', full)
        self.assertNotIn('run_daemon.step.dependOn(', source)
        self.assertNotIn('run_group.step.dependOn(&full_daemon.step)', source)
        self.assertIn('if (target.result.os.tag == .linux) ssh_step', source)
        self.assertIn('if (target.result.os.tag == .linux) daemon_step.dependOn(&run_daemon.step)', source)

    def test_app_forwards_existing_build_and_preserves_runner_semantics(self):
        argv = ["app", "--optimize", "ReleaseSmall", "--ssh-include", "/sdk/include", "--ssh-library", "/sdk/libssh.so"]
        command = ["zig", "build", "test-app", "-j1", "-Doptimize=ReleaseSmall", "--summary", "all", "-Dssh-include=/sdk/include", "-Dssh-library=/sdk/libssh.so"]
        self.assertEqual(workflow.command_for(workflow.parse_args(argv)), command)
        wrapped = ["/stub/capsh", workflow.CAP_DROP, "--", "-c", 'exec "$@"', "thin-test", *command]
        for code, output, mutate, status in [(0, "", False, "passed"), (1, "FAIL application acceptance: example", False, "fixture_failure"), (0, "", True, "source_changed")]:
            with self.subTest(status=status), tempfile.TemporaryDirectory() as d:
                root = Path(d)
                self.fixture(root)
                calls = []
                def stub(actual, **kwargs):
                    calls.append(actual)
                    self.assertEqual(kwargs["cwd"], root)
                    self.assertIs(kwargs["preexec_fn"], workflow.set_child_stack)
                    if mutate:
                        (root / "src" / "a.zig").write_text("changed")
                    return types.SimpleNamespace(returncode=code, stdout=output)
                normalizer = workflow.normalized_command
                def normalize(actual):
                    return normalizer(actual, euid=0, which=lambda _: "/stub/capsh", limits=(0, workflow.STACK_BYTES))
                with mock.patch.object(workflow, "normalized_command", side_effect=normalize), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(workflow.run(argv, root, stub), 0 if status == "passed" else 1)
                self.assertEqual(calls, [wrapped])
                summary = json.loads(next((root / ".zig-cache" / "workflow").glob("*/summary.json")).read_text())
                self.assertEqual(summary["status"], status)
                self.assertEqual(summary["stages"][0]["stage"], "app")
                self.assertEqual(summary["stages"][0]["command"], wrapped)
                self.assertEqual(summary["stages"][0]["exit_code"], code)
                self.assertEqual(summary["source_hash_before"] == summary["source_hash_after"], not mutate)

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
            for name in ("layout.json", "tools/compose.py", "fixtures/models_dev_fixture.json"):
                before = workflow.source_hash(root)
                path = root / "tests" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("stub")
                self.assertNotEqual(before, workflow.source_hash(root))

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
