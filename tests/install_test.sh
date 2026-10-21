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
export REAL_LN
REAL_LN=$(command -v ln)
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
printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "${FIXTURE_RELEASE:-release-fixture}" > "$4/bin/thin"
chmod 0755 "$4/bin/thin"
ZIG
cat > "$fixture/fake tools/install" <<'INSTALL'
#!/usr/bin/env bash
[[ ${FAIL_INSTALL:-0} == 0 ]] || exit 43
exec "$REAL_INSTALL" "$@"
INSTALL
cat > "$fixture/fake tools/mv" <<'MOVE'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${RACE_ALIAS:-} != '' && ${!#} == "$INSTALL_DIR/t" ]]; then
    source "$RACE_HOOK" mv
fi
[[ ${FAIL_MOVE:-0} == 0 ]] || exit 44
if [[ ${FAIL_BINARY_MOVE:-0} != 0 && ${!#} == "$INSTALL_DIR/thin" ]]; then exit 45; fi
exec "$REAL_MV" "$@"
MOVE
cat > "$fixture/fake tools/ln" <<'LINK'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${RACE_ALIAS:-} != '' && ${!#} == "$INSTALL_DIR/t" ]]; then
    source "$RACE_HOOK" ln
fi
[[ ${FAIL_LINK:-0} == 0 ]] || exit 46
exec "$REAL_LN" "$@"
LINK
chmod 0755 "$ZIG" "$fixture/fake tools/install" "$fixture/fake tools/mv" "$fixture/fake tools/ln"
export PATH="$fixture/fake tools:$PATH"
# Fail closed if the test ever tries to elevate privileges.
cat > "$fixture/fake tools/sudo" <<'SUDO'
#!/bin/sh
exit 99
SUDO
chmod 0755 "$fixture/fake tools/sudo"

# Both publication implementations must hit this hook: old staged mv and new ln.
export RACE_HOOK="$fixture/race-hook"
cat > "$RACE_HOOK" <<'RACE'
[[ ! -e "$INSTALL_DIR/t" && ! -L "$INSTALL_DIR/t" ]]
case $RACE_ALIAS in
    file) printf 'racing-command\n' > "$INSTALL_DIR/t" ;;
    link) "$REAL_LN" -sT -- "$RACE_TARGET" "$INSTALL_DIR/t" ;;
    *) exit 97 ;;
esac
printf '%s\n' "$1" > "$RACE_MARKER"
RACE

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

for fault in FAIL_INSTALL FAIL_MOVE FAIL_LINK FAIL_BINARY_MOVE; do
    rm -f -- "$bin/t"
    expect_failure env "$fault=1" "$project/install.sh"
    [[ $(< "$bin/thin") == previous-binary ]]
    no_temps
done
printf 'PASS installer atomic failure and cleanup\n'

race_failed=0
for kind in file link; do
    rm -f -- "$bin/t"
    printf 'previous-binary\n' > "$bin/thin"
    target="$fixture/racing target"
    marker="$fixture/race-$kind.marker"
    printf 'untouched-racing-target\n' > "$target"
    status=0
    env RACE_ALIAS="$kind" RACE_TARGET="$target" RACE_MARKER="$marker" \
        "$project/install.sh" > "$fixture/race-$kind.log" 2>&1 || status=$?
    [[ -f $marker ]] || { printf 'Race hook did not run: %s\n' "$kind" >&2; exit 1; }
    hook=$(< "$marker")
    [[ $hook == mv || $hook == ln ]]
    printf 'RACE hook=%s kind=%s installer_status=%s\n' "$hook" "$kind" "$status"
    preserved=0
    if [[ $kind == file ]]; then
        if [[ -f "$bin/t" && ! -L "$bin/t" && $(< "$bin/t") == racing-command ]]; then preserved=1; fi
    elif [[ -L "$bin/t" && $(readlink -- "$bin/t") == "$target" ]]; then
        preserved=1
    fi
    [[ $(< "$target") == untouched-racing-target ]]
    no_temps
    if [[ $status == 0 || $preserved == 0 || $(< "$bin/thin") != previous-binary ]]; then
        printf 'FAIL race %s: must reject publish and preserve unrelated t and previous binary (t_preserved=%s).\n' "$kind" "$preserved" >&2
        race_failed=1
    fi
done
[[ $race_failed == 0 ]] || exit 1
rm -f -- "$bin/t"
printf 'PASS installer atomic alias race refusal (file and symlink)\n'

rm -f -- "$bin/t"
printf 'unrelated-command\n' > "$bin/t"
expect_failure "$project/install.sh"
[[ $(< "$bin/t") == unrelated-command && $(< "$bin/thin") == previous-binary ]]
no_temps
rm -- "$bin/t"
printf 'unrelated-link-target\n' > "$fixture/other command"
ln -s -- "$fixture/other command" "$bin/t"
expect_failure "$project/install.sh"
[[ $(readlink -- "$bin/t") == "$fixture/other command" && $(< "$fixture/other command") == unrelated-link-target ]]
[[ $(< "$bin/thin") == previous-binary ]]
no_temps
rm -- "$bin/t"
printf 'PASS installer refuses unrelated t files and links\n'

printf 'untouched-target\n' > "$fixture/symlink target"
ln -sf -- "$fixture/symlink target" "$bin/thin"
"$project/install.sh" >/dev/null
[[ ! -L "$bin/thin" && $(< "$fixture/symlink target") == untouched-target ]]
[[ $("$bin/thin") == release-fixture ]]
[[ $(stat -c '%a' -- "$bin/thin") == 755 ]]
no_temps
[[ -L "$bin/t" && $(readlink -- "$bin/t") == thin ]]
[[ $("$bin/t") == release-fixture ]]
printf 'PASS installer paths, permissions and symlink replacement\n'

FIXTURE_RELEASE=release-upgraded "$project/install.sh" >/dev/null
[[ $("$bin/thin") == release-upgraded && $("$bin/t") == release-upgraded ]]
[[ $(readlink -- "$bin/t") == thin ]]
no_temps
printf 'PASS installer repeated upgrade keeps t paired with thin\n'

rm -- "$bin/thin"
[[ -L "$bin/t" && ! -e "$bin/t" && $(readlink -- "$bin/t") == thin ]]
FIXTURE_RELEASE=release-from-dangling "$project/install.sh" >/dev/null
[[ $(readlink -- "$bin/t") == thin && $("$bin/t") == release-from-dangling ]]
no_temps
printf 'PASS installer accepts existing dangling t -> thin\n'
