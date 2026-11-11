#!/usr/bin/env python3
"""Compose the explicitly mapped test projection; never used by product builds."""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import stat
import tempfile

from zigscan import container_closing

MARKER = '.thin-test-composition-v1'
MANIFEST = '.thin-generated-files.json'
GROUPS = {'all', 'fast', 'ui', 'app', 'core', 'integration', 'daemon', 'driver'}


def relative(value):
    if not isinstance(value, str) or not value or '\\' in value:
        raise ValueError('invalid relative path')
    p = PurePosixPath(value)
    if p.is_absolute() or any(x in ('', '.', '..') for x in value.split('/')):
        raise ValueError('unsafe relative path: ' + value)
    return p


def no_symlinks(path, anchor, allow_missing=False):
    """Reject links at/below an already canonicalized, trusted anchor."""
    path = Path(os.path.abspath(path))
    anchor = Path(anchor)
    rel = path.relative_to(anchor)
    parts = [anchor]
    for component in rel.parts:
        parts.append(parts[-1] / component)
    for part in parts:
        try:
            mode = part.lstat().st_mode
        except FileNotFoundError:
            if allow_missing:
                continue
            raise
        if stat.S_ISLNK(mode):
            raise ValueError('symlink forbidden: ' + str(part))


def source(root, value):
    rel = relative(value)
    if len(rel.parts) < 2 or rel.parts[0] not in ('src', 'tests') or any(part in ('.git', '.pi', 'model-metadata.json') for part in rel.parts):
        raise ValueError('forbidden source path: ' + value)
    p = root.joinpath(*rel.parts)
    no_symlinks(p, root)
    if not p.is_file():
        raise ValueError('source is not a regular file: ' + str(p))
    return p.read_bytes()


def publish(path, data, anchor):
    no_symlinks(path, anchor, allow_missing=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    no_symlinks(path.parent, anchor)
    if path.exists() and path.read_bytes() == data:
        return
    fd, tmp = tempfile.mkstemp(prefix='.compose-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def compose(layout_path, out, group):
    if group not in GROUPS:
        raise ValueError('unknown group')
    layout_path = Path(os.path.abspath(layout_path))
    logical_root = layout_path.parent.parent
    root = logical_root.resolve()
    layout_path = root / layout_path.relative_to(logical_root)
    no_symlinks(layout_path, root)
    layout = json.loads(layout_path.read_text(encoding='utf-8'))
    if layout.get('version') != 1 or not isinstance(layout.get('files'), list) or not isinstance(layout.get('assets'), list):
        raise ValueError('unsupported layout')
    out = Path(os.path.abspath(out))
    # Only the explicit parent is trusted: never resolve the final output name.
    out = out.parent.resolve() / out.name
    no_symlinks(out, out.parent, allow_missing=True)
    if out == root or out in root.parents or any(out == root / p or root / p in out.parents for p in ('src', 'tests')):
        raise ValueError('output overlaps source tree')
    if not out.exists():
        out.mkdir(parents=True)
        publish(out / MARKER, (json.dumps({'version': 1, 'source_root': str(root)}, sort_keys=True) + '\n').encode(), out)
    elif not out.is_dir() or not (out / MARKER).is_file():
        raise ValueError('output directory is not owned')
    no_symlinks(out / MARKER, out)
    try:
        ownership = json.loads((out / MARKER).read_text(encoding='utf-8'))
    except (ValueError, UnicodeError) as exc:
        raise ValueError('invalid ownership marker; create a fresh output directory') from exc
    if ownership != {'version': 1, 'source_root': str(root)}:
        raise ValueError('ownership marker does not match canonical source root')
    manifest = out / MANIFEST
    no_symlinks(manifest, out, allow_missing=True)
    previous = json.loads(manifest.read_text()) if manifest.exists() else []
    if not isinstance(previous, list) or not all(isinstance(x, str) for x in previous):
        raise ValueError('invalid output manifest')
    for name in previous:
        relative(name)
        if not name.startswith('src/'):
            raise ValueError('invalid generated path')
        no_symlinks(out / name, out, allow_missing=True)
    outputs = {}
    group_imports = []
    for entry in layout['files']:
        v = str(relative(entry['virtual']))
        if not v.startswith('src/') or v in outputs:
            raise ValueError('duplicate or invalid output')
        if entry['group'] not in GROUPS - {'all', 'driver'}:
            raise ValueError('invalid file group')
        if type(entry.get('unit')) is not bool:
            raise ValueError('file unit membership must be an explicit bool')
        selected = entry['unit'] and entry['group'] == group
        if group not in ('all', 'driver') and selected and v != 'src/root.zig' and entry['fragments']:
            group_imports.append(v[4:])
        data = source(root, entry['production']) if entry['production'] is not None else b''
        if entry['support'] is not None:
            data += b'\n' + source(root, entry['support']) + b'\n'
        for fragment in entry['fragments']:
            role = fragment.get('role', 'case')
            if role not in ('case', 'discovery'):
                raise ValueError('invalid fragment role')
            if group == 'driver' or not (group == 'all' or selected):
                continue
            path = fragment['container']
            if not isinstance(path, list) or not all(isinstance(x, str) and x for x in path):
                raise ValueError('invalid container')
            text = data.decode('utf-8')
            pos = container_closing(text, path)
            text = text[:pos] + '\n' + source(root, fragment['path']).decode('utf-8') + '\n' + text[pos:]
            data = text.encode('utf-8')
        outputs[v] = data
    for entry in layout['assets']:
        v = str(relative(entry['virtual']))
        if not v.startswith('src/') or v in outputs:
            raise ValueError('duplicate or invalid output')
        outputs[v] = source(root, entry['source'])
    if group not in ('all', 'driver'):
        imports = ''.join('    _ = @import(' + json.dumps(p, ensure_ascii=True) + ');\n' for p in sorted(group_imports))
        root_name = 'src/__test_group_root.zig'
        if root_name in outputs:
            raise ValueError('generated group root conflicts with virtual path')
        root_source = 'const std = @import("std");\ntest {\n' + imports + '}\ntest "group contains product tests" {\n    for (@import("builtin").test_functions) |case| {\n        if (std.mem.indexOf(u8, case.name, ".test.") != null and !std.mem.endsWith(u8, case.name, ".test.group contains product tests")) return;\n    }\n    return error.NoMatchingProductTests;\n}\n'
        outputs[root_name] = root_source.encode()
    # All inputs are validated before publishing any output. A build must always
    # invoke compose; no marker alone authorizes using old output on failure.
    for name, data in outputs.items():
        publish(out.joinpath(*relative(name).parts), data, out)
    for name in set(previous) - outputs.keys():
        path = out.joinpath(*relative(name).parts)
        no_symlinks(path, out, allow_missing=True)
        if path.exists():
            if not path.is_file():
                raise ValueError('generated path is not a file')
            path.unlink()
    publish(manifest, (json.dumps(sorted(outputs)) + '\n').encode(), out)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--layout', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--group', required=True, choices=sorted(GROUPS))
    args = p.parse_args()
    compose(args.layout, args.out, args.group)

if __name__ == '__main__':
    main()
