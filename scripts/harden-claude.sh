#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# harden-claude.sh -- verify this account's Claude Code fencing, fix the parts
# that are safe to fix automatically, and state plainly what is left.
#
#   scripts/harden-claude.sh [--dry-run]
#
# Idempotent, and re-running is the point: it doubles as the audit. The only
# things it writes are a gitignore line and file modes, both backed up or
# reversible. It never deletes and never rewrites a transcript -- sections 2
# and 5 report; removal stays a deliberate act.
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
# 4. Home directory exposure -- audit only, and do not jump to conclusions
#
# The home tree reports mode rwxrwx--- with group `domain users`, which reads
# like 130 people can rummage through it. On this filer that inference is
# WRONG, and an earlier version of this script made it loudly.
#
# The mount is NFSv4 on an Isilon. Access is decided by an NFSv4 ACL; the POSIX
# mode the client displays is a lossy *synthesis* of that ACL, not the thing
# being enforced. The proof is below: this account is a member of
# `domain users`, peer home directories show exactly the same group rwx mode,
# and listing them is denied anyway.
#
# So the script measures, states what it cannot determine, and stops. Whether
# THIS home's ACL grants the group anything cannot be answered from inside the
# account, because there is nobody else here to test it with.
# ---------------------------------------------------------------------------
head2 "Home directory exposure"

mode_of() { stat -c '%A %U %G' "$1" 2>/dev/null || echo "unreadable"; }
say "   $(mode_of "$HOME")   \$HOME"
say "   $(mode_of "$CLAUDE_DIR")   ~/.claude"
say "   $(mode_of "$TRANSCRIPTS")   ~/.claude/projects"

fstype="$(findmnt -T "$HOME" -no FSTYPE 2>/dev/null)"
say "   filesystem: ${fstype:-unknown}"

# Am I in the group the mode is granting rights to? Note the group name
# contains a space, so compare by GID -- splitting `id -Gn` on whitespace
# silently breaks "domain users" in half and reports a false negative.
home_gid="$(stat -c '%g' "$HOME" 2>/dev/null)"
home_grp="$(stat -c '%G' "$HOME" 2>/dev/null)"
if id -G 2>/dev/null | tr ' ' '\n' | grep -qx "$home_gid"; then
  in_group=1
  say "   you ARE a member of '$home_grp' (gid $home_gid)"
else
  in_group=0
  say "   you are NOT a member of '$home_grp' (gid $home_gid)"
fi

