#!/usr/bin/env bash
# Build a release binary, then atomically replace the installed executable.
set -euo pipefail

usage() {
    printf '%s\n' \
        'Usage: ./install.sh' \
        'Build with Zig 0.17.0 (-Doptimize=small) and install /usr/local/bin/thin.' \
        'Create t -> thin in the same directory (without changing shell configuration).' \
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

# The one-letter entry must not overwrite an unrelated command. A relative
# target keeps it paired with thin when INSTALL_DIR contains spaces or moves.
alias_path="$install_dir/t"
check_alias() {
    if "${privilege[@]}" test -e "$alias_path" || "${privilege[@]}" test -L "$alias_path"; then
        if ! "${privilege[@]}" test -L "$alias_path" || [[ $("${privilege[@]}" readlink -- "$alias_path") != thin ]]; then
            printf 'Refusing to replace an unrelated command: %s\n' "$alias_path" >&2
            return 1
        fi
    fi
}
check_alias

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
# Publish without replacing anything: a check followed by rename could clobber
# an unrelated t created between those operations. On collision, accept only a
# currently verified relative link (including a dangling one) to thin.
# Do this before replacing the binary so alias failure preserves that binary.
if ! "${privilege[@]}" ln -sT -- thin "$alias_path" 2>/dev/null; then
    if ! "${privilege[@]}" test -L "$alias_path" || [[ $("${privilege[@]}" readlink -- "$alias_path") != thin ]]; then
        printf 'Cannot create alias without replacing an unrelated command: %s\n' "$alias_path" >&2
        exit 1
    fi
fi
"${privilege[@]}" mv -fT -- "$temporary" "$install_dir/thin"
temporary=''
printf 'Installed: %s/thin\nAlias: %s/t -> thin\n' "$install_dir" "$install_dir"
