/* Fixed, anchored ~/.thin key files. No libssh/system configuration discovery.
 * Public-key options/certificates and encrypted host keys are not supported. */
#define _GNU_SOURCE
#include "ssh_transport.h"
#include <libssh/server.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/random.h>
#include <netdb.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int owned_directory(int fd, int private_mode) {
    struct stat st;
    return fstat(fd, &st) == 0 && S_ISDIR(st.st_mode) &&
        st.st_uid == geteuid() && !(st.st_mode & (private_mode ? 077 : 022));
}

int thin_ssh_key_directory(const char *home, int create) {
    /* Walk from / with nofollow at EVERY component, not just the last one. */
    if (!home || home[0] != '/' || strlen(home) >= 4096) return -1;
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return -1;
    char path[4096]; memcpy(path, home, strlen(home) + 1);
    char *save = NULL;
    for (char *p = strtok_r(path, "/", &save); p; p = strtok_r(NULL, "/", &save)) {
        if (!strcmp(p, ".") || !strcmp(p, "..")) { close(fd); return -1; }
        int next = openat(fd, p, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        close(fd); fd = next;
        if (fd < 0) return -1;
    }
    if (!owned_directory(fd, 0)) { close(fd); return -1; }
    if (create && mkdirat(fd, ".thin", 0700) && errno != EEXIST) { close(fd); return -1; }
    int dir = openat(fd, ".thin", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    close(fd);
    if (dir < 0) return -1;
    if (!owned_directory(dir, 1)) { close(dir); return -1; }
    return dir;
}

static char *read_key(int dir, const char *name, size_t *length) {
    /* NONBLOCK prevents a substituted FIFO from hanging before fstat. */
    int fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return NULL;
    struct stat before, after;
    char *data = NULL;
    if (fstat(fd, &before) || !S_ISREG(before.st_mode) || before.st_uid != geteuid() ||
        (before.st_mode & 077) || before.st_nlink != 1 || before.st_size <= 0 || before.st_size > 65536) goto out;
    data = malloc(65537);
    if (!data) goto out;
    size_t n = 0;
    while (n < 65537) {
        ssize_t got = read(fd, data + n, 65537 - n);
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) goto bad;
        if (got == 0) break;
        n += (size_t)got;
    }
    if (n == 0 || n > 65536 || memchr(data, 0, n) || fstat(fd, &after) ||
        before.st_size != (off_t)n || before.st_size != after.st_size ||
        before.st_mtim.tv_sec != after.st_mtim.tv_sec || before.st_mtim.tv_nsec != after.st_mtim.tv_nsec ||
        before.st_ctim.tv_sec != after.st_ctim.tv_sec || before.st_ctim.tv_nsec != after.st_ctim.tv_nsec) goto bad;
    data[n] = 0; *length = n; close(fd); return data;
bad:
    explicit_bzero(data, 65537); free(data); data = NULL;
out:
    close(fd); return data;
}

int thin_ssh_authorized(int dir, ssh_key candidate) {
    size_t length = 0;
    char *text = read_key(dir, "authorized_keys", &length);
    if (!text) return -1;
    unsigned count = 0;
    int match = 0, valid = 1;
    char *save = NULL;
    for (char *line = strtok_r(text, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        size_t n = strlen(line);
        if (n && line[n-1] == '\r') line[n-1] = 0;
        while (*line == ' ' || *line == '\t') ++line;
        if (!*line || *line == '#') continue;
        char *fields = NULL;
        char *type = strtok_r(line, " \t", &fields);
        char *b64 = strtok_r(NULL, " \t", &fields);
        ssh_key key = NULL;
        if (++count > 32 || !type || strcmp(type, "ssh-ed25519") || !b64 || strlen(b64) > 2048 ||
            ssh_pki_import_pubkey_base64(b64, SSH_KEYTYPE_ED25519, &key) != SSH_OK || !key) {
            ssh_key_free(key); valid = 0; break;
        }
        if (candidate && ssh_key_cmp(candidate, key, SSH_KEY_CMP_PUBLIC) == 0) match = 1;
        ssh_key_free(key);
    }
    explicit_bzero(text, 65537); free(text);
    if (!valid || !count) return -1;
    return candidate ? match : 1;
}

static int no_passphrase(const char *prompt, char *buf, size_t len, int echo, int verify, void *arg) {
    (void)prompt; (void)buf; (void)len; (void)echo; (void)verify; (void)arg;
    return -1; /* Never prompt on daemon stdin or silently read an agent. */
}

int thin_ssh_host_key(int dir, int create, ssh_key *key) {
    const char *name = "ssh_host_ed25519_key";
    struct stat st;
    *key = NULL;
    if (fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) < 0) {
        if (errno != ENOENT || !create) return -1;
        ssh_key generated = NULL;
        char *encoded = NULL;
        if (ssh_pki_generate(SSH_KEYTYPE_ED25519, 0, &generated) != SSH_OK) return -1;
        int rc = ssh_pki_export_privkey_base64(generated, NULL, NULL, NULL, &encoded);
        ssh_key_free(generated);
        if (rc != SSH_OK || !encoded) return -1;
        unsigned char random[16];
        size_t got = 0;
        while (got < sizeof random) {
            ssize_t n = getrandom(random + got, sizeof random - got, 0);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            got += (size_t)n;
        }
        char temporary[64] = ".ssh-host-";
        for (size_t i = 0; i < sizeof random && got == sizeof random; ++i)
            snprintf(temporary + 10 + i*2, 3, "%02x", random[i]);
        int fd = got == sizeof random ? openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600) : -1;
        int ok = fd >= 0;
        size_t length = strlen(encoded), offset = 0;
        while (ok && offset < length) {
            ssize_t n = write(fd, encoded + offset, length - offset);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { ok = 0; break; }
            offset += (size_t)n;
        }
        if (ok && fsync(fd)) ok = 0;
        if (fd >= 0) close(fd);
        /* linkat publishes without replacement; an existing winner is loaded
         * and validated below. Our temporary name is removed on every path. */
        if (ok && linkat(dir, temporary, dir, name, 0) && errno != EEXIST) ok = 0;
        if (fd >= 0 && unlinkat(dir, temporary, 0)) ok = 0;
        if (ok && fsync(dir)) ok = 0;
        explicit_bzero(encoded, length); ssh_string_free_char(encoded);
        if (!ok) return -1;
    }
    size_t n = 0;
    char *encoded = read_key(dir, name, &n);
    if (!encoded) return -1;
    int rc = ssh_pki_import_privkey_base64(encoded, NULL, no_passphrase, NULL, key);
    explicit_bzero(encoded, 65537); free(encoded);
    if (rc != SSH_OK || !*key || ssh_key_type(*key) != SSH_KEYTYPE_ED25519) {
        ssh_key_free(*key); *key = NULL; return -1;
    }
    return 0;
}

