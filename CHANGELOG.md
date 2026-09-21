# Changelog

## 2.3

### New
- **CarPlay.** The car's screen shows whichever terminal is open on the phone and follows the cursor: as output arrives, or as you type on the phone, the newest rows and the cursor's part of the line stay in view. diffTerm registers as a navigation app, the only kind CarPlay lets draw its own screen.
- **The screen you are looking at sets the size.** While diffTerm is on the phone, the terminal keeps the phone's size and text, and the car draws the phone's lines small enough to show them whole — down to 7 points; only a phone on its side is wider than that, and then the car follows the cursor along the line. Lock the phone or switch to another app and the car is the only screen anyone is reading, so the terminal is resized to fit it and full-screen programs fit the car; pick the phone up and it gets its own size back. Settings › CarPlay turns the second half off.
- **Keys in the car.** An app can only be pressed through the buttons CarPlay draws for it, so those are the keyboard: Ctrl-C, up, down and Return sit in a column beside the text, and Keys holds esc, tab, left, right, Ctrl-C and Ctrl-D. "Type" opens the car's own keyboard for a whole line and offers this session's history under it; many cars refuse a keyboard while moving, and then that button hides itself. Everything else stays on the phone, which is still the real keyboard.
- **Tabs in the car.** Tabs lists every tab with what it is doing — the command running, the one that failed and its status, or the directory it is sitting in — and opens new ones. Switching on either screen switches both.
- **Alerts in the car.** When a command that ran for ten seconds or more finishes, in any tab, the car says so, with how it ended and how long it took, and Show takes you to it. Programs that post a notification (OSC 9 and 777) show up the same way. With a car on its screen the app never goes to the background, so the phone's own notification would never have fired.
- Dragging the car's screen scrolls back through history, and sideways along lines too long for the car; cars driven by a knob or touchpad scroll from Keys › scroll. Live appears in the car's bar once you have moved off the newest output, like a maps app's recentre button. The title line says which columns are shown and how far back from the live text you are.

### Changed
- The app now uses scenes, which CarPlay requires. Tabs belong to the app rather than to the phone's window, so the car can start diffTerm before the phone has, and the shells keep running when the phone's window is discarded.
- Screens are saved when the app as a whole goes to the background. With the car still showing the terminal, locking the phone no longer counts.

## 2.2

### New
- **Text reflows when the screen changes size.** Rotating the phone or resizing a split re-wraps lines instead of cutting them off at the edge. Scrollback, the cursor, command marks, pictures and collapsed blocks all move with the text.
- **Confirm multi-line pastes.** Pasting text with line breaks into a program that would run each line now asks first. It can be turned off in Settings.
- **Keep the screen awake while a command runs**, so a long build is not suspended by the screen locking. It can be turned off in Settings.
- **Cmd+0** resets the text size.
- **Synchronized output** (DECSET 2026) is honoured, so full-screen programs that draw a frame at a time no longer flicker.

### Removed
- **Persistent Sessions and tmux Sessions.** Shells now always end with the app, and nothing keeps running after a force quit. Screen restore still brings back what was on screen. Upgrading unloads and removes the old session daemon.

### Faster
- Output is processed far faster: plain text about 20× faster, colour-heavy output about 5×, Chinese, Japanese and Korean text and box drawing about 13×, and full-screen redraws about 28×.
- Emoji, CJK and Nerd Font icons are no longer laid out again on every frame, and drawing allocates much less.
- Frames spend a fixed time on output instead of a fixed number of bytes, so the interface stays responsive during heavy output. The screen stops redrawing when nothing is happening.
- Large pastes are written about twice as fast.
- Command history loads in the background, and suggestions skip work when nothing has changed.
- Command completion refreshes its caches in the background instead of pausing typing.
- Pinch-to-zoom, changing a setting and title updates no longer rebuild more than they need to.

### Fixed
- Installing shell integration could erase a `.zshrc` that was not valid UTF-8, and replaced a symlinked rc file with a copy.
- `pbcopy` and `pbpaste` failed on anything larger than about 8 KB.
- Closing a tab with a command still running could leave a zombie process, and a program ignoring the hangup was never stopped.
- Shells inherited descriptors from the app.
- The cursor shape setting was mostly ignored.
- Reset All Settings missed many settings.
- Settings screens were never freed after closing.
- Find highlighted the wrong columns after wide characters.
- A suggestion could go stale while scrolling, stop updating after typing past it, or come back at an empty prompt.
- The bell could fire a burst of haptics or flashes.
- Notification permission changed in iOS Settings was not noticed until relaunch.
- Git branch completion found nothing in linked worktrees.
- The snippet editor saved drafts early, and deleted default snippets came back.
- Custom keys rejected names such as `esc` and `pgup`, and `enter` now behaves exactly like the Return key.
