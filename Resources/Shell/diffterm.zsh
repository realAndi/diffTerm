# diffTerm shell integration — zsh
#
# Tells the terminal where each command begins and ends, using the OSC 133
# marks that iTerm2, WezTerm, kitty, VS Code and Warp all understand. Nothing
# here is diffTerm-specific except the guard at the top: any terminal that
# speaks OSC 133 will read these marks, and any that does not will ignore them.
#
# What the marks buy you:
#   A  where the prompt starts   -> block boundaries, jump between prompts
#   B  where your typing starts  -> "copy this command", ghost-text suggestions
#   C  where the output starts   -> "copy this command's output"
#   D  the exit status           -> the red rail on a failure, and the fact
#                                   that suggestions after a failed build are
#                                   drawn from what you did after *failed*
#                                   builds, not successful ones
#
# Also emits OSC 7 (the working directory) so a new tab opens where the last
# one was, and so suggestions are keyed to the directory you are in.
#
# Safe to source unconditionally: it does nothing outside diffTerm, does
# nothing twice, and touches no variable that is not prefixed.

[ -n "$ZSH_VERSION" ] || return 0
[ "$TERM_PROGRAM" = "diffTerm" ] || return 0
# The app's own completion server is a zsh too, and reads these rc files so
# it sees the same aliases and compdefs. It must not emit marks.
[ -z "$DIFFTERM_COMPLETION_SERVER" ] || return 0
[ -z "$_DIFFTERM_INTEGRATION" ] || return 0
_DIFFTERM_INTEGRATION=1

_diffterm_osc() { printf '\033]%s\007' "$1"; }

# Ran a command since the last prompt? Without this the very first prompt
# would report the exit status of nothing at all.
_DIFFTERM_RAN=

_diffterm_precmd() {
    # Not `status`: zsh reserves that name as a read-only alias for $?, and
    # assigning to it makes the whole hook fail with "read-only variable" —
    # silently, as far as the terminal is concerned, since no mark then
    # arrives at all.
    local _dt_exit=$?
    if [ -n "$_DIFFTERM_RAN" ]; then
        _diffterm_osc "133;D;$_dt_exit"
    fi
    _DIFFTERM_RAN=
    _diffterm_osc "133;A"
    # OSC 7 wants a file URL. The hostname is optional and left empty, which
    # every terminal reads as "this machine".
    _diffterm_osc "7;file://${HOST}${PWD}"
}

_diffterm_preexec() {
    _DIFFTERM_RAN=1
    _diffterm_osc "133;C"
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _diffterm_precmd
add-zsh-hook preexec _diffterm_preexec

# B marks the end of the prompt, so it has to be part of the prompt itself.
# %{...%} tells zsh the sequence takes up no columns; without it every prompt
# would be mis-measured and lines would wrap in the wrong place.
if [[ "$PS1" != *"133;B"* ]]; then
    PS1="${PS1}%{$(printf '\033]133;B\007')%}"
fi