int thin_ssh_listen(const char *address, const char *home) {
    char host[256], service[6];
    const char *port = NULL; size_t n;
    if (!address) return -1;
    if (*address == '[') {
        const char *end = strchr(address, ']');
        if (!end || end[1] != ':') return -1;
        n = (size_t)(end-address-1); port = end+2;
        if (!n || n >= sizeof host) return -1;
        memcpy(host, address+1, n);
    } else {
        const char *end = strrchr(address, ':');
        if (!end || strchr(address, ':') != end) return -1;
        n = (size_t)(end-address); port = end+1;
        if (!n || n >= sizeof host) return -1;
        memcpy(host, address, n);
    }
    host[n] = 0;
    n = strlen(port);
    if (!n || n > 5) return -1;
    unsigned number = 0;
    for (size_t i=0; i<n; ++i) { if (port[i]<'0'||port[i]>'9') return -1; number=number*10+(unsigned)(port[i]-'0'); }
    if (!number || number>65535) return -1;
    memcpy(service, port, n+1);
    struct addrinfo hints = {0}, *addr = NULL;
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV;
    if (getaddrinfo(host, service, &hints, &addr)) return -1;
    int fd = socket(addr->ai_family, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    int one = 1;
    if (fd >= 0) {
        if (setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&one,sizeof one) ||
            (addr->ai_family == AF_INET6 && setsockopt(fd,IPPROTO_IPV6,IPV6_V6ONLY,&one,sizeof one)) ||
            bind(fd,addr->ai_addr,addr->ai_addrlen) || listen(fd,32)) { close(fd); fd=-1; }
    }
    freeaddrinfo(addr);
    if (fd < 0) return -1;
    /* No session/protocol state in the parent, only startup key validation. */
    int dir = thin_ssh_key_directory(home, 1);
    ssh_key key = NULL;
    int ok = dir >= 0 && ssh_init() == SSH_OK && thin_ssh_authorized(dir,NULL) == 1 && thin_ssh_host_key(dir,1,&key) == 0;
    ssh_key_free(key);
    if (dir >= 0) close(dir);
    if (!ok) { close(fd); return -1; }
    return fd;
}

int thin_ssh_accept(int listener) {
    int fd = accept4(listener,NULL,NULL,SOCK_NONBLOCK|SOCK_CLOEXEC);
    if (fd >= 0) return fd;
    /* Admission pressure is local to new connections. Let the supervisor keep
     * serving existing sessions and retry on its next bounded tick. */
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR || errno == ECONNABORTED ||
        errno == EMFILE || errno == ENFILE || errno == ENOMEM || errno == ENOBUFS ||
        errno == ENETDOWN || errno == EPROTO || errno == ENOPROTOOPT || errno == EHOSTDOWN ||
        errno == ENONET || errno == EHOSTUNREACH || errno == EOPNOTSUPP || errno == ENETUNREACH) return -2;
    return -1;
}
