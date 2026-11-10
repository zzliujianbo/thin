/* Darwin foreground IPC shim. Build this file only for Darwin, with libc.
 * No main, no Zig callback, no allocator in the fork child, and NEVER listen.
 * The real service validates the namespace and calls listen after transfer.
 */
#define _DARWIN_C_SOURCE 1
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define HELPER_MS 1500
#define REAP_MS 1500
#define LEAF_MAX 63
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "child publication must not use locks");

struct shared_result {
    _Atomic unsigned node_valid;
    _Atomic int error;
    struct stat node;
};
/* One outstanding helper at a time. A failed reap retains its exact PID AND
 * its cleanup resources here, rather than losing ownership or risking reuse.
 * Subsequent calls retry cleanup before permitting another fork. As with any
 * owned child API, other threads must not use waitpid(-1) to steal this child. */
static pthread_mutex_t helper_lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
    pid_t pid;
    int directory;
    int channel;
    char name[LEAF_MAX + 1];
    struct shared_result *shared;
} owned = { .pid = 0, .directory = -1, .channel = -1, .shared = MAP_FAILED };

static int64_t monotonic_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}
static int prepare_socket(int fd) {
    int status = fcntl(fd, F_GETFL);
    int flags = fcntl(fd, F_GETFD);
    int enabled = 1;
    if (status < 0 || flags < 0 ||
        fcntl(fd, F_SETFL, status | O_NONBLOCK) < 0 ||
        fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0 ||
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof enabled) < 0) return -1;
    return 0;
}
static int same_node(const struct stat *a, const struct stat *b) {
    return S_ISSOCK(a->st_mode) && a->st_uid == geteuid() &&
        a->st_uid == b->st_uid && a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}
static void remove_owned_node(void) {
    struct stat actual;
    if (owned.shared == MAP_FAILED ||
        !atomic_load_explicit(&owned.shared->node_valid, memory_order_acquire)) return;
    if (fstatat(owned.directory, owned.name, &actual, AT_SYMLINK_NOFOLLOW) == 0 &&
        same_node(&actual, &owned.shared->node))
        (void)unlinkat(owned.directory, owned.name, 0);
}
/* waitpid is exact and nonblocking. Reaping, or ECHILD, immediately consumes
 * the ownership token. Nothing may signal that numeric PID afterwards. */
static int wait_owned(int milliseconds) {
    int64_t start = monotonic_ms();
    if (start < 0) return -1;
    int64_t deadline = start + milliseconds;
    for (;;) {
        int status;
        pid_t result = waitpid(owned.pid, &status, WNOHANG);
        if (result == owned.pid) {
            owned.pid = 0;
            if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return 0;
            errno = EIO;
            return -1;
        }
        if (result < 0 && errno == ECHILD) {
            /* A foreign reaper consumed ownership: never kill a reused PID. */
            owned.pid = 0;
            return -1;
        }
        if (result < 0 && errno != EINTR) return -1;
        int64_t now = monotonic_ms();
        if (now < 0) return -1;
        if (now >= deadline) { errno = ETIMEDOUT; return -1; }
        (void)poll(NULL, 0, 2);
    }
}
/* Called only with an unreaped direct child. SIGKILL precedes the final reap;
 * ESRCH is not a reap and does not authorize forgetting the PID. */
