#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# harden-claude.sh -- verify this account's Claude Code fencing, fix the parts
# that are safe to fix automatically, and state plainly what is left.
#
#   scripts/harden-claude.sh [--dry-run]
#
# Idempotent, and re-running is the point: it doubles as the audit. The only
# things it writes are a gitignore line and file modes, both backed up or
# reversible. It deliberately does NOT rewrite session transcripts -- see
# section 2.
#
# Exit 0 when everything it can fix is fixed. Exit 1 when the PHI guard is
# missing or misbehaving, because that is not a warning, it is a broken fence.
# ---------------------------------------------------------------------------
set -uo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

CLAUDE_DIR="$HOME/.claude"
HOOK="$CLAUDE_DIR/hooks/block-phi.py"
SETTINGS="$CLAUDE_DIR/settings.json"
TRANSCRIPTS="$CLAUDE_DIR/projects"
GIT_IGNORE="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore"
STAMP="$(date +%Y%m%d-%H%M%S)"

problems=0
changed=0

say()   { printf '%s\n' "$*"; }
head2() { printf '\n== %s\n' "$*"; }
ok()    { printf '   ok    %s\n' "$*"; }
warn()  { printf '   WARN  %s\n' "$*"; }
bad()   { printf '   FAIL  %s\n' "$*"; problems=$((problems + 1)); }
did()   { printf '   done  %s\n' "$*"; changed=$((changed + 1)); }
plan()  { printf '   would %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. The PHI guard
#
# The hook is the only layer that survives an interpreter, so a failure here is
# fatal. Deny rules alone are decorative: they match a command's prefix, and a
# Python one-liner opening the same path has a different prefix.
# ---------------------------------------------------------------------------
head2 "PHI guard"

if [ ! -f "$HOOK" ]; then
  bad "hook missing: $HOOK -- restore it from config/block-phi.py"
elif [ ! -x "$HOOK" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    plan "chmod +x $HOOK"
  else
    chmod +x "$HOOK" && did "made the hook executable"
  fi
else
  ok "hook present and executable"
fi

if grep -q 'block-phi.py' "$SETTINGS" 2>/dev/null; then
  ok "hook registered in settings under hooks.PreToolUse"
else
  bad "hook is not registered in $SETTINGS"
fi

# Exercise it. A guard nobody tested is a guard nobody has.
if [ -x "$HOOK" ]; then
  guard_fail=0
  probe() { # probe <expected-exit> <json> <label>
    printf '%s' "$2" | python3 "$HOOK" >/dev/null 2>&1
    if [ "$?" -ne "$1" ]; then
      guard_fail=$((guard_fail + 1))
      say "   FAIL  guard case: $3"
    fi
  }
  # must refuse
  probe 2 '{"tool_name":"Bash","tool_input":{"command":"cat data/stage1/s1.diarizen.rttm"}}' \
        "cat an rttm"
  probe 2 '{"tool_name":"Bash","tool_input":{"command":"python3 <<PY\nprint(open(\"data/stage1/s1.diarized.json\").read())\nPY"}}' \
        "python heredoc opens a diarized json"
  probe 2 '{"tool_name":"Bash","tool_input":{"command":"awk 1 data/stage1/s1.transcript.txt"}}' \
        "awk over a transcript"
  probe 2 '{"tool_name":"Read","tool_input":{"file_path":"/x/PSYCH-ASR/data/stage1/s1.rttm"}}' \
        "Read tool on an rttm"
  # must allow
  probe 0 '{"tool_name":"Bash","tool_input":{"command":"ls -la data/stage1/"}}' \
        "listing filenames"
  probe 0 '{"tool_name":"Bash","tool_input":{"command":"python3 scripts/join_speakers.py --rttm data/stage1/s1.diarizen.rttm --outdir data/stage1"}}' \
        "running a pipeline stage"
  probe 0 '{"tool_name":"Bash","tool_input":{"command":"cat data/stage1/s1.arm_scores.json"}}' \
        "the metrics file"
  probe 0 '{"tool_name":"Bash","tool_input":{"command":"cat > doc.md <<MD\nnames the rttm shape in prose\nMD"}}' \
        "a heredoc that writes a document"

  if [ "$guard_fail" -eq 0 ]; then
    ok "8/8 guard cases behave"
  else
    bad "$guard_fail guard case(s) misbehaving"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Credentials recorded in session transcripts -- REPORT ONLY
#
# Transcripts record every command that was run, secrets included, and they sit
# in the group-readable directory audited in section 4.
#
# This section deliberately does not rewrite them. Two reasons. A transcript is
# a log, and a script that edits logs to remove awkward strings is a habit
# worth not acquiring. And redaction does not revoke anything: once a key has
# been on disk in a directory other people can read, rotating it is the only
# fix, after which the recorded copy is inert.
#
# Patterns only, never a literal secret -- this script is committed to a public
# repository.
# ---------------------------------------------------------------------------
head2 "Credentials in transcripts (report only)"

if [ ! -d "$TRANSCRIPTS" ]; then
  warn "no transcript directory at $TRANSCRIPTS"
else
  found=0
  scan() { # scan <label> <extended-regex>
    local n
    n="$(grep -rlE "$2" "$TRANSCRIPTS" 2>/dev/null | wc -l)"
    if [ "$n" -gt 0 ]; then
      warn "$n transcript(s) contain a $1 -- rotate it, do not just delete the file"
      found=$((found + n))
    fi
  }
  # Lengths are set above the longest plausible false positive. An earlier
  # draft used sk-[A-Za-z0-9_-]{24,} and matched a PDF filename 71 times.
  scan "tailscale auth key"       'tskey-[A-Za-z0-9-]{12,}'
  scan "secret passed on argv"    '\-\-secret[= ]+[A-Za-z0-9]{32,}'
  scan "hugging face token"       'hf_[A-Za-z0-9]{34,}'
  scan "anthropic key"            'sk-ant-[A-Za-z0-9_-]{40,}'
  scan "openai-style key"         'sk-[A-Za-z0-9]{40,}'
  scan "github classic PAT"       'ghp_[A-Za-z0-9]{36}'
  scan "github fine-grained PAT"  'github_pat_[A-Za-z0-9_]{50,}'
  scan "aws access key id"        'AKIA[0-9A-Z]{16}'
  [ "$found" -eq 0 ] && ok "no credential-shaped strings found"
fi

# ---------------------------------------------------------------------------
# 3. Permission files that are committed to repositories
#
# `.claude/settings.json` is tracked on purpose in several repositories here --
# the global ignore covers only settings.local.json, and at least one commit
# message says so outright ("board settings survive the dotfile ignore"). So
# this section does NOT add an ignore rule; overriding a deliberate decision is
# not hardening, and an ignore rule cannot untrack a committed file anyway.
#
# What matters instead is that a tracked allowlist stays free of secrets. An
# allowlist entry records a whole command line, and command lines are where
# keys get pasted.
# ---------------------------------------------------------------------------
head2 "Committed permission files"

CRED_RE='tskey-[A-Za-z0-9-]{12,}|--secret[= ]+[A-Za-z0-9]{32,}|hf_[A-Za-z0-9]{34,}|sk-ant-[A-Za-z0-9_-]{40,}|sk-[A-Za-z0-9]{40,}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{50,}|AKIA[0-9A-Z]{16}'
tracked_any=0

for repo in "$HOME"/*/; do
  [ -d "$repo/.git" ] || continue
  files="$(git -C "$repo" ls-files '.claude/settings*.json' 2>/dev/null)"
  [ -n "$files" ] || continue
  tracked_any=1
  name="$(basename "$repo")"

  private="$(cd "$repo" && timeout 15 gh repo view --json isPrivate -q '.isPrivate' 2>/dev/null)"
  case "$private" in
    true)  vis="private" ;;
    false) vis="PUBLIC"  ;;
    *)     vis="visibility unknown" ;;
  esac

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    # Check the committed blob, not the working copy: what is published is
    # what is in the repository.
    n="$(git -C "$repo" show "HEAD:$rel" 2>/dev/null | grep -cE "$CRED_RE")"
    if [ "${n:-0}" -gt 0 ]; then
      bad "$name/$rel ($vis) contains $n credential-shaped string(s) IN GIT HISTORY"
    else
      ok "$name/$rel ($vis) is clean"
    fi
  done <<EOF
$files
EOF
done

[ "$tracked_any" -eq 0 ] && ok "no repository tracks a .claude settings file"

# ---------------------------------------------------------------------------
# 4. Home directory exposure -- audit, and fix only if the filesystem allows
#
# On this cluster the home tree is group rwx for `domain users` and the mode is
# enforced below the client: chmod does not stick and there is no POSIX default
# ACL to strip. The probe below establishes which world we are in rather than
# assuming, so this script stays correct on a machine where chmod does work.
# ---------------------------------------------------------------------------
head2 "Home directory exposure"

mode_of() { stat -c '%A %U %G' "$1" 2>/dev/null || echo "unreadable"; }
say "   $(mode_of "$HOME")   \$HOME"
say "   $(mode_of "$CLAUDE_DIR")   ~/.claude"
say "   $(mode_of "$TRANSCRIPTS")   ~/.claude/projects"

probe_file="$CLAUDE_DIR/.permtest-$STAMP"
if touch "$probe_file" 2>/dev/null; then
  chmod 600 "$probe_file" 2>/dev/null
  probe_mode="$(stat -c '%A' "$probe_file" 2>/dev/null)"
  rm -f "$probe_file"
else
  probe_mode="untestable"
fi

if [ "$probe_mode" = "-rw-------" ]; then
  ok "chmod is honoured here; permissions are yours to set"
  if [ "$DRY_RUN" = 1 ]; then
    plan "chmod 700 ~/.claude and ~/.claude/hooks, 600 the settings"
  else
    chmod 700 "$CLAUDE_DIR" "$CLAUDE_DIR/hooks" 2>/dev/null
    chmod 600 "$SETTINGS" 2>/dev/null
    chmod 700 "$HOOK" 2>/dev/null
    did "tightened ~/.claude to owner-only"
  fi
else
  warn "chmod does NOT stick (a fresh file came back as ${probe_mode})"
  warn "the mode is enforced on the mount and this account cannot revoke it"
  warn "group 'domain users' can read AND write everything under \$HOME,"
  warn "including this hook and your shell profile -- see the handover below"
fi

# ---------------------------------------------------------------------------
# 5. What only a human can do
# ---------------------------------------------------------------------------
head2 "Left for you"

cat <<'HANDOVER'
   1. Revoke any key section 2 flagged. Tailscale admin console -> Settings ->
      Keys, and issue a fresh one if a node still needs to join. No script can
      do this; it needs an authenticated console session. Rotation is the fix.
      Deleting the transcript is not.

   2. If section 4 reported that chmod does not stick, send the storage
      administrators the text below.

      ----------------------------------------------------------------
      My home directory on the dell_storage homefolders mount is mode
      rwxrwx--- with group 'domain users', and the mode is enforced below
      the client: chmod and setfacl both fail to change it, and there is no
      POSIX default ACL to strip.

      Two questions:
        - Is group access on home directories intentional? Every member of
          'domain users' can currently read and write my home tree.
        - Should PHI-derived artifacts live on this mount at all? Session
          logs and analysis outputs under my home fall under the same
          group permissions.

      The write bit concerns me most: files I rely on for integrity,
      including a security hook and my shell profile, are group-writable.
      ----------------------------------------------------------------

   3. Decide what to do with transcripts predating the PHI guard. Sessions run
      in PSYCH-ASR before the guard existed may hold diarization output in
      their logs, in the group-readable directory above. Deleting them trades
      exposure against losing session history, which is your call, not this
      script's. To see the candidates:

        ls ~/.claude/projects/*PSYCH-ASR*/
HANDOVER

# ---------------------------------------------------------------------------
head2 "Summary"
say "   changes made : $changed"
say "   problems     : $problems"
[ "$DRY_RUN" = 1 ] && say "   (dry run -- nothing was written)"

if [ "$problems" -gt 0 ]; then
  say ""
  say "   The PHI guard is not sound. Fix that before running anything in PSYCH-ASR."
  exit 1
fi
exit 0
