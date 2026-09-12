// dtclip — the program installed into the app bundle as both `pbcopy` and
// `pbpaste`, dispatched on argv[0].
//
// It exists because the bootstrap's own pbcopy/pbpaste cannot reach the
// pasteboard on a rootless jailbreak: they fail with "the pasteboard name
// com.apple.UIKit.pboard.general is not valid" and then **exit 0 anyway**.
// That false success is the whole problem — every tool that copies (Claude
// Code's "press c", gh, fzf, vim's + register) believes it worked. So the one
// rule here is that this program never reports a success it did not have.
//
// Copy goes one of two ways:
//
//   * over the per-session socket named by $DIFFTERM_CLIPBOARD, when running
//     as a child of diffTerm, or
//   * as an OSC 52 write to the controlling terminal otherwise, which is what
//     makes it work over ssh and in other terminals.
//
// Paste is socket-only, and deliberately so. diffTerm refuses OSC 52 *reads*
// so that nothing on the far end of an ssh connection can ask the terminal
// what is on your clipboard; reading it back therefore has to be a local
// process holding a socket the app handed out, which the app can gate.

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <fcntl.h>

/* Matches the emulator's own OSC 52 ceiling (Emulator+OSC.swift). */
#define MAX_CLIP (1 << 20)

static const char *progname = "pbcopy";

static void fail(const char *msg) {
    fprintf(stderr, "%s: %s\n", progname, msg);
    exit(1);
}

static void failerr(const char *msg) {
    fprintf(stderr, "%s: %s: %s\n", progname, msg, strerror(errno));
    exit(1);
}

/* ---------------------------------------------------------------- socket */

