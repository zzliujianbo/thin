/* libssh owns protocol/cryptography. This boundary owns one session, on the
 * connection process's TUI thread; daemon/tasks never call these functions.
 * No inherited config, terminal device, shell command or client environment. */
#define _GNU_SOURCE
#include "ssh_transport.h"
#include <libssh/callbacks.h>
#include <libssh/server.h>
#include <sys/socket.h>
#include <sys/prctl.h>
#include <netinet/in.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <stdbool.h>
#include <stdio.h>
#include <errno.h>
#include <poll.h>

#define QUEUE_CAP 65536u
#define IO_CHUNK 16384u
#define INIT_MS 10000
#define FINISH_MS 500
static struct {
    int attempted, active, dead, eof, authenticated, pty, shell, keydir;
    int notification_registered, notification_fd;
    unsigned columns, rows;
    char home[4096];
    ssh_bind bind;
    ssh_session session;
    ssh_channel channel;
    ssh_event event;
    struct ssh_callbacks_struct common;
    struct ssh_server_callbacks_struct server;
    struct ssh_channel_callbacks_struct callbacks;
    unsigned char pending[QUEUE_CAP];
    size_t pending_length;
} g;

static int64_t now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC,&ts)) return INT64_MAX / 2;
    return (int64_t)ts.tv_sec*1000+ts.tv_nsec/1000000;
}
static void event(const char *kind) {
    /* Fixed categories only, no peer-supplied strings/keys/input. Parent drains
     * this pipe with the existing bounded process executor. */
    char text[96];
    int n=snprintf(text,sizeof text,"thin-ssh pid=%ld event=%s\n",(long)getpid(),kind);
    if(n>0 && (size_t)n<sizeof text) { ssize_t ignored=write(2,text,(size_t)n); (void)ignored; }
}
static int auth_none(ssh_session s,const char *user,void *arg) {
    (void)s;(void)user;(void)arg; return SSH_AUTH_DENIED;
}
static int auth_key(ssh_session s,const char *user,ssh_key key,char state,void *arg) {
    (void)s;(void)arg;
    int dir=thin_ssh_key_directory(g.home,0);
    int allowed=dir>=0 ? thin_ssh_authorized(dir,key) : -1;
    if(dir>=0) close(dir);
    if(!user || strcmp(user,"thin") || !key || allowed!=1) {
        event("auth_denied"); return SSH_AUTH_DENIED;
    }
    if(state==SSH_PUBLICKEY_STATE_NONE) { event("key_probe"); return SSH_AUTH_SUCCESS; }
    if(state!=SSH_PUBLICKEY_STATE_VALID) return SSH_AUTH_DENIED;
    g.authenticated=1; event("authenticated"); return SSH_AUTH_SUCCESS;
}
static int service(ssh_session s,const char *name,void *arg) {
    (void)s;(void)arg; return name && !strcmp(name,"ssh-userauth") ? 0 : -1;
}
static unsigned dimension(int n,unsigned max) { return n<1 ? 1 : (unsigned)n>max ? max : (unsigned)n; }
static int pty(ssh_session s,ssh_channel ch,const char *term,int w,int h,int pw,int ph,void *arg) {
    (void)s;(void)term;(void)pw;(void)ph;(void)arg;
    if(!g.authenticated || ch!=g.channel || g.pty) return -1;
    g.columns=dimension(w,512);g.rows=dimension(h,200);g.pty=1; return 0;
}
static int shell(ssh_session s,ssh_channel ch,void *arg) {
    (void)s;(void)arg;
    if(!g.authenticated || !g.pty || ch!=g.channel || g.shell) return 1;
    g.shell=1;return 0;
}
static int resize(ssh_session s,ssh_channel ch,int w,int h,int pw,int ph,void *arg) {
    (void)s;(void)pw;(void)ph;(void)arg;
    if(!g.authenticated || !g.pty || ch!=g.channel) return -1;
    g.columns=dimension(w,512);g.rows=dimension(h,200);return 0;
}
static int deny_exec(ssh_session s,ssh_channel ch,const char *text,void *arg) {
    (void)s;(void)ch;(void)text;(void)arg; event("reject_exec");return 1;
}
static int deny_env(ssh_session s,ssh_channel ch,const char *name,const char *value,void *arg) {
    (void)s;(void)ch;(void)name;(void)value;(void)arg;event("reject_env");return 1;
}
static int deny_subsystem(ssh_session s,ssh_channel ch,const char *name,void *arg) {
    (void)s;(void)ch;(void)name;(void)arg;event("reject_subsystem");return 1;
}
static void eof(ssh_session s,ssh_channel ch,void *arg) {
    (void)s;(void)ch;(void)arg;g.eof=1;
}
static ssh_channel open_channel(ssh_session s,void *arg) {
    (void)arg;
    if(!g.authenticated || g.channel) return NULL;
    ssh_channel ch=ssh_channel_new(s);
    if(!ch) return NULL;
    ssh_callbacks_init(&g.callbacks);
    g.callbacks.channel_pty_request_function=pty;
    g.callbacks.channel_shell_request_function=shell;
    g.callbacks.channel_pty_window_change_function=resize;
    g.callbacks.channel_exec_request_function=deny_exec;
    g.callbacks.channel_env_request_function=deny_env;
    g.callbacks.channel_subsystem_request_function=deny_subsystem;
    g.callbacks.channel_eof_function=eof;
    g.callbacks.channel_close_function=eof;
    /* Registering agent/X11 callbacks accepts those requests in libssh 0.10.
     * Leave them unset, as well as forwarding channel-open callbacks. */
    if(ssh_set_channel_callbacks(ch,&g.callbacks)!=SSH_OK) { ssh_channel_free(ch);return NULL; }
    g.channel=ch;return ch;
}
static void global_request(ssh_session s,ssh_message message,void *arg) {
    (void)s;(void)arg;
    if(!message) return;
    if(ssh_message_subtype(message)==SSH_GLOBAL_REQUEST_KEEPALIVE)
        (void)ssh_message_global_request_reply_success(message,0);
    else { event("reject_global");(void)ssh_message_reply_default(message); }
}

