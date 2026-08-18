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

---

## 1. Cluster facts this repo depends on

| Fact | Value |
| --- | --- |
| Scheduler | Slurm |
| GPU partitions | `c3_short` (9 h cap), `c3` (7 d cap), `c3_accel` (7 d cap) |
| `c3` / `c3_short` nodes | 6 nodes, **1× NVIDIA A40 (46 GB) each**, ~1 TB RAM |
| `c3_accel` node | **compute306 only**, **4× A40**, 96 CPUs, 1 TB RAM |
| GPU isolation | **None.** `nvidia-smi` shows a node's GPUs whether or not you reserved one |
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
| Pre-existing HF models | `/media/studies/ehr_study/analysis/mferguson/models/` | whisper, pyannote, embedders, and `google_medgemma-27b-text-it` (safetensors, for vllm) |

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

---

## 3. Environment (`~/.bashrc`)

A delimited `# >>> ollama >>>` block in `~/.bashrc` sets these. A backup of the pre-edit file is at
`~/.bashrc.bak.20260817160921`.

| Variable | Value | Why |
| --- | --- | --- |
| `PATH` | prepend `$HOME/bin` | reach the binary |
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

---

## 4. Serving

Two Slurm jobs. Submit **from the repo root** — the log paths are relative.

| Job | Partition | GPUs | Use |
| --- | --- | --- | --- |
| `slurm_jobs/ollama_serve.sbatch` | `c3` | 1 | daily driver (qwen3-coder, medgemma) |
| `slurm_jobs/ollama_serve_accel.sbatch` | `c3_accel` | 4 | `gpt-oss:120b` only |

Both source `~/.bashrc` (batch jobs do not do this automatically), guard on `OLLAMA_MODELS`, and run
`ollama serve` **in the foreground** — backgrounding it would let the script exit and Slurm would
tear down the allocation within seconds.

The accel job additionally exports `OLLAMA_SCHED_SPREAD=1` to force sharding across all four cards.

### After submitting

1. `squeue -u $USER` → note the node (e.g. `compute300`) and confirm `gres/gpu:N`.
2. Read `slurm_jobs/logs/ollama_serve_err.txt` — ollama logs to **stderr**. Look for
   `Listening on 127.0.0.1:11500` and an `inference compute ... NVIDIA A40` line.
3. `ssh <node>` and use the client from there.

### Reaching the server

The endpoint is **loopback on the job's node**. From any other node the connection is refused —
this is deliberate, not a bug. SSH to the node holding the job (permitted on this cluster, verified)
and run the client there. Do **not** rebind to `0.0.0.0`: that exposes a PHI-processing endpoint to
every user on the cluster.

### Verifying a 4-GPU shard

**Not yet performed** — the accel job has never been submitted (§8). What follows is the acceptance
criterion to check the first time it runs, not a record of observed behavior.

After one prompt to `gpt-oss:120b`, on compute306:

- `nvidia-smi` should show roughly **16–18 GB on each of four cards**. One card near 46 GB with three
  idle means the spread did not take.
- `ollama ps` must report `100% GPU`. Any CPU offload means it fell back and will be unusably slow.

`CUDA_VISIBLE_DEVICES` indices are **relative to the allocation**, not physical device numbers —
Slurm remaps them. Never hardcode a device index.

---

## 5. Models

| Tag | Size | Role |
| --- | --- | --- |
| `qwen3-coder:30b` | 18.6 GB | Default coding model. MoE, 30B total / ~3B active, tuned for agentic tool-calling. Fits one A40 with room for a 64k context |
| `medgemma:27b-it-q8_0` | 29.6 GB | Clinical prototyping. q8, not q4 — quantization damage shows up first on careful text extraction |
| `gpt-oss:120b` | 65.4 GB | Strongest coder available here. MoE. **Requires `c3_accel`** |

Pull with `ollama pull <tag>` from a shell on the node running the server. A server must already be
running — no GPU needed for a pull, it is network and disk only. Pulls are chunked and resumable;
re-running the same tag continues from an orphan blob rather than restarting.

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

---

## 8. Not done yet

- **The PHI boundary, layer 3.** Layers 1 and 2 are done (§6): global default-deny on `webfetch` /
  `websearch`, and a single `coder` agent that raises them to `ask`. Both are config, and config is
  one bad edit from being wrong. The remaining layer is the one that cannot be misconfigured:
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
  copy of `google_medgemma-27b-text-it` is already staged and vllm consumes it directly — at bf16
  (~55 GB) it needs two A40s with tensor parallelism. Intended workflow: prototype prompts against
  ollama q8, run production passes on vllm bf16.
- **The 4-GPU shard is unverified.** `gpt-oss:120b` finished downloading, but
  `ollama_serve_accel.sbatch` has never been submitted and no prompt has ever reached the model. The
  acceptance criteria in §4 are therefore a *specification*, not an observation. This is also the
  cheapest available rehearsal for the vllm work above, which needs tensor parallelism across two
  A40s on the same node.
- **Walltime.** Both jobs are 8 h. `c3` and `c3_accel` allow up to 7 days if a longer-lived server
  is wanted.
