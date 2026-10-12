#!/usr/bin/env bash
# Build a release binary, then atomically replace the installed executable.
set -euo pipefail

usage() {
    printf '%s\n' \
        'Usage: ./install.sh' \
        'Build with Zig 0.17.0 (-Doptimize=small) and install /usr/local/bin/thin.' \
        '' \
        'Environment:' \
        '  ZIG          Compiler executable (default: zig)' \
        '  INSTALL_DIR  Absolute installation directory (default: /usr/local/bin)' \
        '' \
        'Build output: zig-out/release/bin/thin' \
        'Build runs as the current user; sudo is used only if installation requires it.'
}

if [[ $# -eq 1 && ( $1 == --help || $1 == -h ) ]]; then
    usage
    exit 0
fi
if [[ $# -ne 0 ]]; then
    usage >&2
    exit 2
fi

zig_bin=${ZIG:-zig}
install_dir=${INSTALL_DIR:-/usr/local/bin}
if [[ $install_dir != /* ]]; then
    printf 'INSTALL_DIR must be an absolute path.\n' >&2
    exit 2
fi
if ! command -v "$zig_bin" >/dev/null 2>&1; then
    printf 'Zig 0.17.0 was not found. Set ZIG to its executable path.\n' >&2
    exit 1
fi

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd -- "$project_dir"
prefix="$project_dir/zig-out/release"
printf 'Building release (small)...\n'
"$zig_bin" build -Doptimize=small --prefix "$prefix"
artifact="$prefix/bin/thin"
if [[ ! -f $artifact || ! -x $artifact ]]; then
    printf 'Build did not produce an executable: %s\n' "$artifact" >&2
    exit 1
fi

privilege=()
if ! mkdir -p -- "$install_dir" 2>/dev/null || [[ ! -w $install_dir ]]; then
    if [[ $EUID -eq 0 ]] || ! command -v sudo >/dev/null 2>&1; then
        printf 'Cannot write to %s; use a writable INSTALL_DIR or install with administrator privileges.\n' "$install_dir" >&2
        exit 1
    fi
    privilege=(sudo)
    "${privilege[@]}" mkdir -p -- "$install_dir"
fi

temporary=''
cleanup() {
    if [[ -n $temporary ]]; then
        "${privilege[@]}" rm -f -- "$temporary" || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# A same-directory rename keeps the previous binary intact if copying fails,
# and supports replacing an executable that an existing process is still using.
temporary=$("${privilege[@]}" mktemp -- "$install_dir/.thin.XXXXXX")
"${privilege[@]}" install -m 0755 -- "$artifact" "$temporary"
"${privilege[@]}" mv -fT -- "$temporary" "$install_dir/thin"
temporary=''
printf 'Installed: %s/thin\n' "$install_dir"
