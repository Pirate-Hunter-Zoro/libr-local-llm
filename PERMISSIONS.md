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

## 6. Rebuilding this on a new machine

1. Copy [`config/block-phi.py`](config/block-phi.py) to `~/.claude/hooks/block-phi.py` and mark
   it executable.
2. Copy [`config/claude-settings.json`](config/claude-settings.json) to `~/.claude/settings.json`,
   correcting the absolute path in the `hooks.PreToolUse` command to the new home.
3. Confirm `skipDangerousModePermissionPrompt` is `false`.
4. Verify by feeding the hook JSON on stdin and checking exit codes — 2 is a refusal, 0 is a
   pass. The two cases that matter most: a heredoc opening a diarized JSON must refuse, and a
   pipeline script running over an RTTM input must pass.
