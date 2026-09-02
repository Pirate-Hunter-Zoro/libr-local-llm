# Claude Code permissions on LIBR compute

Architecture record for the assistant's permission configuration: what is granted, what is
refused, where each rule lives, and which traps were paid for. The settings live under
`~/.claude/`, which is gitignored in every repository here, so verbatim copies are tracked
alongside this file:

- [`config/claude-settings.json`](config/claude-settings.json) — the user-level settings
- [`config/block-phi.py`](config/block-phi.py) — the PHI guard hook

Established 2026-09-02. No PHI, no participant identifiers and no credentials appear in any of
the three files; this repository is public.

---

## 0. The problem this solves

The account has no admin rights, which bounds the damage to the OS and nothing else. An agent
running as this user can still reach every file in the home tree, every mounted study share, the
credentials in `~/.ssh` and `~/.aws`, and the open network. `bypassPermissions` mode removes the
one step that would catch a prompt injection before it acts, so the goal is to make the
permission prompt rare enough that bypass mode is never worth reaching for.

Two properties are wanted at once, and they conflict in exactly one place (§4):

1. **Convenience** — routine read-only work never prompts, in *any* repository.
2. **Security** — diarization and ASR outputs derived from identifiable therapy recordings are
   unreadable by the assistant, and credentials are unreadable by anything.

---

## 1. Three layers, in precedence order

Deny beats allow. The `PreToolUse` hook beats both, because it inspects the command text rather
than matching a pattern against its prefix.

| Layer | Lives in | Enforces |
|---|---|---|
| Hook | `~/.claude/hooks/block-phi.py` | the PHI ban, regardless of interpreter |
| Deny rules | `~/.claude/settings.json` → `permissions.deny` | PHI paths, credential files, `sudo`, curl-pipe-to-shell |
| Allow rules | `~/.claude/settings.json` → `permissions.allow`, plus per-repo files | which commands skip the prompt |

### Why the hook is the layer that carries the weight

Permission patterns match against the *prefix* of a command string. A rule denying
`Bash(cat *.rttm*)` says nothing about a Python one-liner that opens the same path, and the
allowlists in the research repos already grant `Bash(python3 *)` and `Bash(awk *)`. Deny rules
alone would therefore be decorative.

The hook receives the tool call as JSON on stdin, matches artifact *shapes* anywhere in the
command text, and exits 2 to refuse. An interpreter cannot route around it, because the path
still has to appear somewhere in the command it is handed — including inside a heredoc body.

---

## 2. What the PHI guard refuses

Artifact shapes, matched anywhere on disk so that a copy is covered too:

| Shape | What it holds |
|---|---|
| `*.rttm` | speaker turns |
| `*.diarized.json` | ASR words joined to speakers |
| `*.transcript.txt` | rendered transcript |
| `*.aligned.json` | word-level ASR alignment |
| `*.arm_comparison.json` | embeds verbatim disputed text |
| `PSYCH-ASR/data/**` | every stage-1 artifact and all raw audio |

Also refused: the arm-comparison script. It prints disputed transcript spans to stdout, so
running it is a read even though the assistant opens no file.

### What stays readable, deliberately

Refusing too much would make the assistant useless on the diarization bake-off, so the guard is
deliberately narrow:

- **`*.arm_scores.json`** — DER at each collar, missed detection, false alarm, confusion,
  talk-time ratio error, backchannel accuracy. The writer builds that dict out of numbers and
  never touches segment text. This is the file carrying the actual result, and it stays open.
- **`slurm_jobs/logs/**`** — the stage-1 jobs log segment counts, durations and speaker counts,
  never content. Debugging a failed job needs them.
- **Every pipeline script, and running it.** Writing to disk is not reading to the model, so the
  diarizers, the joiner, the ASR stage and every `sbatch` still operate on the real artifacts.
- **`ls` / `find` / `stat`** against the artifacts. Filenames and sizes are not content.

### Trap: a heredoc that writes is not a heredoc that reads

The guard's first version blocked this very document, because the prose names the artifact
extensions. The rule now distinguishes by what is consuming the heredoc: an interpreter can open
a path from inside the body and is still scanned, while `cat > file <<EOF` is writing literal
text and is exempt. Getting this wrong in the safe direction makes the guard unusable; getting it
wrong in the other direction makes it useless.

The ordering matters too. The named-script check has to come *after* the heredoc exemption, or
documenting the script's name blocks the document.

### Trap: two absolute paths reach the same tree

Home is visible as both `/home/<user>/…` and `/mnt/dell_storage/homefolders/<user>/…`. A deny
rule anchored to one path leaves the other wide open, so every path-anchored rule is written
twice. The hook sidesteps this entirely by matching on artifact shape rather than on location.

