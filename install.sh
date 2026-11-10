#!/usr/bin/env bash
# Build a release binary, then atomically replace the installed executable.
set -euo pipefail

usage() {
    printf '%s\n' \
        'Usage: ./install.sh' \
        'Build with Zig 0.17.0 (-Doptimize=small) and install /usr/local/bin/thin.' \
        'Supports Linux x86_64 and Intel macOS (local mode; requires system Perl).' \
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

platform=$(uname -s)
perl_bin=''
case $platform in
    Linux) ;;
    Darwin)
        if [[ $(uname -m) != x86_64 ]]; then
            printf 'The macOS installer supports Intel (x86_64) only.\n' >&2
            exit 1
        fi
        if ! perl_bin=$(command -v perl); then
            printf 'macOS installation requires system Perl for atomic file publication.\n' >&2
            exit 1
        fi
        ;;
    *) printf 'Installation supports Linux x86_64 and Intel macOS only.\n' >&2; exit 1 ;;
esac

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

# Empty array expansion under `set -u` fails in macOS's system Bash 3.2.
use_sudo=0
run_install() {
    if [[ $use_sudo == 1 ]]; then sudo "$@"; else "$@"; fi
}
if ! mkdir -p -- "$install_dir" 2>/dev/null || [[ ! -w $install_dir ]]; then
    if [[ $EUID -eq 0 ]] || ! command -v sudo >/dev/null 2>&1; then
        printf 'Cannot write to %s; use a writable INSTALL_DIR or install with administrator privileges.\n' "$install_dir" >&2
        exit 1
    fi
    use_sudo=1
    run_install mkdir -p -- "$install_dir"
fi

# The one-letter entry must not overwrite an unrelated command. A relative
# target keeps it paired with thin when INSTALL_DIR contains spaces or moves.
alias_path="$install_dir/t"
check_alias() {
    if run_install test -e "$alias_path" || run_install test -L "$alias_path"; then
        if ! run_install test -L "$alias_path" || [[ $(run_install readlink "$alias_path") != thin ]]; then
            printf 'Refusing to replace an unrelated command: %s\n' "$alias_path" >&2
            return 1
        fi
    fi
}
check_alias

temporary=''
cleanup() {
    if [[ -n $temporary ]]; then
        run_install rm -f -- "$temporary" || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# A same-directory rename keeps the previous binary intact if copying fails,
# and supports replacing an executable that an existing process is still using.
temporary=$(run_install mktemp "$install_dir/.thin.XXXXXX")
run_install install -m 0755 "$artifact" "$temporary"

# BSD ln/mv lack GNU -T: plain -h still treats a real destination directory as
# a container, including one raced into place. Perl's symlink/rename builtins
# operate on the exact destination leaf, preserving the Linux -T semantics.
publish_alias() {
    if [[ $platform == Darwin ]]; then
        run_install "$perl_bin" -e 'symlink($ARGV[0], $ARGV[1]) or die "symlink: $!\n";' -- thin "$alias_path"
    else
        run_install ln -sT -- thin "$alias_path"
    fi
}
publish_binary() {
    if [[ $platform == Darwin ]]; then
        run_install "$perl_bin" -e 'rename($ARGV[0], $ARGV[1]) or die "rename: $!\n";' -- "$temporary" "$install_dir/thin"
    else
        run_install mv -fT -- "$temporary" "$install_dir/thin"
    fi
}
# Publish without replacing anything: a check followed by rename could clobber
# an unrelated t created between those operations. On collision, accept only a
# currently verified relative link (including a dangling one) to thin.
# Do this before replacing the binary so alias failure preserves that binary.
if ! publish_alias 2>/dev/null; then
    if ! run_install test -L "$alias_path" || [[ $(run_install readlink "$alias_path") != thin ]]; then
        printf 'Cannot create alias without replacing an unrelated command: %s\n' "$alias_path" >&2
        exit 1
    fi
fi
publish_binary
temporary=''
printf 'Installed: %s/thin\nAlias: %s/t -> thin\n' "$install_dir" "$install_dir"
