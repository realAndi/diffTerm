#ifndef DT_PTY_H
#define DT_PTY_H

#include <sys/types.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <signal.h>

/// Forks a child attached to a fresh pseudo-terminal and execs `path`.
///
/// The whole point of doing this in C is the window between fork() and exec():
/// only async-signal-safe calls are legal there, and Swift gives no way to
/// guarantee that (ARC traffic, exclusivity checks and lazy globals can all
/// run). Keeping it here makes the constraint enforceable by inspection.
///
/// Returns 0 on success, or a negated errno on failure.
/// On success `*out_master` is the pty master fd (O_NONBLOCK, CLOEXEC) and
/// `*out_pid` is the child's pid.
int dt_spawn_pty(const char *path,
                 char *const argv[],
                 char *const envp[],
                 const char *cwd,
                 unsigned short cols,
                 unsigned short rows,
                 int *out_master,
                 pid_t *out_pid);

/// Pushes a new window size to the pty so the child sees SIGWINCH.
int dt_set_winsize(int master, unsigned short cols, unsigned short rows,
                   unsigned short pixel_width, unsigned short pixel_height);

/// Non-blocking reap. Returns 1 and fills `*status` when the child exited,
/// 0 if it is still running, negative errno on error.
int dt_try_reap(pid_t pid, int *status);

/// Sends a signal to the child's foreground process group where possible,
/// falling back to the child itself.
int dt_signal_foreground(int master, pid_t fallback_pid, int sig);

/// pid of the pty's foreground process group, or -1.
pid_t dt_foreground_pid(int master);

#endif