---

## 3. What the credential deny covers

`~/.ssh/**`, `~/.aws/credentials`, `~/.gnupg/**`, `~/.netrc`, `~/.git-credentials`. No workflow
here reads them, and they are the obvious prize for an injected instruction. `sudo` and
`curl … | bash` are denied for the same reason: no legitimate step needs either.

`.env` is **not** denied. The ASR setup genuinely checks whether a token variable is populated,
and blocking it would break a real step without slowing an attacker who already has a shell.

---

## 4. Where convenience and security actually conflict

One place: **ad-hoc interpreter invocations.** `Bash(python3 *)` grants arbitrary code execution
— functionally equivalent to bypass mode for anything expressible in Python.

The resolution taken:

- `Bash(python3 *)` and `Bash(node *)` stay **only in the repositories that already had them**
  (Tutor-Board, PSYCH-ASR), where heredoc-driven work is the daily pattern and the repository is
  trusted. They are **not** promoted to the user level.
- The PHI guard makes this safe *for the PHI question specifically*, because it reads the heredoc
  body. It does not make it safe in general.
- Everything else that is genuinely read-only is promoted to the user level, so it follows the
  session into any repository.

The honest consequence: **in a repository with no project allowlist, an ad-hoc `python3` heredoc
still prompts.** That is the price of not rebuilding bypass mode inside the allowlist, and it is
the right price.

---

## 5. What the user-level allowlist covers

Promoted because it is repository-agnostic and read-only:

- **Slurm** — `squeue`, `sacct`, `sinfo`, `scontrol show`
- **Hardware and environment** — `nvidia-smi`, `ffprobe`, `ffmpeg -version`, `module avail`,
  `module list`, `quota -s`
- **Syntax checks that execute nothing** — `bash -n`, `python3 -m py_compile`, `node --check`
- **Loopback HTTP only** — `curl -s http://127.0.0.1:*` and the `localhost` forms. No egress host
  is granted at the user level; the research repositories grant their own, host by host.
- **Cross-repository git reads** — `git -C * log|status|diff`
- **The board and tutor CLIs**, read-only verbs only: `next`, `recap`, `status`, `net`, `doctor`,
  `inbox`, `slate`, `wait`, `eyes`, `hw status|list`, `review status|list`, `tutor where`,
  `tutor agent status`. `start`, `stop`, `open`, `finish`, `push` and `vpn` are omitted on
  purpose — they mutate or reach the network.
- **Document conversion** — `pdftotext`, `pdftoppm`, `kpsewhich`, `tr`

Deliberately omitted: `awk` (it has `system()`), anything that pushes, and every package
installer. A push is worth one keystroke.

### Trap: the allowlist entry has to match what is actually typed

The Tutor-Board allowlist was full of entries reading `Bash(./bin/board next *)` while the real
invocation was `board next` — the CLI is on `PATH`. Every one of those entries had been silently
missing for months, and the prompts they were meant to suppress kept arriving. When an allowlist
appears not to work, compare it against the literal command string in the transcript before
concluding the mechanism is broken.

### Trap: the bypass-mode warning had been suppressed

`skipDangerousModePermissionPrompt` was `true`, which removes the confirmation dialog on entering
`bypassPermissions`. Now `false`. That prompt is the last thing standing between a tired evening
and an unattended agent.

### Trap: hooks are live immediately

Editing `settings.json` mid-session does *not* leave the hook unarmed until restart, as one might
assume by analogy with shell configuration. The guard began refusing calls in the same session it
was written. Plan for a mistake in a hook to take effect at once.

---

## 6. The audit script

[`scripts/harden-claude.sh`](scripts/harden-claude.sh) verifies all of the above and fixes what
is safe to fix without a decision. It is idempotent, and re-running it *is* the audit.
`--dry-run` reports without writing.

What it checks:

1. the hook is present, executable, registered, and behaves on 8 probe cases
2. transcripts under `~/.claude/projects/` for credential-shaped strings
3. every committed `.claude/settings*.json`, with repository visibility, for secrets
4. whether `chmod` is honoured on this filesystem, tightening `~/.claude` where it is
5. stale session transcripts and the size of the prompt log (see §8)

Exit 1 means the PHI guard is unsound. Nothing should run in `PSYCH-ASR` until it exits 0.

### What it deliberately does not do

- **It does not rewrite transcripts.** An earlier draft redacted secrets from them in place. That
  is log tampering wearing a hygiene costume, and it fixes nothing: once a key has sat in a
  directory other people can read, rotation is the only remedy, after which the recorded copy is
  inert. The script reports and names the rotation step instead.
