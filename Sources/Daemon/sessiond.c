// diffterm-sessiond — the persistent owner of the shells.
//
// The problem it solves: an app's child processes die when iOS suspends or
// jetsams the app, so backgrounding diffTerm kills whatever was running. This
// daemon is started by launchd, not by the app, so it lives outside the app's
// process coalition and survives the app being backgrounded, killed, or
// force-quit. It owns each shell's pty; the app is only a client that streams
// bytes to and from it over a unix socket. Nothing about the terminal is
// interpreted here — it is a transparent conduit, so the app's own emulator
// still sees the raw shell output (OSC 133 marks and all), and every feature
// built on that keeps working.
//
// Per session it keeps a ring buffer of recent output, so a client that
// reattaches after being away is replayed what it missed and comes back to a
// live screen rather than a dead snapshot.
//
// Protocol, framed both ways as: type(u8) session(u32 LE) length(u32 LE) payload.
//   client -> daemon: LIST, CREATE, ATTACH, DATA(input), RESIZE, DETACH,
//                     CLOSE(kill), PING.
//   daemon -> client: DATA(output), EXIT(status), SESSIONS(list), OK, ERR.

#include "../CBridge/DTPty.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>

// Message types.
enum {
    MSG_LIST    = 0x01,
    MSG_CREATE  = 0x02,
    MSG_ATTACH  = 0x03,
    MSG_DATA    = 0x04,   // client -> daemon: input to the pty
    MSG_RESIZE  = 0x05,
    MSG_DETACH  = 0x06,
    MSG_CLOSE   = 0x07,
    MSG_PING    = 0x08,

    MSG_OUTPUT   = 0x81,  // daemon -> client: output from the pty
    MSG_EXIT     = 0x82,
    MSG_SESSIONS = 0x83,
    MSG_OK       = 0x84,
    MSG_ERR      = 0x85,
    MSG_PONG     = 0x86,
};

#define MAX_SESSIONS 64
#define MAX_CLIENTS  8
#define RING_CAP     (512 * 1024)
// How long a finished session's transcript is kept for a late attach.
#define REAP_GRACE_SECS 30

typedef struct {
    int       in_use;
    uint32_t  id;
    int       master;     // pty master fd, -1 when gone
    pid_t     pid;
    int       exited;
    int       status;
    time_t    exited_at;
    int       client;     // attached client fd, -1 when detached
    unsigned char *ring;
    size_t    ring_len;   // valid bytes, <= RING_CAP
    size_t    ring_head;  // index of the oldest byte
} session_t;

typedef struct {
    int    fd;            // -1 when free
    unsigned char *buf;   // partial inbound frame
    size_t len, cap;
} client_t;

static session_t sessions[MAX_SESSIONS];
static client_t  clients[MAX_CLIENTS];

// ---- small helpers ---------------------------------------------------------

static void put_u32(unsigned char *p, uint32_t v) {
    p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; p[2] = (v >> 16) & 0xFF; p[3] = (v >> 24) & 0xFF;
}
static uint32_t get_u32(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint16_t get_u16(const unsigned char *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

// Write all bytes, tolerating short writes; returns 0 on success, -1 on error.
static int write_all(int fd, const unsigned char *data, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, data + off, len - off);
        if (n > 0) { off += (size_t)n; continue; }
        if (n < 0 && (errno == EINTR)) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            // The client is not draining; drop rather than block the whole
            // daemon. A slow client loses bytes, not the session.
            return -1;
        }
        return -1;
    }
    return 0;
}

static int send_frame(int fd, uint8_t type, uint32_t session,
                      const unsigned char *payload, uint32_t len) {
    unsigned char hdr[9];
    hdr[0] = type;
    put_u32(hdr + 1, session);
    put_u32(hdr + 5, len);
    if (write_all(fd, hdr, sizeof(hdr)) != 0) return -1;
    if (len && write_all(fd, payload, len) != 0) return -1;
    return 0;
}

// ---- sessions --------------------------------------------------------------

static session_t *session_find(uint32_t id) {
    for (int i = 0; i < MAX_SESSIONS; i++)
        if (sessions[i].in_use && sessions[i].id == id) return &sessions[i];
    return NULL;
}

static session_t *session_alloc(void) {
    for (int i = 0; i < MAX_SESSIONS; i++)
        if (!sessions[i].in_use) return &sessions[i];
    return NULL;
}

