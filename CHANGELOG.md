# Changelog

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