static int stop_owned(void) {
    if (owned.pid == 0) return 0;
    (void)kill(owned.pid, SIGKILL);
    (void)wait_owned(REAP_MS);
    return owned.pid == 0 ? 0 : -1;
}
static void release_owned(int remove_node) {
    if (remove_node) remove_owned_node();
    if (owned.directory >= 0) close(owned.directory);
    if (owned.channel >= 0) close(owned.channel);
    if (owned.shared != MAP_FAILED) munmap(owned.shared, sizeof *owned.shared);
    owned.directory = owned.channel = -1;
    owned.shared = MAP_FAILED;
    owned.name[0] = 0;
}
static int receive_socket(int channel, int64_t deadline) {
    for (;;) {
        int64_t now = monotonic_ms();
        if (now < 0) return -1;
        if (now >= deadline) { errno = ETIMEDOUT; return -1; }
        struct pollfd p = { .fd = channel, .events = POLLIN };
        int rc = poll(&p, 1, (int)(deadline - now));
        if (rc < 0 && errno == EINTR) continue;
        if (rc < 0) return -1;
        if (rc == 0) continue;
        char byte = 0;
        struct iovec iov = { .iov_base = &byte, .iov_len = 1 };
        union { struct cmsghdr align; char bytes[CMSG_SPACE(8 * sizeof(int))]; } control;
        memset(&control, 0, sizeof control);
        struct msghdr message = { .msg_iov = &iov, .msg_iovlen = 1,
            .msg_control = control.bytes, .msg_controllen = sizeof control.bytes };
        ssize_t n = recvmsg(channel, &message, MSG_DONTWAIT);
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (n < 0) return -1;
        int result = -1, count = 0, invalid = 0;
        /* Close every received right even on protocol/truncation failure. */
        for (struct cmsghdr *h = CMSG_FIRSTHDR(&message); h;
             h = CMSG_NXTHDR(&message, h)) {
            size_t remaining = message.msg_controllen - (size_t)((char *)h - (char *)message.msg_control);
            if (h->cmsg_len < CMSG_LEN(0) || h->cmsg_len > remaining) { invalid = 1; break; }
            if (h->cmsg_level != SOL_SOCKET || h->cmsg_type != SCM_RIGHTS) {
                invalid = 1; continue;
            }
            size_t bytes = h->cmsg_len - CMSG_LEN(0);
            if (bytes % sizeof(int)) invalid = 1;
            for (size_t at = 0; at + sizeof(int) <= bytes; at += sizeof(int)) {
                int fd;
                memcpy(&fd, (char *)CMSG_DATA(h) + at, sizeof fd);
                if (count++ == 0) result = fd; else close(fd);
            }
        }
        if (n != 1 || byte != 'F' || count != 1 || invalid ||
            (message.msg_flags & (MSG_CTRUNC | MSG_TRUNC))) {
            if (result >= 0) close(result);
            int helper_error = atomic_load_explicit(&owned.shared->error, memory_order_acquire);
            errno = helper_error ? helper_error : EIO;
            return -1;
        }
        /* SO_NOSIGPIPE was set before fork, while the socket was alive.
         * SCM_RIGHTS does not transfer FD_CLOEXEC, so set it before exposure. */
        int flags = fcntl(result, F_GETFD);
        if (flags < 0 || fcntl(result, F_SETFD, flags | FD_CLOEXEC) < 0) {
            int saved = errno; close(result); errno = saved; return -1;
        }
        return result;
    }
}

/* Returns an owned, bound, unlistened socket; -1 + errno on failure;
 * -2 means a killed but not yet reaped helper is retained in owned. */
