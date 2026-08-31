# libr-local-llm

Local LLM inference on LIBR compute — **no admin rights, no data leaving the cluster.**

> **This repo is public** (`github.com/Pirate-Hunter-Zoro/libr-local-llm`). That is defensible
> because it holds serving configuration only — no PHI, no data, no credentials — but it is a
> standing constraint on every future commit, not a one-time decision. Nothing sensitive goes in
> here. Ever.

This repo holds the serving infrastructure (Slurm jobs, client config) that the research repos sit
on top of. It is deliberately *not* part of `PSYCH-ASR` or `TRD-EHR`: both projects need local
inference, and a general-purpose model server is not a stage in either pipeline. If a third project
appears, it uses this too.

> **Why local at all.** `PSYCH-ASR` processes identifiable PHI (psychotherapy session recordings and
> their transcripts). Its README states the constraint plainly: no audio, transcript, or derived
> feature may ever leave the node or reach an external API. Every model that touches that data must
> therefore run on LIBR hardware. This repo is how that happens.

> **Documentation convention** (mirrored from `Research-Journey/README.md`): this README documents
> **architecture only** — what exists, where it lives, how it is wired, and which traps were paid
> for. No empirical results, no findings, no model-quality claims. Sizes, ports, walltimes, and
> resource asks are architecture and belong here.

> **Where the next phase is planned.** [`DESIGN.md`](DESIGN.md) holds the design for **the fleet** —
> a preemption-aware service running all three engines (ollama, vllm, colibrì) across the cluster's
> GPUs, acquiring nodes when they are free and yielding them when somebody else needs them. It is
> design only; **nothing in it is built.** This README stays the record of what *exists*, and the two
> must not be read as one document. Durable facts graduate from `DESIGN.md` into here when a piece
> is built and verified. (Added 2026-08-22.)

---

## 0. Bootstrap from zero (order matters)

How this was built, in the order it must be redone on a fresh account or after a wipe. Details for
each step are in the numbered sections below.

1. **Get `zstd`.** `module load zstd/1.5.6-GCCcore-13.3.0`. It is not installed system-wide, and all
   Ollama Linux release assets are zstd-compressed. Prefer the `GCCcore-13.3.0` build — the 1.5.5
   build is against 13.2.0 and forces a downgrade-reload of `GCCcore` and `zlib`.
2. **Download the Ollama tarball.** `curl -L -O -f` against the GitHub release asset
   `ollama-linux-amd64.tar.zst` (v0.32.14 at time of writing, 1.42 GB). The `-L` is mandatory —
   the URL 302-redirects and curl without it silently writes a redirect stub and exits 0. The
   `ollama.com/download/...tgz` URL in older install scripts is **dead**: it redirects to an asset
   that 404s.
3. **Verify it.** `sha256sum` against the release's published `sha256sum.txt`.
4. **Extract into `$HOME`.** `tar -x --zstd -f <tarball> -C ~`. The `-C ~` is load-bearing: the
   archive holds `bin/ollama` and `lib/ollama/`, and the binary finds its bundled CUDA runtime by a
   fixed relative path. Extracted anywhere else it starts fine and then reports no GPU. This yields
   `~/bin/ollama` (39 MB) and `~/lib/ollama` (2.2 GB). Delete the tarball afterwards.
5. **Add the `~/.bashrc` block** (§3). Eight variables. `PATH`, then the seven `OLLAMA_*` settings.
   Open a new shell; `ollama --version` should print `0.32.14` and warn that no server is running.
6. **Create the model store.** `mkdir -p` the directory named by `OLLAMA_MODELS`. Use a dedicated
   `ollama/` subdirectory — the parent `models/` already holds ~120 GB of HuggingFace weights
   (whisper, pyannote, embedders) and ollama's `blobs/`+`manifests/` should not be scattered among
   them.
7. **Start a server.** `sbatch slurm_jobs/ollama_serve.sbatch` from the repo root. A GPU is *not*
   required to download models, but you need a running server for the next step, so this doubles as
   the first real test. Confirm from `slurm_jobs/logs/ollama_serve_err.txt` that it is listening and
   found the A40.
8. **Pull the models.** `ssh` to the node from `squeue`, then `ollama pull <tag>` once per model
   (§5). ~117 GB total. Concurrent pulls in separate shells are safe — different models write
   different blobs. Verify afterwards that the store grew and `~/.ollama` did **not** (it should
   hold only a ~200 KB keypair).
9. **Install opencode.** `npm install -g opencode-ai` — with `-g`, or it installs into the current
   directory and litters the repo.
10. **Write the opencode config** (§6), including the `enabled_providers` allowlist. Verify with
    `opencode models` on the server's node: exactly three `ollama/` entries, nothing remote.
