# diffTerm

diffTerm is a terminal emulator for jailbroken iOS and iPadOS. It runs a real
shell on your device and draws the result the way a terminal is supposed to,
so the tools you already use behave the way you expect. It supports iOS 14 and
newer.

The emulator is written from scratch against the DEC VT500 state diagram
rather than pattern matching on escape sequences. It covers VT100, VT220 and
xterm control sequences, 24 bit colour, the alternate screen, scroll regions,
mouse reporting and the OSC extensions modern shells rely on. Accuracy is
measured with esctest rather than claimed.

Source the included shell integration script in zsh, bash or fish and diffTerm
learns where your commands begin and end. Each command and its output become a
block you can collapse to one line, jump between from the keyboard, or copy
whole without dragging a selection across the screen. A tab shows a dot while
something is running and marks it when a command fails, and a new tab opens in
the directory the last one was in.

As you type, the rest of the line appears ahead of the cursor as dim ghost
text. Suggestions come from what you have run before, weighted by the command
that just finished, the directory you are in, and whether that command
succeeded. Accept one with Tab or the right arrow, or tap the part you want.
All of it is computed on device from your own history. There is no account, no
server and no model behind it.

When history has nothing to offer, completion falls back to what exists.
Commands on your PATH, files and directories around you, and subcommands and
flags for roughly seven hundred tools using Fig's completion specs, so `git ch`
becomes `git checkout`. Git branches are read from the repository. diffTerm can
also ask a background zsh what your own completion system would insert, so your
aliases and plugins are respected rather than guessed at.

Tabs and split panes are both here. Panes divide either way, resize by
dragging, and even out on a double tap. The key row carries only what the
software keyboard cannot produce, so escape, tab, control, alt, arrows, home
and end, page keys and function keys. Modifiers arm on a tap and lock on a
double tap, keys repeat while held, and holding the spacebar lets you slide the
caret along the line. Hardware keyboards are fully supported.

Plenty is customizable. Themes, the app icon, the font and its size, the shell
and where it starts, and which extras are switched on.

Programs can print pictures into the terminal using either iTerm2's image
protocol or Sixel, so imgcat, chafa, lsix and gnuplot all display properly.
Images take real rows, scroll with the output around them, and clear with it.

iOS kills an app's child processes when it suspends the app, which normally
means backgrounding a terminal kills whatever was running. Turn on the tmux
option and every tab becomes a tmux window, so your shells survive the app
being closed or force quit. Without it, tabs still restore their contents when
you come back.

Working `pbcopy` and `pbpaste` ship with the app and are linked into your path,
because the ones in the bootstrap cannot reach the pasteboard and exit
successfully anyway. Programs can set the clipboard over OSC 52, but reading it
back is refused, so nothing you run over ssh can read your clipboard.

There is also find in scrollback, word and line selection, link detection,
snippets, and a notification when a long running command finishes while you are
in another app.

One build covers iPhone and iPad. The iPad layout is implemented but has not
yet been run on real hardware.

## Installing

diffTerm is published in my package repository. Add the source in Sileo or
Zebra and then search for diffTerm.

```
https://reallyitsandi.com/repo/
```

## Building

diffTerm builds on the device it runs on. You need the Procursus toolchain with
`clang`, `swiftc`, `ldid`, `make` and `python3`, and the iPhoneOS SDK at
`/var/jb/usr/share/SDKs/iPhoneOS.sdk`. Building a package also needs
`dpkg-deb`.

```sh
make            # compile, bundle and sign
make test       # run the test harness
make install    # install and register the app
make package    # build a .deb
```

## License

MIT. See `LICENSE`. The completion specs are derived from Fig's, also MIT, and
ship with their license. The bundled font carries its own OFL license.
