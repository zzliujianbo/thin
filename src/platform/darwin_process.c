/* Darwin-only process ABI boundary. No fork and no child-side Zig execution.
 * The caller owns all descriptors and keeps the direct child unreaped until
 * AFTER its final group signal. Build this file only for Darwin targets. */
#define _DARWIN_C_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <termios.h>
#include <libproc.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* Do not confuse this with POSIX_SPAWN_START_SUSPENDED (0x0080). */
_Static_assert(POSIX_SPAWN_CLOEXEC_DEFAULT == 0x4000, "spawn allowlist flag ABI");

/* Returns a POSIX error number; on failure no PID ownership is transferred.
 * All setup is in the parent. The kernel executes the file actions/attributes.
 * dir_fd is always an opened directory, never a replaceable cwd pathname.
 * inherited descriptors retain their numbers, even if initially FD_CLOEXEC. */
int thin_darwin_process_spawn(pid_t *pid, const char *executable,
                             char *const argv[], char *const envp[],
                             int dir_fd, int input_fd, int output_fd, int error_fd,
                             const int *inherited, size_t inherited_count)
{
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int rc = posix_spawn_file_actions_init(&actions);
    if (rc != 0)
        return rc;
    rc = posix_spawnattr_init(&attributes);
    if (rc != 0) {
        (void)posix_spawn_file_actions_destroy(&actions);
        return rc;
    }
#define SETUP(call) do { rc = (call); if (rc != 0) goto out; } while (0)
    sigset_t empty, defaults;
    if (sigemptyset(&empty) != 0 || sigfillset(&defaults) != 0 ||
        sigdelset(&defaults, SIGKILL) != 0 || sigdelset(&defaults, SIGSTOP) != 0) {
        rc = errno;
        goto out;
    }
    SETUP(posix_spawnattr_setsigmask(&attributes, &empty));
    SETUP(posix_spawnattr_setsigdefault(&attributes, &defaults));
    SETUP(posix_spawnattr_setpgroup(&attributes, 0));
    SETUP(posix_spawnattr_setflags(&attributes,
        POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK |
        POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP));
    SETUP(posix_spawn_file_actions_adddup2(&actions, input_fd, STDIN_FILENO));
    SETUP(posix_spawn_file_actions_adddup2(&actions, output_fd, STDOUT_FILENO));
    SETUP(posix_spawn_file_actions_adddup2(&actions, error_fd, STDERR_FILENO));
    /* The _np API is available since 10.15, unlike the macOS 26 POSIX spelling.
     * It marks a file-action source, NOT an exec allowlist member. Close the
     * temporary sources explicitly so no file-action implementation detail can
     * accidentally carry them through exec. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    SETUP(posix_spawn_file_actions_addfchdir_np(&actions, dir_fd));
#pragma clang diagnostic pop
    SETUP(posix_spawn_file_actions_addclose(&actions, dir_fd));
    SETUP(posix_spawn_file_actions_addclose(&actions, input_fd));
    SETUP(posix_spawn_file_actions_addclose(&actions, output_fd));
    SETUP(posix_spawn_file_actions_addclose(&actions, error_fd));
    for (size_t i = 0; i < inherited_count; ++i) {
        if (inherited[i] <= STDERR_FILENO) {
            rc = EINVAL;
            goto out;
        }
        SETUP(posix_spawn_file_actions_addinherit_np(&actions, inherited[i]));
    }
    rc = posix_spawn(pid, executable, &actions, &attributes, argv, envp);
out:
    (void)posix_spawnattr_destroy(&attributes);
    (void)posix_spawn_file_actions_destroy(&actions);
    return rc;
#undef SETUP
}

/* Darwin's indirect /dev/tty device reports POLLNVAL to poll. Open a fresh
 * description of the kernel-reported controlling tty node instead, without
 * changing inherited stdio flags. Do not accept another terminal merely
 * because stdin is a tty: prove its session, foreground group and identity.
 * C owns ttyname_r's UNIX03 symbol alias as well as the stat ABI. */
int thin_darwin_terminal_open(void)
{
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
        errno = ENOTTY;
        return -1;
    }
    pid_t session = getsid(0);
    pid_t group = getpgrp();
    if (session < 0 || tcgetsid(STDIN_FILENO) != session ||
        tcgetpgrp(STDIN_FILENO) != group) {
        errno = EPERM;
        return -1;
    }
    char name[PATH_MAX];
    int rc = ttyname_r(STDIN_FILENO, name, sizeof name);
    if (rc != 0) {
        errno = rc;
        return -1;
    }
    int fd = open(name, O_RDWR | O_NOCTTY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return -1;
    struct stat original, opened;
    if (fstat(STDIN_FILENO, &original) != 0 || fstat(fd, &opened) != 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    if (!S_ISCHR(original.st_mode) || !S_ISCHR(opened.st_mode) ||
        original.st_dev != opened.st_dev || original.st_ino != opened.st_ino ||
        original.st_rdev != opened.st_rdev || tcgetsid(fd) != session ||
        tcgetpgrp(fd) != group) {
        close(fd);
        errno = EPERM;
        return -1;
    }
    return fd;
}

/* WNOWAIT is essential: observing exit must not release PID/PGID ownership. */
int thin_darwin_process_observed_exit(pid_t pid)
{
    siginfo_t info;
    memset(&info, 0, sizeof(info));
    if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) < 0)
        return -1;
    if (info.si_pid == 0)
        return 0;
    if (info.si_pid != pid) {
        errno = EPROTO;
        return -1;
    }
    return 1;
}