static int clip_connect(void) {
    const char *path = getenv("DIFFTERM_CLIPBOARD");
    if (path == NULL || *path == '\0') return -1;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof addr.sun_path) return -1;
    strncpy(addr.sun_path, path, sizeof addr.sun_path - 1);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr *)&addr, (socklen_t)sizeof addr) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int write_all(int fd, const char *buf, size_t len) {
    while (len > 0) {
        ssize_t n = write(fd, buf, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        buf += n;
        len -= (size_t)n;
    }
    return 0;
}

static int read_all(int fd, char *buf, size_t len) {
    while (len > 0) {
        ssize_t n = read(fd, buf, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        buf += n;
        len -= (size_t)n;
    }
    return 0;
}

/* Reads one \n-terminated status line. */
static int read_line(int fd, char *buf, size_t cap) {
    size_t used = 0;
    while (used + 1 < cap) {
        char c;
        ssize_t n = read(fd, &c, 1);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        if (c == '\n') break;
        buf[used++] = c;
    }
    buf[used] = '\0';
    return 0;
}

/* ---------------------------------------------------------------- base64 */

static const char b64set[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static char *b64encode(const unsigned char *in, size_t len) {
    size_t out_len = (len + 2) / 3 * 4;
    char *out = malloc(out_len + 1);
    if (out == NULL) return NULL;

    size_t i = 0, o = 0;
    while (i + 2 < len) {
        unsigned v = ((unsigned)in[i] << 16) | ((unsigned)in[i + 1] << 8) | in[i + 2];
        out[o++] = b64set[(v >> 18) & 0x3F];
        out[o++] = b64set[(v >> 12) & 0x3F];
        out[o++] = b64set[(v >> 6) & 0x3F];
        out[o++] = b64set[v & 0x3F];
        i += 3;
    }
    if (i < len) {
        unsigned v = (unsigned)in[i] << 16;
        int rest = (int)(len - i);
        if (rest > 1) v |= (unsigned)in[i + 1] << 8;
        out[o++] = b64set[(v >> 18) & 0x3F];
        out[o++] = b64set[(v >> 12) & 0x3F];
        out[o++] = rest > 1 ? b64set[(v >> 6) & 0x3F] : '=';
        out[o++] = '=';
    }
    out[o] = '\0';
    return out;
}

/* ------------------------------------------------------------------ copy */

static unsigned char *read_stdin(size_t *out_len) {
    size_t cap = 65536, len = 0;
    unsigned char *buf = malloc(cap);
    if (buf == NULL) fail("out of memory");

    for (;;) {
        if (len == cap) {
            /* One byte past the ceiling is enough to know it is too big. */
            if (cap > MAX_CLIP) break;
            cap *= 2;
            unsigned char *grown = realloc(buf, cap);
            if (grown == NULL) fail("out of memory");
            buf = grown;
        }
        ssize_t n = read(STDIN_FILENO, buf + len, cap - len);
        if (n < 0) {
            if (errno == EINTR) continue;
            failerr("read");
        }
        if (n == 0) break;
        len += (size_t)n;
    }

    /* Truncating silently is the failure mode this program exists to fix. */
    if (len > MAX_CLIP) fail("input is larger than the 1 MiB clipboard limit");
    *out_len = len;
    return buf;
}

/* Writes the OSC 52 sequence to the controlling terminal. Returns 0 on
   success. Used when there is no diffTerm socket — over ssh, or in another
   terminal that honours OSC 52. */
static int copy_via_osc52(const unsigned char *data, size_t len) {
    int fd = open("/dev/tty", O_WRONLY | O_NOCTTY);
    if (fd < 0) {
        /* No controlling terminal: stderr may still be one. */
        if (!isatty(STDERR_FILENO)) return -1;
        fd = dup(STDERR_FILENO);
        if (fd < 0) return -1;
    }

    char *b64 = b64encode(data, len);
    if (b64 == NULL) { close(fd); return -1; }

    int rc = 0;
    if (write_all(fd, "\033]52;c;", 7) < 0) rc = -1;
    if (rc == 0 && write_all(fd, b64, strlen(b64)) < 0) rc = -1;
    if (rc == 0 && write_all(fd, "\007", 1) < 0) rc = -1;

    free(b64);
    close(fd);
    return rc;
}

static int do_copy(void) {
    size_t len = 0;
    unsigned char *data = read_stdin(&len);

    int fd = clip_connect();
    if (fd >= 0) {
        char header[64];
        int hn = snprintf(header, sizeof header, "COPY %zu\n", len);
        char status[128];
        if (write_all(fd, header, (size_t)hn) == 0 &&
            write_all(fd, (const char *)data, len) == 0 &&
            read_line(fd, status, sizeof status) == 0) {
            close(fd);
            free(data);
            if (strcmp(status, "OK") == 0) return 0;
            fprintf(stderr, "%s: %s\n", progname,
                    strncmp(status, "ERR ", 4) == 0 ? status + 4 : status);
            return 1;
        }
        close(fd);
        /* Fall through to OSC 52 rather than giving up. */
    }

    int rc = copy_via_osc52(data, len);
    free(data);
    if (rc < 0) fail("no diffTerm clipboard socket and no terminal to write OSC 52 to");
    return 0;
}

/* ----------------------------------------------------------------- paste */

static int do_paste(void) {
    int fd = clip_connect();
    if (fd < 0) {
        fail("no clipboard socket — pbpaste only works inside diffTerm, "
             "because reading the clipboard over OSC 52 is refused by design");
    }

    if (write_all(fd, "PASTE\n", 6) < 0) failerr("write");

    char status[128];
    if (read_line(fd, status, sizeof status) < 0) fail("no reply from diffTerm");

    if (strncmp(status, "DATA ", 5) != 0) {
        fprintf(stderr, "%s: %s\n", progname,
                strncmp(status, "ERR ", 4) == 0 ? status + 4 : status);
        return 1;
    }

    char *end = NULL;
    unsigned long len = strtoul(status + 5, &end, 10);
    if (end == status + 5 || len > MAX_CLIP) fail("malformed reply from diffTerm");

    if (len > 0) {
        char *buf = malloc(len);
        if (buf == NULL) fail("out of memory");
        if (read_all(fd, buf, len) < 0) fail("short reply from diffTerm");
        if (write_all(STDOUT_FILENO, buf, len) < 0) failerr("write");
        free(buf);
    }
    close(fd);
    return 0;
}

/* ------------------------------------------------------------------ main */

int main(int argc, char **argv) {
    const char *base = argc > 0 && argv[0] != NULL ? strrchr(argv[0], '/') : NULL;
    base = base != NULL ? base + 1 : (argc > 0 && argv[0] != NULL ? argv[0] : "pbcopy");
    progname = base;

    if (argc > 1 && (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0)) {
        printf("usage: pbcopy < file      copy stdin to the iOS clipboard\n"
               "       pbpaste            write the iOS clipboard to stdout\n\n"
               "Shipped with diffTerm. pbcopy uses $DIFFTERM_CLIPBOARD when it is\n"
               "set and falls back to an OSC 52 write to the terminal; pbpaste\n"
               "needs the socket, because OSC 52 reads are refused.\n");
        return 0;
    }

    return strcmp(base, "pbpaste") == 0 ? do_paste() : do_copy();
}
