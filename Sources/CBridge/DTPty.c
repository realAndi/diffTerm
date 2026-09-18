#include "DTPty.h"

#include <util.h>
#include <fcntl.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <sys/wait.h>
#include <paths.h>
#include <strings.h>
/* xlocale.h defines _USE_EXTENDED_LOCALES_, which is what makes
   langinfo.h declare nl_langinfo_l; the order matters. */
#include <xlocale.h>
#include <langinfo.h>

/* Why an exec failed, for the child to print. strerror is not
   async-signal-safe, and between fork and exec in a threaded process only
   those are, so the reasons worth telling apart are spelled out here. */
static const char *exec_failure_reason(int err) {
    switch (err) {
    case ENOENT:   return "no such file";
    case EACCES:   return "permission denied";
    case EPERM:    return "operation not permitted";
    case ENOEXEC:  return "not a program this system can run";
    case ENOTDIR:  return "a component of the path is not a directory";
    case ELOOP:    return "too many levels of symbolic links";
#ifdef EBADARCH
    case EBADARCH: return "built for the wrong architecture";
#endif
#ifdef EBADEXEC
    case EBADEXEC: return "bad executable (often a code signature iOS rejected)";
#endif
    default:       return "exec failed";
    }
}

static void write_str(int fd, const char *s) {
    size_t len = strlen(s);
    while (len > 0) {
        ssize_t n = write(fd, s, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return;
        s += n;
        len -= (size_t)n;
    }
}

/* Decimal, without printf, for the same reason as above. */
static void write_int(int fd, int value) {
    char digits[12];
    int i = (int)sizeof(digits);
    unsigned int v = value < 0 ? 0u - (unsigned int)value : (unsigned int)value;
    do { digits[--i] = (char)('0' + v % 10); v /= 10; } while (v && i > 1);
    if (value < 0) digits[--i] = '-';
    while (i < (int)sizeof(digits)) {
        ssize_t n = write(fd, digits + i, (size_t)((int)sizeof(digits) - i));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return;
        i += (int)n;
    }
}

int dt_spawn_pty(const char *path,
                 char *const argv[],
                 char *const envp[],
                 const char *cwd,
                 unsigned short cols,
                 unsigned short rows,
                 int *out_master,
                 pid_t *out_pid) {
    if (!path || !argv || !out_master || !out_pid) return -EINVAL;

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = cols ? cols : 80;
    ws.ws_row = rows ? rows : 24;

    struct termios tio;
    memset(&tio, 0, sizeof(tio));
    tio.c_iflag = ICRNL | IXON | IXANY | IMAXBEL | BRKINT | IUTF8;
    tio.c_oflag = OPOST | ONLCR;
    tio.c_cflag = CREAD | CS8 | HUPCL;
    tio.c_lflag = ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL;
    tio.c_cc[VEOF]     = 4;      /* ^D */
    tio.c_cc[VEOL]     = 255;
    tio.c_cc[VEOL2]    = 255;
    tio.c_cc[VERASE]   = 0x7f;   /* DEL — matches what we send for backspace */
    tio.c_cc[VWERASE]  = 23;     /* ^W */
    tio.c_cc[VKILL]    = 21;     /* ^U */
    tio.c_cc[VREPRINT] = 18;     /* ^R */
    tio.c_cc[VINTR]    = 3;      /* ^C */
    tio.c_cc[VQUIT]    = 0x1c;   /* ^\ */
    tio.c_cc[VSUSP]    = 26;     /* ^Z */
    tio.c_cc[VDSUSP]   = 25;     /* ^Y */
    tio.c_cc[VSTART]   = 17;     /* ^Q */
    tio.c_cc[VSTOP]    = 19;     /* ^S */
    tio.c_cc[VLNEXT]   = 22;     /* ^V */
    tio.c_cc[VDISCARD] = 15;     /* ^O */
    tio.c_cc[VMIN]     = 1;
    tio.c_cc[VTIME]    = 0;
    tio.c_cc[VSTATUS]  = 20;     /* ^T */
    cfsetispeed(&tio, B38400);
    cfsetospeed(&tio, B38400);

    /* The descriptor ceiling is read here, not in the child: getdtablesize is
       not on the async-signal-safe list. Clamped because the soft limit can be
       enormous (61440 on macOS), and every close is a syscall. */
    int fd_ceiling = getdtablesize();
    if (fd_ceiling < 256) fd_ceiling = 256;
    if (fd_ceiling > 65536) fd_ceiling = 65536;

    int master = -1;
    pid_t pid = forkpty(&master, NULL, &tio, &ws);
    if (pid < 0) {
        return -errno;
    }

    if (pid == 0) {
        /* Child. Async-signal-safe calls only until execve. */
        if (cwd && cwd[0]) {
            if (chdir(cwd) != 0) {
                /* A missing start directory must not stop the shell. */
                if (chdir("/var/mobile") != 0) { (void)chdir("/"); }
            }
        }

        /* forkpty leaves signal dispositions inherited from the app, which
           has SIGPIPE ignored and several handlers installed by UIKit. A
           shell that inherits those misbehaves in subtle ways, so reset. */
        for (int sig = 1; sig < NSIG; sig++) {
            signal(sig, SIG_DFL);
        }
        sigset_t empty;
        sigemptyset(&empty);
        sigprocmask(SIG_SETMASK, &empty, NULL);

        /* Nothing past stdio belongs to the shell. Without this every shell
           inherited whatever the app had open that nobody marked
           close-on-exec, and a program in one tab could reach descriptors
           that belong to the app or to another tab. */
        for (int fd = STDERR_FILENO + 1; fd < fd_ceiling; fd++) {
            (void)close(fd);
        }

        execve(path, argv, envp);
        /* execve only returns on failure. Say so on the terminal: a bare
           "exited with status 127" gives the person looking at it nothing
           to go on. _exit avoids running any atexit handlers inherited
           from the parent. */
        int err = errno;
        write_str(STDERR_FILENO, "\033[1;31mdiffTerm:\033[0m couldn't run ");
        write_str(STDERR_FILENO, path);
        write_str(STDERR_FILENO, ": ");
        write_str(STDERR_FILENO, exec_failure_reason(err));
        write_str(STDERR_FILENO, " (errno ");
        write_int(STDERR_FILENO, err);
        write_str(STDERR_FILENO, ")\n");
        _exit(127);
    }

    /* Parent. */
    int flags = fcntl(master, F_GETFL, 0);
    if (flags >= 0) fcntl(master, F_SETFL, flags | O_NONBLOCK);
    fcntl(master, F_SETFD, FD_CLOEXEC);

    *out_master = master;
    *out_pid = pid;
    return 0;
}

int dt_set_winsize(int master, unsigned short cols, unsigned short rows,
                   unsigned short pixel_width, unsigned short pixel_height) {
    if (master < 0) return -EBADF;
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = cols;
    ws.ws_row = rows;
    ws.ws_xpixel = pixel_width;
    ws.ws_ypixel = pixel_height;
    if (ioctl(master, TIOCSWINSZ, &ws) != 0) return -errno;
    return 0;
}

int dt_try_reap(pid_t pid, int *status) {
    if (pid <= 0) return -EINVAL;
    int st = 0;
    pid_t r = waitpid(pid, &st, WNOHANG);
    if (r == 0) return 0;
    if (r < 0) return -errno;
    if (status) *status = st;
    return 1;
}

int dt_child_running(pid_t pid) {
    if (pid <= 0) return 0;
    siginfo_t info;
    memset(&info, 0, sizeof(info));
    /* WNOWAIT: look without reaping, so whoever owns the reap still sees the
       exit status. An exited-but-unreaped child reports its pid here. */
    if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) != 0) return 0;
    return info.si_pid == 0 ? 1 : 0;
}

pid_t dt_foreground_pid(int master) {
    if (master < 0) return -1;
    pid_t pgrp = tcgetpgrp(master);
    return pgrp;
}

int dt_signal_foreground(int master, pid_t fallback_pid, int sig) {
    pid_t pgrp = tcgetpgrp(master);
    if (pgrp > 0) {
        if (killpg(pgrp, sig) == 0) return 0;
    }
    if (fallback_pid > 0) {
        if (kill(fallback_pid, sig) == 0) return 0;
    }
    return -errno;
}

int dt_locale_is_utf8(const char *name) {
    if (!name) return 0;
    locale_t loc = newlocale(LC_CTYPE_MASK, name, NULL);
    if (!loc) return 0;
    const char *codeset = nl_langinfo_l(CODESET, loc);
    int utf8 = codeset != NULL && strcasecmp(codeset, "UTF-8") == 0;
    freelocale(loc);
    return utf8;
}

int dt_locale_is_complete(const char *name) {
    if (!name) return 0;
    locale_t loc = newlocale(LC_ALL_MASK, name, NULL);
    if (!loc) return 0;
    freelocale(loc);
    return 1;
}
