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

/// 1 if `pid` is a child that has not exited yet, 0 if it has exited (reaped
/// or not) or is not our child. Never reaps, so it is safe to ask while
/// someone else owns the `waitpid`. An unreaped child's pid cannot be reused,
/// which is what makes a signal sent after a 1 here reach the right process.
int dt_child_running(pid_t pid);

/// 1 if `name` names a locale whose character type is UTF-8, 0 otherwise.
///
/// Asked in C because Swift's Darwin module does not export `nl_langinfo_l`
/// on every SDK — the declaration is behind `_USE_EXTENDED_LOCALES_`, and
/// which toolchain re-exports it differs between the on-device Procursus
/// swiftc and the one in CI. The C declaration is in both, so the question
/// gets asked here and Swift only sees the answer.
///
/// `newlocale` rather than `setlocale`: this must not disturb the process's
/// own locale, on whatever thread happens to ask first.
int dt_locale_is_utf8(const char *name);

/// 1 if `name` is a locale complete enough for `$LANG` or `$LC_ALL`, which
/// stand in for every category rather than just the character type.
int dt_locale_is_complete(const char *name);

#endif
