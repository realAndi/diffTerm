#include "DTPty.h"

#include <util.h>
#include <fcntl.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <sys/wait.h>
#include <paths.h>

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

        execve(path, argv, envp);
        /* execve only returns on failure; _exit avoids running any atexit
           handlers inherited from the parent. */
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