pid_t thin_darwin_process_reap(pid_t pid, int *status)
{
    return waitpid(pid, status, WNOHANG);
}

static int64_t monotonic_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0)
        return -1;
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int before_deadline(int64_t end)
{
    int64_t now = monotonic_ms();
    if (now < 0)
        return -1;
    if (now >= end) {
        errno = ETIMEDOUT;
        return -1;
    }
    return 0;
}

/* libproc reports 0/ESRCH for unreaped Darwin zombies. Never interpret that
 * as death: demand a complete sysctl kernel record with the same PID. */
static int member_info(pid_t pid, struct proc_bsdinfo *info)
{
    memset(info, 0, sizeof(*info));
    errno = 0;
    int bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, (int)sizeof(*info));
    if (bytes == (int)sizeof(*info))
        return 0;
    if (bytes != 0 || errno != ESRCH) {
        if (bytes != 0 || errno == 0)
            errno = EPROTO;
        return -1;
    }
    int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    struct kinfo_proc kernel;
    memset(&kernel, 0, sizeof(kernel));
    size_t size = sizeof(kernel);
    if (sysctl(mib, 4, &kernel, &size, NULL, 0) < 0)
        return -1;
    if (size != sizeof(kernel) || kernel.kp_proc.p_pid != pid) {
        errno = ESRCH;
        return -1;
    }
    info->pbi_pid = (uint32_t)kernel.kp_proc.p_pid;
    info->pbi_ppid = (uint32_t)kernel.kp_eproc.e_ppid;
    info->pbi_pgid = (uint32_t)kernel.kp_eproc.e_pgid;
    info->pbi_status = (uint32_t)kernel.kp_proc.p_stat;
    info->pbi_start_tvsec = (uint64_t)kernel.kp_proc.p_starttime.tv_sec;
    info->pbi_start_tvusec = (uint64_t)kernel.kp_proc.p_starttime.tv_usec;
    return 0;
}

struct process_birth {
    uint64_t seconds;
    uint64_t microseconds;
};

static int compare_pid(const void *a, const void *b)
{
    pid_t x = *(const pid_t *)a, y = *(const pid_t *)b;
    return (x > y) - (x < y);
}

/* Returns PID COUNT, not bytes. Full capacity is ambiguous, never complete. */
static int list_group(pid_t pgid, pid_t *pids, size_t capacity)
{
    errno = 0;
    int count = proc_listpgrppids(pgid, pids, (int)(capacity * sizeof(*pids)));
    if (count < 0 || (count == 0 && errno != 0)) {
        if (errno == 0)
            errno = EIO;
        return -1;
    }
    return count;
}

/* 1 = some member may execute/fork, 0 = verified zombie-only owned group,
 * -1 = indeterminate (including missing pinned leader, ESRCH, short metadata,
 * permission failure, truncation, and deadline). Caller must fail closed.
 * Every retry and metadata syscall shares ONE deadline: sustained fork churn
 * cannot reset the budget. Memory and sorting are also capped (65536 PIDs).
 * Only query groups whose direct leader is still owned and unreaped. */
