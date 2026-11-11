/*
 * Standalone Darwin P0 mechanism probe, NOT a production spawn implementation.
 * Build: clang -std=c11 -Wall -Wextra -Werror process_probe.c -o process_probe
 * Uses only owned fork fixtures. A passing local run says nothing about arm64
 * or the project's eventual minimum macOS version. SIGTERM/SIGINT request
 * bounded parent cleanup; children restore default signal dispositions.
 * Runner should allow >5s for cleanup before hard-killing the probe session.
 */
#define _DARWIN_C_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define PARENT_MS 2500
#define CHILD_MS 5000
#define EXIT_CODE 23

static volatile sig_atomic_t termination_requested;
static bool cleaning_up;
static bool inject_metadata_failure; /* Probe-only fail-closed assertion. */

static void request_termination(int signal_number)
{
    termination_requested = signal_number;
}

static void child_signals(void)
{
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = SIG_DFL;
    if (sigemptyset(&action.sa_mask) < 0 ||
        sigaction(SIGTERM, &action, NULL) < 0 ||
        sigaction(SIGINT, &action, NULL) < 0 ||
        sigaction(SIGPIPE, &action, NULL) < 0)
        _exit(98);
    termination_requested = 0;
}

#define SYS_CHECK(condition, message) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s: %s: %s\n", name, message, strerror(errno)); \
        goto out; \
    } \
} while (0)
#define CHECK(condition, message) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s: %s\n", name, message); \
        goto out; \
    } \
} while (0)

static int64_t now_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0)
        return -1;
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int64_t deadline(int milliseconds)
{
    int64_t now = now_ms();
    return now < 0 ? -1 : now + milliseconds;
}

static int remaining(int64_t end)
{
    if (termination_requested && !cleaning_up) {
        errno = ECANCELED;
        return -1;
    }
    if (end < 0) {
        errno = EIO;
        return -1;
    }
    int64_t now = now_ms();
    if (now < 0)
        return -1;
    if (now >= end) {
        errno = ETIMEDOUT;
        return 0;
    }
    return (int)(end - now);
}

static int tick(int64_t end)
{
    int left = remaining(end);
    if (left <= 0)
        return -1;
    int rc = poll(NULL, 0, left < 5 ? left : 5);
    return rc < 0 && errno != EINTR ? -1 : 0;
}

static void close_fd(int *fd)
{
    if (*fd >= 0) {
        /* Do not retry close: the descriptor may already have been released. */
        (void)close(*fd);
        *fd = -1;
    }
}

static int make_pipe(int fds[2])
{
    if (pipe(fds) < 0)
        return -1;
    for (int i = 0; i < 2; ++i) {
        if (fcntl(fds[i], F_SETFD, FD_CLOEXEC) < 0 ||
            fcntl(fds[i], F_SETFL, O_NONBLOCK) < 0) {
            int saved = errno;
            close_fd(&fds[0]);
            close_fd(&fds[1]);
            errno = saved;
            return -1;
        }
    }
    return 0;
}

/* Every pipe operation, including fixture handshakes, has a finite deadline. */
static int transfer(int fd, void *data, size_t size, bool writing, int64_t end)
{
    size_t done = 0;
    while (done < size) {
        int left = remaining(end);
        if (left <= 0)
            return -1;
        struct pollfd pfd = { .fd = fd, .events = writing ? POLLOUT : POLLIN };
        int rc = poll(&pfd, 1, left);
        if (rc < 0 && errno == EINTR)
            continue;
        if (rc <= 0) {
            if (rc == 0)
                errno = ETIMEDOUT;
            return -1;
        }
        ssize_t n = writing ? write(fd, (char *)data + done, size - done)
                            : read(fd, (char *)data + done, size - done);
        if (n < 0 && (errno == EINTR || errno == EAGAIN))
            continue;
        if (n <= 0) {
            if (n == 0)
                errno = EPIPE;
            return -1;
        }
        done += (size_t)n;
    }
    return 0;
}

static int send_byte(int fd, char byte)
{
    return transfer(fd, &byte, 1, true, deadline(PARENT_MS));
}

