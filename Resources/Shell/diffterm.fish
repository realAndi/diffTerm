# diffTerm shell integration — fish
#
# See diffterm.zsh for what the OSC 133 marks are. fish has real events for
# both sides of a command, so this is the shortest of the three.

status is-interactive; or exit 0
test "$TERM_PROGRAM" = "diffTerm"; or exit 0
set -q _DIFFTERM_INTEGRATION; and exit 0
set -g _DIFFTERM_INTEGRATION 1

function _diffterm_osc
    printf '\033]%s\007' $argv[1]
end

function _diffterm_prompt --on-event fish_prompt
    if set -q _DIFFTERM_RAN
        _diffterm_osc "133;D;$_DIFFTERM_STATUS"
        set -e _DIFFTERM_RAN
    end
    _diffterm_osc "133;A"
    _diffterm_osc "7;file://"(hostname)"$PWD"
end

function _diffterm_preexec --on-event fish_preexec
    set -g _DIFFTERM_RAN 1
    _diffterm_osc "133;C"
end

function _diffterm_postexec --on-event fish_postexec
    set -g _DIFFTERM_STATUS $status
end

# fish redraws its prompt itself, so B goes on the end of it rather than into
# a variable.
functions -q fish_prompt; and functions --copy fish_prompt _diffterm_inner_prompt
function fish_prompt
    _diffterm_inner_prompt
    _diffterm_osc "133;B"
end