int thin_darwin_process_group_alive(pid_t pgid, uint32_t remaining_ms)
{
    if (pgid <= 1) {
        errno = EINVAL;
        return -1;
    }
    int64_t now = monotonic_ms();
    if (now < 0)
        return -1;
    int64_t end = now + remaining_ms;
    size_t capacity = 64;
    pid_t *pids = NULL, *verify = NULL;
    struct process_birth *births = NULL;
    int result = -1;
    for (;;) {
        if (before_deadline(end) < 0)
            goto out;
        pid_t *grown = realloc(pids, capacity * sizeof(*pids));
        if (grown == NULL) {
            errno = ENOMEM;
            goto out;
        }
        pids = grown;
        int count = list_group(pgid, pids, capacity);
        if (before_deadline(end) < 0 || count < 0)
            goto out;
        if ((size_t)count >= capacity) {
            if (capacity >= 65536) {
                errno = EOVERFLOW;
                goto out;
            }
            capacity *= 2;
            continue;
        }
        if (count == 0) {
            errno = ESRCH; /* The unreaped leader must remain visible. */
            goto out;
        }
        births = malloc((size_t)count * sizeof(*births));
        if (births == NULL) {
            errno = ENOMEM;
            goto out;
        }
        bool leader_seen = false;
        qsort(pids, (size_t)count, sizeof(*pids), compare_pid);
        for (int i = 0; i < count; ++i) {
            if (before_deadline(end) < 0)
                goto out;
            if (pids[i] <= 0 || (i > 0 && pids[i] == pids[i - 1])) {
                errno = EPROTO;
                goto out;
            }
            struct proc_bsdinfo info;
            if (member_info(pids[i], &info) < 0)
                goto out;
            if (before_deadline(end) < 0)
                goto out;
            if (info.pbi_pid != (uint32_t)pids[i] ||
                info.pbi_pgid != (uint32_t)pgid ||
                info.pbi_status < SIDL || info.pbi_status > SZOMB) {
                errno = EPROTO;
                goto out;
            }
            births[i] = (struct process_birth){ info.pbi_start_tvsec, info.pbi_start_tvusec };
            leader_seen |= pids[i] == pgid;
            if (info.pbi_status != SZOMB) {
                result = 1;
                goto out;
            }
        }
        if (!leader_seen) {
            errno = ESRCH;
            goto out;
        }
        /* A parent could fork after enumeration, then become a zombie before
         * member_info. A second enumeration must contain ONLY already-proven
         * zombies. Newly appearing members mean retry in the outer run loop,
         * never a false empty snapshot. Zombies cannot generate new children. */
        verify = malloc(capacity * sizeof(*verify));
        if (verify == NULL) {
            errno = ENOMEM;
            goto out;
        }
        if (before_deadline(end) < 0)
            goto out;
        int second = list_group(pgid, verify, capacity);
        if (before_deadline(end) < 0 || second < 0)
            goto out;
        if ((size_t)second >= capacity) {
            result = 1;
            goto out;
        }
        leader_seen = false;
        qsort(verify, (size_t)second, sizeof(*verify), compare_pid);
        for (int i = 0; i < second; ++i) {
            if (before_deadline(end) < 0)
                goto out;
            if (verify[i] <= 0 || (i > 0 && verify[i] == verify[i - 1])) {
                errno = EPROTO;
                goto out;
            }
            const pid_t *original = bsearch(&verify[i], pids, (size_t)count, sizeof(*pids), compare_pid);
            if (original == NULL) {
                result = 1;
                goto out;
            }
            /* Descendant PIDs (unlike the pinned direct child) may be reaped
             * and reused. Require the SAME zombie incarnation in the second
             * list, not merely a matching integer PID. */
            struct proc_bsdinfo info;
            if (member_info(verify[i], &info) < 0 || before_deadline(end) < 0)
                goto out;
            const struct process_birth *birth = &births[original - pids];
            if (birth->seconds == 0 || birth->microseconds >= 1000000 ||
                info.pbi_pid != (uint32_t)verify[i] ||
                info.pbi_pgid != (uint32_t)pgid || info.pbi_status != SZOMB ||
                info.pbi_start_tvsec != birth->seconds ||
                info.pbi_start_tvusec != birth->microseconds) {
                errno = EPROTO;
                goto out;
            }
            leader_seen |= verify[i] == pgid;
        }
        if (!leader_seen) {
            errno = ESRCH;
            goto out;
        }
        result = 0;
        goto out;
    }
out:
    {
        int saved = errno;
        free(births);
        free(verify);
        free(pids);
        errno = saved;
    }
    return result;
}