- **It does not add a gitignore rule for `.claude/settings.json`.** Several repositories here
  track that file on purpose — one commit says so outright, *"board settings survive the dotfile
  ignore"*. Overriding a deliberate decision is not hardening, and an ignore rule cannot untrack
  a committed file in any case. The script audits the committed blobs for secrets instead, which
  is the risk that actually exists.
- **It does not delete anything.** Transcripts predating the guard are an exposure with a cost on
  both sides, so the script names the tradeoff and leaves the call to a person.

### Trap: a secret regex tuned too loose is worse than none

The first version matched `sk-[A-Za-z0-9_-]{24,}` and reported twelve compromised transcripts.
All 71 hits were one PDF filename containing the letters `sk-str`. A scanner that cries wolf gets
ignored, which is strictly worse than not running it. Every pattern is now set above the longest
plausible false positive, and real key formats are matched by their own prefixes.

---

## 7. Rebuilding this on a new machine

1. Copy [`config/block-phi.py`](config/block-phi.py) to `~/.claude/hooks/block-phi.py` and mark
   it executable.
2. Copy [`config/claude-settings.json`](config/claude-settings.json) to `~/.claude/settings.json`,
   correcting the absolute path in the `hooks.PreToolUse` command to the new home.
3. Run [`scripts/harden-claude.sh`](scripts/harden-claude.sh). It confirms the rest, including
   that `skipDangerousModePermissionPrompt` is `false`, and reports anything it cannot fix.

---

## 8. Session history is disposable

Decided 2026-09-02. Session transcripts under `~/.claude/projects/` are not part of the record.
Every repository here documents itself — README, `DESIGN.md`, the contract files — so the durable
account of what was built lives in git, and a transcript is only a log of how it came to be
written. Against that near-zero value, transcripts accumulate whatever reached the assistant's
context, which for `PSYCH-ASR` meant diarization output from sessions predating the guard in §1.

The archive was purged on 2026-09-02: 95 transcripts, 201 MB, plus `~/.claude/history.jsonl`, the
prompt log that records every command typed. Three transcripts were spared as live or recently
touched. `~/.claude/projects/` went from 235 MB to 51 MB.

**`harden-claude.sh` reports; it does not delete.** That asymmetry is deliberate. An audit you are
told to re-run must never be the thing that destroys data, and this directory holds transcripts
belonging to other people's live sessions — losing a colleague's in-flight work to a routine audit
is not a trade worth the seconds it saves. §5 of the script counts what is eligible, excludes the
current session and anything touched in the last 30 minutes, and prints the command.

### Trap: `find` here is `bfs`

The purge was first written with `! -newermt '30 minutes ago'`. On these nodes `find` is `bfs`,
which rejects relative timestamps outright — so the predicate errored, the eligible list came back
empty, and *the spare-list came back empty too*. Had the delete not been gated on a count, it
would have run with no exclusions and taken the live sessions with it. Use `-mmin`, which both
implementations accept, and never let a delete depend on a predicate whose failure mode is an
empty exclusion set.

---

## 9. What this configuration does not solve

### Trap: `rwxrwx---` on this filer does not mean what it says

The home tree reports mode `rwxrwx---` with group `domain users`, a group with 130 members. An
earlier version of this document concluded from that alone that 130 people could read and write
the home tree, and said so twice, in public commits. That conclusion was wrong.

The mount is NFSv4 on an Isilon. Access is decided by an NFSv4 ACL, and the POSIX mode the client
displays is a lossy synthesis of that ACL rather than the thing being enforced. The measurement
that settles it, which `harden-claude.sh` now performs:

| Check | Result |
|---|---|
| Am I in `domain users`? | yes, it is the primary group |
| Peer homes showing the same `rwxrwx---` and group | 79 |
| …that deny me anyway | 70 |
| …that let me in | 9 |

If the group bits were live, membership would open all 79. Seventy refuse, so the bits are
decorative and the ACL defaults to closed. The nine are individual choices by their owners, not
the platform's default.

Two lessons worth more than the finding. A mode is evidence about a filesystem's *conventions*,
not proof of access — the only proof is attempting the access. And the test that produced the
false alarm was itself broken: `id -Gn | tr ' ' '\n' | grep -x 'domain users'` splits a group name
that contains a space and returns a confident false negative. Compare group membership by GID.

What remains genuinely unknown: this home's own ACL cannot be read from the account that owns it,
because `nfs4_getfacl` is not installed. Unverified is not the same as exposed, and it is not the
same as safe either. `harden-claude.sh` prints the question to send the storage administrators —
phrased as a question, since that is what it is.