11. **Put the repo's `bin/` on `PATH`.** Append it inside the `# >>> ollama >>>` block in `~/.bashrc`
    (§3). **This step is required, not cosmetic** — the driver commands (§4a) live in the repo rather
    than in `~/bin` so they stay tracked in git, which means nothing finds them until `PATH` says
    where they are. After this, steps 7 and 8 above collapse into `ollama-up` and `ollama-code`.
    A clone on a fresh account is not usable until this is done.

---

## 1. Cluster facts this repo depends on

| Fact | Value |
| --- | --- |
| Scheduler | Slurm |
| GPU partitions | `c3_short` (9 h cap), `c3` (7 d cap), `c3_accel` (7 d cap) |
| `c3` / `c3_short` nodes | 6 nodes, **1× NVIDIA A40 (46 GB) each**, ~1 TB RAM |
| `c3_accel` node | **compute306 only**, **4× A40**, 96 CPUs, 1 TB RAM |
| CPU (every node) | 2× Intel Xeon Gold 6342 @ 2.80 GHz — 24 cores/socket, 96 threads, **2 NUMA nodes**, **AVX-512 with VNNI** |
| GPU compute capability | **8.6** (Ampere), driver 610.43.02. No FP8 tensor cores — AWQ/GPTQ int4, int8 and bf16 are the usable formats |
| GPU interconnect | **NVLink reports all links inactive.** Cross-GPU traffic goes over PCIe, so tensor parallelism pays an all-reduce tax on every layer |
| GPU isolation | **None.** `nvidia-smi` shows a node's GPUs whether or not you reserved one |
| Node-local scratch | **None.** `TmpDisk=0`, and `/` is a RAM-backed tmpfs. Every cold model load is an NFS read |
| `/tmp` | RAM-backed **tmpfs**, node-local, vanishes with the node. Never write logs there |
| Home | NFS, 100 GB share. Not a model store |
| Studies share | `/media/studies` → `/mnt/dell_storage/studies`, ~16 TB free |
| Outbound HTTPS | Works from compute nodes (model pulls succeed inside an allocation) |
| `zstd` | Not installed system-wide; available via `module load zstd/1.5.6-GCCcore-13.3.0` |

**The GPU-isolation point is the one that bites.** A job with no `--gres=gpu:N` still *sees* the
node's cards and can use them, but Slurm has not reserved them and will hand the same card to
someone else. Always request GPUs explicitly; verify with `scontrol show job <id>` that `AllocTRES`
contains `gres/gpu=N`, and that `CUDA_VISIBLE_DEVICES` is set inside the job.

---

## 2. What is installed, and where

Nothing here required admin rights.

| Component | Location | Notes |
| --- | --- | --- |
| Ollama binary | `~/bin/ollama` | v0.32.14, user-local |
| Ollama CUDA runtime | `~/lib/ollama` | ~2.2 GB, bundled `cuda_v12` + `cuda_v13` backends. Path is relative to the binary — do not move one without the other |
| Model weights (GGUF) | `/media/studies/ehr_study/analysis/mferguson/models/ollama` | ~117 GB. `blobs/` + `manifests/` |
| Ollama client identity | `~/.ollama/` | ed25519 keypair only, ~200 KB. **Not** model storage |
| opencode CLI | `~/.nvm/versions/node/v24.15.0/bin/opencode` | v1.18.18, `npm install -g opencode-ai` |
| opencode config | `~/.config/opencode/opencode.json` | tracked copy in `config/opencode.json` |
| Driver commands | `bin/ollama-up`, `bin/ollama-code`, `bin/ollama-down` | tracked here; put `bin/` on `PATH` (§3). See §4a |
| Pre-existing HF models | `/media/studies/ehr_study/analysis/mferguson/models/` | whisper, pyannote, embedders, and `google_medgemma-27b-text-it` (safetensors, for vllm) |
| colibrì upstream checkout | `~/colibri` | ~65 MB. Read-only clone of `github.com/JustVugg/colibri`, kept current by a daily user timer (§2.1). Nothing here runs it yet — see §8 |

### Installing ollama from scratch

Ollama no longer publishes `.tgz` for Linux — only `.tar.zst`. The old `ollama.com/download/...tgz`
URL redirects to a GitHub release asset that 404s.

1. `module load zstd/1.5.6-GCCcore-13.3.0` (choose the GCCcore-13.3.0 build; the 1.5.5 build forces
   a downgrade-reload of `GCCcore` and `zlib`).
2. Download `ollama-linux-amd64.tar.zst` from the GitHub release with `curl -L -O -f`. **`-L` is
   mandatory** — the URL 302-redirects and curl without it writes a redirect stub and exits 0.
3. Verify with `sha256sum` against the release's `sha256sum.txt`.
4. Extract with `tar -x --zstd -f <tarball> -C ~`. The `-C ~` target is load-bearing: the archive
   contains `bin/ollama` and `lib/ollama/`, and the binary locates its CUDA libraries by a fixed
   relative path. Extract anywhere else and it starts but reports no GPU.

### Installing opencode