static void ring_append(session_t *s, const unsigned char *data, size_t len) {
    if (!s->ring) return;
    if (len >= RING_CAP) {
        // Keep only the tail that fits.
        memcpy(s->ring, data + (len - RING_CAP), RING_CAP);
        s->ring_len = RING_CAP;
        s->ring_head = 0;
        return;
    }
    for (size_t i = 0; i < len; i++) {
        size_t pos = (s->ring_head + s->ring_len) % RING_CAP;
        if (s->ring_len < RING_CAP) {
            s->ring[pos] = data[i];
            s->ring_len++;
        } else {
            s->ring[s->ring_head] = data[i];
            s->ring_head = (s->ring_head + 1) % RING_CAP;
        }
    }
}

// Replay the whole ring to a client as OUTPUT frames.
static void ring_replay(session_t *s, int fd) {
    if (!s->ring || s->ring_len == 0) return;
    // The ring is circular; send in up to two contiguous spans.
    size_t first = s->ring_head + s->ring_len <= RING_CAP
                   ? s->ring_len
                   : RING_CAP - s->ring_head;
    send_frame(fd, MSG_OUTPUT, s->id, s->ring + s->ring_head, (uint32_t)first);
    if (first < s->ring_len)
        send_frame(fd, MSG_OUTPUT, s->id, s->ring, (uint32_t)(s->ring_len - first));
}

static void session_free(session_t *s) {
    if (s->master >= 0) { close(s->master); s->master = -1; }
    if (s->ring) { free(s->ring); s->ring = NULL; }
    memset(s, 0, sizeof(*s));
    s->master = -1;
    s->client = -1;
}

// Detach any client currently on this session (used when another steals it,
// or when a client disconnects).
static void session_detach_client(int fd) {
    for (int i = 0; i < MAX_SESSIONS; i++)
        if (sessions[i].in_use && sessions[i].client == fd)
            sessions[i].client = -1;
}

// ---- CREATE payload parsing -----------------------------------------------
//
// cols(u16) rows(u16) then NUL-terminated strings:
//   cwd, exe, then argv... terminated by an empty string, then envp...
//   terminated by an empty string.

static int handle_create(session_t *s, const unsigned char *p, uint32_t len) {
    if (len < 4) return -1;
    uint16_t cols = get_u16(p);
    uint16_t rows = get_u16(p + 2);
    const char *cur = (const char *)(p + 4);
    const char *end = (const char *)(p + len);

    // A run of NUL-terminated strings; bounded by `end`.
    #define NEXT_STR(dst) do { \
        (dst) = cur; \
        while (cur < end && *cur) cur++; \
        if (cur >= end) return -1; \
        cur++; /* skip NUL */ \
    } while (0)

    const char *cwd; NEXT_STR(cwd);
    // The exec path is sent separately from argv, because a login shell's
    // argv[0] is "-zsh", not a path execve can find.
    const char *exe; NEXT_STR(exe);

    char *argv[256]; int argc = 0;
    for (;;) {
        const char *a; NEXT_STR(a);
        if (*a == '\0') break;                 // empty string ends args
        if (argc >= 255) return -1;
        argv[argc++] = (char *)a;
    }
    argv[argc] = NULL;
    if (argc == 0) return -1;

    char *envp[512]; int envc = 0;
    for (;;) {
        if (cur >= end) break;                 // env is optional / may run out
        const char *e; NEXT_STR(e);
        if (*e == '\0') break;
        if (envc >= 511) break;
        envp[envc++] = (char *)e;
    }
    envp[envc] = NULL;
    #undef NEXT_STR

    int master = -1; pid_t pid = -1;
    // argv[0] is the exec path.
    int rc = dt_spawn_pty(exe, argv, envp, cwd, cols, rows, &master, &pid);
    if (rc != 0) return rc;

    s->master = master;
    s->pid = pid;
    s->exited = 0;
    s->ring = malloc(RING_CAP);
    s->ring_len = 0;
    s->ring_head = 0;
    return 0;
}

// ---- client frame dispatch -------------------------------------------------

