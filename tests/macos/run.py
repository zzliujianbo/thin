#!/usr/bin/env python3
"""Build/run standalone Darwin P0 probes without changing product build policy."""

import argparse
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time


def positive_int(value):
    count = int(value)
    if count < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return count


def stop_owned_group(process):
    # Observe without reaping: keep the leader PID reserved until the final
    # group signal. C probes get a grace period to clean their own child groups.
    try:
        os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    except ChildProcessError:
        return  # Ownership lost: never signal a possibly recycled PID/PGID.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT):
            break
        time.sleep(0.02)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)


def run_owned(command, *, timeout, env=None):
    process = subprocess.Popen(command, env=env, start_new_session=True)
    try:
        code = process.wait(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        stop_owned_group(process)
        raise
    if code:
        raise subprocess.CalledProcessError(code, command)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default=os.environ.get("CC", "zig cc"),
                        help="C compiler command (default: CC or 'zig cc')")
    parser.add_argument("--repeat", type=positive_int, default=1,
                        help="run each compiled probe this many times")
    parser.add_argument("--probe", choices=("all", "ipc", "process"), default="all")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("these independent probes require native macOS")
    if os.getuid() == 0 or os.getuid() != os.geteuid() or os.getgid() != os.getegid():
        parser.error("run as a non-root user with matching real/effective IDs")
    compiler = shlex.split(args.cc)
    if not compiler:
        parser.error("--cc must not be empty")
    directory = Path(__file__).resolve().parent
    names = ("ipc", "process") if args.probe == "all" else (args.probe,)
    try:
        # A short, canonical path fits sockaddr_un and lets Python remove IPC
        # fixtures even when a probe is terminated before its C cleanup runs.
        with tempfile.TemporaryDirectory(prefix="thin-p0-", dir="/private/tmp") as temporary:
            environment = dict(os.environ, THIN_MACOS_P0_TMPDIR=temporary)
            for name in names:
                binary = Path(temporary) / (name + "_probe")
                command = [*compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                           str(directory / (name + "_probe.c")), "-o", str(binary)]
                print("+", shlex.join(command), flush=True)
                run_owned(command, timeout=120)
                for iteration in range(1, args.repeat + 1):
                    print(f"[{name} {iteration}/{args.repeat}]", flush=True)
                    run_owned([str(binary)], timeout=45, env=environment)
    except KeyboardInterrupt:
        print("Darwin P0 probes interrupted; owned process group cleanup requested.", file=sys.stderr)
        return 130
    except (OSError, subprocess.SubprocessError) as error:
        print(f"Darwin P0 probe failed: {error}", file=sys.stderr)
        return 1
    print("All selected Darwin P0 probes passed (not a product compatibility gate).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