`npm install -g opencode-ai` (note: package `opencode-ai`, command `opencode`). Node v24.15.0 via
nvm; the global prefix is inside `$HOME`, so no sudo and it is visible on every node. npm warns that
a postinstall script was blocked — **ignore it**; the platform binary arrives as an optional
dependency and works.

### 2.1 Keeping the colibrì checkout current

(Added 2026-08-30.) `~/colibri` is a plain clone of the upstream engine, tracking `main`. It is
fast-forwarded **once a day, automatically**. This is unrelated to any tutoring or serving process
and shares nothing with them: its own script, its own log, its own timer.

| Piece | Path |
| --- | --- |
| The script | `~/.local/bin/colibri-pull` |
| Log (one line per run) | `~/.local/state/colibri-pull.log` |
| Once-a-day guard | `~/.local/state/colibri-pull.stamp` |
| Timer + service units | `~/.config/systemd/user/colibri-pull.{timer,service}` |

`colibri-pull` is fast-forward-only and never fatal: a dirty tree or a diverged branch is logged and
left alone, because merging somebody else's repository is not a decision a timer gets to make.
`colibri-pull --force` runs it by hand regardless of the day guard.

**Why a systemd `--user` timer and not cron.** `crontab` is refused on this cluster — *"You
(mferguson) are not allowed to access to (crontab) because of pam configuration"* — so cron was
never available to us. The user timer is what is left, and it needs two deliberate settings to work
on a machine like this:

- **`Persistent=true`, which is the load-bearing one.** The account has `Linger=no`, so the systemd
  user manager exists only while a session does, and a compute node's allocation takes it away
  besides. A timer alone would therefore not be running at midnight and would simply never fire.
  `Persistent=true` records the last run in `~/.local/share/systemd/timers/`, and **that path is on
  the shared home** — so a *different* node, on a *later* day, reads the same record, sees the run is
  overdue, and fires it at login. The node is disposable; the record is not.
- **A small `RandomizedDelaySec` (2m).** The jitter's usual job — spreading load across many
  machines — buys one user with one repository nothing, and a delay longer than a short editor
  session would let the day's pull be missed entirely.

Net effect: at most one pull per day, taken on the first login of the day on whatever node you land
on, or at 00:00 if you happen to already be logged in. Verified 2026-08-30 by backdating the
persistent record three days and cold-starting the timer: it fired at once, then re-armed for the
following day.

---

## 3. Environment (`~/.bashrc`)

A delimited `# >>> ollama >>>` block in `~/.bashrc` sets these. A backup of the pre-edit file is at
`~/.bashrc.bak.20260817160921`.

