# diffTerm completion server — capture setup (zsh)
#
# Sourced into an interactive zsh the app runs *for itself*, after the user's
# own rc files, so the same compdefs, aliases and plugins apply. It turns that
# shell into a completion oracle: the app types a command line and a Tab, the
# widget below runs the real command-line completion system — `_git` reading
# this repo's branches, `_make` reading this Makefile's targets, `_ssh`
# reading known_hosts — and prints back exactly what Tab would insert. None of
# it runs in the user's own shell.
#
# Per request the app sends, at this shell's prompt:
#   Ctrl-U                          clear any leftover line
#   cd -- '<cwd>'; _DTC_ID=<id> \r  change directory, tag the reply (executes)
#   <line> \t                       type the line, Tab fires the capture
# and reads back:
#   NUL <id> US <completed line> NUL
#
# The line is *typed*, never executed — no Enter follows it, only Tab — so the
# shell completes it and never runs it.

[[ -o interactive ]] || return 0

# compsys, unless the user's rc already started it. `-u` skips the interactive
# "insecure directories" prompt that would hang a headless shell; `-D` skips
# the dump file this shell will not reuse.
if ! (( $+functions[_main_complete] )); then
    autoload -Uz compinit && compinit -u -D 2>/dev/null
fi
zmodload zsh/zselect 2>/dev/null

# One match, inserted, no menu and no list: ghost text wants a single answer.
zstyle ':completion:*' menu no 2>/dev/null

# A SIGINT aborts at most the current completion — never the request shell.
TRAPINT() { return 1 }

_dtc_post() { compstate[insert]=1; unset 'compstate[list]' }

# Watchdog, in centiseconds. A completion that runs longer than this — `_git`
# on a large repo, a generator waiting on a daemon — is abandoned with an
# interrupt to this shell, so one slow completion cannot wedge the server. The
# app simply gets no answer, and the local guess it already showed stands.
_DTC_WATCHDOG=${DIFFTERM_COMPLETION_WATCHDOG:-40}

_dtc_widget() {
    local dog
    { zselect -t $_DTC_WATCHDOG; kill -INT $$ } 2>/dev/null &!
    dog=$!
    {
        local -a comppostfuncs
        comppostfuncs=(_dtc_post)
        CURSOR=$#BUFFER
        zle complete-word 2>/dev/null
    } always {
        kill $dog 2>/dev/null
        TRY_BLOCK_ERROR=0
    }
    print -rn -- $'\0'"${_DTC_ID:-0}"$'\x1f'"${BUFFER}"$'\0'
    # Clear the line for the next request without executing anything.
    zle kill-whole-line
}
zle -N _dtc_widget
bindkey '^I' _dtc_widget
bindkey '^U' kill-whole-line
_DTC_ID=0

# rc files are done and the widget is live: the app holds requests until it
# sees this rather than racing the shell's startup.
print -rn -- $'\0'"0"$'\x1f'"ready"$'\0'