void thin_ssh_close(void) {
    g.active=0;
    if(g.channel) { ssh_channel_free(g.channel);g.channel=NULL; }
    if(g.event) {
        if(g.notification_registered) {
            (void)ssh_event_remove_fd(g.event,g.notification_fd);
            g.notification_registered=0;
        }
        if(g.session) (void)ssh_event_remove_session(g.event,g.session);
        ssh_event_free(g.event);g.event=NULL;
    }
    if(g.session) { ssh_silent_disconnect(g.session);ssh_free(g.session);g.session=NULL; }
    if(g.bind) { ssh_bind_free(g.bind);g.bind=NULL; }
    if(g.keydir>=0 && g.attempted) { close(g.keydir);g.keydir=-1; }
    explicit_bzero(g.pending,sizeof g.pending);g.pending_length=0;
}

int thin_ssh_init(int fd,const char *home,int owner_pid) {
    /* A managed child receives the accepted socket as stdin through the
     * existing exec handshake; never enabled by ambient environment flags. */
    if(g.attempted) return -1;
    g.attempted=1;g.keydir=-1;
    struct sockaddr_storage peer; socklen_t size=sizeof peer;
    int type=0; socklen_t type_size=sizeof type;
    ssh_key host=NULL; bool config=false;
    if(owner_pid<=1 || getppid()!=owner_pid || prctl(PR_SET_PDEATHSIG,SIGTERM) || getppid()!=owner_pid ||
        getpeername(fd,(struct sockaddr *)&peer,&size) ||
        (peer.ss_family!=AF_INET && peer.ss_family!=AF_INET6) ||
        getsockopt(fd,SOL_SOCKET,SO_TYPE,&type,&type_size) || type!=SOCK_STREAM) goto fail;
    int flags=fcntl(fd,F_GETFL);
    if(flags<0 || fcntl(fd,F_SETFL,flags|O_NONBLOCK)<0 || fcntl(fd,F_SETFD,FD_CLOEXEC)<0) goto fail;
    if(!home || strlen(home)>=sizeof g.home) goto fail;
    memcpy(g.home,home,strlen(home)+1);
    g.keydir=thin_ssh_key_directory(home,0);
    if(g.keydir<0 || ssh_init()!=SSH_OK || thin_ssh_host_key(g.keydir,0,&host)) goto fail;
    g.bind=ssh_bind_new();
    if(!g.bind || ssh_bind_options_set(g.bind,SSH_BIND_OPTIONS_PROCESS_CONFIG,&config)!=SSH_OK) goto fail;
    if(ssh_bind_options_set(g.bind,SSH_BIND_OPTIONS_IMPORT_KEY,host)!=SSH_OK) goto fail;
    host=NULL; /* bind owns it */
    g.session=ssh_new();
    if(!g.session) goto fail;
    /* In libssh 0.10 accept_fd can fail both before and after taking the fd,
     * including after replacing its opaque socket. Never guess ownership or
     * double-close it. No backend/task exists yet: fail-stop this connection
     * process and let the kernel reclaim ALL partially initialized resources. */
    if(ssh_bind_accept_fd(g.bind,g.session,fd)!=SSH_OK) _exit(1);
    fd=-1; /* session owns it */
    ssh_set_blocking(g.session,0);
    ssh_set_auth_methods(g.session,SSH_AUTH_METHOD_PUBLICKEY);
    ssh_callbacks_init(&g.server);
    g.server.auth_none_function=auth_none;
    g.server.auth_pubkey_function=auth_key;
    g.server.service_request_function=service;
    g.server.channel_open_request_session_function=open_channel;
    if(ssh_set_server_callbacks(g.session,&g.server)!=SSH_OK) goto fail;
    ssh_callbacks_init(&g.common);g.common.global_request_function=global_request;
    if(ssh_set_callbacks(g.session,&g.common)!=SSH_OK) goto fail;
    g.event=ssh_event_new();if(!g.event) goto fail;
    int64_t deadline=now_ms()+INIT_MS;
    int rc=ssh_handle_key_exchange(g.session);
    if(rc!=SSH_OK && rc!=SSH_AGAIN) goto fail;
    if(ssh_event_add_session(g.event,g.session)!=SSH_OK) goto fail;
    while(rc!=SSH_OK) {
        int64_t remain=deadline-now_ms();if(remain<=0) goto timeout;
        if(ssh_event_dopoll(g.event,(int)(remain>50?50:remain))==SSH_ERROR) goto fail;
        rc=ssh_handle_key_exchange(g.session);
        if(rc!=SSH_OK && rc!=SSH_AGAIN) goto fail;
    }
    while(!g.shell) {
        int64_t remain=deadline-now_ms();if(remain<=0) goto timeout;
        if(g.eof || !ssh_is_connected(g.session) || ssh_event_dopoll(g.event,(int)(remain>50?50:remain))==SSH_ERROR) goto fail;
    }
    g.active=1;event("ready");return 0;
timeout:
    event("handshake_timeout");
fail:
    ssh_key_free(host);
    if(fd>=0) close(fd);
    thin_ssh_close();return -1;
}