int thin_darwin_ipc_bind_at(int directory, const char *name,
    uint32_t *dev_major, uint32_t *dev_minor, uint64_t *ino) {
    size_t length = strnlen(name, LEAF_MAX + 1);
    if (!length || length > LEAF_MAX || strchr(name, '/') ||
        !strcmp(name, ".") || !strcmp(name, "..")) { errno = EINVAL; return -1; }
    int lock_error = pthread_mutex_trylock(&helper_lock);
    if (lock_error) { errno = EBUSY; return -1; }
    int result = -1, saved = 0, pair[2] = { -1, -1 }, socket_fd = -1;
    int mask_changed = 0;
    sigset_t old_mask, blocked;
    if (owned.pid != 0) {
        if (stop_owned() != 0) { result = -2; saved = ETIMEDOUT; goto done; }
        release_owned(1);
    }
    owned.directory = fcntl(directory, F_DUPFD_CLOEXEC, 0);
    if (owned.directory < 0) goto failure;
    memcpy(owned.name, name, length + 1);
    owned.shared = mmap(NULL, sizeof *owned.shared, PROT_READ | PROT_WRITE,
        MAP_ANON | MAP_SHARED, -1, 0);
    if (owned.shared == MAP_FAILED) goto failure;
    memset(owned.shared, 0, sizeof *owned.shared);
    atomic_init(&owned.shared->node_valid, 0);
    atomic_init(&owned.shared->error, 0);
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) < 0) goto failure;
    if (prepare_socket(pair[0]) < 0 || prepare_socket(pair[1]) < 0) goto failure;
    owned.channel = pair[0]; pair[0] = -1;
    socket_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (socket_fd < 0 || prepare_socket(socket_fd) < 0) goto failure;

    /* Everything involving strings, CMSG construction, limits and signal-mask
     * construction happens BEFORE fork. Child uses only async-signal-safe libc
     * calls + lock-free publication. All catchable signals remain blocked there
     * so no inherited Zig signal handler can execute in the child. */
    struct sockaddr_un address;
    memset(&address, 0, sizeof address);
    address.sun_family = AF_UNIX;
    address.sun_len = (unsigned char)(offsetof(struct sockaddr_un, sun_path) + length + 1);
    memcpy(address.sun_path, name, length + 1);
    char byte = 'F';
    struct iovec iov = { .iov_base = &byte, .iov_len = 1 };
    union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int))]; } control;
    memset(&control, 0, sizeof control);
    struct msghdr message = { .msg_iov = &iov, .msg_iovlen = 1,
        .msg_control = control.bytes, .msg_controllen = sizeof control.bytes };
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(header), &socket_fd, sizeof socket_fd);
    int max_fd = getdtablesize();
    if (max_fd < 0) goto failure;
    if (max_fd <= socket_fd) max_fd = socket_fd + 1;
    if (max_fd <= pair[1]) max_fd = pair[1] + 1;
    if (max_fd <= owned.directory) max_fd = owned.directory + 1;
    sigfillset(&blocked);
    int mask_error = pthread_sigmask(SIG_SETMASK, &blocked, &old_mask);
    if (mask_error) { errno = mask_error; goto failure; }
    mask_changed = 1;
    int64_t start = monotonic_ms();
    if (start < 0) goto failure;
    pid_t child = fork();
    if (child == 0) {
        for (int fd = 0; fd < max_fd; ++fd)
            if (fd != pair[1] && fd != socket_fd && fd != owned.directory) close(fd);
        int error = 0;
        if (fchdir(owned.directory) < 0) error = errno;
        (void)umask(0177);
        if (!error && bind(socket_fd, (struct sockaddr *)&address, address.sun_len) < 0) error = errno;
        if (!error) {
            if (fstatat(owned.directory, owned.name, &owned.shared->node, AT_SYMLINK_NOFOLLOW) < 0)
                error = errno;
            else
                atomic_store_explicit(&owned.shared->node_valid, 1, memory_order_release);
        }
        atomic_store_explicit(&owned.shared->error, error, memory_order_release);
        if (error) { byte = 'E'; message.msg_control = NULL; message.msg_controllen = 0; }
        ssize_t sent;
        do { sent = sendmsg(pair[1], &message, 0); } while (sent < 0 && errno == EINTR);
        close(socket_fd); close(pair[1]); close(owned.directory);
        _exit(!error && sent == 1 ? 0 : 1);
    }
    if (child < 0) goto failure;
    owned.pid = child;
    (void)pthread_sigmask(SIG_SETMASK, &old_mask, NULL); mask_changed = 0;
    close(pair[1]); pair[1] = -1;
    /* Keep a real descriptor reference until recvmsg installs the transferred
     * one. A queued SCM_RIGHTS reference alone must not become the last owner:
     * XNU can drain that socket when the sender closes before reception. */
    result = receive_socket(owned.channel, start + HELPER_MS);
    saved = result < 0 ? errno : 0;
    close(socket_fd); socket_fd = -1;
    if (wait_owned(HELPER_MS) != 0) {
        if (!saved) saved = errno;
        if (result >= 0) close(result);
        result = -1;
    }
    if (owned.pid != 0 && stop_owned() != 0) {
        result = -2;
        if (!saved) saved = ETIMEDOUT;
        goto done; /* Keep PID, mmap, dirfd, channel and inode ownership. */
    }
    if (result >= 0) {
        struct stat actual;
        if (!atomic_load_explicit(&owned.shared->node_valid, memory_order_acquire) ||
            fstatat(owned.directory, owned.name, &actual, AT_SYMLINK_NOFOLLOW) != 0 ||
            !same_node(&actual, &owned.shared->node) || (actual.st_mode & 0777) != 0600) {
            saved = EIO; close(result); result = -1;
        }
    }
    if (result >= 0) {
        uint32_t dev = (uint32_t)owned.shared->node.st_dev;
        *dev_major = dev >> 24;
        *dev_minor = dev & 0x00ffffff;
        *ino = (uint64_t)owned.shared->node.st_ino;
    }
    release_owned(result < 0);
    goto done;
failure:
    saved = errno;
    if (mask_changed) (void)pthread_sigmask(SIG_SETMASK, &old_mask, NULL);
    release_owned(1);
done:
    if (pair[0] >= 0) close(pair[0]);
    if (pair[1] >= 0) close(pair[1]);
    if (socket_fd >= 0) close(socket_fd);
    pthread_mutex_unlock(&helper_lock);
    if (result < 0) errno = saved ? saved : EIO;
    return result;
}

int thin_darwin_ipc_credentials(int fd, uint32_t *pid, uint32_t *uid, uint32_t *gid) {
    pid_t kernel_pid = 0;
    uid_t kernel_uid;
    gid_t kernel_gid;
    socklen_t length = sizeof kernel_pid;
    if (getpeereid(fd, &kernel_uid, &kernel_gid) != 0 ||
        getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &kernel_pid, &length) != 0) return -1;
    if (length != sizeof kernel_pid || kernel_pid <= 0) { errno = EIO; return -1; }
    *pid = (uint32_t)kernel_pid; *uid = kernel_uid; *gid = kernel_gid;
    return 0;
}
