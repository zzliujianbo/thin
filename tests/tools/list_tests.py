#!/usr/bin/env python3
"""Inventory a Zig 0.17 standard test runner without executing tests."""
import argparse
import json
import os
import selectors
import struct
import subprocess
import sys
import time

MAX_OUTPUT = 64 * 1024 * 1024
MAX_TESTS = 1_000_000
HEADER = struct.Struct('<II')


def parse(data):
    def message(pos, expected):
        if len(data) - pos < 8:
            raise ValueError('truncated message header')
        tag, length = HEADER.unpack_from(data, pos)
        pos += 8
        if tag != expected or length > MAX_OUTPUT or length > len(data) - pos:
            raise ValueError('unexpected tag or invalid message length')
        return data[pos:pos + length], pos + length

    version, pos = message(0, 0)
    version = version.decode('utf-8')
    if not version.startswith('0.17.0'):
        raise ValueError('unsupported Zig version')
    body, pos = message(pos, 3)
    if pos != len(data) or len(body) < 8:
        raise ValueError('unexpected trailing bytes or short metadata')
    strings_len, count = HEADER.unpack_from(body)
    if count > MAX_TESTS or 8 + 8 * count + strings_len != len(body):
        raise ValueError('invalid metadata sizes')
    table = body[8 + 8 * count:]
    if not table or table[0] != 0:
        raise ValueError('invalid string table')
    names = []
    for i in range(count):
        offset = struct.unpack_from('<I', body, 8 + 4 * i)[0]
        if offset == 0 or offset >= len(table) or table[offset - 1] != 0:
            raise ValueError('invalid name offset')
        end = table.find(b'\0', offset)
        if end < 0 or end == offset:
            raise ValueError('unterminated or empty name')
        names.append(table[offset:end].decode('utf-8'))
    return {'zig_version': version, 'count': count, 'unique_count': len(set(names)), 'names': names}


def inventory(binary, timeout):
    if not 0 < timeout <= 300:
        raise ValueError('timeout must be in (0, 300] seconds')
    deadline = time.monotonic() + timeout
    proc = subprocess.Popen([binary, '--listen=-'], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
    try:
        # Fixed messages only: query_test_metadata, then exit. Never run_test.
        proc.stdin.write(HEADER.pack(4, 0) + HEADER.pack(0, 0))
        proc.stdin.close()
        chunks = bytearray()
        with selectors.DefaultSelector() as sel:
            os.set_blocking(proc.stdout.fileno(), False)
            sel.register(proc.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not sel.select(remaining):
                    raise TimeoutError('metadata response timed out')
                part = os.read(proc.stdout.fileno(), 65536)
                if not part:
                    break
                chunks.extend(part)
                if len(chunks) > MAX_OUTPUT:
                    raise ValueError('metadata response exceeds limit')
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('runner exit timed out')
        if proc.wait(timeout=remaining) != 0:
            raise ValueError('runner exited unsuccessfully')
        return parse(chunks)
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        proc.stdout.close()
        if not proc.stdin.closed:
            proc.stdin.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', help='path to compiled Zig test binary')
    parser.add_argument('--timeout', type=float, default=30)
    parser.add_argument('--output', required=True, help='JSON inventory output path')
    args = parser.parse_args()
    try:
        result = inventory(os.path.abspath(args.binary), args.timeout)
        with open(args.output, 'w', encoding='utf-8') as f:
            json.dump(result, f, ensure_ascii=False, indent=2)
            f.write('\n')
        print(f"tests={result['count']} unique={result['unique_count']}")
    except (OSError, ValueError, TimeoutError, subprocess.TimeoutExpired):
        # Child output, paths and exception text may contain private data.
        print('inventory: metadata query failed', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
