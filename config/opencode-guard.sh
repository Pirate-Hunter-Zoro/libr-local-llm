# ---------------------------------------------------------------------------
# opencode-guard.sh -- sourced from the `# >>> ollama >>>` block in ~/.bashrc.
#
# Bare `opencode` almost never works on this cluster, and when it fails it fails
# uselessly: the configured endpoint is 127.0.0.1:11500, loopback-only on the
# node holding the Slurm allocation, so anywhere else the TUI just reports that
# the API could not be reached. It does not say which node, which job, or which
# command would have worked. The two commands that do work are `ollama-up` and
# `ollama-code` (README section 4a).
#
# This defines a shell function -- not a wrapper script in the repo's bin/ --
# for two reasons. bin/ is APPENDED to PATH on purpose (README section 3,
# constraint 2) so repo contents can never shadow a system command, which means
# a bin/opencode would lose to the real binary and never run. And a function
# wins over PATH lookup without touching PATH order at all.
#
# It is a signpost, not a fence: `command opencode` still reaches the real
# binary, and every invocation that does not need a live model endpoint passes
# straight through untouched.
# ---------------------------------------------------------------------------

opencode() {
    local sub="${1:-}"

    # 1. The typo that prompted this. `opencode up accel` does not error: there
    #    is no `up` subcommand, so yargs falls through to the default TUI and
    #    reads "up" as the [project] directory argument, "accel" is discarded,
    #    and nothing is ever submitted to Slurm. The failure then surfaces one
    #    command later, as an unreachable API, pointing at nothing.
    case "$sub" in
        up|down|code)
            printf 'opencode has no "%s" subcommand.\n' "$sub" >&2
            printf 'The driver commands are named ollama-*, not opencode:\n\n' >&2
            printf '    ollama-%s %s\n\n' "$sub" "${*:2}" >&2
            printf 'Note that "opencode %s ..." does NOT fail -- it reads "%s" as a\n' "$sub" "$sub" >&2
            printf 'directory to open and starts the TUI, so nothing gets submitted.\n' >&2
            return 2
            ;;
    esac

    # 2. Subcommands that read config, credentials or local state and never
    #    touch the model endpoint. These are the ones README section 6 asks you
    #    to run for verification, so they must work from the login node.
    case "$sub" in
        completion|mcp|providers|auth|agent|upgrade|uninstall|models|stats|\
        export|import|github|session|plugin|plug|db|debug|-*)
            command opencode "$@"
            return
            ;;
    esac

    # 3. Everything left -- no args (TUI), a bare directory (TUI there), `run`,
    #    `serve`, `web`, `attach`, `pr`, `acp` -- wants a model behind
    #    OLLAMA_HOST. Check that something is actually listening before handing
    #    over, so the diagnosis names the node instead of the symptom.
    local endpoint="${OLLAMA_HOST:-127.0.0.1:11500}"
    local host="${endpoint%:*}" port="${endpoint##*:}"

    # Probed with bash's own /dev/tcp rather than a helper binary, so this still
    # works on a stripped PATH -- and without a timeout, because the endpoint is
    # loopback by design: a connect there either lands or is refused at once.
    if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
        command opencode "$@"
        return
    fi

    printf 'Nothing is listening on %s (this node: %s).\n\n' "$endpoint" "${HOSTNAME:-unknown}" >&2

    # Ask Slurm whether a server exists elsewhere. A state file would go stale
    # the moment a job ended; squeue never does. Same reasoning as ollama-code.
    local job="" node="" name=""
    if command -v squeue >/dev/null 2>&1; then
        for name in ollama_serve_accel ollama_serve; do
            job="$(squeue -u "$USER" -n "$name" -t RUNNING -h -o '%i' 2>/dev/null | head -1)"
            [ -n "$job" ] && break
        done
    fi

    if [ -n "$job" ]; then
        node="$(squeue -j "$job" -h -o '%N' 2>/dev/null)"
        printf 'A server IS up: %s job %s on %s.\n' "$name" "$job" "${node:-?}" >&2
        printf 'Its endpoint is loopback-only on that node, so a client here cannot\n' >&2
        printf 'reach it. Step into the allocation instead of running opencode direct:\n\n' >&2
        printf '    ollama-code                     # TUI, current directory\n' >&2
        printf '    ollama-code "your prompt"       # one-shot, no TUI\n' >&2
    else
        printf 'No Ollama server is running. Start one, then connect:\n\n' >&2
        printf '    ollama-up            # 1 GPU, c3_short  (qwen3-coder, medgemma)\n' >&2
        printf '    ollama-up accel      # 4 GPUs, c3_accel (gpt-oss:120b)\n' >&2
        printf '    ollama-code          # then this, from anywhere\n' >&2
    fi

    printf '\n(Deliberate bypass, if you know the endpoint is local: command opencode)\n' >&2
    return 1
}