| Variable | Value | Why |
| --- | --- | --- |
| `PATH` | **prepend** `$HOME/bin` | reach the ollama binary |
| `PATH` | **append** `$HOME/libr-local-llm/bin` | reach the driver commands (§4a). See below — this one has three constraints |
| `OLLAMA_MODELS` | `/media/studies/.../models/ollama` | weights on studies, not the 100 GB home share |
| `OLLAMA_HOST` | `127.0.0.1:11500` | non-default port avoids collisions on shared nodes; **loopback keeps a PHI-processing endpoint off the cluster network** |
| `OLLAMA_CONTEXT_LENGTH` | `65536` | ollama defaults to a few thousand tokens; an agent silently truncates its own history there |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` | roughly halves long-context VRAM |
| `OLLAMA_FLASH_ATTENTION` | `1` | same |
| `OLLAMA_MAX_LOADED_MODELS` | `1` | qwen3-coder + medgemma = 48.2 GB, more than one A40 holds; evict cleanly |
| `OLLAMA_KEEP_ALIVE` | `20m` | release VRAM when idle so others can use the card |

**`OLLAMA_MODELS` is read from the *server's* environment, not the client's.** `ollama pull` is only
a client; the server writes the files. Start the server from a shell that has not sourced `.bashrc`
and 117 GB lands in `~/.ollama`.

### The `bin/` PATH entry (three constraints, all deliberate)

The driver commands live in the repo, not in `~/bin`, so that they stay tracked in git and are
reviewable alongside the sbatch files they drive. The cost is that `PATH` has to point at them, and
the line that does it is fussier than it looks:

1. **Reference it through `$HOME`, not the storage path.** `$HOME/libr-local-llm` and
   `/mnt/dell_storage/homefolders/.../libr-local-llm` are the *same directory* — same inode, two
   mounts. Hardcoding the `/mnt` form works but bakes in a mount layout for no benefit.
2. **Append, never prepend.** `$HOME/bin` is prepended because the ollama binary must win. The repo's
   `bin/` is appended so that repo contents can never shadow a system command — a file added here
   later should not silently outrank one in `/usr/bin`.
3. **Guard it with an `if` block, not `[ -d … ] && …`.** The `&&` form returns non-zero when the
   directory is absent, and this is the last executable line in the block — so sourcing `.bashrc`
   would exit non-zero and abort a batch job running under `set -e`. That is trap §7.6 in a new
   costume. The `if` form returns zero either way.

Verified: the commands resolve in a fresh login shell and on a compute node, and sourcing `.bashrc`
under `set -e` returns zero both with the directory present and with it missing.

---

## 4. Serving

Two Slurm jobs. Submit **from the repo root** — the log paths are relative.

| Job | Partition | GPUs | CPUs | Use |
| --- | --- | --- | --- | --- |
| `slurm_jobs/ollama_serve.sbatch` | `c3_short` | 1 | 4 | daily driver (qwen3-coder, medgemma) |
| `slurm_jobs/ollama_serve_accel.sbatch` | `c3_accel` | 4 | 8 | `gpt-oss:120b` only |

**On the partition choice.** `c3` and `c3_short` are two queues over the *same six nodes*
(compute300–305, one A40 each). They differ only in time limit — 7 days versus 9 hours — and in how
contended they are: `c3` was carrying 201 running jobs against `c3_short`'s 13 when this was
measured. A server that lives under 9 hours schedules sooner on `c3_short`, so that is the default.
Switch the file to `c3` if you want one to outlive that; `ollama-up` rejects a `single` walltime over
9 h rather than letting Slurm return a partition-limit error that does not say what to change.

**On the CPU ask.** Both jobs used to reserve far more CPU than they use. Measured on a live server
holding a 70 GB model at 100% GPU: **0.1% CPU, 73 MB RSS, node load 0.00.** With weights on the GPU
the host does almost nothing, and the one expensive phase — the cold model load — is disk-I/O bound,
not CPU bound. This is not a micro-optimization: an 8-CPU ask left the single-GPU job **queued behind
two nodes whose A40 was idle but which had only 4 free CPUs.** Memory stays generous on purpose; it
is page cache for the mmap'd weights, which is what makes a reload fast.

Both source `~/.bashrc` (batch jobs do not do this automatically), guard on `OLLAMA_MODELS`, and run
`ollama serve` **in the foreground** — backgrounding it would let the script exit and Slurm would
tear down the allocation within seconds.

The accel job additionally exports `OLLAMA_SCHED_SPREAD=1` to force sharding across all four cards.

### After submitting

1. `squeue -u $USER` → note the node (e.g. `compute300`) and confirm `gres/gpu:N`.
2. Read `slurm_jobs/logs/ollama_serve_err.txt` — ollama logs to **stderr**. Look for
   `Listening on 127.0.0.1:11500`.
3. Step onto the node (see below) and use the client from there.

In practice you should not do any of this by hand — `ollama-up` (§4a) does all three and refuses to
report success unless they all pass.

### Reaching the server

The endpoint is **loopback on the job's node**. From any other node the connection is refused —
this is deliberate, not a bug. Do **not** rebind to `0.0.0.0`: that exposes a PHI-processing endpoint
to every user on the cluster.

Two ways onto the node. **Prefer the first.**

- **`srun --jobid=<id> --overlap`** steps into the existing allocation and runs a command there. No
  SSH key, no password, and it inherits the job's `CUDA_VISIBLE_DEVICES`. Add `--pty` for anything
  interactive (a TUI needs it). This is what `ollama-code` uses.
- **`ssh <node>`** also works *if* your key agent is set up. It is not always: a non-interactive SSH
  from the login node was refused with `Permission denied (publickey,password)` while `srun
  --overlap` to the same node succeeded in the same shell. Treat SSH as the fallback.

### Verifying a 4-GPU shard

**Verified 2026-08-20** on compute306, job 2041641, `gpt-oss:120b`. Observed, not specified:

| Check | Observed |
| --- | --- |
| `nvidia-smi` per-card VRAM | 18877 / 17139 / 17205 / 16573 MiB — 16–18 GB on each of four cards |
| `ollama ps` | `100% GPU`, 70 GB, context 65536 |
| GPU detection | 4× A40, `compute=8.6`, `cuda_v13` backend, driver 13.3 |

`OLLAMA_SCHED_SPREAD=1` engages as intended. One card near 46 GB with three idle would mean it had
not; any CPU offload in `ollama ps` would mean it fell back and would be unusably slow.

Cold-start cost, same run: **total 5m00s, of which load was 4m46s** — 65.4 GB paging off the NFS
studies share at roughly 230 MB/s. Warm generation ran at 34.1 tok/s. That load figure is the whole
argument for warming a model *before* a demo rather than during one (§4a).

`CUDA_VISIBLE_DEVICES` indices are **relative to the allocation**, not physical device numbers —
Slurm remaps them. Never hardcode a device index.

---

## 4a. Driver commands (`bin/`)

Three tracked scripts wrap everything above. They run **from anywhere, including the login node** —
they find the job through `squeue` and step onto its node with `srun --overlap`.

**They are not on `PATH` by default.** They live in the repo rather than `~/bin` so they stay under
version control, which means `~/.bashrc` has to be told where they are — §3 covers the line and the
three constraints on it. Until that is done, they only work when called by path from the repo root.
Once it is, none of §4's manual steps need doing by hand again.

Deliberately **no state file**: the client asks Slurm which job is running every time. A state file
goes stale the moment a job ends or a second one is submitted; `squeue` never does.

| Command | Does |
| --- | --- |
| `ollama-up [single\|accel] [hours]` | Submits the matching sbatch, waits for `RUNNING`, asserts `AllocTRES` contains `gres/gpu=`, waits for `Listening on` in the stderr log. Exits non-zero unless the server is actually serving. Optional walltime in hours overrides the file's 8 h. Reports the pending reason while it waits, and leaves the job queued if it gives up. |
| `ollama-code [-m model] [-d dir] [-k dur] [-p single\|accel] [message…]` | Finds the running server and launches opencode on its node. No message → the TUI. A message → a one-shot `opencode run`. |
| `ollama-down [all\|single\|accel]` | Cancels the server jobs. Run it when done — compute306 is the only 4-GPU node. |

Behaviors worth knowing:

- **`ollama-up` refuses to double-submit.** `OLLAMA_MAX_LOADED_MODELS` is 1 and both profiles bind
  the same loopback port, so a second server is never useful. It also truncates the stderr log first,
  because the readiness check greps for `Listening on` and a stale hit from the previous job would
  report success before the new server had started.
- **`ollama-code` adopts the resident model** when `-m` is absent, reading it from `ollama ps`.
  Naming a different model evicts the warm one and pays the multi-minute reload — not something to
  discover mid-demo. With nothing resident it falls back to the profile's default.
- **`ollama-code -k <duration>` warms and exits.** Use it before a demo. It sends one throwaway
  prompt with `--keepalive` so the load cost is paid up front, then stops rather than dropping into
  the TUI, which makes it safe to call from a script.
- `ollama-up` prefers `--chdir` over a `cd`, since §4's log paths are relative to the repo root, and
  captures the job id via `sbatch --parsable` rather than parsing "Submitted batch job N".
- **Both scripts scrub `SLURM_*` before shelling out**, which is what lets them run from inside
  another allocation. See trap §7.19 — this is not defensive garnish, the unscrubbed version fails.

---

## 4b. Working from an editor on a compute node

The common case: a VSCode remote session whose workspace is served from an interactive job on some
compute node, while the model server holds a *different* node. The endpoint is loopback on the
server's node, so the editor's node cannot reach it directly — and the two nodes are not the same
one.

The driver commands already handle this. From the VSCode terminal, `ollama-code` finds the server
through `squeue` and hops to its node with `srun --overlap`, exactly as it would from the login node.
Nothing about the editor's own allocation needs changing, and no port forwarding is involved.

Two things to know:

- **Your files are visible from both nodes.** Home and `/media/studies` are network filesystems
  mounted everywhere, so the opencode session started on the server's node sees the same workspace.
  Pass the workspace path with `-d` if you launch from somewhere else; the default is the current
  directory, which is usually what you want.
- **This is the case that trips trap §7.19.** Running Slurm commands from inside an allocation is
  what breaks without the `SLURM_*` scrub. Verified working from compute302 against a server on
  compute306.

---

## 5. Models

| Tag | Size | Role |
| --- | --- | --- |
| `qwen3-coder:30b` | 18.6 GB | Default coding model. MoE, 30B total / ~3B active, tuned for agentic tool-calling. Fits one A40 with room for a 64k context |
| `medgemma:27b-it-q8_0` | 29.6 GB | Clinical prototyping. q8, not q4 — quantization damage shows up first on careful text extraction |
| `gpt-oss:120b` | 65.4 GB | Strongest coder available here. MoE. **Requires `c3_accel`**. Reasoning model — `ollama run` exposes `--think` (true/false or high/medium/low) and `--hidethinking` |

The store on disk is ~131 GB, larger than the sum of the tags above: `blobs/` also holds layers that
no current manifest points at.

Pull with `ollama pull <tag>` from a shell on the node running the server. A server must already be
running — no GPU needed for a pull, it is network and disk only. Pulls are chunked and resumable;
re-running the same tag continues from an orphan blob rather than restarting.

**Cold loads are slow and it is the studies share, not the GPUs.** `gpt-oss:120b` took 4m46s to page
65.4 GB off NFS (~230 MB/s) before its first token. Warm it before you need it — `ollama-code -k`
(§4a) exists for exactly that.

`ollama list` shows only *completed* models — the manifest is written last. Mid-flight, the store
directory will be larger than the sum of listed models.

---

## 6. opencode (the coding assistant)

Config lives at `~/.config/opencode/opencode.json`; a tracked copy is `config/opencode.json`.
Structure:

- `enabled_providers: ["ollama"]` — **default-deny provider allowlist.** opencode ships ~8 hosted
  "free" models under an `opencode/` provider (OpenCode Zen). Those are **remote**; selecting one
  sends the prompt off-cluster. This key hides every provider not listed, so future opencode releases
  cannot quietly add another remote option to the picker.
- `provider.ollama` — `npm: "@ai-sdk/openai-compatible"`, `options.baseURL:
  "http://127.0.0.1:11500/v1"` (note the `/v1` suffix and port **11500**, not ollama's default 11434).
- `provider.ollama.models` — keys must exactly match the ids returned by `GET /v1/models`, which for
  ollama are the tag names.
- `model` — the default, `ollama/qwen3-coder:30b`.
- `permission` — **top-level default-deny for `webfetch` and `websearch`.** Same principle as
  `enabled_providers`: the default is "no", and exceptions are named explicitly. This matters because
  opencode's built-in default for almost every gated tool is `allow` — an *absent* `permission`
  section is not a closed door, it is an open one.
- `agent.coder` — a `primary` agent that overrides both web tools back up to `ask` (not `allow`).
  `default_agent` points at it. Every other agent — the built-in `build`, `plan`, `general`,
  `explore`, `title`, `summary`, `compaction` — inherits the global deny.

Resolution order is built-in agent defaults, then the top-level `permission` block, then the
per-agent block; last one wins. Verified against the built-in `explore` agent, which ships with
`webfetch: allow` and is correctly overridden to `deny` by the global block.

Verify with `opencode models` on the server's node: it should list exactly three `ollama/` entries
and nothing else. Verify the permission wiring with `opencode agent list`, which prints each agent's
fully resolved rule stack — `coder` should end in `ask`, everything else in `deny`.

**opencode cannot be used to reach Claude.** Its docs state Anthropic prohibits routing Claude
Pro/Max subscriptions through it, and the plugins that did so were removed in 1.3.0. The only
supported Anthropic path is a per-token API key. Claude Code (LIBR seat) and opencode+ollama are
separate tools with a clean split: Claude Code for non-PHI work, opencode for anything local.

### Web access: decided scope (2026-08-20, not yet applied)

The intent is to let the coding assistant reach the web. Recorded here as a decision so the
reasoning survives the config change.

**Permissions are per *agent*, not per model.** There is no setting that grants web access to
`qwen3-coder:30b`. Any model can be driven by any agent, so the boundary that matters is the
*workload*, not the weights: a `coder` agent running medgemma is fine, a transcript-coding agent
running qwen3 is not. "Enable web for all our models" does not map onto anything opencode exposes,
and thinking in those terms is how the wrong agent ends up with the wrong tool.

Two distinct risks, and the second is the one usually missed:

- **Egress.** Anything in the context window can leave in a search query or a fetch URL. §1 confirms
  outbound HTTPS works from compute nodes, so opencode's config is the *only* thing keeping PHI on
  the cluster.
- **Ingress — prompt injection.** Fetched pages enter the context as text the model cannot
  distinguish from your instructions. The `coder` agent has file and shell access, so every page it
  reads becomes a potential instruction source. This risk is present even with no PHI anywhere near
  the session.

What will change, and what deliberately will not:

| Setting | Decision |
| --- | --- |
| Top-level `permission` deny | **Unchanged.** It is what closes the built-in `explore` subagent, which ships with `webfetch: allow` (trap §7.12). A per-agent-only config would leave that open. |
| `coder` → `webfetch` | Raise `ask` → `allow`. A URL you typed is the lower-risk direction. |
| `coder` → `websearch` | **Keep at `ask`.** This is the direction where your prompt text leaves the building. |
| Any transcript-reading agent | Never. No web tools, ever. |

**This makes layer 3 more urgent, not less** (§8). Loosening layers 1 and 2 is precisely why the
layer that cannot be misconfigured needs to exist.

---

## 7. Traps already paid for

Do not re-learn these.

1. **The dead `.tgz` URL.** `ollama.com/download/ollama-linux-amd64.tgz` redirects to a GitHub asset
   that no longer exists (404). All Linux assets are `.tar.zst` now.
2. **`curl` without `-L`** writes a redirect stub and exits 0 — looks like "nothing happened".
3. **`-C` on curl takes an argument** (`-C -` to auto-resume). Bare `-C` swallows the next token.
4. **`[` is a command, not punctuation.** `[!` is parsed as a command named `[!` and fails with
   "command not found" — and `bash -n` *passes*, because it is syntactically valid. The failing
   command returns non-zero, the `if` reads that as false, and the guard silently never fires.
   Write `[ ! -d ... ]` with spaces.
5. **`ollama pull` needs a running server.** `/api/generate` does *not* download a missing model; it
   errors. A script that pipes that call to `/dev/null` and prints "Model loaded" is lying.
6. **`.bashrc` is not sourced by batch jobs.** Source it explicitly, and do so *before* `set -e` —
   `.bashrc` contains `[ -s file ] && source file` patterns that return non-zero when a file is
   absent and would abort the job during startup.
7. **`npm install` without `-g`** installs into the current directory and pollutes the repo with
   `node_modules/`, `package.json`, and `package-lock.json`.
8. **The npm postinstall warning for `opencode-ai` is harmless.** The real binary arrives as an
   optional dependency.
9. **`~/.ollama` appearing is not a failure.** It holds an ed25519 client keypair, ~200 KB. Check its
   *size*, not its existence.
10. **A Slurm job without `--gres=gpu:N` still sees the node's GPUs.** Seeing a card is not reserving
    one.
11. **opencode's permission defaults are `allow`, not `deny`.** Every gated tool except `doom_loop`
    and `external_directory` defaults to `allow`. "We never configured web tools" therefore means
    the web tools were *on*, not off. Only `.env` files are denied out of the box.
12. **The built-in `explore` subagent ships with `webfetch`/`websearch` set to `allow`.** A global
    deny does override it, but agent-level defaults exist and are invisible until you read the
    resolved stack from `opencode agent list`. Do not assume the built-ins are inert.
13. **conda envs are not Python venvs.** `setup_envs.sh` in PSYCH-ASR creates *conda* prefix envs; a
    conda env can hold compiled binaries (which is why it was a candidate for `zstd`), a `python -m
    venv` cannot.
14. **`--keepalive` is per *request*, not per session.** It sets the hold for that one call. Any
    later request that omits it — and **opencode omits it on every call** — resets the model's expiry
    to `OLLAMA_KEEP_ALIVE` (20 m). Warming a model two hours before a demo and then poking it once
    through opencode drops the hold back to 20 minutes, so it evicts before the audience arrives and
    you pay the ~5-minute reload live.
15. **GPU discovery in ollama 0.32.14 is lazy.** The `inference compute ... NVIDIA A40` lines appear
    when the *first model loads*, not at startup. A freshly started server logs `Listening on` and
    then `discovering available GPUs...` and stops. An absent A40 line at that point means nothing
    has loaded yet, **not** that the GPUs were missed.
16. **SSH to a compute node is not guaranteed; `srun --overlap` is.** A non-interactive SSH from the
    login node was refused (`publickey,password`) while `srun --jobid=<id> --overlap` reached the same
    node from the same shell. Build tooling on `srun`, not `ssh`.
17. **Grepping a Slurm log for a readiness string needs the log truncated first.** `Listening on`
    from the *previous* job is still sitting in the file and will report success before the new
    server has started. `ollama-up` empties the stderr log before submitting.
18. **`ollama run` writes a spinner to the captured stream.** Piping it to a file yields tens of
    thousands of ANSI escape sequences around the actual answer. Strip escapes before reading it
    programmatically, or the timings block is unfindable.
19. **Slurm commands run *inside* an allocation inherit `SLURM_*` and misbehave.** This is the one
    that bites when your editor is already on a compute node (§4b). A nested `srun --jobid=<other>
    --overlap` dies with **exit 192** despite naming a different job explicitly, because it picks up
    the outer job's `SLURM_JOB_ID` and step context. Worse and quieter: `sbatch` inherits the outer
    job's `SLURM_*` too, and those **override the `#SBATCH` directives in the file** — a server
    submitted from a compute-node terminal can come up with the wrong partition, memory, or GPU
    count and never say so. Both `ollama-up` and `ollama-code` unset every `SLURM_*` variable before
    shelling out. Verified failing and then passing from compute302 against a server on compute306.
20. **Loopback is not a security boundary on a shared node.** (Added 2026-08-22.) Slurm gives a job
    no network namespace, so *any* user with a shell on the node running the server can connect to
    `127.0.0.1:11500` on it. §4's "the endpoint is loopback, from any other node the connection is
    refused" is true and is a real control against the *cluster network* — it is not a control
    against the *node's other users*, and this README previously read as though it were both. The
    honest statement: loopback is necessary and not sufficient, and **ollama has no authentication
    at all**, so today the only thing between another account on compute30x and our endpoint is that
    they have no reason to look. Two consequences: keep the endpoint on the least-populated node we
    reasonably can, and treat "does this engine support an API key" as a selection criterion for
    anything added next (colibrì does; ollama does not). This is a live gap, not a hypothetical one.

21. **There is no cron here, and a user timer does not survive on its own.** (Added 2026-08-30.)
    `crontab` is blocked by PAM for this account, and `Linger=no` means the systemd user manager
    dies with your last session — on a compute node it dies with the allocation regardless. So
    "schedule it for 3am" is not a thing this cluster can do for a user account: nothing of ours is
    running at 3am. Anything recurring must be written to *catch up when a session next exists*
    (`Persistent=true`, whose record lives on the shared home and therefore survives the node), and
    must be idempotent for the period, because two logins on two nodes in one day will otherwise run
    it twice. §2.1 is the worked example.

---

## 8. Not done yet

- **The fleet — the repo's next phase, designed 2026-08-22, none of it built.** All three engines
  (ollama, vllm, colibrì) behind one front door, spread across the cluster's GPUs by a supervisor
  that acquires nodes when they are free, **yields them when another user's job is blocked by what we
  hold**, and regrows when it can. The full design — goals and non-goals, the placement argument, the
  two data planes, the yield ladder, the citizenship rules, milestones with exit criteria, the
  measurements we owe ourselves, and the traps anticipated but not yet paid for — is
  [`DESIGN.md`](DESIGN.md). Read that before writing any of it. Three things from it that change how
  the items below should be read:
  - **Replicas, not shards.** With NVLink inactive (§1), independent single-GPU replicas beat
    tensor parallelism for any model that fits on one card — more aggregate throughput, and a replica
    can be surrendered one at a time where a 4-GPU job cannot. This supersedes the tensor-parallel
    assumption in the vllm item below.
  - **`c3_accel` is booked, never held.** Unchanged in spirit, tightened in practice.
  - **Citizenship is the core feature.** The hardware is already bought and already powered; the real
    cost of this service is other people's queue time, plus our own fair-share, which the *research*
    jobs then pay for. A fleet that has to be torn down by hand when a colleague complains has
    already failed.
- **Web access for the coding agent — NEXT.** Decision made and recorded in §6; the config edit
  itself is not applied. Raise `coder`'s `webfetch` from `ask` to `allow`, leave `websearch` at
  `ask`, and leave the top-level deny alone so the built-in `explore` subagent stays closed. Verify
  afterwards with `opencode agent list`, which prints each agent's fully resolved rule stack: `coder`
  should show `webfetch: allow` / `websearch: ask`, and **every other agent must still show both as
  `deny`**. If `explore` comes back with `allow`, the global block was edited by mistake — that is
  trap §7.12 and it is silent.
- **The PHI boundary, layer 3.** Layers 1 and 2 are done (§6): global default-deny on `webfetch` /
  `websearch`, and a single `coder` agent that raises them to `ask`. Both are config, and config is
  one bad edit from being wrong — and the web-access change above deliberately makes layer 2 weaker,
  which raises the value of this one rather than lowering it. The remaining layer is the one that
  cannot be misconfigured:
  **the clinical model must never run through opencode at all** — a plain Python client against the
  loopback endpoint with no tool-calling surface in the code. Nothing stops a tool-enabled agent from
  putting a transcript fragment into a search query, which is an exfiltration event under
  PSYCH-ASR's on-prem constraint. Not yet written.
- **vllm for PSYCH-ASR Stage 3c.** (Stage *3c* — behavioral and content coding with a local LLM.
  PSYCH-ASR's Stage 4 is feasibility modeling at N=20 and involves no LLM at all; earlier versions of
  this README, the Research-Journey README, and `LOCAL-LLM_TODO.txt` all mis-numbered this as
  "Stage 4".) Ollama is right for interactive single-user coding. Batch transcript work
  wants vllm: continuous batching for throughput, and guided decoding against a JSON schema so the
  model is structurally incapable of emitting anything but a valid rating object. The HF safetensors
  copy of `google_medgemma-27b-text-it` is already staged and vllm consumes it directly. Intended
  workflow: prototype prompts against ollama q8, run production passes on vllm bf16.
  **Revised 2026-08-22:** at bf16 (~55 GB) MedGemma 27B does not fit one A40, so it needs either two
  cards with tensor parallelism *or* 8-bit weights and a single card. `DESIGN.md` §4.2 argues for the
  second — one card per replica, several replicas — because on a PCIe-only host replicas are both
  faster in aggregate and yieldable one at a time. The 4-GPU shard verification (§4) stands either
  way; it says the multi-GPU path works, not that we should prefer it.
  `DESIGN.md` §5.3 also changes *how* the batch pass is driven: a filesystem work queue on the
  studies share rather than a network service. That is not a detour — it delivers the layer-3 PHI
  property above as a consequence of the architecture (there is no socket to misconfigure) instead of
  as a discipline someone has to maintain.
- **Walltime.** Both sbatch files default to 8 h. `c3` and `c3_accel` allow up to 7 days if a
  longer-lived server is wanted; `ollama-up` takes an hours argument for shorter ones, which is the
  right choice on `c3_accel` since compute306 is the only 4-GPU node.
- **`ollama-code` cannot pick the model for the TUI.** opencode's `--model` flag exists on its `run`
  subcommand but not on the bare TUI invocation, so `-m` only takes effect for one-shot prompts. In
  the TUI you get `config/opencode.json`'s default and change it from the in-app picker. Making `-m`
  work there means writing the default into the config before launching, which is a config mutation
  and has not been done.

The 4-GPU shard and one-command serving both used to live in this section. They are done (§4, §4a);
the shard verification says the multi-GPU path on this hardware is sound, which is worth having
established even though `DESIGN.md` now argues for replicas over sharding wherever a model fits on
one card. Knowing that the option works is what makes declining to use it a choice.
