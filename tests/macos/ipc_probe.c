/* Standalone Darwin P0 experiment, not a production transport implementation.
 * All sockets, paths and children are private to this test. No TCP listeners. */
#define _DARWIN_C_SOURCE 1
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define BUDGET_MS 3000
#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s (errno=%d: %s)\n", \
        __LINE__, #condition, errno, strerror(errno)); goto cleanup; \
} } while (0)

struct fixture {
    char path[80];
    int root;
    int directory;
};
struct peer { pid_t pid; uid_t uid; gid_t gid; };

static int64_t now_ms(void) {
    struct timespec time;
    if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) abort();
    return (int64_t)time.tv_sec * 1000 + time.tv_nsec / 1000000;
}
static int ready(int fd, short events) {
    int64_t deadline = now_ms() + BUDGET_MS;
    for (;;) {
        int64_t left = deadline - now_ms();
        if (left <= 0) { errno = ETIMEDOUT; return -1; }
        struct pollfd pollfd = { .fd = fd, .events = events };
        int result = poll(&pollfd, 1, (int)left);
        if (result > 0) return 0;
        if (result < 0 && errno != EINTR) return -1;
    }
}
static int wait_child(pid_t *pid) {
    int64_t deadline = now_ms() + BUDGET_MS;
    while (now_ms() < deadline) {
        int status;
        pid_t result = waitpid(*pid, &status, WNOHANG);
        if (result == *pid) {
            *pid = 0;
            return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
        }
        if (result < 0 && errno != EINTR) return -1;
        (void)poll(NULL, 0, 2);
    }
    errno = ETIMEDOUT;
    return -1;
}
static void stop_child(pid_t *pid) {
    if (*pid <= 0) return;
    (void)kill(*pid, SIGKILL); /* Only an exact, still-unreaped child. */
    if (wait_child(pid) != 0 && *pid > 0)
        fprintf(stderr, "FAIL: could not reap owned child %ld\n", (long)*pid);
}
static int descriptor_flags(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
    return fcntl(fd, F_SETFD, FD_CLOEXEC);
}
static int control_pair(int pair[2]) {
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, pair) != 0) return -1;
    struct timeval timeout = { .tv_sec = 3, .tv_usec = 0 };
    for (int i = 0; i < 2; ++i) {
        if (setsockopt(pair[i], SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout) != 0 ||
            setsockopt(pair[i], SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout) != 0 ||
            fcntl(pair[i], F_SETFD, FD_CLOEXEC) != 0) {
            close(pair[0]); close(pair[1]); pair[0] = pair[1] = -1;
            return -1;
        }
    }
    return 0;
}
static int address(const char *path, struct sockaddr_un *value) {
    size_t length = strlen(path);
    if (length >= sizeof value->sun_path) { errno = ENAMETOOLONG; return -1; }
    memset(value, 0, sizeof *value);
    value->sun_family = AF_UNIX;
    value->sun_len = (unsigned char)(offsetof(struct sockaddr_un, sun_path) + length + 1);
    memcpy(value->sun_path, path, length + 1);
    return 0;
}
static int peer_identity(int fd, struct peer *peer) {
    socklen_t length = sizeof peer->pid;
    if (getpeereid(fd, &peer->uid, &peer->gid) != 0 ||
        getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer->pid, &length) != 0 ||
        length != sizeof peer->pid || peer->pid <= 0) return -1;
    return 0;
}
static bool expected_peer(const struct peer *peer, pid_t pid) {
    return peer->pid == pid && peer->uid == geteuid() && peer->gid == getegid();
}
static int send_fd(int channel, int fd) {
    char byte = 'F';
    struct iovec iov = { .iov_base = &byte, .iov_len = 1 };
    union { struct cmsghdr align; char data[CMSG_SPACE(sizeof(int))]; } control;
    memset(&control, 0, sizeof control);
    struct msghdr message = { .msg_iov = &iov, .msg_iovlen = 1,
        .msg_control = control.data, .msg_controllen = sizeof control.data };
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof fd);
    memcpy(CMSG_DATA(header), &fd, sizeof fd);
    return sendmsg(channel, &message, 0) == 1 ? 0 : -1;
}
static int receive_fd(int channel) {
    char byte = 0;
    struct iovec iov = { .iov_base = &byte, .iov_len = 1 };
    union { struct cmsghdr align; char data[CMSG_SPACE(sizeof(int))]; } control;
    memset(&control, 0, sizeof control);
    struct msghdr message = { .msg_iov = &iov, .msg_iovlen = 1,
        .msg_control = control.data, .msg_controllen = sizeof control.data };
    if (recvmsg(channel, &message, 0) != 1) return -1;
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    if (!header || header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS ||
        header->cmsg_len != CMSG_LEN(sizeof(int))) return -1;
    int fd;
    memcpy(&fd, CMSG_DATA(header), sizeof fd);
    if (byte != 'F' || (message.msg_flags & (MSG_CTRUNC | MSG_TRUNC)) ||
        CMSG_NXTHDR(&message, header) != NULL || descriptor_flags(fd) != 0) {
        close(fd); return -1;
    }
    return fd;
}
static int fixture_open(struct fixture *fixture) {
    fixture->root = fixture->directory = -1;
    const char *base = getenv("THIN_MACOS_P0_TMPDIR");
    if (!base) base = "/private/tmp";
    int length = snprintf(fixture->path, sizeof fixture->path, "%s/ipc.XXXXXX", base);
    if (length < 0 || length >= (int)sizeof fixture->path) {
        fixture->path[0] = 0; errno = ENAMETOOLONG; return -1;
    }
    if (!mkdtemp(fixture->path)) { fixture->path[0] = 0; return -1; }
    fixture->root = open(fixture->path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fixture->root < 0 || mkdirat(fixture->root, "endpoint", 0700) != 0) return -1;
    fixture->directory = openat(fixture->root, "endpoint", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    return fixture->directory >= 0 ? 0 : -1;
}
static void fixture_close(struct fixture *fixture) {
    if (fixture->directory >= 0) {
        (void)unlinkat(fixture->directory, "control.sock", 0);
        close(fixture->directory);
    }
    if (fixture->root >= 0) {
        (void)unlinkat(fixture->root, "endpoint", AT_REMOVEDIR);
        (void)unlinkat(fixture->root, "moved", AT_REMOVEDIR);
        close(fixture->root);
    }
    if (fixture->path[0]) (void)rmdir(fixture->path);
}
/* The helper is single-threaded and never listens. The real owner must listen
 * after transfer, so listen-time credentials do not name the helper. */
static int helper_bind(int directory) {
    int pair[2] = { -1, -1 }, result = -1;
    pid_t helper = 0;
    if (control_pair(pair) != 0) goto cleanup;
    helper = fork();
    if (helper < 0) { helper = 0; goto cleanup; }
    if (helper == 0) {
        close(pair[0]);
        if (fchdir(directory) != 0) _exit(10);
        umask(0177); /* Create the socket at 0600; no chmod race on the leaf. */
        struct sockaddr_un value;
        if (address("control.sock", &value) != 0) _exit(11);
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0 || bind(fd, (struct sockaddr *)&value, value.sun_len) != 0 ||
            send_fd(pair[1], fd) != 0) _exit(12);
        close(fd); close(pair[1]);
        _exit(0);
    }
    close(pair[1]); pair[1] = -1;
    result = receive_fd(pair[0]);
    if (wait_child(&helper) != 0) {
        if (result >= 0) close(result);
        result = -1;
    }
cleanup:
    stop_child(&helper);
    if (pair[0] >= 0) close(pair[0]);
    if (pair[1] >= 0) close(pair[1]);
    return result;
}
static bool same_object(const struct stat *left, const struct stat *right) {
    return left->st_dev == right->st_dev && left->st_ino == right->st_ino;
}
static int published_directory_matches(const struct fixture *fixture) {
    struct stat opened, path;
    if (fstat(fixture->directory, &opened) != 0 ||
        fstatat(fixture->root, "endpoint", &path, AT_SYMLINK_NOFOLLOW) != 0) return -1;
    return S_ISDIR(path.st_mode) && same_object(&opened, &path);
}
static int remove_if_same(int directory, const struct stat *expected) {
    struct stat actual;
    if (fstatat(directory, "control.sock", &actual, AT_SYMLINK_NOFOLLOW) != 0) return -1;
    if (!S_ISSOCK(actual.st_mode) || actual.st_uid != geteuid() || !same_object(&actual, expected)) return 0;
    return unlinkat(directory, "control.sock", 0) == 0 ? 1 : -1;
}
static int move_directory(const struct fixture *fixture) {
    if (renameat(fixture->root, "endpoint", fixture->root, "moved") != 0) return -1;
    return mkdirat(fixture->root, "endpoint", 0700);
}
static int client_run(int channel, int inherited_listener, const char *path, pid_t owner) {
    close(inherited_listener);
    char byte = 'R';
    if (send(channel, &byte, 1, 0) != 1 || recv(channel, &byte, 1, 0) != 1 || byte != 'C') return 20;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un value;
    if (fd < 0 || descriptor_flags(fd) != 0 || address(path, &value) != 0) return 21;
    if (connect(fd, (struct sockaddr *)&value, value.sun_len) != 0 && errno != EINPROGRESS) return 22;
    int error = 0;
    socklen_t length = sizeof error;
    if (ready(fd, POLLOUT) != 0 || getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) != 0 || error) return 23;
    struct peer peer;
    if (peer_identity(fd, &peer) != 0 || !expected_peer(&peer, owner) ||
        send(channel, &peer, sizeof peer, 0) != sizeof peer) return 24;
    if (recv(channel, &byte, 1, 0) != 1 || byte != 'A') return 25;
    if (peer_identity(fd, &peer) != 0 || !expected_peer(&peer, owner) ||
        send(channel, &peer, sizeof peer, 0) != sizeof peer) return 26;
    close(fd); close(channel);
    return 0;
}
static int test_identity(void) {
    int result = 1, listener = -1, accepted = -1, pair[2] = { -1, -1 };
    pid_t client = 0;
    struct fixture fixture = { .root = -1, .directory = -1 };
    struct stat node;
    CHECK(fixture_open(&fixture) == 0);
    listener = helper_bind(fixture.directory);
    CHECK(listener >= 0); /* Helper has exited and been reaped. */
    CHECK(published_directory_matches(&fixture) == 1);
    CHECK(fstatat(fixture.directory, "control.sock", &node, AT_SYMLINK_NOFOLLOW) == 0);
    CHECK(S_ISSOCK(node.st_mode) && (node.st_mode & 0777) == 0600 && node.st_uid == geteuid());
    CHECK(control_pair(pair) == 0);
    char path[104];
    CHECK(snprintf(path, sizeof path, "%s/endpoint/control.sock", fixture.path) < (int)sizeof path);
    pid_t owner = getpid();
    client = fork();
    CHECK(client >= 0);
    if (client == 0) { close(pair[0]); _exit(client_run(pair[1], listener, path, owner)); }
    close(pair[1]); pair[1] = -1;
    char byte = 0;
    CHECK(recv(pair[0], &byte, 1, 0) == 1 && byte == 'R');
    CHECK(listen(listener, 4) == 0); /* Owner, not helper, captures listener identity. */
    byte = 'C';
    CHECK(send(pair[0], &byte, 1, 0) == 1);
    struct peer peer;
    CHECK(recv(pair[0], &peer, sizeof peer, 0) == sizeof peer);
    CHECK(expected_peer(&peer, owner)); /* Client queried before accept. */
    CHECK(ready(listener, POLLIN) == 0);
    accepted = accept(listener, NULL, NULL);
    CHECK(accepted >= 0 && descriptor_flags(accepted) == 0);
    int enabled = 1;
    CHECK(setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof enabled) == 0);
    socklen_t length = sizeof enabled;
    enabled = 0;
    CHECK(getsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &enabled, &length) == 0 && enabled == 1);
    CHECK(peer_identity(accepted, &peer) == 0 && expected_peer(&peer, client));
    CHECK(!expected_peer(&peer, owner)); /* A false hello PID would be rejected. */
    byte = 'A';
    CHECK(send(pair[0], &byte, 1, 0) == 1);
    CHECK(recv(pair[0], &peer, sizeof peer, 0) == sizeof peer && expected_peer(&peer, owner));
    CHECK(wait_child(&client) == 0);
    CHECK(signal(SIGPIPE, SIG_DFL) != SIG_ERR);
    bool closed = false;
    int64_t deadline = now_ms() + BUDGET_MS;
    while (now_ms() < deadline) {
        if (send(accepted, "x", 1, 0) < 0) {
            CHECK(errno == EPIPE || errno == ECONNRESET);
            closed = true;
            break;
        }
        (void)poll(NULL, 0, 2);
    }
    CHECK(closed);
    CHECK(remove_if_same(fixture.directory, &node) == 1);
    puts("PASS helper bind/owner listen: peer PID+UID/GID before and after accept, 0600, SO_NOSIGPIPE");
    result = 0;