int thin_ssh_active(void) { return g.active; }
static void flush(void) {
    while(g.pending_length && !g.dead && !g.eof && g.channel && ssh_channel_is_open(g.channel)) {
        /* Bound libssh's send queue too: at most one chunk behind its socket. */
        if(ssh_get_status(g.session)&SSH_WRITE_PENDING) return;
        uint32_t window=ssh_channel_window_size(g.channel);
        size_t n=g.pending_length;
        if(n>IO_CHUNK) n=IO_CHUNK;
        if(n>window) n=window;
        if(!n) return;
        int written=ssh_channel_write(g.channel,g.pending,(uint32_t)n);
        if(written==SSH_AGAIN || written==0) return;
        if(written<0 || (size_t)written>n) { g.dead=1;return; }
        memmove(g.pending,g.pending+written,g.pending_length-(size_t)written);
        g.pending_length-=(size_t)written;
    }
}
ptrdiff_t thin_ssh_write(const void *data,size_t length) {
    if(!g.active || g.dead || g.eof) return -1;
    flush();if(g.dead) return -1;
    size_t n=QUEUE_CAP-g.pending_length;if(n>length) n=length;
    memcpy(g.pending+g.pending_length,data,n);g.pending_length+=n;flush();
    return g.dead ? -1 : (ptrdiff_t)n;
}
ptrdiff_t thin_ssh_read(void *out,size_t length) {
    if(!g.active || g.dead) return -1;
    if(length>IO_CHUNK) length=IO_CHUNK;
    int rc=ssh_channel_read_nonblocking(g.channel,out,(uint32_t)length,0);
    if(rc>0) return rc;
    if(rc==SSH_ERROR || (rc!=SSH_AGAIN && (g.eof || ssh_channel_is_eof(g.channel) || !ssh_is_connected(g.session)))) return -1;
    return 0;
}
static int notification_ready(int fd,int revents,void *data) {
    (void)fd;(void)revents;(void)data;
    /* Wake only. The TUI consumes the queue and drains its eventfd, never this
     * libssh callback. All registration/removal remains on the SSH owner. */
    return 0;
}
int thin_ssh_notification_fd(int fd) {
    if(!g.active || !g.event) return -1;
    if(g.notification_registered) {
        if(ssh_event_remove_fd(g.event,g.notification_fd)!=SSH_OK) return -1;
        g.notification_registered=0;
    }
    if(fd<0) return 0;
    if(ssh_event_add_fd(g.event,fd,POLLIN,notification_ready,NULL)!=SSH_OK) return -1;
    g.notification_fd=fd;g.notification_registered=1;
    return 0;
}
int thin_ssh_wait(int want_write,int ms) {
    (void)want_write;
    if(!g.active || g.dead) return -1;
    flush();if(ms<0) ms=0;if(ms>100) ms=100;
    if(ssh_event_dopoll(g.event,ms)==SSH_ERROR) return -1;
    flush();return g.dead ? -1 : 0;
}
void thin_ssh_size(unsigned *columns,unsigned *rows) { *columns=g.columns;*rows=g.rows; }
static int drain(int64_t deadline) {
    for(;;) {
        flush();
        if(g.dead || !g.session) return -1;
        int status=ssh_get_status(g.session);
        if(!g.pending_length && !(status&SSH_WRITE_PENDING)) return 0;
        if((status&(SSH_CLOSED|SSH_CLOSED_ERROR)) || now_ms()>=deadline) return -1;
        if(ssh_event_dopoll(g.event,10)==SSH_ERROR) return -1;
    }
}
int thin_ssh_finish(int code) {
    if(!g.active || g.dead || !g.shell || !ssh_is_connected(g.session)) return -1;
    int64_t deadline=now_ms()+FINISH_MS;
    if(drain(deadline)) return -1; /* Never announce success with discarded tail. */
    int rc=ssh_channel_request_send_exit_status(g.channel,code);
    if(rc!=SSH_OK && rc!=SSH_AGAIN) return -1;
    do {
        rc=ssh_channel_send_eof(g.channel);
        if(rc==SSH_AGAIN && (now_ms()>=deadline || ssh_event_dopoll(g.event,10)==SSH_ERROR)) return -1;
    } while(rc==SSH_AGAIN);
    if(rc!=SSH_OK) return -1;
    do {
        rc=ssh_channel_close(g.channel);
        if(rc==SSH_AGAIN && (now_ms()>=deadline || ssh_event_dopoll(g.event,10)==SSH_ERROR)) return -1;
    } while(rc==SSH_AGAIN);
    if(rc!=SSH_OK || drain(deadline)) return -1;
    event("finished");return 0;
}
