"""Pure stub tests: no Zig compilation, product cases, network or user config."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parent / 'tools'
with patch.object(sys, 'path', [str(TOOLS), *sys.path]):
    spec = importlib.util.spec_from_file_location('shard_guard_under_test', TOOLS / 'verify_shards.py')
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)


def fixtures():
    names = {name: [*sorted(guard.SHARD_BOOKKEEPING), 'product.' + name] for name in guard.SHARDS}
    names['full'] = [*sorted(guard.FULL_BOOKKEEPING), *('product.' + name for name in guard.SHARDS)]
    return names


class ShardSetTests(unittest.TestCase):
    def setUp(self):
        self.names = fixtures()
        self.pairs = [(name, '/stub/' + name) for name in guard.SHARDS]
        self.queries = []

    def query(self, binary, timeout):
        self.assertEqual(timeout, guard.QUERY_TIMEOUT)
        self.assertGreater(timeout, 0)
        self.assertLessEqual(timeout, 300)
        label = Path(binary).name
        self.queries.append(label)
        names = self.names[label]
        return {'names': names, 'count': len(names), 'unique_count': len(set(names))}

    def verify(self, pairs=None):
        with patch.object(guard, 'inventory', side_effect=self.query):
            return guard.verify('/stub/full', self.pairs if pairs is None else pairs)

    def test_exact_partition_and_bookkeeping_success(self):
        report = self.verify()
        self.assertTrue(report['ok'])
        self.assertEqual(report['errors'], [])
        self.assertEqual(self.queries, ['full', *guard.SHARDS])
        self.assertEqual(report['union_count'], 6)
        for item in report['inventories'].values():
            self.assertEqual(item['bookkeeping_count'], 2)

    def test_equal_counts_with_different_case_names_fail(self):
        self.names['fast'][-1] = 'product.other'
        report = self.verify()
        self.assertFalse(report['ok'])
        self.assertEqual(report['union_count'], 6)
        self.assertEqual(report['missing'], ['product.fast'])
        self.assertEqual(report['extra'], ['product.other'])

    def test_invalid_duplicate_missing_unknown_and_extra_ids_do_not_query(self):
        invalid = [self.pairs[:-1], self.pairs + [self.pairs[0]],
                   [*self.pairs[:-1], self.pairs[0]],
                   [*self.pairs[:-1], ('unknown', '/stub/daemon')]]
        for pairs in invalid:
            with self.subTest(pairs=pairs):
                self.queries.clear()
                report = self.verify(pairs)
                self.assertFalse(report['ok'])
                self.assertEqual(report['errors'], ['invalid_shard_ids'])
                self.assertEqual(self.queries, [])

    def test_missing_extra_and_cross_shard_duplicate(self):
        baseline = copy.deepcopy(self.names)
        for mode in ('missing', 'extra', 'overlap'):
            with self.subTest(mode=mode):
                self.names = copy.deepcopy(baseline)
                if mode == 'missing':
                    self.names['full'].append('product.unowned')
                elif mode == 'extra':
                    self.names['fast'].append('product.driver_only')
                else:
                    self.names['ui'].append('product.fast')
                report = self.verify()
                self.assertFalse(report['ok'])
                if mode == 'missing':
                    self.assertEqual(report['missing'], ['product.unowned'])
                elif mode == 'extra':
                    self.assertEqual(report['extra'], ['product.driver_only'])
                else:
                    self.assertEqual(report['overlap'], {'product.fast': ['fast', 'ui']})

    def test_full_and_shard_internal_duplicate_names_fail(self):
        for label in ('full', 'fast'):
            with self.subTest(label=label):
                self.names = fixtures()
                self.names[label].append(self.names[label][-1])
                report = self.verify()
                self.assertFalse(report['ok'])
                self.assertIn('duplicate_names', report['errors'])
                self.assertEqual(len(report['inventories'][label]['duplicates']), 1)

    def test_anonymous_and_other_root_cases_are_not_ignored(self):
        for name in ('feature.test_0', 'root.test_1', 'root.test.actual',
                     '__test_group_root.test_1'):
            with self.subTest(name=name):
                self.names = fixtures()
                self.names['full'].append(name)
                report = self.verify()
                self.assertFalse(report['ok'])
                self.assertEqual(report['missing'], [name])
                self.names['fast'].append(name)
                self.assertTrue(self.verify()['ok'])
        # The full-only root.test_0 is NOT bookkeeping in a shard.
        self.names = fixtures()
        self.names['fast'].append('root.test_0')
        self.assertEqual(self.verify()['extra'], ['root.test_0'])
        # The shard-only anonymous root is NOT bookkeeping in the full binary.
        self.names = fixtures()
        self.names['full'].append('__test_group_root.test_0')
        self.assertEqual(self.verify()['missing'], ['__test_group_root.test_0'])

    def test_empty_full_and_empty_shard_fail_after_bookkeeping_removal(self):
        for label in ('full', *guard.SHARDS):
            with self.subTest(label=label):
                self.names = fixtures()
                self.names[label] = sorted(guard.FULL_BOOKKEEPING if label == 'full'
                                          else guard.SHARD_BOOKKEEPING)
                report = self.verify()
                self.assertFalse(report['ok'])
                self.assertIn('empty_product_inventory', report['errors'])

    def test_main_exit_status_and_metadata_exception_redaction(self):
        args = ['--full', '/stub/full']
        for name, path in self.pairs:
            args += ['--shard', name, path]
        for mode in ('success', 'mismatch', 'metadata_error'):
            with self.subTest(mode=mode):
                self.names = fixtures()
                if mode == 'mismatch':
                    self.names['fast'].append('product.extra')
                out, err = io.StringIO(), io.StringIO()
                effect = ValueError('PRIVATE_EXCEPTION_BODY') if mode == 'metadata_error' else self.query
                with patch.object(guard, 'inventory', side_effect=effect):
                    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                        status = guard.main(args)
                self.assertEqual(status, 0 if mode == 'success' else 1)
                self.assertNotIn('PRIVATE_EXCEPTION_BODY', out.getvalue() + err.getvalue())
                self.assertNotIn('/stub', out.getvalue() + err.getvalue())


# This peer only returns supplied metadata, and rejects any bytes other than
# query_test_metadata + exit. It cannot execute product test functions.
PEER = r'''#!/usr/bin/env python3
import json, struct, sys
from pathlib import Path
p = Path(__file__)
config = json.loads(p.with_suffix('.json').read_text())
commands = sys.stdin.buffer.read()
p.with_suffix('.commands').write_bytes(commands)
if commands != struct.pack('<IIII', 4, 0, 0, 0):
    sys.exit(9)
sys.stderr.write('PRIVATE_CHILD_STDERR\n')
version = b'PRIVATE_CHILD_BODY' if config.get('mode') == 'bad_version' else b'0.17.0'
def message(tag, body):
    sys.stdout.buffer.write(struct.pack('<II', tag, len(body)) + body)
message(0, version)
table = bytearray(b'\0')
offsets = []
for name in config['names']:
    offsets.append(len(table))
    table.extend(name.encode('utf-8') + b'\0')
body = struct.pack('<II', len(table), len(offsets))
body += b''.join(struct.pack('<I', offset) for offset in offsets)
body += b'\0' * (4 * len(offsets)) + table
message(3, body)
sys.stdout.buffer.flush()
if config.get('mode') == 'nonzero':
    sys.exit(7)
'''


class ShardProtocolTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.names = fixtures()
        self.paths = {}
        for label, names in self.names.items():
            path = self.directory / label
            path.write_text(PEER, encoding='utf-8')
            path.chmod(0o700)
            path.with_suffix('.json').write_text(json.dumps({'names': names}), encoding='utf-8')
            self.paths[label] = path

    def invoke(self, output=None, pairs=None):
        args = [sys.executable, str(TOOLS / 'verify_shards.py'), '--full', str(self.paths['full'])]
        for label, path in (pairs if pairs is not None else [(n, self.paths[n]) for n in guard.SHARDS]):
            args += ['--shard', label, str(path)]
        if output is not None:
            args += ['--output', str(output)]
        return subprocess.run(args, capture_output=True, text=True, timeout=15)

    def assert_redacted(self, result):
        text = result.stdout + result.stderr
        self.assertNotIn('PRIVATE_CHILD', text)
        self.assertNotIn(str(self.directory), text)
        self.assertNotIn('Traceback', text)

    def test_seven_real_stub_queries_only_and_optional_private_report(self):
        output = self.directory / 'report.json'
        result = self.invoke(output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_redacted(result)
        for path in self.paths.values():
            self.assertEqual(path.with_suffix('.commands').read_bytes(), struct.pack('<IIII', 4, 0, 0, 0))
        report = json.loads(output.read_text())
        self.assertTrue(report['ok'])
        self.assertEqual(report['union_count'], 6)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        # Omitting --output still succeeds and creates no report files.
        before = set(self.directory.iterdir())
        self.assertEqual(self.invoke().returncode, 0)
        self.assertEqual(set(self.directory.iterdir()), before)

    def test_metadata_bad_version_and_nonzero_child_exit_fail_closed(self):
        for mode in ('bad_version', 'nonzero'):
            with self.subTest(mode=mode):
                self.paths['full'].with_suffix('.json').write_text(
                    json.dumps({'names': self.names['full'], 'mode': mode}), encoding='utf-8')
                output = self.directory / (mode + '.report')
                result = self.invoke(output)
                self.assertNotEqual(result.returncode, 0)
                self.assert_redacted(result)
                report = json.loads(output.read_text())
                self.assertEqual(report['errors'], ['metadata_query_failed'])
                self.assertFalse(report['ok'])

    def test_cli_missing_duplicate_unknown_ids_are_nonzero_without_queries(self):
        pairs = [(n, self.paths[n]) for n in guard.SHARDS]
        invalid = [pairs[:-1], [*pairs[:-1], pairs[0]],
                   [*pairs[:-1], ('PRIVATE_UNKNOWN_ID', pairs[-1][1])]]
        for candidate in invalid:
            with self.subTest(candidate=candidate):
                result = self.invoke(pairs=candidate)
                self.assertNotEqual(result.returncode, 0)
                self.assert_redacted(result)
                self.assertNotIn('PRIVATE_UNKNOWN_ID', result.stdout + result.stderr)
                self.assertFalse(any(self.directory.glob('*.commands')))


if __name__ == '__main__':
    unittest.main()
