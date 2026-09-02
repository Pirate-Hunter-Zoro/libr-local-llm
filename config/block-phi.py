#!/usr/bin/env python3
"""PreToolUse guard: refuse to read PSYCH-ASR diarization / ASR outputs.

These artifacts are derived from identifiable therapy-session recordings.
The pipeline may still be RUN and its scripts read; only the outputs and the
raw audio are off limits, plus compare_arms.py, which prints verbatim
transcript text to stdout.

Exit 0 = allow.  Exit 2 = block (stderr goes back to the model).
"""
import json
import re
import sys

# Artifact shapes that carry session content, wherever they live.
ARTIFACT = re.compile(
    r"""
      \.rttm\b
    | \.diarized\.json\b
    | \.transcript\.txt\b
    | \.aligned\.json\b
    | \.arm_comparison\.json\b
    | PSYCH-ASR/data/[^\s'"]*\.(?:wav|m4a|mp3|flac|mp4|mov)\b
    """,
    re.VERBOSE | re.IGNORECASE,
)

# Prints verbatim disputed transcript text to stdout.
BLOCKED_SCRIPT = re.compile(r"\bcompare_arms\.py\b")

# Invoking the pipeline is fine; it writes to disk rather than to the model.
PIPELINE = re.compile(r"\b(?:scripts|slurm_jobs)/[\w.-]+\.(?:py|sh|sbatch)\b")

# Commands that only touch metadata, never content.
SAFE_VERBS = {
    "ls", "find", "stat", "du", "df", "file", "basename", "dirname", "realpath",
    "sbatch", "squeue", "sacct", "scontrol", "sinfo",
    "rm", "mv", "cp", "mkdir", "touch", "test", "sha256sum", "md5sum",
    "git",
}

NOTE = (
    "Blocked: PSYCH-ASR diarization/ASR outputs are derived from identifiable "
    "therapy-session PHI and this session is configured not to read them. "
    "Readable instead: the pipeline scripts, slurm_jobs/logs/** (counts only), "
    "and *.arm_scores.json (DER metrics, no transcript text). "
    "Listing filenames with ls/find is allowed."
)


def leading_verb(segment):
    for token in segment.strip().split():
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token):
            continue
        if token in {"sudo", "env", "nohup", "command", "nice", "time", "timeout"}:
            continue
        if re.match(r"^-|^\d+(\.\d+)?[smhd]?$", token):
            continue
        return token.rsplit("/", 1)[-1]
    return ""


# An interpreter can open a path from inside a heredoc body. Anything else
# fed a heredoc is consuming literal text, not reading a file.
INTERPRETERS = {
    "python", "python3", "node", "perl", "ruby", "php", "lua", "awk", "gawk",
    "sh", "bash", "zsh", "jq", "sed",
}


def bash_is_blocked(command):
    # `cat > doc.md <<'MD' ... MD` writes content. Documentation that merely
    # names an artifact extension, or the script that prints them, is not a
    # read of one. This is checked first so prose is never mistaken for a call.
    if "<<" in command and leading_verb(command.split("\n", 1)[0]) not in INTERPRETERS:
        return False
    if BLOCKED_SCRIPT.search(command):
        return True
    for segment in re.split(r"&&|\|\||\||;|\n", command):
        if not ARTIFACT.search(segment):
            continue
        if PIPELINE.search(segment):
            continue          # running a pipeline stage over its own inputs
        if leading_verb(segment) in SAFE_VERBS:
            continue          # metadata only
        return True
    return False


def main():
    try:
        event = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    tool = event.get("tool_name", "")
    args = event.get("tool_input") or {}
    blocked = False

    if tool == "Bash":
        command = args.get("command", "")
        blocked = isinstance(command, str) and bash_is_blocked(command)
    elif tool in {"Read", "Edit", "Write", "NotebookEdit"}:
        blocked = bool(ARTIFACT.search(str(args.get("file_path", ""))))
    elif tool in {"Grep", "Glob"}:
        target = f"{args.get('path', '')} {args.get('glob', '')} {args.get('pattern', '')}"
        blocked = bool(ARTIFACT.search(target))

    if blocked:
        print(NOTE, file=sys.stderr)
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