static void handle_frame(client_t *c, uint8_t type, uint32_t sid,
                         const unsigned char *payload, uint32_t len) {
    switch (type) {
    case MSG_PING:
        send_frame(c->fd, MSG_PONG, 0, NULL, 0);
        break;

    case MSG_LIST: {
        unsigned char buf[4 + MAX_SESSIONS * 9];
        uint32_t count = 0;
        unsigned char *w = buf + 4;
        for (int i = 0; i < MAX_SESSIONS; i++) {
            if (!sessions[i].in_use) continue;
            put_u32(w, sessions[i].id); w += 4;
            put_u32(w, (uint32_t)sessions[i].pid); w += 4;
            *w++ = sessions[i].exited ? 0 : 1;
            count++;
        }
        put_u32(buf, count);
        send_frame(c->fd, MSG_SESSIONS, 0, buf, (uint32_t)(w - buf));
        break;
    }

    case MSG_CREATE: {
        session_t *s = session_find(sid);
        if (s) {
            // Already exists — treat CREATE as an attach so a relaunch that
            // does not know the session is live still lands on it.
            session_detach_client(c->fd);
            s->client = c->fd;
            send_frame(c->fd, MSG_OK, sid, NULL, 0);
            ring_replay(s, c->fd);
            if (s->exited) {
                unsigned char st[4]; put_u32(st, (uint32_t)s->status);
                send_frame(c->fd, MSG_EXIT, sid, st, 4);
            }
            break;
        }
        s = session_alloc();
        if (!s) { send_frame(c->fd, MSG_ERR, sid, NULL, 0); break; }
        memset(s, 0, sizeof(*s));
        s->in_use = 1; s->id = sid; s->master = -1; s->client = -1;
        if (handle_create(s, payload, len) != 0) {
            session_free(s);
            send_frame(c->fd, MSG_ERR, sid, NULL, 0);
            break;
        }
        s->client = c->fd;
        send_frame(c->fd, MSG_OK, sid, NULL, 0);
        break;
    }

    case MSG_ATTACH: {
        session_t *s = session_find(sid);
        if (!s) { send_frame(c->fd, MSG_ERR, sid, NULL, 0); break; }
        session_detach_client(c->fd);
        s->client = c->fd;
        send_frame(c->fd, MSG_OK, sid, NULL, 0);
        ring_replay(s, c->fd);
        if (s->exited) {
            unsigned char st[4]; put_u32(st, (uint32_t)s->status);
            send_frame(c->fd, MSG_EXIT, sid, st, 4);
        }
        break;
    }

    case MSG_DATA: {
        session_t *s = session_find(sid);
        if (s && s->master >= 0 && !s->exited) write_all(s->master, payload, len);
        break;
    }

    case MSG_RESIZE: {
        session_t *s = session_find(sid);
        if (s && s->master >= 0 && len >= 8) {
            dt_set_winsize(s->master, get_u16(payload), get_u16(payload + 2),
                           get_u16(payload + 4), get_u16(payload + 6));
        }
        break;
    }

    case MSG_DETACH: {
        session_t *s = session_find(sid);
        if (s && s->client == c->fd) s->client = -1;
        break;
    }

    case MSG_CLOSE: {
        session_t *s = session_find(sid);
        if (s) {
            if (s->master >= 0 && !s->exited)
                dt_signal_foreground(s->master, s->pid, SIGHUP);
            // It will be reaped and freed by the main loop.
            if (s->pid > 0) kill(s->pid, SIGHUP);
        }
        break;
    }
    }
}

// Feed a client's newly-read bytes, extracting complete frames.
static void client_consume(client_t *c) {
    size_t off = 0;
    while (c->len - off >= 9) {
        const unsigned char *h = c->buf + off;
        uint8_t type = h[0];
        uint32_t sid = get_u32(h + 1);
        uint32_t plen = get_u32(h + 5);
        if (plen > RING_CAP) { c->len = 0; return; }   // malformed; reset
        if (c->len - off - 9 < plen) break;            // wait for more
        handle_frame(c, type, sid, h + 9, plen);
        off += 9 + plen;
    }
    if (off > 0) {
        memmove(c->buf, c->buf + off, c->len - off);
        c->len -= off;
    }
}

static void client_close(client_t *c) {
    if (c->fd < 0) return;
    session_detach_client(c->fd);
    close(c->fd);
    c->fd = -1;
    if (c->buf) { free(c->buf); c->buf = NULL; }
    c->len = c->cap = 0;
}

// ---- main ------------------------------------------------------------------

