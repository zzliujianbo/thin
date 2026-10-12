#!/usr/bin/env bash
# Isolated installer checks; never write to /usr/local/bin or invoke sudo.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
project="$fixture/project with spaces"
bin="$fixture/installed bin"
mkdir -p -- "$project" "$bin" "$fixture/fake tools"
cp -- "$root/install.sh" "$project/install.sh"
export REAL_INSTALL
REAL_INSTALL=$(command -v install)
export REAL_MV
REAL_MV=$(command -v mv)
export FIXTURE_PROJECT="$project"
export ZIG="$fixture/fake tools/zig"
export INSTALL_DIR="$bin"

cat > "$ZIG" <<'ZIG'
#!/usr/bin/env bash
set -euo pipefail
[[ $PWD == "$FIXTURE_PROJECT" ]]
[[ $# -eq 4 && $1 == build && $2 == -Doptimize=small && $3 == --prefix && $4 == "$PWD/zig-out/release" ]]
[[ ${FAIL_BUILD:-0} == 0 ]] || exit 42
mkdir -p -- "$4/bin"
printf '#!/bin/sh\nprintf "release-fixture\\n"\n' > "$4/bin/thin"
chmod 0755 "$4/bin/thin"
ZIG
cat > "$fixture/fake tools/install" <<'INSTALL'
#!/usr/bin/env bash
[[ ${FAIL_INSTALL:-0} == 0 ]] || exit 43
exec "$REAL_INSTALL" "$@"
INSTALL
cat > "$fixture/fake tools/mv" <<'MOVE'
#!/usr/bin/env bash
[[ ${FAIL_MOVE:-0} == 0 ]] || exit 44
exec "$REAL_MV" "$@"
MOVE
chmod 0755 "$ZIG" "$fixture/fake tools/install" "$fixture/fake tools/mv"
export PATH="$fixture/fake tools:$PATH"
# Fail closed if the test ever tries to elevate privileges.
cat > "$fixture/fake tools/sudo" <<'SUDO'
#!/bin/sh
exit 99
SUDO
chmod 0755 "$fixture/fake tools/sudo"

no_temps() {
    if compgen -G "$bin/.thin.*" >/dev/null; then
        printf 'Installer left a temporary file.\n' >&2
        exit 1
    fi
}
expect_failure() {
    if "$@" > "$fixture/failure.log" 2>&1; then
        printf 'Expected installer failure.\n' >&2
        exit 1
    fi
}

cd -- "$fixture"
ZIG=/does/not/exist "$project/install.sh" --help >/dev/null
expect_failure "$project/install.sh" unexpected-argument
expect_failure env INSTALL_DIR=relative "$project/install.sh"
[[ ! -e "$project/zig-out" ]]
printf 'previous-binary\n' > "$bin/thin"
expect_failure env ZIG=/does/not/exist "$project/install.sh"
expect_failure env FAIL_BUILD=1 "$project/install.sh"
[[ $(< "$bin/thin") == previous-binary ]]
no_temps
printf 'PASS installer preflight and build failure\n'

for fault in FAIL_INSTALL FAIL_MOVE; do
    expect_failure env "$fault=1" "$project/install.sh"
    [[ $(< "$bin/thin") == previous-binary ]]
    no_temps
done
printf 'PASS installer atomic failure and cleanup\n'

printf 'untouched-target\n' > "$fixture/symlink target"
ln -sf -- "$fixture/symlink target" "$bin/thin"
"$project/install.sh" >/dev/null
[[ ! -L "$bin/thin" && $(< "$fixture/symlink target") == untouched-target ]]
[[ $("$bin/thin") == release-fixture ]]
[[ $(stat -c '%a' -- "$bin/thin") == 755 ]]
no_temps
printf 'PASS installer paths, permissions and symlink replacement\n'
