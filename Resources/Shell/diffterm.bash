# diffTerm shell integration — bash
#
# See diffterm.zsh for what the OSC 133 marks are and why they matter. This is
# the same thing through bash's hooks: PROMPT_COMMAND for the prompt side, and
# a DEBUG trap for the moment a command starts running.

[ -n "$BASH_VERSION" ] || return 0
[ "$TERM_PROGRAM" = "diffTerm" ] || return 0
[ -z "$_DIFFTERM_INTEGRATION" ] || return 0
_DIFFTERM_INTEGRATION=1

_diffterm_osc() { printf '\033]%s\007' "$1"; }

_DIFFTERM_RAN=

_diffterm_precmd() {
    local _dt_exit=$?
    if [ -n "$_DIFFTERM_RAN" ]; then
        _diffterm_osc "133;D;$_dt_exit"
    fi
    _DIFFTERM_RAN=
    _diffterm_osc "133;A"
    _diffterm_osc "7;file://${HOSTNAME}${PWD}"
    _DIFFTERM_AT_PROMPT=1
}

# The DEBUG trap fires before every command, including the ones
# PROMPT_COMMAND itself runs. The flag makes sure only the first one after a
# prompt counts as "the user ran something".
_diffterm_preexec() {
    [ -n "$_DIFFTERM_AT_PROMPT" ] || return 0
    _DIFFTERM_AT_PROMPT=
    _DIFFTERM_RAN=1
    _diffterm_osc "133;C"
}

trap '_diffterm_preexec' DEBUG
PROMPT_COMMAND="_diffterm_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

# \[...\] is bash's "this takes up no columns", the counterpart to zsh's %{%}.
case "$PS1" in
    *133\;B*) ;;
    *) PS1="${PS1}\[$(printf '\033]133;B\007')\]" ;;
esac
