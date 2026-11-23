"""Post-test watermarks for runner-owned Zig caches. Keep manifests with outputs."""
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import re
import shutil
import subprocess

HIGH = 6 << 30
LOW = 4 << 30
MARK = '.thin-test-cache-v1'


def generation(base, number):
    p = base / f'g{number:08d}'
    try:
        p.mkdir(mode=0o700)
    except FileExistsError:
        pass
    else:
        (p / MARK).touch(mode=0o600)
    return p


def generations(base):
    return sorted(p for p in base.iterdir() if re.fullmatch(r'g[0-9]{8}', p.name))


def owned(p):
    return p.resolve() == p and p.is_dir() and not (p / MARK).is_symlink() and (p / MARK).is_file()


def allocated(p):
    # Do not cross mount points or dereference symlinks.
    out = subprocess.check_output(['du', '-skx', str(p)], timeout=60)
    return int(out.split()[0]) * 1024


def idle(p):
    # Unknown command, timeout, permission warning etc. => retain. Other
    # runner builds additionally hold a shared lock for their full lifetime.
    for cmd in (['pgrep', '-x', 'zig'], ['lsof', '-nP', '-t', '+D', str(p)]):
        r = subprocess.run(cmd, capture_output=True, timeout=30)
        if r.returncode != 1 or r.stderr or r.stdout:
            return False
    # A stopped local container may still need its bind source on restart.
    sock = Path('/var/run/docker.sock')
    if sock.exists():
        docker = ['docker', '--host', 'unix:///var/run/docker.sock']
        ids = subprocess.check_output(docker + ['ps', '-aq'], timeout=10).split()
        if ids:
            sources = subprocess.check_output(docker + ['inspect', '--format', '{{range .Mounts}}{{println .Source}}{{end}}', *ids], timeout=15)
            for raw in sources.splitlines():
                if raw:
                    source = Path(os.fsdecode(raw))
                    if p.is_relative_to(source) or source.is_relative_to(p):
                        return False
    return True


def mounted(p):
    if os.path.exists('/proc/self/mountinfo'):
        # ismount() alone misses same-device bind mounts (including single files).
        for line in Path('/proc/self/mountinfo').read_bytes().splitlines():
            name = re.sub(rb'\\\\([0-7]{3})', lambda m: bytes([int(m[1], 8)]), line.split()[4])
            if Path(os.fsdecode(name)).is_relative_to(p):
                return True
        return False
    return p.is_mount() or any((Path(parent) / d).is_mount() for parent, ds, _ in os.walk(p) for d in ds)


def trim(base, current, *, high=HIGH, low=LOW, unused=idle):
    dirs = generations(base)
    if current not in dirs or not all(owned(p) for p in dirs):
        return
    sizes = {p: allocated(p) for p in dirs}
    total = sum(sizes.values())
    if total <= high:
        return
    for p in dirs:
        if p == current or p == dirs[-1] or total <= low:
            continue
        # No custom payload, package store or mounted subtree in a retired cache.
        if any(q.name not in {MARK, 'o', 'h', 'z', 'b', 'c', 'tmp', 'generated-tests'} for q in p.iterdir()):
            continue
        if not unused(p) or not owned(p):
            continue
        if mounted(p):
            continue
        shutil.rmtree(p)
        total -= sizes[p]
        print(f'cache: retired {p.name} ({sizes[p] / 2**30:.2f} GiB)', flush=True)
    # Never remove the cache that produced this run. If it alone is already
    # over budget, hand the next build a fresh cache, then retire this one.
    if current == dirs[-1] and sizes[current] > high and not any(p.exists() for p in dirs[:-1]):
        generation(base, int(current.name[1:]) + 1)


@contextmanager
def managed(root):
    base = root / '.zig-cache' / 'test-builds'
    if os.environ.get('ZIG_LOCAL_CACHE_DIR') or base.resolve() != base:
        yield None
        return
    base.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(fd, fcntl.LOCK_SH)
        dirs = generations(base)
        current = dirs[-1] if dirs else generation(base, 0)
        if not owned(current):
            yield None
            return
        yield current
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            trim(base, current)
        except BlockingIOError:
            pass
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            print(f'cache: cleanup skipped ({type(exc).__name__})', flush=True)
    finally:
        os.close(fd)
