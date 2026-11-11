"""Offline composition contract tests; no Zig compiler or product execution."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parent / 'tools'
sys.path.insert(0, str(TOOLS))
import compose
import zigscan


class Scanner(unittest.TestCase):
    def test_top_level_append_does_not_scan(self):
        text = 'const x = struct { };\n'
        with patch.object(zigscan, 'scan', side_effect=AssertionError('unexpected scan')):
            self.assertEqual(zigscan.container_closing(text, []), len(text))
        with patch.object(zigscan, 'scan', wraps=zigscan.scan) as scanner:
            pos = zigscan.container_closing(text, ['x'])
            self.assertEqual(text[pos], '}')
            scanner.assert_called_once_with(text)

    def test_multiline_literal_preserves_payload_without_parsing_it(self):
        source = 'test "sample" {\n    const x =\n        \\\\test { original }\n        \\\\second } {\n    ;\n    _ = x;\n}\n'
        changed = source.replace('original', 'changed')
        tokens = [t.text for t in zigscan.scan(source)]
        self.assertNotEqual(tokens, [t.text for t in zigscan.scan(changed)])
        self.assertIn('\\\\test { original }', tokens)
        self.assertIn('\\\\second } {', tokens)
        self.assertEqual(len(zigscan.tests(source)), 1)
        self.assertEqual(len(zigscan.tests(changed)), 1)


class Composition(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.layout_path = self.root / 'tests/layout.json'
        self.out = self.root / 'cache'
        self.put('src/a.zig', 'const helper = 7;\nconst Session = struct { const private = 1; };\n')
        self.put('src/b.zig', 'pub const n = 1;\n')
        self.put('tests/support/a.zig', 'const fake = helper;\n')
        self.put('tests/unit/a_test.zig', 'test "outer" { _ = fake; }\n')
        self.put('tests/unit/a_session_test.zig', 'test "nested" { _ = private; }\n')
        self.put('tests/unit/a_discovery.zig', 'test { _ = @import("b.zig"); }\n')
        self.put('tests/unit/b_test.zig', 'test "other" { _ = n; }\n')
        self.put('tests/fixtures/x.json', '{"ok":true}')
        self.layout = {'version': 1, 'files': [
            {'virtual': 'src/a.zig', 'production': 'src/a.zig', 'support': 'tests/support/a.zig', 'group': 'fast', 'unit': True, 'fragments': [
                {'path': 'tests/unit/a_test.zig', 'container': []},
                {'path': 'tests/unit/a_session_test.zig', 'container': ['Session']},
                {'path': 'tests/unit/a_discovery.zig', 'container': [], 'role': 'discovery'}]},
            {'virtual': 'src/b.zig', 'production': 'src/b.zig', 'support': None, 'group': 'ui', 'unit': True, 'fragments': [
                {'path': 'tests/unit/b_test.zig', 'container': []}]},
        ], 'assets': [{'virtual': 'src/fixture.json', 'source': 'tests/fixtures/x.json'}]}
        self.save()

    def put(self, path, data):
        p = self.root / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(data)

    def save(self):
        self.put('tests/layout.json', json.dumps(self.layout))

    def run_group(self, group='all'):
        compose.compose(self.layout_path, self.out, group)

    def text(self, path):
        return (self.out / path).read_text()

    def test_roundtrip_private_nested_and_asset(self):
        self.run_group()
        text = self.text('src/a.zig')
        cases = zigscan.tests(text)
        self.assertEqual([p for _, _, p in cases], [['Session'], [], []])
        self.assertIn('const fake = helper;', text)
        self.assertIn('_ = private;', text)
        self.assertEqual(self.text('src/fixture.json'), '{"ok":true}')
        self.assertFalse((self.out / 'src/__test_group_root.zig').exists())

    def test_group_roots_owners_and_driver(self):
        self.run_group('fast')
        self.assertIn('test "outer"', self.text('src/a.zig'))
        self.assertNotIn('test "other"', self.text('src/b.zig'))
        root = self.text('src/__test_group_root.zig')
        self.assertIn('@import("a.zig")', root)
        self.assertNotIn('@import("b.zig")', root)
        self.assertIn('NoMatchingProductTests', root)
        self.assertIn('std.mem.indexOf(u8, case.name, ".test.")', root)
        self.assertIn('std.mem.endsWith(u8, case.name, ".test.group contains product tests")', root)
        self.assertNotIn('test_functions.len', root)
        self.run_group('ui')
        self.assertNotIn('test "outer"', self.text('src/a.zig'))
        self.assertNotIn('test {', self.text('src/a.zig'))
        self.assertIn('test "other"', self.text('src/b.zig'))
        self.assertIn('@import("b.zig")', self.text('src/__test_group_root.zig'))
        self.run_group('driver')
        self.assertNotIn('test "', self.text('src/a.zig'))
        self.assertNotIn('test {', self.text('src/a.zig'))
        self.assertIn('const fake = helper;', self.text('src/a.zig'))
        self.assertFalse((self.out / 'src/__test_group_root.zig').exists())

    def test_discovery_only_and_root_entry_not_group_imports(self):
        self.layout['files'].append({'virtual':'src/root.zig','production':None,'support':None,'group':'fast','unit':True,'fragments':[{'path':'tests/unit/a_discovery.zig','container':[],'role':'discovery'}]})
        self.save(); self.run_group('fast')
        self.assertNotIn('@import("root.zig")', self.text('src/__test_group_root.zig'))

    def test_specialized_only_cases_remain_in_all_not_unit_groups(self):
        self.layout['files'][0]['unit'] = False
        self.save()
        self.run_group('all')
        self.assertIn('test "outer"', self.text('src/a.zig'))
        self.assertIn('test "nested"', self.text('src/a.zig'))
        self.assertIn('test {', self.text('src/a.zig'))
        self.run_group('fast')
        self.assertNotIn('test "', self.text('src/a.zig'))
        self.assertNotIn('test {', self.text('src/a.zig'))
        self.assertIn('const fake = helper;', self.text('src/a.zig'))
        self.assertNotIn('@import("a.zig")', self.text('src/__test_group_root.zig'))

    def test_unit_discovery_root_is_imported_only_by_owner(self):
        self.put('tests/unit/bridge_discovery.zig', 'test { _ = @import("b.zig"); }\n')
        self.layout['files'].append({'virtual': 'src/tests/ui_bridge_test_root.zig', 'production': None, 'support': None, 'group': 'ui', 'unit': True, 'fragments': [{'path': 'tests/unit/bridge_discovery.zig', 'container': [], 'role': 'discovery'}]})
        self.save()
        self.run_group('ui')
        self.assertIn('@import("tests/ui_bridge_test_root.zig")', self.text('src/__test_group_root.zig'))
        self.assertIn('test {', self.text('src/tests/ui_bridge_test_root.zig'))
        self.run_group('fast')
        self.assertNotIn('@import("tests/ui_bridge_test_root.zig")', self.text('src/__test_group_root.zig'))
        self.assertNotIn('test {', self.text('src/tests/ui_bridge_test_root.zig'))

    def test_unit_membership_is_required_and_strict_bool(self):
        entry = self.layout['files'][0]
        for value in (None, 0, 1, 'true', [], {}):
            entry['unit'] = value
            self.save()
            with self.assertRaisesRegex(ValueError, 'explicit bool'):
                self.run_group()
        del entry['unit']
        self.save()
        with self.assertRaisesRegex(ValueError, 'explicit bool'):
            self.run_group()

    def test_unchanged_and_unrelated_output_mtime(self):
        self.run_group('fast')
        paths = [self.out/'src/a.zig', self.out/'src/__test_group_root.zig']
        before = [p.stat().st_mtime_ns for p in paths]
        self.run_group('fast')
        self.assertEqual(before, [p.stat().st_mtime_ns for p in paths])
        self.put('src/b.zig', 'pub const n = 2;\n')
        self.run_group('fast')
        self.assertEqual(before, [p.stat().st_mtime_ns for p in paths])

    def test_ownership_cleanup_and_unowned_file(self):
        self.out.mkdir(); self.put('cache/keep', 'untouched')
        with self.assertRaises(ValueError): self.run_group()
        (self.out/'keep').unlink(); self.out.rmdir()
        self.run_group('fast')
        self.put('cache/keep', 'untouched')
        self.layout['files'].pop(1); self.save(); self.run_group('fast')
        self.assertFalse((self.out/'src/b.zig').exists())
        self.assertEqual(self.text('keep'), 'untouched')

    def test_output_symlinks_and_forged_manifest(self):
        self.run_group()
        (self.out/'src/a.zig').unlink()
        (self.out/'src/a.zig').symlink_to(self.root/'src/a.zig')
        with self.assertRaises(ValueError): self.run_group()
        (self.out/'src/a.zig').unlink()
        (self.out/compose.MANIFEST).write_text(json.dumps(['../escape']))
        with self.assertRaises(ValueError): self.run_group()

    def test_forbidden_sources_ancestor_and_generated_root_collision(self):
        for value in ('.pi/private', '.git/config', 'model-metadata.json', 'src/model-metadata.json', 'tests/.pi/private'):
            self.layout['files'][0]['production'] = value
            self.save()
            with self.assertRaises(ValueError): self.run_group()
        self.layout['files'][0]['production'] = 'src/a.zig'
        self.save()
        with self.assertRaises(ValueError): compose.compose(self.layout_path, self.root.parent, 'fast')
        self.layout['files'].append({'virtual': 'src/__test_group_root.zig', 'production': None, 'support': None, 'group': 'core', 'unit': False, 'fragments': []})
        self.save()
        with self.assertRaises(ValueError): self.run_group('fast')

    def test_trusted_parent_and_project_aliases(self):
        with tempfile.TemporaryDirectory() as d:
            anchor = Path(d)
            parent_alias = anchor / 'parent-alias'
            parent_alias.symlink_to(self.root.parent, target_is_directory=True)
            project_alias = anchor / 'project-alias'
            project_alias.symlink_to(self.root, target_is_directory=True)
            layout_alias = parent_alias / self.root.name / 'tests/layout.json'
            cache_parent_alias = project_alias / 'cache'
            compose.compose(layout_alias, cache_parent_alias, 'fast')
            marker = json.loads((self.out / compose.MARKER).read_text())
            self.assertEqual(marker, {'version': 1, 'source_root': str(self.root.resolve())})
            before = (self.out / 'src/a.zig').stat().st_mtime_ns
            compose.compose(project_alias / 'tests/layout.json', self.out, 'fast')
            self.assertEqual(before, (self.out / 'src/a.zig').stat().st_mtime_ns)
            # A final output basename is never treated as a trusted alias.
            output_link = anchor / 'output-link'
            output_link.symlink_to(self.out, target_is_directory=True)
            with self.assertRaises(ValueError):
                compose.compose(self.layout_path, output_link, 'fast')
            # Canonicalization must not hide links below the source anchor.
            source_link = self.root / 'src/linked.zig'
            source_link.symlink_to(self.root / 'src/a.zig')
            self.layout['files'][0]['production'] = 'src/linked.zig'
            self.save()
            with self.assertRaises(ValueError):
                compose.compose(layout_alias, self.out, 'fast')

    def test_layout_and_tests_directory_links_are_not_trusted(self):
        original = self.layout_path.read_text()
        self.put('real-layout.json', original)
        self.layout_path.unlink()
        self.layout_path.symlink_to(self.root / 'real-layout.json')
        with self.assertRaises(ValueError): self.run_group()
        self.layout_path.unlink()
        self.layout_path.write_text(original)
        (self.root / 'tests').rename(self.root / 'actual-tests')
        (self.root / 'tests').symlink_to(self.root / 'actual-tests', target_is_directory=True)
        with self.assertRaises(ValueError): self.run_group()

    def test_marker_binds_project_not_group_and_rejects_legacy(self):
        self.run_group('fast')
        self.run_group('ui')
        with tempfile.TemporaryDirectory() as d:
            other = Path(d)
            (other / 'tests').mkdir()
            (other / 'tests/layout.json').write_text(json.dumps({'version': 1, 'files': [], 'assets': []}))
            before = (self.out / compose.MARKER).read_bytes()
            with self.assertRaisesRegex(ValueError, 'canonical source root'):
                compose.compose(other / 'tests/layout.json', self.out, 'fast')
            self.assertEqual(before, (self.out / compose.MARKER).read_bytes())
        (self.out / compose.MARKER).write_bytes(b'thin-test-composition-v1\n')
        with self.assertRaisesRegex(ValueError, 'fresh output directory'):
            self.run_group()

    def test_traversal_symlinks_and_bad_layout(self):
        for value in ('../escape', '/tmp/escape', 'src/../escape'):
            self.layout['files'][0]['virtual'] = value; self.save()
            with self.assertRaises(ValueError): self.run_group()
        self.layout['files'][0]['virtual'] = 'src/a.zig'
        self.layout['files'][0]['production'] = 'src/link.zig'
        (self.root/'src/link.zig').symlink_to('a.zig'); self.save()
        with self.assertRaises(ValueError): self.run_group()
        self.layout['version'] = 99; self.save()
        p = subprocess.run([sys.executable, str(TOOLS/'compose.py'), '--layout', str(self.layout_path), '--out', str(self.out), '--group', 'all'], capture_output=True)
        self.assertNotEqual(p.returncode, 0)


if __name__ == '__main__':
    unittest.main()
