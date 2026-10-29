#!/usr/bin/env python3
"""Small, offline-first entry point for the existing Zig build graph."""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
GROUPS = {"focus": "test-focus", "render": "test-render", "interaction": "test-interaction", "communication": "test-communication", "streaming": "test-streaming", "full": "test"}
STACK_BYTES = 32 * 1024 * 1024
CAP_DROP = "--drop=cap_dac_override,cap_dac_read_search"


def source_hash(root):
    digest = hashlib.sha256()
    paths = [root / "build.zig"]
    for directory in ("src", "tests"):
        base = root / directory
        if base.exists():
            paths.extend(p for p in base.rglob("*") if p.is_file() and "__pycache__" not in p.parts and not p.is_symlink())
    for path in sorted(paths, key=lambda p: p.relative_to(root).as_posix()):
        name = path.relative_to(root).as_posix().encode()
        data = path.read_bytes()
        digest.update(len(name).to_bytes(8, "big") + name + len(data).to_bytes(8, "big") + data)
    return digest.hexdigest()


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("group", choices=["preflight", *GROUPS])
    p.add_argument("--filter", help="required nonempty substring for focus only")
    p.add_argument("--ssh-include")
    p.add_argument("--ssh-library")
    p.add_argument("--optimize", choices=["Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"], default="Debug")
    p.add_argument("-j", "--jobs", type=int, default=1)
    return p


def parse_args(argv):
    p = parser()
    args = p.parse_args(argv)
    if args.jobs < 1:
        p.error("jobs must be positive")
    if args.group == "focus":
        if args.filter is None or not args.filter.strip():
            p.error("focus requires a nonempty --filter")
    elif args.filter is not None:
        p.error("--filter is only valid for focus")
    return args


def command_for(args):
    command = ["zig", "build", GROUPS[args.group], f"-j{args.jobs}", "-Doptimize=" + args.optimize, "--summary", "all"]
    if args.group == "focus":
        command.append("-Dtest-filter=" + args.filter)
    if args.ssh_include:
        command.append("-Dssh-include=" + args.ssh_include)
    if args.ssh_library:
        command.append("-Dssh-library=" + args.ssh_library)
    return command


def normalized_command(command, euid=None, which=shutil.which, limits=None):
    """Prepare only test children; preflight never calls this function."""
    if limits is None:
        limits = resource.getrlimit(resource.RLIMIT_STACK)
    _, hard = limits
    if hard != resource.RLIM_INFINITY and hard < STACK_BYTES:
        raise RuntimeError("stack hard limit is below required 32 MiB")
    if euid is None:
        euid = os.geteuid()
    if euid == 0:
        capsh = which("capsh")
        if not capsh:
            raise RuntimeError("capsh is required for root-run permission fixtures")
        # The command and each argument are positional parameters, never shell text.
        return [capsh, CAP_DROP, "--", "-c", 'exec "$@"', "thin-test", *command]
    return command


def set_child_stack():
    _, hard = resource.getrlimit(resource.RLIMIT_STACK)
    resource.setrlimit(resource.RLIMIT_STACK, (STACK_BYTES, hard))


def classify(code, text, focus=False):
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
    if code != 0:
        if re.search(r"\berror\.NoMatchingProductTests\b", text):
            return "no_matching_tests"
        if re.search(r"^FAIL application acceptance:", text, re.MULTILINE):
            return "fixture_failure"
        if re.search(r"(?i)(TestExpectedEqual|test .* failed|assertion.*failed|test failure|\b\d+ tests? failed\b|run test [^\n]*\b[1-9]\d* fail\b)", text):
            return "assertion_failure"
        return "build_or_infrastructure_or_unknown"
    if focus:
        counts = re.findall(r"\b(\d+)/(\d+) tests? passed\b", text)
        if not any(int(passed) > 0 and int(passed) == int(total) for passed, total in counts):
            return "no_positive_test_evidence"
    return "passed"


def python_syntax(root):
    for p in sorted((root / "tests").rglob("*.py")):
        if "__pycache__" not in p.parts:
            ast.parse(p.read_bytes(), filename=str(p.relative_to(root)))


def run(argv=None, root=ROOT, executor=subprocess.run):
    args = parse_args(argv)
    root = Path(root)
    log_root = root / ".zig-cache" / "workflow"
    log_root.mkdir(parents=True, exist_ok=True)
    run_dir = Path(tempfile.mkdtemp(prefix=args.group + "-", dir=log_root))
    log_path = run_dir / "stage.log"
    summary_path = run_dir / "summary.json"
    before = source_hash(root)
    stages = []
    outputs = []

    def stage(name, command, action):
        print("stage:", name, "command:", subprocess.list2cmdline(command), flush=True)
        start = time.monotonic()
        try:
            code, output = action()
        except (OSError, SyntaxError, UnicodeError, RuntimeError, subprocess.SubprocessError) as exc:
            code, output = 127, str(exc) + "\n"
        stages.append({"stage": name, "command": command, "duration_seconds": time.monotonic() - start, "exit_code": code})
        outputs.append("== " + name + " ==\n" + output)
        return code, output

    def execute(command, **kwargs):
        result = executor(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace", check=False, **kwargs)
        return result.returncode, result.stdout or ""

    if args.group == "preflight":
        def check_python():
            python_syntax(root)
            return 0, "Python AST syntax check passed\n"
        code, output = stage("python-syntax", ["python-ast.parse", "tests/**/*.py"], check_python)
        if code == 0:
            cmd = ["zig", "fmt", "--check", "build.zig", "src", "tests"]
            code, output = stage("zig-format", cmd, lambda: execute(cmd))
        if code == 0:
            for path in sorted((root / "tests").rglob("*.mjs")):
                cmd = ["node", "--check", path.relative_to(root).as_posix()]
                code, output = stage("node-syntax", cmd, lambda: execute(cmd))
                if code != 0:
                    break
        status = "passed" if code == 0 else "build_or_infrastructure_or_unknown"
    else:
        command = command_for(args)
        try:
            command = normalized_command(command)
        except RuntimeError as exc:
            def failed_normalization():
                raise RuntimeError(str(exc))
            # Execute inside the exception scope so its message remains available.
            code, output = stage("normalization", command, failed_normalization)
        else:
            code, output = stage(args.group, command, lambda: execute(command, preexec_fn=set_child_stack))
        status = classify(code, output, args.group == "focus")

    log_path.write_text("\n".join(outputs), encoding="utf-8")
    try:
        after = source_hash(root)
        if before != after:
            status = "source_changed"
    except OSError as exc:
        after = None
        status = "source_hash_error"
        with log_path.open("a", encoding="utf-8") as f:
            f.write("\nsource hashing failed: " + str(exc) + "\n")
    summary = {"stage": args.group, "stages": stages, "status": status, "source_hash_before": before, "source_hash_after": after, "log": str(log_path.relative_to(root))}
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print("status:", status, "log:", log_path, "summary:", summary_path, flush=True)
    return 0 if status == "passed" else 1


if __name__ == "__main__":
    sys.exit(run())
