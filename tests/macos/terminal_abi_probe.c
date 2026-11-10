/* Header-backed checks for the explicit Zig libc ABI. No user terminal is used.
 * Zig 0.17 has no @cImport; these compile-time assertions independently check
 * the small constant/layout surface in platform/{terminal_abi,posix_terminal}.
 */
#define _DEFAULT_SOURCE 1
#define _DARWIN_C_SOURCE 1
#include <stddef.h>
#include <stdio.h>
#include <locale.h>
#include <fcntl.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <util.h>
_Static_assert(sizeof(struct termios) == 72, "Darwin termios size");
_Static_assert(_Alignof(struct termios) == 8, "Darwin termios alignment");
_Static_assert(NCCS == 20 && offsetof(struct termios, c_cc) == 32, "Darwin cc layout");
_Static_assert(offsetof(struct termios, c_ispeed) == 56 && offsetof(struct termios, c_ospeed) == 64, "Darwin speed layout");
_Static_assert(TIOCGWINSZ == 0x40087468UL && TIOCSWINSZ == 0x80087467UL, "Darwin window requests");
_Static_assert(TCOOFF == 1 && TCOON == 2, "Darwin flow actions");
_Static_assert(LC_CTYPE == 2 && LC_NUMERIC == 4, "Darwin locale categories");
#elif defined(__linux__) && defined(__x86_64__)
#include <pty.h>
_Static_assert(sizeof(struct termios) == 60, "glibc termios size");
_Static_assert(_Alignof(struct termios) == 4, "glibc termios alignment");
_Static_assert(NCCS == 32 && offsetof(struct termios, c_cc) == 17, "glibc cc layout");
_Static_assert(offsetof(struct termios, c_ispeed) == 52 && offsetof(struct termios, c_ospeed) == 56, "glibc speed layout");
_Static_assert(TIOCGWINSZ == 0x5413 && TIOCSWINSZ == 0x5414, "Linux window requests");
_Static_assert(TCOOFF == 0 && TCOON == 1, "Linux flow actions");
_Static_assert(LC_CTYPE == 0 && LC_NUMERIC == 1, "Linux locale categories");
#else
#error "probe supports macOS and Linux x86_64 glibc only"
#endif
_Static_assert(sizeof(struct winsize) == 8 && _Alignof(struct winsize) == 2, "winsize ABI");
_Static_assert(offsetof(struct winsize, ws_row) == 0 && offsetof(struct winsize, ws_col) == 2, "winsize fields");

int main(void) {
    int master = -1, slave = -1, result = 1;
    int flags = -1, restored_flags = -1;
    struct termios original, raw, restored;
    if (openpty(&master, &slave, NULL, NULL, NULL) != 0) { perror("openpty"); return 1; }
    flags = fcntl(slave, F_GETFL);
    if (flags < 0 || fcntl(slave, F_SETFL, flags | O_NONBLOCK) != 0 ||
        write(slave, "x", 1) != 1 || fcntl(slave, F_SETFL, flags) != 0) goto cleanup;
    restored_flags = fcntl(slave, F_GETFL);
    if (restored_flags < 0) goto cleanup;
#if defined(__APPLE__)
    /* XNU FWASWRITTEN is kernel-maintained history, not an F_SETFL option. */
    if ((flags ^ restored_flags) & ~0x00010000) goto cleanup;
    printf("PASS libc fcntl restoration (flags diff=0x%x; FWASWRITTEN=0x10000)\n", flags ^ restored_flags);
#else
    if (flags != restored_flags) goto cleanup;
#endif
    if (tcgetattr(slave, &original) != 0) goto cleanup;
    raw = original;
    cfmakeraw(&raw);
    if (tcsetattr(slave, TCSANOW, &raw) != 0 ||
        tcsetattr(slave, TCSANOW, &original) != 0 || tcgetattr(slave, &restored) != 0) goto cleanup;
    tcflag_t difference = original.c_lflag ^ restored.c_lflag;
#if defined(__APPLE__)
    /* Darwin marks canonical-input reprocessing pending on raw -> canonical.
     * It is kernel state, not an application configuration bit to erase. */
    if (difference & ~((tcflag_t)PENDIN)) goto cleanup;
    printf("PASS SDK ABI and libc raw roundtrip (lflag diff=0x%llx; PENDIN=0x%llx)\n",
           (unsigned long long)difference, (unsigned long long)PENDIN);
#else
    if (difference != 0) goto cleanup;
    puts("PASS SDK ABI and libc raw roundtrip");
#endif
    result = 0;
cleanup:
    if (result) perror("FAIL libc terminal roundtrip");
    close(slave);
    close(master);
    return result;
}
