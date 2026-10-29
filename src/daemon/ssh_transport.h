/* Linux libssh boundary. One SSH session per connection process, never shared
 * across threads or forked after initialization. All terminal calls are serial.
 * No shell, PTY, environment forwarding, or application task execution here. */
#ifndef THIN_SSH_TRANSPORT_H
#define THIN_SSH_TRANSPORT_H
#include <stddef.h>
#include <libssh/libssh.h>
int thin_ssh_listen(const char *address, const char *home);
int thin_ssh_accept(int listener);
int thin_ssh_init(int fd, const char *home, int owner_pid);
int thin_ssh_active(void);
ptrdiff_t thin_ssh_read(void *out, size_t length);
ptrdiff_t thin_ssh_write(const void *data, size_t length);
int thin_ssh_wait(int want_write, int ms);
int thin_ssh_notification_fd(int fd);
void thin_ssh_size(unsigned *columns, unsigned *rows);
int thin_ssh_finish(int code);
void thin_ssh_close(void);
/* Private anchored key store helpers. Returned directory/key are caller-owned. */
int thin_ssh_key_directory(const char *home, int create);
int thin_ssh_host_key(int dir, int create, ssh_key *key);
/* key==NULL validates the complete authorized list without authenticating. */
int thin_ssh_authorized(int dir, ssh_key key);
#endif