// Best-effort `mkdir -p` of a socket's parent directory, so the daemon can
// start before the app has ever created its Application Support folder.
static void mkdir_parents(const char *path) {
    char buf[1024];
    strncpy(buf, path, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = 0;
    char *slash = strrchr(buf, '/');
    if (!slash) return;
    *slash = 0;
    for (char *p = buf + 1; *p; p++) {
        if (*p == '/') { *p = 0; mkdir(buf, 0700); *p = '/'; }
    }
    mkdir(buf, 0700);
}

static int make_listener(const char *path) {
    mkdir_parents(path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    unlink(path);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return -1; }
    chmod(path, 0600);
    if (listen(fd, 8) != 0) { close(fd); return -1; }
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    return fd;
}

int main(int argc, char **argv) {
    const char *sock_path = argc > 1 ? argv[1]
        : "/var/jb/var/mobile/Library/Application Support/diffTerm/sessiond.sock";

    signal(SIGPIPE, SIG_IGN);
    // SIGCHLD is deliberately left at its default: setting it to SIG_IGN makes
    // the system auto-reap children, and then our own waitpid(WNOHANG) can
    // never observe an exit — so the shell's EXIT would never reach the app.
    // We reap explicitly each loop, so zombies do not accumulate.

    for (int i = 0; i < MAX_SESSIONS; i++) { sessions[i].master = -1; sessions[i].client = -1; }
    for (int i = 0; i < MAX_CLIENTS; i++)  { clients[i].fd = -1; }

    int lfd = make_listener(sock_path);
    if (lfd < 0) { fprintf(stderr, "sessiond: cannot listen on %s: %s\n", sock_path, strerror(errno)); return 1; }

    unsigned char rbuf[65536];

    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(lfd, &rfds);
        int maxfd = lfd;
        for (int i = 0; i < MAX_CLIENTS; i++)
            if (clients[i].fd >= 0) { FD_SET(clients[i].fd, &rfds); if (clients[i].fd > maxfd) maxfd = clients[i].fd; }
        for (int i = 0; i < MAX_SESSIONS; i++)
            if (sessions[i].in_use && sessions[i].master >= 0)
                { FD_SET(sessions[i].master, &rfds); if (sessions[i].master > maxfd) maxfd = sessions[i].master; }

        struct timeval tv = { 1, 0 };
        int n = select(maxfd + 1, &rfds, NULL, NULL, &tv);
        if (n < 0) { if (errno == EINTR) continue; break; }

        // New client.
        if (FD_ISSET(lfd, &rfds)) {
            int cfd = accept(lfd, NULL, NULL);
            if (cfd >= 0) {
                int slot = -1;
                for (int i = 0; i < MAX_CLIENTS; i++) if (clients[i].fd < 0) { slot = i; break; }
                if (slot < 0) { close(cfd); }
                else {
                    int fl = fcntl(cfd, F_GETFL, 0);
                    if (fl >= 0) fcntl(cfd, F_SETFL, fl | O_NONBLOCK);
                    clients[slot].fd = cfd;
                    clients[slot].len = 0; clients[slot].cap = 0; clients[slot].buf = NULL;
                }
            }
        }

        // Client input.
        for (int i = 0; i < MAX_CLIENTS; i++) {
            client_t *c = &clients[i];
            if (c->fd < 0 || !FD_ISSET(c->fd, &rfds)) continue;
            ssize_t r = read(c->fd, rbuf, sizeof(rbuf));
            if (r > 0) {
                size_t need = c->len + (size_t)r;
                if (need > c->cap) {
                    size_t ncap = c->cap ? c->cap : 4096;
                    while (ncap < need) ncap *= 2;
                    unsigned char *nb = realloc(c->buf, ncap);
                    if (!nb) { client_close(c); continue; }
                    c->buf = nb; c->cap = ncap;
                }
                memcpy(c->buf + c->len, rbuf, (size_t)r);
                c->len = need;
                client_consume(c);
            } else if (r == 0) {
                client_close(c);
            } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                client_close(c);
            }
        }

        // pty output.
        for (int i = 0; i < MAX_SESSIONS; i++) {
            session_t *s = &sessions[i];
            if (!s->in_use || s->master < 0 || !FD_ISSET(s->master, &rfds)) continue;
            ssize_t r = read(s->master, rbuf, sizeof(rbuf));
            if (r > 0) {
                ring_append(s, rbuf, (size_t)r);
                if (s->client >= 0) {
                    if (send_frame(s->client, MSG_OUTPUT, s->id, rbuf, (uint32_t)r) != 0)
                        s->client = -1;   // client wedged; keep the session
                }
            } else if (r == 0 || (r < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
                // pty closed — the shell is gone. Close the fd; reap below.
                close(s->master); s->master = -1;
            }
        }

        // Reap exited shells; GC long-finished sessions.
        time_t now = time(NULL);
        for (int i = 0; i < MAX_SESSIONS; i++) {
            session_t *s = &sessions[i];
            if (!s->in_use) continue;
            if (!s->exited && s->pid > 0) {
                int status = 0, rc = dt_try_reap(s->pid, &status);
                if (rc == 1) {
                    s->exited = 1;
                    s->status = WIFEXITED(status) ? WEXITSTATUS(status)
                              : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : status);
                    s->exited_at = now;
                    if (s->master >= 0) { close(s->master); s->master = -1; }
                    if (s->client >= 0) {
                        unsigned char st[4]; put_u32(st, (uint32_t)s->status);
                        send_frame(s->client, MSG_EXIT, s->id, st, 4);
                    }
                }
            }
            if (s->exited && (now - s->exited_at) > REAP_GRACE_SECS)
                session_free(s);
        }
    }

    return 0;
}