cleanup:
    stop_child(&client);
    if (accepted >= 0) close(accepted);
    if (listener >= 0) close(listener);
    if (pair[0] >= 0) close(pair[0]);
    if (pair[1] >= 0) close(pair[1]);
    fixture_close(&fixture);
    return result;
}
static int test_directory_replacement(bool before_bind) {
    int result = 1, listener = -1;
    struct fixture fixture = { .root = -1, .directory = -1 };
    struct stat node, replacement;
    CHECK(fixture_open(&fixture) == 0);
    if (before_bind) CHECK(move_directory(&fixture) == 0);
    listener = helper_bind(fixture.directory);
    CHECK(listener >= 0);
    if (!before_bind) CHECK(move_directory(&fixture) == 0);
    CHECK(published_directory_matches(&fixture) == 0);
    CHECK(fstatat(fixture.directory, "control.sock", &node, AT_SYMLINK_NOFOLLOW) == 0 && S_ISSOCK(node.st_mode));
    CHECK(fstatat(fixture.root, "endpoint/control.sock", &replacement, AT_SYMLINK_NOFOLLOW) < 0 && errno == ENOENT);
    CHECK(remove_if_same(fixture.directory, &node) == 1);
    printf("PASS directory replacement %s bind: original inode anchored, wrong path rejected\n", before_bind ? "before" : "after");
    result = 0;
cleanup:
    if (listener >= 0) close(listener);
    fixture_close(&fixture);
    return result;
}
static int test_replaced_node(void) {
    int result = 1, listener = -1, file = -1;
    struct fixture fixture = { .root = -1, .directory = -1 };
    struct stat original, replacement;
    CHECK(fixture_open(&fixture) == 0);
    listener = helper_bind(fixture.directory);
    CHECK(listener >= 0);
    CHECK(fstatat(fixture.directory, "control.sock", &original, AT_SYMLINK_NOFOLLOW) == 0);
    CHECK(unlinkat(fixture.directory, "control.sock", 0) == 0);
    file = openat(fixture.directory, "control.sock", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    CHECK(file >= 0 && remove_if_same(fixture.directory, &original) == 0);
    CHECK(fstatat(fixture.directory, "control.sock", &replacement, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(replacement.st_mode));
    puts("PASS cleanup refuses a replaced non-socket node");
    result = 0;
cleanup:
    if (file >= 0) close(file);
    if (listener >= 0) close(listener);
    fixture_close(&fixture);
    return result;
}
int main(void) {
    if (getuid() != geteuid() || getgid() != getegid()) {
        fputs("This probe requires matching real/effective user and group IDs.\n", stderr);
        return 2;
    }
    umask(0077);
    if (test_identity() || test_directory_replacement(true) ||
        test_directory_replacement(false) || test_replaced_node()) return 1;
    return 0;
}