# Do the mode bits actually decide anything? Test against peers that show the
# same mode. If the group bit were enforced, membership would get us in.
peers_same_mode=0
peers_denied=0
for d in "$(dirname "$HOME")"/*/; do
  [ -d "$d" ] || continue
  [ "$(basename "$d")" = "$(basename "$HOME")" ] && continue
  [ "$(stat -c '%g' "$d" 2>/dev/null)" = "$home_gid" ] || continue
  case "$(stat -c '%A' "$d" 2>/dev/null)" in
    drwxrwx*) peers_same_mode=$((peers_same_mode + 1))
              ls "$d" >/dev/null 2>&1 || peers_denied=$((peers_denied + 1)) ;;
  esac
done

peers_open=$((peers_same_mode - peers_denied))
if [ "$in_group" = 1 ] && [ "$peers_same_mode" -gt 0 ]; then
  say "   peers with the same mode: $peers_same_mode ($peers_denied deny you, $peers_open let you in)"
  # A single readable peer proves nothing: users can open their own directory.
  # What matters is which way the filer leans by default.
  if [ "$((peers_denied * 100 / peers_same_mode))" -ge 75 ]; then
    ok "the POSIX mode is synthetic -- you are in '$home_grp', these homes all"
    ok "show group rwx, and $peers_denied of $peers_same_mode deny you anyway"
    ok "-> an NFSv4 ACL decides access here, and it defaults to closed"
    say "   the $peers_open open one(s) are individual choices, not the default"
    warn "THIS home's ACL still cannot be read from the account that owns it"
    warn "(nfs4_getfacl is not installed) -- unverified, not proven safe"
  else
    bad "$peers_open of $peers_same_mode peer homes are readable by you"
    bad "-> group access looks live on this filer; assume yours is too"
  fi
else
  warn "could not establish whether the mode bits are enforced here"
fi

# chmod failing is expected on ACL-backed storage and is not itself a finding.
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
  say "   chmod does not stick (a fresh file came back as ${probe_mode})"
  say "   -- normal on ACL-backed storage, and not evidence of exposure"
fi

# ---------------------------------------------------------------------------
# 5. Session history
#
# Policy, decided 2026-09-02: session transcripts are disposable here. Every
# repository on this account documents itself -- README, DESIGN, the contract
# files -- so the durable record is in git, and a transcript is only a log of
# how that record came to be written. Against that they accumulate whatever
# reached the assistant's context, which for PSYCH-ASR meant diarization output
# from sessions predating the guard in section 1.
#
# The script REPORTS what is eligible and prints the command. It does not
# delete on its own, and that is deliberate: an audit you are told to re-run
# should never be the thing that destroys data, and transcripts belonging to
# other people's live sessions share this directory. Losing a colleague's
# in-flight session to a routine audit is not a trade worth making for the few
# seconds it saves.
# ---------------------------------------------------------------------------
head2 "Session history"

LIVE_WINDOW_MIN=30   # a transcript touched this recently may be a live session

if [ ! -d "$TRANSCRIPTS" ]; then
  ok "no transcript directory"
else
  self="${CLAUDE_CODE_SESSION_ID:-nomatch}"
  # NOTE: `find` on these nodes is bfs, which rejects relative -newermt
  # timestamps ("30 minutes ago") with an error rather than matching nothing.
  # -mmin is portable across both and fails safe.
  eligible="$(find "$TRANSCRIPTS" -name '*.jsonl' -type f \
                   ! -mmin "-$LIVE_WINDOW_MIN" ! -name "*${self}*" 2>/dev/null | wc -l)"
  live="$(find "$TRANSCRIPTS" -name '*.jsonl' -type f -mmin "-$LIVE_WINDOW_MIN" 2>/dev/null | wc -l)"

  if [ "$eligible" -eq 0 ]; then
    ok "no stale transcripts ($live live or recent, left alone)"
  else
    mb="$(find "$TRANSCRIPTS" -name '*.jsonl' -type f \
               ! -mmin "-$LIVE_WINDOW_MIN" ! -name "*${self}*" -printf '%s\n' 2>/dev/null \
          | awk '{s+=$1} END {printf "%.0f", s/1048576}')"
    warn "$eligible stale transcript(s), ${mb} MB, eligible for removal"
    say  "   $live left alone (this session, or touched in the last ${LIVE_WINDOW_MIN}m)"
    say  "   to purge them:"
    say  "     find ~/.claude/projects -name '*.jsonl' -type f \\"
    say  "          ! -mmin -${LIVE_WINDOW_MIN} ! -name \"*\$CLAUDE_CODE_SESSION_ID*\" -delete"
  fi

  # The prompt log is the same class of record: it stores every command typed,
  # which is where a secret pasted onto a command line comes to rest.
  # Claude Code recreates this file as soon as you type, so its existence is
  # not a finding. Its size is: a large one has been accumulating for months.
  PROMPT_LOG="$CLAUDE_DIR/history.jsonl"
  log_kb=$(( $(stat -c%s "$PROMPT_LOG" 2>/dev/null || echo 0) / 1024 ))
  if [ "$log_kb" -gt 64 ]; then
    warn "prompt log is ${log_kb} KB -- every command typed, secrets included"
    say  "   to clear it:  rm -f ~/.claude/history.jsonl"
  else
    ok "prompt log is small (${log_kb} KB)"
  fi
fi

# ---------------------------------------------------------------------------
# 6. What only a human can do
# ---------------------------------------------------------------------------
head2 "Left for you"

cat <<'HANDOVER'
   1. Rotate whatever section 2 flagged, in whichever system issued it. Check
      what the secret actually gates before deciding urgency -- a value passed
      as `--secret` may be an application's own shared secret rather than a
      cloud credential, and the two carry very different risk. Rotation is the
      fix either way; deleting the transcript is not.

   2. Ask the storage administrators the questions below. This is a question,
      not an incident report: section 4 establishes that the POSIX mode is
      synthetic on this filer, so the real ACL on your home is unknown from
      here rather than known to be bad.

      ----------------------------------------------------------------
      My home directory on the homefolders NFSv4 mount shows mode rwxrwx---
      with group 'domain users'. I understand the mode is a synthesis of the
      underlying NFSv4 ACL rather than the ACL itself -- I am in that group,
      and peer home directories showing the same mode correctly deny me.

      I cannot read the actual ACL from my account (nfs4_getfacl is not
      installed), so two questions:

        - What does the ACL on my home directory actually grant, and to whom?
        - Analysis outputs derived from identifiable recordings live under my
          home. If the ACL grants anything beyond me, is this mount an
          appropriate location for them, or should they move to a share with
          an explicit access list?
      ----------------------------------------------------------------

   3. Nothing further on session history -- policy is set (section 5) and the
      transcripts predating the PHI guard were purged on 2026-09-02. Section 5
      reports anything that has since accumulated and prints the command.

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