static int observe_exit(pid_t pid, siginfo_t *info)
{
    int64_t end = deadline(PARENT_MS);
    for (;;) {
        if (remaining(end) <= 0)
            return -1;
        memset(info, 0, sizeof(*info));
        if (waitid(P_PID, (id_t)pid, info, WEXITED | WNOHANG | WNOWAIT) < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (info->si_pid == pid)
            return 0;
        if (tick(end) < 0)
            return -1;
    }
}

static int reap_exact(pid_t pid, int *status)
{
    int64_t end = deadline(PARENT_MS);
    for (;;) {
        if (remaining(end) <= 0)
            return -1;
        pid_t got = waitpid(pid, status, WNOHANG);
        if (got == pid)
            return 0;
        if (got < 0 && errno != EINTR)
            return -1;
        if (tick(end) < 0)
            return -1;
    }
}

struct snapshot {
    int live;
    int zombies;
    pid_t failed_pid;
    int failed_bytes;
    int sysctl_fallbacks;
    bool leader_seen;
    bool member_seen;
};

/* libproc cannot describe an unreaped zombie on the tested Darwin host.
 * ESRCH is NOT proof of death: obtain and validate a real kernel snapshot.
 * Missing/short sysctl results remain indeterminate, never an empty group. */
static int member_info(pid_t pid, struct proc_bsdinfo *info,
                       int *raw_bytes, bool *used_sysctl)
{
    memset(info, 0, sizeof(*info));
    *used_sysctl = false;
    if (inject_metadata_failure) {
        *raw_bytes = 0;
        errno = EACCES;
        return -1;
    }
    errno = 0;
    *raw_bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, (int)sizeof(*info));
    if (*raw_bytes == (int)sizeof(*info))
        return 0;
    if (*raw_bytes != 0) {
        errno = EPROTO;
        return -1;
    }
    if (errno != ESRCH) {
        if (errno == 0)
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
    *used_sysctl = true;
    return 0;
}

static int snapshot_error(pid_t *pids, int saved_error)
{
    free(pids);
    errno = saved_error ? saved_error : EIO;
    return -1;
}

/*
 * proc_listpgrppids returns a PID COUNT (unlike proc_listpids' byte count).
 * A full buffer is ambiguous: grow and retry, never call it an empty group.
 * Failed/short metadata without a valid sysctl snapshot is indeterminate.
 * This controlled fixture is stable during assertions except member exit;
 * production would need a separate policy for racing exits / permission errors.
 */
static int snapshot_group(pid_t leader, pid_t member, struct snapshot *result)
{
    *result = (struct snapshot){0};
    size_t capacity = 1; /* Deliberately exercise full-buffer growth with two members. */
    pid_t *pids = NULL;
    int64_t end = deadline(PARENT_MS);
    for (;;) {
        if (remaining(end) <= 0)
            return snapshot_error(pids, errno);
        pid_t *grown = realloc(pids, capacity * sizeof(*pids));
        if (grown == NULL)
            return snapshot_error(pids, ENOMEM);
        pids = grown;
        errno = 0;
        int count = proc_listpgrppids(leader, pids, (int)(capacity * sizeof(*pids)));
        if (count < 0 || (count == 0 && errno != 0))
            return snapshot_error(pids, errno);
        if ((size_t)count >= capacity) {
            if (capacity >= 65536)
                return snapshot_error(pids, EOVERFLOW);
            capacity *= 2;
            continue;
        }
        *result = (struct snapshot){0};
        for (int i = 0; i < count; ++i) {
            struct proc_bsdinfo info;
            int bytes = 0;
            bool used_sysctl = false;
            if (pids[i] <= 0) {
                result->failed_pid = pids[i];
                return snapshot_error(pids, EPROTO);
            }
            int status = member_info(pids[i], &info, &bytes, &used_sysctl);
            if (status != 0 ||
                info.pbi_pid != (uint32_t)pids[i] ||
                info.pbi_pgid != (uint32_t)leader ||
                info.pbi_status < SIDL || info.pbi_status > SZOMB) {
                result->failed_pid = pids[i];
                result->failed_bytes = bytes;
                return snapshot_error(pids, status != 0 ? errno : EPROTO);
            }
            result->sysctl_fallbacks += used_sysctl;
            if (info.pbi_status == SZOMB)
                ++result->zombies;
            else
                ++result->live;
            result->leader_seen |= pids[i] == leader;
            result->member_seen |= pids[i] == member;
        }
        free(pids);
        return 0;
    }
}

struct fixture {
    pid_t leader;
    pid_t member; /* A real child of the leader, orphaned when the leader exits. */
    int command;
    int member_command;
    int completion; /* Writer stays in the fixture until kernel process exit. */
    bool pinned_group;
};

/* All inherited descriptors below have explicit ownership; no exec is used. */
static int start_fixture(struct fixture *f, bool background)
{
    int command[2] = {-1, -1};
    int member_command[2] = {-1, -1};
    int ready[2] = {-1, -1};
    int rc = -1;
    if (make_pipe(command) < 0 || make_pipe(member_command) < 0 || make_pipe(ready) < 0)
        goto out;
    f->leader = fork();
    if (f->leader < 0)
        goto out;
    if (f->leader == 0) {
        child_signals();
        close_fd(&command[1]);
        close_fd(&member_command[1]);
        close_fd(&ready[0]);
        char byte;
        /* Parent establishes the group before allowing a descendant to fork. */
        if (transfer(command[0], &byte, 1, false, deadline(CHILD_MS)) < 0 || byte != 'S')
            _exit(90);
        if (background) {
            pid_t child = fork();
            if (child < 0)
                _exit(91);
            if (child == 0) {
                close_fd(&command[0]);
                pid_t self = getpid();
                if (transfer(ready[1], &self, sizeof(self), true, deadline(CHILD_MS)) < 0)
                    _exit(92);
                /* Keep ready[1] until _exit: parent also uses it as completion proof. */
                (void)transfer(member_command[0], &byte, 1, false, deadline(CHILD_MS));
                close_fd(&member_command[0]);
                _exit(0);
            }
            close_fd(&ready[1]); /* Background child is now the only completion writer. */
        } else {
            pid_t self = getpid();
            if (transfer(ready[1], &self, sizeof(self), true, deadline(CHILD_MS)) < 0)
                _exit(93);
        }
        close_fd(&member_command[0]);
        /* Without a background child, leader retains ready[1] through _exit. */
        int got = transfer(command[0], &byte, 1, false, deadline(CHILD_MS));
        close_fd(&command[0]);
        _exit(got == 0 && byte == 'X' ? EXIT_CODE : 94);
    }
    close_fd(&command[0]);
    close_fd(&member_command[0]);
    close_fd(&ready[1]);
    f->completion = ready[0];
    ready[0] = -1;
    f->command = command[1];
    command[1] = -1;
    f->member_command = member_command[1];
    member_command[1] = -1;
    if (setpgid(f->leader, f->leader) < 0)
        goto out;
    f->pinned_group = true;
    if (send_byte(f->command, 'S') < 0)
        goto out;
    pid_t announced = -1;
    if (transfer(f->completion, &announced, sizeof(announced), false, deadline(PARENT_MS)) < 0)
        goto out;
    if (announced <= 0 || (background && announced == f->leader) ||
        (!background && announced != f->leader)) {
        errno = EPROTO;
        goto out;
    }
    if (background)
        f->member = announced;
    rc = 0;
out:
    {
        int saved = errno;
        for (int i = 0; i < 2; ++i) {
            close_fd(&command[i]);
            close_fd(&member_command[i]);
            close_fd(&ready[i]);
        }
        errno = saved;
    }
    return rc;
}

static int wait_group_state(struct fixture *f, int live, int zombies,
                            struct snapshot *result)
{
    int64_t end = deadline(PARENT_MS);
    int last_error = 0;
    for (;;) {
        if (remaining(end) <= 0) {
            if (last_error != 0)
                errno = last_error;
            return -1;
        }
        if (snapshot_group(f->leader, f->member, result) == 0) {
            last_error = 0;
            if (result->live == live && (zombies < 0 || result->zombies == zombies))
                return 0;
        } else {
            /* A disappearing orphan can race enumeration; retry, not empty. */
            last_error = errno;
            if ((errno != ESRCH && errno != ENOENT) || result->failed_pid == f->leader)
                return -1; /* An unreaped leader cannot race PID reuse/disappearance. */
        }
        if (tick(end) < 0) {
            if (last_error != 0)
                errno = last_error;
            return -1;
        }
    }
}

/* No libproc dependency in cleanup: candidate API failure must not leak fixtures. */
static int pipe_eof(int fd, bool drain_payload, int milliseconds)
{
    int64_t end = deadline(milliseconds);
    for (;;) {
        int left = remaining(end);
        if (left <= 0)
            return -1;
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        int rc = poll(&pfd, 1, left);
        if (rc < 0 && errno == EINTR)
            continue;
        if (rc <= 0) {
            if (rc == 0)
                errno = ETIMEDOUT;
            return -1;
        }
        char bytes[64];
        ssize_t n = read(fd, bytes, sizeof(bytes));
        if (n == 0)
            return 0;
        if (n < 0 && (errno == EINTR || errno == EAGAIN))
            continue;
        if (n > 0 && drain_payload)
            continue;
        if (n > 0)
            errno = EPROTO;
        return -1;
    }
}

static int finish_fixture(struct fixture *f, int *status)
{
    int rc = 0;
    cleaning_up = true; /* Cancellation initiates cleanup, not cancellation of cleanup. */
    close_fd(&f->command);
    close_fd(&f->member_command);
    if (f->leader <= 0)
        goto out;
    /*
     * LAST group signal BEFORE reaping the pinned leader. Never signal that
     * PGID again after waitpid: PID/PGID reuse could target unrelated processes.
     * The orphan is killed in this group; launchd, not us, reaps that grandchild.
     */
    pid_t target = f->pinned_group ? -f->leader : f->leader;
    int signal_error = kill(target, SIGKILL) < 0 ? errno : 0;
    bool completed = f->completion >= 0 && pipe_eof(f->completion, true, PARENT_MS) == 0;
    if (f->completion >= 0 && !completed) {
        perror("FAIL fixture cleanup: completion EOF deadline");
        rc = -1;
    }
    if (signal_error == EPERM && completed) {
        /* Darwin may return EPERM for an all-zombie group. Accept ONLY with
         * completion EOF and exact WNOWAIT proof that our leader is also dead.
         * This is fixture cleanup, NOT a fallback that makes libproc pass. */
        siginfo_t info;
        memset(&info, 0, sizeof(info));
        if (waitid(P_PID, (id_t)f->leader, &info, WEXITED | WNOHANG | WNOWAIT) == 0 &&
            info.si_pid == f->leader)
            signal_error = 0;
    }
    if (signal_error != 0 && signal_error != ESRCH) {
        fprintf(stderr, "FAIL fixture cleanup: final SIGKILL: %s\n", strerror(signal_error));
        rc = -1;
    }
    if (reap_exact(f->leader, status) < 0) {
        perror("FAIL fixture cleanup: exact waitpid deadline");
        rc = -1;
    }
    f->leader = -1;
out:
    close_fd(&f->completion);
    cleaning_up = false;
    return rc;
}

static struct fixture empty_fixture(void)
{
    return (struct fixture){ .leader = -1, .member = -1,
                             .command = -1, .member_command = -1, .completion = -1 };
}

static int test_waitid(void)
{
    const char *name = "waitid WNOWAIT -> exact waitpid";
    struct fixture f = empty_fixture();
    bool ok = false;
    int status = 0;
    siginfo_t info;
    SYS_CHECK(start_fixture(&f, false) == 0, "start owned leader");
    SYS_CHECK(send_byte(f.command, 'X') == 0, "release leader");
    SYS_CHECK(observe_exit(f.leader, &info) == 0, "observe exit without reaping");
    CHECK(info.si_code == CLD_EXITED && info.si_status == EXIT_CODE, "wrong exit observation");
    SYS_CHECK(observe_exit(f.leader, &info) == 0, "repeat WNOWAIT observation");
    CHECK(info.si_code == CLD_EXITED && info.si_status == EXIT_CODE, "repeated observation changed");
    ok = true;
out:
    if (finish_fixture(&f, &status) < 0)
        ok = false;
    if (ok && (!WIFEXITED(status) || WEXITSTATUS(status) != EXIT_CODE)) {
        fprintf(stderr, "FAIL %s: exact waitpid did not recover original exit status\n", name);
        ok = false;
    }
    if (ok)
        printf("PASS %s (observed twice, exit=%d)\n", name, EXIT_CODE);
    return ok ? 0 : -1;
}

static bool report_group(struct fixture *f, int live, int zombies,
                         bool expect_member, const char *label)
{
    struct snapshot state = {0};
    if (wait_group_state(f, live, zombies, &state) < 0) {
        fprintf(stderr, "FAIL libproc: %s: snapshot indeterminate: %s; "
                "proc_pidinfo PID=%d (leader=%d), bytes=%d\n",
                label, strerror(errno), state.failed_pid, f->leader, state.failed_bytes);
        return false;
    }
    if (!state.leader_seen || state.member_seen != expect_member) {
        fprintf(stderr, "FAIL libproc: %s: missing/unexpected known fixture PID\n", label);
        return false;
    }
    printf("PASS libproc+sysctl: %s (live=%d, zombies=%d, sysctl=%d)\n",
           label, state.live, state.zombies, state.sysctl_fallbacks);
    return true;
}

static int test_groups(void)
{
    const char *name = "libproc process-group classification";
    struct fixture f = empty_fixture();
    struct snapshot state;
    siginfo_t info;
    int status = 0;
    bool ok = false;
    bool classifications_ok = true;
    SYS_CHECK(start_fixture(&f, true) == 0, "start leader and its background child");
    SYS_CHECK(wait_group_state(&f, 2, 0, &state) == 0, "enumerate two live members");
    CHECK(state.leader_seen && state.member_seen, "missing known live fixture PIDs");
    struct proc_bsdinfo member;
    int bytes = proc_pidinfo(f.member, PROC_PIDTBSDINFO, 0, &member, (int)sizeof(member));
    SYS_CHECK(bytes == (int)sizeof(member), "read background child ancestry");
    CHECK(member.pbi_ppid == (uint32_t)f.leader, "background member is not leader's child");
    printf("PASS libproc: live leader + live background child (live=2, zombies=0)\n");
    inject_metadata_failure = true;
    int missing = snapshot_group(f.leader, f.member, &state);
    int missing_error = errno;
    inject_metadata_failure = false;
    CHECK(missing < 0 && missing_error == EACCES && state.failed_pid > 0,
          "unavailable metadata was mistaken for a complete/empty group");
    puts("PASS unavailable process metadata fails closed, never an empty group");

    SYS_CHECK(send_byte(f.command, 'X') == 0, "exit leader without reaping");
    SYS_CHECK(observe_exit(f.leader, &info) == 0, "pin exited leader with WNOWAIT");
    CHECK(info.si_code == CLD_EXITED && info.si_status == EXIT_CODE, "leader exit status mismatch");
    bytes = proc_pidinfo(f.member, PROC_PIDTBSDINFO, 0, &member, (int)sizeof(member));
    SYS_CHECK(bytes == (int)sizeof(member), "read still-live background child after leader exit");
    CHECK(member.pbi_status != SZOMB && member.pbi_pgid == (uint32_t)f.leader,
          "background child is not still live in the original group");
    if (!report_group(&f, 1, 1, true, "unreaped zombie leader + live background child"))
        classifications_ok = false;

    SYS_CHECK(send_byte(f.member_command, 'X') == 0, "exit background child");
    SYS_CHECK(pipe_eof(f.completion, false, PARENT_MS) == 0, "confirm background child exit");
    if (!report_group(&f, 0, 1, false, "zombie-only leader group is NOT live"))
        classifications_ok = false;
    SYS_CHECK(observe_exit(f.leader, &info) == 0, "leader remains unreaped after libproc checks");
    ok = classifications_ok;
out:
    if (finish_fixture(&f, &status) < 0)
        ok = false;
    if (ok && (!WIFEXITED(status) || WEXITSTATUS(status) != EXIT_CODE)) {
        fprintf(stderr, "FAIL %s: lost original leader exit status\n", name);
        ok = false;
    }
    return ok ? 0 : -1;
}

static int test_owner_pipe(void)
{
    const char *name = "owner SIGKILL -> dedicated lifetime-pipe EOF";
    int life[2] = {-1, -1};
    int report[2] = {-1, -1};
    pid_t owner = -1;
    pid_t worker = -1;
    siginfo_t info;
    int status;
    bool ok = false;
    SYS_CHECK(make_pipe(life) == 0 && make_pipe(report) == 0, "create nonblocking pipes");
    owner = fork();
    SYS_CHECK(owner >= 0, "fork owner");
    if (owner == 0) {
        child_signals();
        close_fd(&life[0]);
        close_fd(&report[0]);
        close_fd(&report[1]);
        /* Owner is the ONLY writer after parent/worker close inherited copies. */
        int64_t end = deadline(CHILD_MS);
        while (remaining(end) > 0) {
            if (tick(end) < 0)
                break;
        }
        close_fd(&life[1]);
        _exit(95); /* Bounded fallback, not the expected SIGKILL path. */
    }
    worker = fork();
    SYS_CHECK(worker >= 0, "fork worker");
    if (worker == 0) {
        child_signals();
        close_fd(&life[1]); /* Essential: worker must not keep itself alive. */
        close_fd(&report[0]);
        char byte;
        errno = 0;
        ssize_t n = read(life[0], &byte, 1);
        if (n != -1 || errno != EAGAIN)
            _exit(96); /* It must NOT already be EOF while owner is alive. */
        if (send_byte(report[1], 'R') < 0 || pipe_eof(life[0], false, CHILD_MS) < 0 ||
            send_byte(report[1], 'E') < 0)
            _exit(97);
        close_fd(&life[0]);
        close_fd(&report[1]);
        _exit(0);
    }
    close_fd(&life[0]);
    close_fd(&life[1]); /* Essential: no supervisor writer can mask owner death. */
    close_fd(&report[1]);
    char message;
    SYS_CHECK(transfer(report[0], &message, 1, false, deadline(PARENT_MS)) == 0,
              "worker readiness / initial no-EOF assertion");
    CHECK(message == 'R', "bad worker readiness");
    memset(&info, 0, sizeof(info));
    SYS_CHECK(waitid(P_PID, (id_t)owner, &info, WEXITED | WNOHANG | WNOWAIT) == 0,
              "check owner has not exited");
    CHECK(info.si_pid == 0, "owner exited before SIGKILL");
    SYS_CHECK(kill(owner, SIGKILL) == 0, "SIGKILL owned owner PID");
    SYS_CHECK(observe_exit(owner, &info) == 0, "observe owner death");
    CHECK(info.si_code == CLD_KILLED && info.si_status == SIGKILL, "owner did not die by SIGKILL");
    SYS_CHECK(transfer(report[0], &message, 1, false, deadline(PARENT_MS)) == 0,
              "worker EOF report");
    CHECK(message == 'E', "worker did not observe EOF");
    SYS_CHECK(observe_exit(worker, &info) == 0, "bounded worker exit after EOF");
    CHECK(info.si_code == CLD_EXITED && info.si_status == 0, "worker exit was not clean");
    ok = true;
out:
    cleaning_up = true;
    close_fd(&life[0]);
    close_fd(&life[1]);
    close_fd(&report[0]);
    close_fd(&report[1]);
    /* Both are unreaped DIRECT children: exact PID signals cannot hit reused PIDs. */
    pid_t children[2] = {owner, worker};
    for (int i = 0; i < 2; ++i) {
        if (children[i] > 0 && kill(children[i], SIGKILL) < 0 && errno != ESRCH) {
            fprintf(stderr, "FAIL %s: cleanup SIGKILL: %s\n", name, strerror(errno));
            ok = false;
        }
    }
    for (int i = 0; i < 2; ++i) {
        if (children[i] > 0) {
            if (reap_exact(children[i], &status) < 0) {
                fprintf(stderr, "FAIL %s: cleanup exact waitpid: %s\n", name, strerror(errno));
                ok = false;
            } else if (ok && (i == 0 ? !WIFSIGNALED(status) || WTERMSIG(status) != SIGKILL
                                    : !WIFEXITED(status) || WEXITSTATUS(status) != 0)) {
                fprintf(stderr, "FAIL %s: exact waitpid status mismatch\n", name);
                ok = false;
            }
        }
    }
    cleaning_up = false;
    if (ok)
        printf("PASS %s (initially not EOF; no TUI connection involved)\n", name);
    return ok ? 0 : -1;
}

int main(void)
{
    /* Closed fixture pipes must report EPIPE, not terminate the cleanup parent. */
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = SIG_IGN;
    if (sigemptyset(&action.sa_mask) < 0 || sigaction(SIGPIPE, &action, NULL) < 0) {
        perror("FAIL ignore SIGPIPE");
        return EXIT_FAILURE;
    }
    action.sa_handler = request_termination;
    if (sigaction(SIGTERM, &action, NULL) < 0 || sigaction(SIGINT, &action, NULL) < 0) {
        perror("FAIL install cancellation handler");
        return EXIT_FAILURE;
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    int failures = 0;
    if (!termination_requested)
        failures += test_waitid() != 0;
    if (!termination_requested)
        failures += test_groups() != 0;
    if (!termination_requested)
        failures += test_owner_pipe() != 0;
    if (termination_requested) {
        fprintf(stderr, "FAIL process probe: signal %d requested bounded cleanup\n", termination_requested);
        return 128 + termination_requested;
    }
    printf("%s process probe: %d failed mechanism(s)\n", failures ? "FAIL" : "PASS", failures);
    return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
