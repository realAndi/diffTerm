# RootHide compatibility

*Research note 2026-09-17; phases 1–3 implemented 2026-09-18. Still untested
on a roothide device — see [Status](#status).*

> **2.2.2.** This work was written against 2.0 and ported onto 2.2.1, which had
> already removed sessiond and tmux sessions. The sections below on the daemon's
> socket, `sessiond --where`, the daemon plist and tmux describe code that is no
> longer in the tree; everything else applies as written. Packages for all three
> kinds of jailbreak come from `tools/build-deb.sh`, not `make package
> SCHEME=…`. The first roothide report came from Serotonin with roothide's
> Bootstrap, where 2.2.1 found no `/var/jb` and exited 127.

diffTerm was written against a rootless jailbreak: the bootstrap at `/var/jb`,
spelled out 57 times across 11 files, and every shell the app spawns agreeing
with the app about what a path means. RootHide — the environment
[Relaxin](https://github.com/OwnGoalStudio/Relaxin) provides, and the same one
[RootHide Bootstrap](https://github.com/roothide/Bootstrap) provides on
TrollStore — breaks both assumptions, the second in a way that is not obvious
from reading the code.

This document covers what roothide is, why a terminal is the hard case, what
was changed to support it, how other terminals handle it, and what still has to
be tried on real hardware before anyone is told it works.

## Status

**Done, on this (rootless) device, with no behaviour change here:**

- Every hard-coded bootstrap path goes through one resolver,
  `Sources/Core/JailbreakRoot.swift`, which finds the bootstrap at launch.
- Every place a path crosses between the app and a shell is translated. On
  rootless the translation is the identity, which is why nothing here changed.
- `sessiond` finds its own socket by the same rules as the app, and
  `sessiond --where` prints it. The daemon plist no longer passes it.
- `make package SCHEME=roothide` builds a roothide-shaped `.deb`, on either kind
  of device. The Makefile and `Tools/load-sessiond.sh` pick their prefix from
  the device they run on.
- The harness covers the translation rules, discovery against a synthetic
  roothide tree, the socket-length rule, and `sessiond`/app agreement.

**Not done, and not doable here:** running it on roothide. Everything in
[§8](#8-open-questions) is still open, and the design rests on roothide's
documentation rather than observation. "Supported" should wait for someone with
a roothide device to install the package and work through that list.

**Recommendation unchanged: do not convert this device.** It is the build
machine, and whether roothide's repo carries the Swift toolchain
(`swift 5.9.2~RELEASE` and `build-essential` here come from `apt.procurs.us`,
`1900/main`, `iphoneos-arm64`) is unverified. Relaxin covers 16.5.1–17.3.1, so
this iPhone 15 Pro on 17.3 is in range — an argument for a second device.

## 1. What roothide is

Rootless and roothide are both "the bootstrap does not touch `/`". They differ
in where the bootstrap lives and, more importantly, in who knows about it.

| | rootless (Dopamine) | roothide (Relaxin, RootHide Bootstrap) |
|---|---|---|
| Bootstrap root | `/var/jb`, fixed | `/var/containers/Bundle/Application/.jbroot-XXXXXXXXXXXXXXXX`, random per install |
| Finding it | hard-code it | `jbroot()` from libroothide, or the `.jbroot` symlink |
| Library linking | absolute `/var/jb/usr/lib/...` | `@loader_path/.jbroot/usr/lib/...` |
| What a bootstrap binary thinks `/` is | the real `/` | **jbroot** |
| Reaching the real filesystem from a bootstrap binary | it is already there | `/rootfs/...` |
| Package layout | `./var/jb/Applications/...` | `./Applications/...` — same shape as rootful |
| deb `Architecture` | `iphoneos-arm64` | `iphoneos-arm64e` |

Two details carry almost all the consequences.

**The jbroot path is random, and it is under `/var/containers/Bundle/Application`
on purpose** — that is a location where non-platform binaries are allowed to
execute and where a directory does not look out of place. The 16 characters are
hex, and libroothide validates them: the low byte of the 64-bit value equals the
XOR of the other seven. The name changes every time the jailbreak is installed,
so nothing may cache it across installs and nothing may ship it in a file.

**Bootstrap binaries run under vroot.** This is the part that has no rootless
analogue. Procursus-for-roothide is compiled against a shim that replaces
roughly 200 path-taking libc calls, so a bootstrap program — `zsh`, `ls`,
`tmux`, `git`, `make` — sees jbroot as `/`. It accepts jbroot-based paths and it
*prints* jbroot-based paths. The real filesystem is reachable from inside it as
`/rootfs`. Programs built outside that toolchain — which includes everything in
this repository, because we drive `clang` and `swiftc` ourselves — are not
shimmed and see the real filesystem.

So on a roothide device there are two spellings for every file, and which one is
correct depends on which process is reading it:

```
the app says:     /var/containers/Bundle/Application/.jbroot-a1b2.../usr/bin/zsh
the shell says:   /usr/bin/zsh

the app says:     /var/mobile/Documents
the shell says:   /rootfs/var/mobile/Documents
```

libroothide names the conversions: `jbroot()` takes the shell's spelling and
returns the app's, `rootfs()` goes the other way, and both exist as shell
commands too. This document calls them the **jbroot plane** (what bootstrap
binaries speak) and the **rootfs plane** (what we speak).

Relaxin stages the RootHide bootstrap, so all of the above applies to it
unchanged; it is a delivery mechanism for the same environment, not a third
scheme.

## 2. Why a terminal is the hard case

Most tweaks only need `jbroot("/some/fixed/path")` where they used to write
`/var/jb/some/fixed/path`. That is a find-and-replace.

A terminal emulator is the process that sits exactly on the plane boundary. It
does three things that a tweak does not:

1. **It executes bootstrap binaries from outside the bootstrap.** `posix_spawn`
   is ours, unshimmed, so the executable path must be rootfs-plane — but the
   environment we hand that process (`PATH`, `HOME`, `TMPDIR`, `TERMINFO`,
   `SHELL`) is read by the shimmed child, so it must be jbroot-plane. The same
   spawn needs both spellings at once.
2. **It consumes paths the shell produces.** The working directory the shell
   reports over OSC 7, and absolute paths typed on the command line that ghost
   text completes and checks — both arrive in the jbroot plane and are then
   used by the app as if they were ours: stored in preferences, passed to
   `stat`, inherited by split panes, used as a `chdir` target for the next
   shell. Every one of those is a silent failure under roothide, not a crash.
3. **It hands paths to bootstrap binaries as arguments.** The tmux socket is the
   sharp example, below.

Category 1 and 3 are bugs we can reason about. Category 2 is the one worth being
careful with, because a wrong answer looks like an empty completion list or a
tab that opened in the wrong directory, and nothing logs.

### The tmux socket, concretely

`TmuxEnvironment.socketPath` (`Sources/Core/TmuxTransport.swift`) deliberately
puts the socket outside the bootstrap, at
`/var/mobile/Library/Application Support/diffTerm/tmux.sock` — 58 characters,
comfortably inside `sun_path`'s 104. That comment already records that `$TMPDIR`
inside `/var/jb` resolved to 166 characters and tmux failed to start.

Under roothide, passing that string unchanged to `tmux -S` means tmux — shimmed —
reads it as jbroot-relative and binds
`/var/containers/Bundle/Application/.jbroot-XXXXXXXXXXXXXXXX/var/mobile/Library/Application Support/diffTerm/tmux.sock`:
59 + 58 = 117 characters. Too long to bind, inside the bootstrap where we
explicitly did not want it, and durable across nothing. The correct argument is
the jbroot-plane spelling of the path we mean — `/rootfs/var/mobile/...`, 65
characters, which the shim resolves back to the 58-character real path before
binding.

That is the whole problem in one line of argv, and the fix is a translation, not
a different constant.

## 3. What changed

### One resolver

`Sources/Core/JailbreakRoot.swift` is the only place that knows where the
bootstrap is:

```swift
JailbreakRoot.jb("/usr/bin/zsh")      // a fixed bootstrap path, spelled for the app
JailbreakRoot.toShell(path)           // app → shell, for anything a shell will read
JailbreakRoot.fromShell(path)         // shell → app, for anything a shell produced
JailbreakRoot.scheme                  // .rootless, .roothide or .rootful
```

On roothide, with the bootstrap at `R`:

```
jb("/usr/bin/zsh")          -> R/usr/bin/zsh
fromShell("/usr/bin/zsh")   -> R/usr/bin/zsh
fromShell("/rootfs/var/x")  -> /var/x
toShell(R + "/usr/bin/zsh") -> /usr/bin/zsh
toShell("/var/mobile")      -> /rootfs/var/mobile
```

On rootless and rootful both translations return their argument, so a call site
is written once and never asks which jailbreak it is on. `fromShell` is
idempotent, because a path already under `R` cannot have come from a shell,
which never sees `R`. `toShell` cannot be idempotent — `/usr/bin/zsh` is a real
path in both spellings, naming different files — so it is applied exactly once,
where a path leaves the app.

The translations live on a `Layout` value, not on global state. That is what
lets the harness check the roothide rules on a rootless device: it builds a
roothide layout by hand and asks it questions.

### Finding the root

In order, stopping at the first that answers:

1. **A `.jbroot` link beside our own executable.** roothide makes one in every
   directory that holds a Mach-O, at install time or when the binary is loaded.
   It says how *this copy* of the app was installed, so it outranks everything
   else. When a `.jbroot-…` directory resolves to the same place, its name is
   used as the prefix, because that is how the rest of the system spells it.
2. **`/var/jb`.** Rootless.
3. **A `.jbroot-<16 hex>` directory under `/var/containers/Bundle/Application`
   holding a `usr/bin`.** roothide without the link: a hand-copied bundle, or
   the harness, which is not in a bundle at all. The newest wins if there are
   several. The app can list that directory without privileges; confirmed here.
4. **Nothing.** Rootful or no jailbreak. Paths are used as written.

libroothide also checksums the 16 digits. This does not, on purpose: a
directory of that shape holding a bootstrap is evidence enough, and the checksum
is a detail that could change without notice.

The result is computed once per launch and never stored, since the roothide name
changes every time the jailbreak is installed.

### The rule at the boundary

Each path is in one of two spellings depending on who reads it, and the code
follows four rules:

| A path that is… | is in… | examples |
|---|---|---|
| held, stat'ed, opened, exec'd or `chdir`'d to by the app | the app's spelling | `workingDirectory`, `resolvedShell()`, sockets we bind |
| read by a shell or a bootstrap tool | the shell's (`toShell`) | `PATH`, `HOME`, `SHELL`, `PWD`, `TMPDIR`, `TERMINFO`, argv[0], tmux's `-S` and `-c`, the completion zsh's `cd` and rc file, the rc line the integration installer writes |
| produced by a shell | converted with `fromShell` | OSC 7, absolute paths typed on the command line |
| stored | the shell's | preferences (`shellPath`, `customStartDirectory`, `lastWorkingDirectory`), session snapshots, history `pwd` keys |

The last rule is a choice, and it is the one worth defending. A stored path in
the shell's spelling has no random part, so it survives a roothide reinstall
that renames the whole bootstrap. It is also what the user saw and typed:
Settings shows `/usr/bin/zsh`, not a 59-character container path. On rootless
the two spellings are the same, so existing stored data needs no migration.

### Where, file by file

| File | What changed |
|---|---|
| `Sources/Core/JailbreakRoot.swift` | new: discovery and the translations |
| `Sources/Core/UserEnvironment.swift` | passwd from `jb("/etc/passwd")`, with its paths read in the shell's spelling; `logicalPath` is now `JailbreakRoot.canonical`; new `socketPath(named:)` |
| `Sources/UI/TerminalSession.swift` | shell candidates via `jb`; environment built in the app's spelling and handed over in the shell's; argv[0] and `$PWD` translated; OSC 7 and snapshots translated; stored start directories read back with `fromShell` |
| `Sources/Core/TmuxTransport.swift` | tmux exec'd by the app's path, told everything in its own: argv[0], `-S`, `new-window -c` |
| `Sources/Core/ShellCompletionServer.swift` | zsh via `jb`; the typed `cd`, `ZDOTDIR` and the rc file's `source` line translated |
| `Sources/Core/Completers.swift` | PATH fallback via `jb`; an absolute word on the command line read with `fromShell` before it is listed |
| `Sources/Core/NextCommandPredictor.swift` | an absolute path argument read with `fromShell` before it is checked |
| `Sources/Core/CommandHistoryStore.swift` | `pwd` stored and compared in the shell's spelling |
| `Sources/Core/ShellIntegrationInstaller.swift` | the `source` line written into `.zshrc` translated |
| `Sources/Core/DaemonTransport.swift` | socket from `UserEnvironment.socketPath(named:)` |
| `Sources/Settings/Preferences.swift` | stored paths documented as the shell's spelling; defaults translated to match |
| `Sources/Settings/SettingsViewController.swift` | shell picker checks paths in the app's spelling, shows and stores them in the shell's |
| `Sources/Daemon/sessiond.c` | finds the bootstrap and its socket itself; `--where` |
| `Resources/LaunchDaemon/dev.diffterm.sessiond.plist` | a template; no socket argument |
| `Makefile` | `HOST_JB` / `HOST_SCHEME` from the device; `SCHEME` for packaging |
| `Tools/load-sessiond.sh` | prefix from the device; socket from `sessiond --where` |

Three sites I listed during research turned out not to need anything:

- **tmux's `pane_current_path`.** diffTerm never reads it. Directory tracking comes
  from OSC 7 over the pane's raw output.
- **The completion zsh's replies.** They are completed command lines, text in the
  shell's own terms, and are shown as ghost text, never used as a path by the
  app.
- **`pbcopy`/`pbpaste` and `$DIFFTERM_CLIPBOARD`.** The helpers are ours and not
  shimmed, and an environment variable passes through the shell untouched, so
  the socket path goes to a program that reads the app's spelling. Only the
  helpers' directory on `PATH` needed translating, since the shell searches it.

## 4. Sockets

`sun_path` holds 104 bytes including the NUL, and a roothide root is 59
characters by itself. So under roothide, where a socket lives stops being a
matter of taste.

- **tmux** already kept its socket in the device home
  (`/var/mobile/Library/Application Support/diffTerm/tmux.sock`, 58 bytes). It
  is now handed to tmux as `/rootfs/var/mobile/...`, which the shim resolves to
  the 58-byte path. Untranslated it would have been 117 bytes and could not be
  bound. The harness asserts both numbers.
- **sessiond** keeps its socket in the bootstrap home when the path fits there:
  69 bytes on rootless, the same place as always. On roothide it never fits (121
  bytes), so it moves to the device home. `UserEnvironment.socketPath(named:)`
  and `sessiond.c` apply the same rule, and the harness runs `sessiond --where`
  and checks it against the path the app will dial.

The daemon locates itself rather than being told where to listen. That removes
the question of whether roothide's launchd hook translates every element of
`ProgramArguments` or only the first. The plist now names only the binary, in
the bootstrap's spelling: `/var/jb/Applications/diffTerm.app/sessiond` on
rootless, `/Applications/diffTerm.app/sessiond` on roothide, as roothide's
documentation asks. The socket folder now follows the bundle's name, as the
app's does, so a `diffTermDev` build's daemon and app agree. Before, the plist
hard-coded `diffTerm`.

## 5. Build and packaging

```make
HOST_JB     := $(if $(wildcard /var/jb/bin/sh),/var/jb,)          # the device make runs on
HOST_SCHEME := rootless | roothide (/rootfs exists) | rootful
SCHEME      ?= $(HOST_SCHEME)                                     # the device a .deb is for
```

`$(wildcard)` rather than `$(shell)` because `SHELL` itself is set from
`HOST_JB`, and nothing can be run before it is. `SHELL`, `SDK`, `INSTALL_DIR`,
`LOCAL_BIN` and `DAEMON_DEST` are all `$(HOST_JB)/...`, so on roothide, where
make and clang see the bootstrap as `/`, they collapse to the rootful spelling.

`make package SCHEME=roothide` lays the bundle out at `./Applications` rather
than `./var/jb/Applications`, sets `Architecture: iphoneos-arm64e`, has
`postinst`/`prerm` name `/Applications/diffTerm.app` (they run under the
target's dpkg), and writes `diffTerm_2.0_roothide.deb` beside the rootless one.
It can be built on either kind of device, because nothing about the bootstrap's
location is compiled into the binaries. The Mach-O stays `arm64`. Only
injected tweaks need arm64e slices, and this is an app.

The research note proposed a second variable for the real path, `JB_REAL`. In
the end nothing needed one: the plist is written in the host's spelling, the
maintainer scripts in the target's, and the binaries resolve the real path
themselves.

One caveat carries over: roothide's vroot notes that Swift/Objective-C packages
are sometimes left unshimmed. If `swiftc` is one of them, `SDK` will be wrong on
a roothide build machine. `make SDK=$(jbroot /usr/share/SDKs/iPhoneOS.sdk)`
works around it, and question 2 in §8 settles it.

`RootHide Patcher` may well install an unmodified rootless `.deb`, but it only
rewrites our literals, not the paths the shell hands back. Use it for a quick
look, not as the port.

## 6. How other terminals handle it

**NewTerm doesn't — it gets converted.** Upstream
[hbang/NewTerm](https://github.com/hbang/NewTerm) has no roothide code. Its
`Common/Controllers/SubProcess.swift` picks the first of
`["/var/jb/usr/bin/login", "/usr/bin/login"]` that exists, falls back to a
hard-coded `/var/jb/bin/zsh` for XinaA15, and runs
`login -fp <user> NewTermLoginHelper <cwd> <shell>` with an environment of just
`TERM`, `COLORTERM`, `TERM_PROGRAM`, `LC_TERMINAL` and `LANG` on top of its own.
On roothide it reaches users through RootHide Patcher and roothide's runtime
patching of `/var/jb`. A search result also mentioned a community fork that
builds a roothide package. That is unverified; I did not read the fork.

It gets away with that because it is a thin terminal. It starts `login` and
draws whatever comes back. It never reads a path back from the shell, runs no
daemon, and builds almost no environment itself, since `login` and the
bootstrap's `zprofile` do that inside the shimmed world. Once patching fixes the
one hard-coded launch path, everything downstream is already in the shell's
spelling. diffTerm is thicker: it builds the environment, tracks the directory,
completes and checks paths, and runs a daemon. That is why it needs the
boundary rules above, and why a patched diffTerm would open a shell and then
quietly misbehave.

One thing is worth borrowing if hardware testing turns up environment trouble:
let the bootstrap's `login` or `zprofile` set more of `PATH` and `HOME`, since
they already speak the shell's spelling. Note the catch, though. NewTerm passes
its helper's path (the app's spelling) as an argument to a shimmed `login`, which
works only if vroot leaves a path already inside the root alone. That is
unverified too.

## 7. What was tested, and how

On this device (rootless, Dopamine, iOS 17.3):

- The full harness, before and after: 830 checks before, 894 after, the same two
  failing both times. Those two are the packed git spec round-trip, which failed
  before any of this was touched and has nothing to do with paths.
- New `jailbreak root` checks: every roothide translation, both round trips,
  the resolved-spelling case, partial-prefix false matches, the tmux and daemon
  socket lengths, rootless and rootful identity, name-shape validation, and
  discovery against a synthetic tree for each of the four outcomes, including
  "the link beats `/var/jb`" and "a wrong-shaped `.jbroot-` is ignored".
- Live checks that on this device `PATH`, `HOME` and tmux's arguments come out
  exactly as before.
- `sessiond --where` against the app's `DaemonWire.socketPath`.
- `make package` for both schemes, inspected with `dpkg-deb -c` and `-I`.

What a rootless device cannot show: vroot itself. The bootstrap binaries here
are not shimmed, so no synthetic setup makes `zsh` report a path in the
roothide spelling. The inbound half is unit-tested and not observed.

## 8. Open questions

For whoever tries it on roothide, in this order. The first two decide whether a
roothide device can also build, not just run.

1. **Is there a Swift toolchain?** `apt-cache policy swift build-essential clang`
   and `swiftc --version`. If there isn't, the app can still be built here with
   `make package SCHEME=roothide`.
2. **Is `swiftc` shimmed?** Compile a program that prints `realpath("/")` with
   `clang` and with `swiftc`, and compare. If they differ, pass `SDK=` explicitly.
3. **Does the package install, and does `.jbroot` appear?**
   `dpkg -i diffTerm_2.0_roothide.deb`, then `ls -la /Applications/diffTerm.app/.jbroot`.
   If dpkg rejects the architecture, `dpkg -I` a known-good roothide package from
   the repo and copy its `Architecture`.
4. **Does it launch, and does `no-container` still hold?** If history, sessions
   and prompts don't persist across launches, the app has been given a data
   container and `UserEnvironment.supportDirectory` needs to follow it.
5. **Does a shell start with a sane environment?** `echo $PATH $HOME $SHELL $PWD`
   should show the shell's spelling: `/usr/bin:...:/rootfs/usr/bin`, `/var/mobile`.
6. **Does OSC 7 come back in the shell's spelling?** `cd /rootfs/var/mobile`,
   then open a split. It should start in the same place.
7. **Do blocks, ghost text and completion work?** Type `ls /usr/b` and check
   the ghost text completes it.
8. **tmux:** turn on Run Shells in tmux, then check that tmux is installed from
   the roothide repo, that a tab opens, and that `ls -l /rootfs/var/mobile/Library/Application\ Support/diffTerm/`
   shows `tmux.sock`.
9. **sessiond:** `sudo sh Tools/load-sessiond.sh`, then compare the socket it
   reports with `sessiond --where`.
10. **`make install` itself:** `sudo`/askpass, and `uicache -p /Applications/diffTerm.app`.

## 9. Plan

| Phase | Work | Status |
|---|---|---|
| 1 | `JailbreakRoot`, discovery, harness coverage; every literal routed through it | done |
| 2 | Translation at every boundary in §3 | done |
| 3 | `sessiond` self-location and `--where`; plist template; `SCHEME=roothide` packaging; loader script | done |
| 4 | Install on a roothide device and work through §8 | **needs hardware** |
| 5 | README: two supported schemes, `make package SCHEME=roothide` | after 4 |

## 10. Non-goals

- **Do not symlink `/var/jb` to the roothide root.** It would hide most of this
  work and defeat the point of the environment the user chose.
- **Do not store the prefix** in a file, a plist or a preference. It changes on
  every install. Resolve it at launch, every launch.
- **Do not branch on the scheme at call sites.** One resolver, two translations,
  and call sites that read the same on every jailbreak. `socketPath(named:)`
  decides by length, not by scheme, for that reason.
- **Do not convert the build device** until question 1 is answered.

## References

- [roothide/Developer — roothide vs rootless](https://github.com/RootHide/Developer/blob/main/roothide.md) · [interface.md](https://github.com/roothide/Developer/blob/main/interface.md) · [vroot.md](https://github.com/roothide/Developer/blob/main/vroot.md)
- [roothide/libroothide](https://github.com/roothide/libroothide)
- [roothide/Bootstrap](https://github.com/roothide/Bootstrap) · [Bootstrap-basebin](https://deepwiki.com/roothide/Bootstrap-basebin)
- [The Apple Wiki — Roothide](https://theapplewiki.com/wiki/Roothide)
- [opa334/libroot](https://github.com/opa334/libroot)
- [Relaxin (OwnGoal Studio)](https://github.com/OwnGoalStudio/Relaxin)
- [hbang/NewTerm](https://github.com/hbang/NewTerm) — `Common/Controllers/SubProcess.swift`
