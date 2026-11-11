#!/usr/bin/env python3
"""Check six compiled unit shards against a compiled full unit inventory.

Metadata queries only; Zig's standard runner still executes the actual tests.
Each query has a 30-second deadline. --output optionally creates a new private
JSON report; existing files are never overwritten. No binary is compiled here.
"""
import argparse
from collections import Counter
import json
import os
import subprocess
import sys

# No incidental bytecode cache when this metadata guard is invoked by a build.
sys.dont_write_bytecode = True
from list_tests import inventory

SHARDS = ('fast', 'ui', 'app', 'core', 'integration', 'daemon')
FULL_BOOKKEEPING = frozenset(('root.test_0', 'root.test.unit test inventory is nonempty'))
SHARD_BOOKKEEPING = frozenset((
    '__test_group_root.test_0', '__test_group_root.test.group contains product tests',
))
QUERY_TIMEOUT = 30


def verify(full, shards):
    """Return safe counts and static case names, never paths or child output."""
    report = {
        'ok': False, 'errors': [], 'inventories': {},
        'missing': [], 'extra': [], 'overlap': {}, 'union_count': 0,
    }
    ids = [name for name, _ in shards]
    if len(ids) != len(SHARDS) or set(ids) != set(SHARDS):
        report['errors'].append('invalid_shard_ids')
        return report
    paths = dict(shards)
    products = {}
    for label, binary in [('full', full)] + [(name, paths[name]) for name in SHARDS]:
        try:
            names = inventory(os.path.abspath(binary), QUERY_TIMEOUT)['names']
        except (OSError, ValueError, TimeoutError, subprocess.TimeoutExpired):
            report['errors'].append('metadata_query_failed')
            return report
        bookkeeping = FULL_BOOKKEEPING if label == 'full' else SHARD_BOOKKEEPING
        duplicates = sorted(name for name, count in Counter(names).items() if count > 1)
        business = set(names) - bookkeeping
        products[label] = business
        report['inventories'][label] = {
            'total_count': len(names),
            'bookkeeping_count': sum(name in bookkeeping for name in names),
            'product_count': sum(name not in bookkeeping for name in names),
            'unique_product_count': len(business),
            'duplicates': duplicates,
        }
        if duplicates:
            report['errors'].append('duplicate_names')
        if not business:
            report['errors'].append('empty_product_inventory')
    owners = {}
    for label in SHARDS:
        for name in products[label]:
            owners.setdefault(name, []).append(label)
    union = set(owners)
    report['union_count'] = len(union)
    report['overlap'] = {name: owners[name] for name in sorted(owners) if len(owners[name]) > 1}
    report['missing'] = sorted(products['full'] - union)
    report['extra'] = sorted(union - products['full'])
    if report['overlap']:
        report['errors'].append('overlapping_shards')
    if report['missing']:
        report['errors'].append('missing_cases')
    if report['extra']:
        report['errors'].append('extra_cases')
    report['ok'] = not report['errors']
    return report


class SafeParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse's default error can echo arbitrary argument values.
        self.exit(2, 'shards: invalid arguments\n')


def main(argv=None):
    parser = SafeParser(description=__doc__)
    parser.add_argument('--full', required=True, metavar='BINARY')
    parser.add_argument('--shard', action='append', nargs=2, required=True,
                        metavar=('ID', 'BINARY'), help='repeat once for each of: ' + ', '.join(SHARDS))
    parser.add_argument('--output', metavar='JSON', help='optional new private JSON report')
    args = parser.parse_args(argv)
    report = verify(args.full, args.shard)
    if args.output:
        try:
            fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w', encoding='utf-8') as output:
                json.dump(report, output, ensure_ascii=True, indent=2)
                output.write('\n')
        except OSError:
            print('shards: report write failed', file=sys.stderr)
            return 1
    full_count = report['inventories'].get('full', {}).get('unique_product_count', 0)
    duplicate_count = sum(len(item['duplicates']) for item in report['inventories'].values())
    print('shards: ok={} full={} union={} missing={} extra={} overlaps={} duplicates={} errors={}'.format(
        report['ok'], full_count, report['union_count'], len(report['missing']), len(report['extra']),
        len(report['overlap']), duplicate_count, len(report['errors'])))
    if not report['ok']:
        print('shards: inventory verification failed', file=sys.stderr)
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    sys.exit(main())
