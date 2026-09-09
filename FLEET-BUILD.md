# FLEET-BUILD.md — the build runbook for a colibrì-centred inference service

**Point a fresh session at this file.** It is the implementation plan for a local inference service
built around **colibrì** running a frontier MoE model on LIBR compute: acquired when free, given
back when somebody else needs it, restarted when it dies, and reachable from a terminal client on
any node.

**Revised 2026-09-09, second pass.** The first pass planned a three-engine fleet with ollama as the
daily driver. That is withdrawn. ollama's models (`qwen3-coder:30b`, `gpt-oss:120b`) are judged
inadequate in quality and reasoning for the work this is for, so the service is now built around
colibrì, which is the only engine here that can run a frontier-scale model at all. vLLM survives
with a narrowed, non-overlapping job (§8). Everything about the supervisor, the restart chain, and
the kill switch is unchanged and is still §5.

Read in this order before writing a line: [`AI_INSTRUCTIONS.md`](AI_INSTRUCTIONS.md),
[`README.md`](README.md), [`DESIGN.md`](DESIGN.md), then this file. A 16-slide plain-language
walkthrough is [`docs/fleet_walkthrough.pdf`](docs/fleet_walkthrough.pdf) (source
`docs/fleet_walkthrough.tex`).

**No sudo, anywhere, at any step.**

---

## 1. The verdict

**Buildable: yes. And the pivot to colibrì is better supported by the evidence than the plan it
replaces** — this hardware is unusually well matched to how colibrì works, for a reason nobody had
noticed: **1 TB of RAM per node.**

**The speed is 4–8 tok/s and that is a measurement, not a fear.** It does not get better with more
GPUs. §3 is the arithmetic and §3.4 is where the evidence comes from.

Three consequences, stated up front because everything below follows from them:

1. **This is a consultant, not an agent loop.** At 6 tok/s a 500-token answer takes 80 seconds and a
   2,000-token answer takes five and a half minutes. Asking one hard question and waiting is
   entirely reasonable. Driving forty tool calls through it is not, and no amount of engineering
   changes that.
2. **The four-GPU node buys almost nothing here, and that is the surprise.** With 1 TB of RAM the
   whole 372 GB model is RAM-resident, and colibrì's own controlled measurement puts the VRAM-versus
   -RAM placement difference at **under 2 %** once that is true. What the GPU is for is the *dense
   and attention* tensors — about 23 GB, which fits on **one** A40. compute306 is not needed for
   capacity.
3. **The cold start, not the GPU, is the hard constraint.** 372 GB off the studies share at a
   measured ~230 MB/s is **~27 minutes** before the first token. That single number drives the
   partition choice (§4), the citizenship design (§7), and why this service cannot be treated as
   yieldable in the way an ollama server was.

---

## 2. What colibrì is, in one paragraph

A 744B-parameter MoE activates ~40B parameters per token, and only the routed experts change from
token to token. colibrì therefore does not load the model — it **places** it. The dense part
(attention, shared experts, embeddings, ~17B params, ~9.9 GB at int4) stays resident; the 19,456
routed experts (~19 MB each) live across VRAM, RAM and disk as tiers of one hierarchy, staged on
demand with a per-layer LRU, a learned pinned hot-store, and one-layer-ahead prefetch. Placement
decides *speed only*: the router's decisions and the weights' precision are identical whether an
expert answered from VRAM or from disk. It is a single C file, no BLAS, no Python at runtime, and
it serves exactly one generation at a time.

---

## 3. The performance model — where the speed comes from and where it stops

This is the section to read before arguing about hardware. Everything is bandwidth arithmetic on a
per-token expert working set.

### 3.1 The governing equation

From colibrì's own instrumented run (`docs/experiments/glm52-4xa6000-2026-08-02.md` §5):

```
expert weights touched per token = 8 experts × 20.1 MB × 75 layers = 12.1 GB
time per token ≈ (bytes served from RAM) / (achieved RAM read bandwidth)
```

That is the whole ceiling. Everything else — tiering, pinning, context length, KV width — is
bounded above by it. On the 4×A6000 reference host the CPU-side routed path sustained
**19.67 GB/s** against ~85 GB/s of theoretical DDR4-2400, i.e. 23 % of the machine, and the
resulting ceiling was **3.0 tok/s**.

### 3.2 Why our node is the good case

| | reference host (4×A6000) | **LIBR compute30x** |
|---|---|---|
| CPU | EPYC 7402P, Zen 2, 24c/48t, **AVX2 only** | 2× Xeon Gold 6342, Ice Lake-SP, **48c/96t**, **AVX-512 + VNNI** |
| NUMA | 1 node | **2 nodes**, 515 GB each, distance 20 |
| RAM | 264 GB DDR4-2400, ~85 GB/s | **1 TB DDR4-3200**, ~410 GB/s across two sockets |
| model residency | 367 of 429 GB — **disk stays in the path** | **372 GB of 1 TB — the entire model, RAM-resident, disk leaves the decode path permanently** |
| GPU | 4× A6000 48 GB, sm_86 | 1–4× A40 46 GB, **sm_86 — same generation** |
| storage | local NVMe, 2.86 GB/s | NFS, **0.23 GB/s** — 12× worse, and it only affects cold start |

Two of those matter and the rest are detail. **AVX-512 VNNI** gives the int4 dot-product kernels a
path the reference host did not have, and colibrì selects it automatically at compile time. **1 TB
of RAM** removes disk from decode entirely, which is the configuration behind every good number in
colibrì's experiment set and which the reference host could not reach.

### 3.3 What the GPU is actually for

`CUDA_DENSE=1` was worth **×2.8** on the reference host (1.53 → 4.26 tok/s) and is **not mentioned
in colibrì's public README**. It moves the dense and attention tensors onto the GPU. It was decisive
because attention dominates decode as a generation lengthens — 64 % of decode time on a 750-token
answer, 26 % on a 64-token one.

Those tensors cost ~12 GB, plus ~11 GB of KV cache at 32k context. **23 GB — one A40 holds it.**

What four cards would add is expert residency in VRAM, and colibrì's own controlled A/B says that is
worth almost nothing once RAM residency is achieved: VRAM-heavy (188 GB) measured 2.81 tok/s against
balanced (176 GB) at 2.78 — indistinguishable — while raising the *RAM* budget from 205 to 235 GB
bought **+25 %**. An arithmetic check in the same report puts the VRAM/RAM bandwidth differential at
~1.3 ms of a 77 ms token, **under 2 %**.

> **Therefore: one A40, not four.** This is the same conclusion `DESIGN.md` §4.1 reached, but for a
> stronger reason than it had. It also means the service never touches compute306 for capacity,
> which is the best citizenship story available to us.

### 3.4 The number, and where it comes from

colibrì's source carries measurements taken on a **2-socket Ice Lake 48-core host with GLM-5.2 int4
fully resident** — the same CPU generation, core count, and residency condition as ours. From
`c/colibri.c`:

| condition | tok/s | expert-matmul | source |
|---|---|---|---|
| int4 IDOT off at S=1 (pre-VNNI baseline) | 3.65 | 67.8 GB/s | `colibri.c:541` |
| **AVX-512 VNNI int4 IDOT** (automatic when compiled for it) | **3.85** | **89.5 GB/s** | `colibri.c:541` |
| baseline in the XEXP campaign | 4.20 | — | `colibri.c:554` |
| **+ `XEXP=1`** (one OpenMP region per batch-union block) | **4.68** | **131.9 GB/s** | `colibri.c:554` |

Those runs are **CPU-side**; none of them mentions `CUDA_DENSE`. Adding one A40 to take the dense
and attention path is the ×2.8 lever on a host where the CPU was the bottleneck — ours is far
stronger, so expect less, but attention is 26–64 % of decode and moving it is aimed at the phase
that dominates.

> **Projected: 6–12 tok/s, most likely around 8.** *Projection*, from measured components: a
> measured 4.68 tok/s CPU-side floor on our CPU class, times a partial capture of a measured ×2.8
> GPU lever. The first real measurement replaces this line.
>
> `XEXP=1` was **neutral or negative on a 24-core box** and is opt-in for that reason. On 48 cores it
> is the single largest CPU-side lever available. Measure it; do not assume it.

### 3.5 What does not help, with evidence

- **More GPUs** — §3.3. Under 2 % once RAM-resident.
- **Concurrency.** The engine serialises: 1.32 / 1.51 / 1.46 tok/s aggregate at 1 / 2 / 4 clients.
  Two measurement clients at once produce erratic numbers and must be discarded. A colibrì backend
  is a **single-slot resource**; queue for it, never load-balance onto it.
- **Prefetch machinery, once resident.** Removing `URING` + `PILOT*` was worth **+26 %**: with
  experts resident the disk reads 0 MB/s during decode, so the overlap machinery only consumes CPU,
  which is the scarce resource. Keep `DIRECT=1 PIPE=1`.
- **Maximising memory blindly.** With the dense path on the CPU, a 176 GB/188 GB configuration
  measured *slower* than a 99 GB one. Gains do not compose; two settings aimed at the same residual
  miss do not add.
- **Longer context, for free.** Decode falls 23 % going from 32k to 131k, with no cliff up to 196k
  and prefill flat at 148–198 tok/s. `CTX=131072` is the recommended point.

### 3.6 The NUMA question, which is ours alone to answer

The reference host was single-socket. We have **two NUMA nodes of 515 GB each, distance 20**, and
the model is 372 GB. Two configurations, and they are genuinely different machines:

- **One socket.** `numactl --cpunodebind=0 --membind=0`. 24 cores, ~205 GB/s, every expert access
  local. **The model fits inside one NUMA node with 143 GB to spare** — this is the clean case, and
  it is not obvious it loses.
- **Both sockets interleaved.** `COLI_NUMA=1`. 48 cores, ~410 GB/s aggregate, but half of all expert
  reads cross UPI at 2× the latency. This is the configuration the 4.68 tok/s figure came from.

`coli tune` sweeps OpenMP thread count and NUMA policy on the real model and machine, and
disqualifies any candidate whose greedy output drifts by a byte. Use it rather than guessing — and
note that colibrì's own report names the thread-count sweep as *"the single most valuable
measurement still outstanding"* on this axis.

---

## 4. Placement, and the partition problem that has no clean answer

The colibrì backend wants: **1 GPU, ~500 GB RAM, as many cores as the node will give, and a life
long enough that a 27-minute cold start amortises.**

`MaxMemPerCPU=12000` couples the memory ask to the CPU ask (`README.md`, and §2.2 of the previous
revision): 500 GB forces at least 42 CPUs, and we want the cores anyway. `MaxCPUsPerNode=92`.
So the honest description of the ask is **`--gres=gpu:1 --cpus-per-task=92 --mem=500G`, which is
essentially one whole node of the six.** Say that out loud in any conversation about this service;
it is not a small job wearing a small costume.

Now the partition, and this is the genuinely hard part:

| partition | time limit | preemption exposure | GPUs | verdict |
|---|---|---|---|---|
| `c3_short` | **9 h** | none (`PriorityTier=20`, `PreemptMode=OFF`) | 1 | safe, but 27 min of every 9 h is a cold start — **5 % duty lost, 2.7 restarts a day** |
| `c3` | 7 d | **`SIGSTOP` by any `c3_short` job** (tier 10, `SUSPEND`) | 1 | long enough, but a suspended generation hangs the client with no error (§9.1) |
| `c3_accel` | 7 d | **none in practice** — no higher-tier partition contains compute306 | 4 | the only place offering *both* a long life and no preemption |

**The inversion worth noticing:** having argued in §3.3 that we do not need compute306's cards, the
strongest reason to run there is its *partition*, not its GPUs. It is the only combination on this
cluster of a 7-day limit and no preemption exposure, and a 27-minute cold start is exactly the
workload that cares.

That is decision 1 in §11 and it is not mine to make. The plan's default is **`c3_short` with the
restart chain**, because holding the cluster's only four-GPU node for a service that measurably does
not need four GPUs is indefensible however convenient the partition is. Take the 5 %.

**Page cache is the mitigation nobody has costed.** A node has 1 TB of RAM and the model is 372 GB.
A restart that lands on the *same* node may find much of the container still in page cache and skip
most of the 27 minutes. Measure it in P0 (test 9); if it holds, `c3_short` plus `--nodelist` affinity
becomes much cheaper than the table above suggests, and the argument for `c3_accel` weakens further.

---

## 5. The supervisor, the chain, and the kill switch

**Unchanged from the previous revision.** A 2-CPU Slurm job on `c3_short` that derives everything
from `squeue` and keeps no inventory state, submits its own successor at birth with
`--dependency=afterany:$SLURM_JOB_ID`, checks `${FLEET_STATE}/STOP` before anything else, and takes
one action per 30-second cycle with the reason logged. `fleet down` writes `STOP` first, then
cancels. A systemd `--user` timer is the once-a-day backstop, on the same `Persistent=true` pattern
as `colibri-pull` and `harden-claude`, and for the same reason: crontab is refused by PAM here.

Two changes the pivot forces:

- **Readiness is not "listening".** colibrì takes ~27 minutes to first token. A readiness timeout
  written for ollama fires at 3 % of the way through and the supervisor concludes the backend failed
  — `DESIGN.md` §14.3 anticipated exactly this. Readiness is `GET /health` answering **and** a
  one-token generation completing. Timeout 45 minutes, not 5.
- **The fair-share arithmetic gets worse and the answer is the same.** The supervisor's own 2-CPU
  floor still costs roughly our entire current recent usage if it runs around the clock (previous
  revision §2.3). `idle_exit_minutes: 120` stays the default. But note the colibrì backend itself
  now bills ~92 CPUs whenever it exists, which dwarfs the supervisor entirely — the honest framing
  is that **the backend is the fair-share cost and the supervisor is a rounding error.**

---

## 6. The front door — and colibrì hands us a better one than opencode

colibrì's HTTP server speaks **three** protocols on one port: OpenAI `/v1/chat/completions`, the
**Anthropic Messages API at `/v1/messages`**, and its own. GLM-5.2 supports OpenAI `tools` *and*
Anthropic `tool_use`, with `<tool_call>` blocks natively.

That means **Claude Code itself points at the local model with three environment variables** —
`ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL` — with no shim and no translating
proxy. The terminal experience the user actually wants is the one they already have, against local
weights.

Prefer it to opencode for this service, and keep opencode configured as the fallback. Three things
that follow:

- **colibrì has an API key and ollama does not.** `COLI_API_KEY` closes the gap recorded as live in
  `README.md` §7.20: loopback is not a boundary against other users on the same node, and until now
  nothing else was. **Set it on every backend that exists.** This is a strict improvement in the PHI
  posture, and it is the reason `DESIGN.md` §9 named "does this engine support an API key" as a
  selection criterion.
- **`KVSAVE=0` is mandatory on any PHI path.** colibrì persists conversation KV state to a dot-file
  **inside the model directory** by default, roughly 182 KB per token, so that conversations reopen
  warm. Pointed at a model on the studies share that is PHI-derived state accumulating on shared
  storage. Turn it off, and keep the slot-to-slot KV prefix adoption disabled too.
- **The cross-node problem is unchanged**, and so is the answer: `srun --overlap` stdio relay (§7.2
  of the previous revision), or simply step onto the backend's node. With one long-lived backend
  instead of an elastic pool, stepping on is very nearly good enough, and the relay drops to a
  convenience rather than a requirement.

`COLI_MAX_QUEUE` (default 8) and `COLI_QUEUE_TIMEOUT` (default 300 s) give a bounded FIFO with
OpenAI-shaped 429s and a `x-colibri-queue-wait-ms` header. That is the single-slot queueing
`DESIGN.md` §5.5 asked for, already built.

---

## 7. Citizenship, under a service that cannot cheaply be given back

This is where the pivot costs something real and the plan should not pretend otherwise.

An ollama replica was 18.6 GB and came back in 90 seconds, so yielding it was nearly free. A
colibrì backend holds ~500 GB of RAM and a whole node's cores for 27 minutes of reload. **The yield
ladder still applies but it now has one rung**, and pulling it takes the service down for half an
hour.

What survives, and it is not nothing:

- **We hold one GPU of seven, and never compute306.** The scarcest resource on the cluster is
  untouched. That is a better citizenship position than the previous plan's two-of-six.
- **Hard caps still bind.** One backend. Never a second. Never `c3_accel` without an explicit
  request.
- **Idle release still applies, on a much longer clock.** Nothing has used it in `idle_release_minutes`
  → give the node back. Default **180 minutes**, not 30: releasing a 27-minute asset over a lunch
  break is the thrashing `DESIGN.md` §10 warns about, where a fleet that thrashes is worse than a
  fleet that is simply smaller.
- **The hold-off is unchanged and still the first bug to expect.** Do not re-request until the
  triggering job is no longer pending, floor 15 minutes.
- **The yield predicate is unchanged and the `BeginTime` filter is still the load-bearing part** —
  every pending job on this cluster on 2026-09-09 was `BeginTime`, not `Resources`.

**What must be recorded honestly:** yielding this service costs the user 27 minutes of downtime, so
the supervisor will do it reluctantly and rarely, and the fair-share bill for ~92 CPUs is paid
continuously while it exists. If that is not acceptable, the answer is a shorter walltime and more
frequent release, not a smarter policy.

---

## 8. vLLM — narrowed, and now clearly not in competition

colibrì serves **one generation at a time**. It cannot do corpus work, at any tuning, ever. So the
two engines stop overlapping entirely and the router that was going to arbitrate between them is not
needed:

| | colibrì | vLLM |
|---|---|---|
| workload | one hard question, interactively | ten thousand documents, unattended |
| model | GLM-5.2 744B int4 | MedGemma 27B, 8-bit |
| shape | one long-lived backend, single slot | N single-GPU replicas, continuous batching |
| plane | HTTP on loopback, Anthropic protocol | **filesystem work queue, no socket at all** |
| why | frontier reasoning on PHI | PSYCH-ASR Stage 3c, schema-guided JSON |

vLLM keeps `DESIGN.md` M0/M1 unchanged: user-local conda prefix, single-GPU replicas rather than
tensor-parallel shards (no NVLink, and a replica is yieldable one at a time), driven by a filesystem
work queue on the studies share with atomic-rename claiming. That queue is the strongest PHI control
in the whole design because it removes the socket entirely, and it is preemption-tolerant for free.

**Do not build a router between these two.** They share no caller and no workload.

---

## 9. The model menu inside colibrì

Eight families run on the same engine. Only these are viable here, and the filter is brutal: it must
fit in 1 TB of RAM, and it must support tool calling or it cannot drive a terminal client.

| model | total / active | container | tool calling | verdict |
|---|---|---|---|---|
| **GLM-5.2** | 744B / 40B | **372 GB** | **yes** (OpenAI + Anthropic) | **the default.** The reference model, the best-measured path, the one every number in §3 belongs to |
| **DeepSeek V4 Flash** | 284B / **13B** | 167 GB (REAP-150B: 85 GB) | **yes**, native DSML | **measure it.** One third the active parameters should mean materially less per-token traffic; the only figure in its doc is 1.5–1.6 tok/s on an unnamed host, so this is a hypothesis, not a recommendation |
| **GLM-5.3-Flash** | 321B / 40B | ~195 GB converted | yes | a lighter GLM; same family, needs conversion |
| Inkling | 975B / 41B | 469 GB | **no** — HTTP 400 on tools | unusable for a terminal client |
| Kimi K3 | 2.8T / 104B | **~1.6 TB** | yes | **does not fit in RAM.** At 230 MB/s from NFS it would stream forever. Dead here |
| Qwen3.8-Flash-Next | 125B / 6B | 185 GB | no | unusable for a terminal client |
| Qwen3.6-35B-A3B | 35B / 3B | ~20 GB | — | same class the user just rejected; noted only because the CUDA VRAM tier measured **1.44 → 10.05 tok/s** on it |

**Quality is not free and the number is known.** GLM-5.2's int4 container measures **−8.2 percentage
points** against the unquantized model, concentrated on the hardest questions, and 62.5 % mean
`acc_norm` on a 0-shot multiple-choice harness. Whether a 744B model at int4 beats a well-served
smaller model at 8-bit **for our tasks** is a blind side-by-side nobody has run. It remains owed
(`DESIGN.md` §13) and the pivot makes it more important, not less.

---

## 10. Build and tune

### 10.1 Build

```
module load CUDA/13.1.0        # matches driver CUDA UMD 13.3; the build notes say 13.x
module load GCC/13.3.0         # or the system gcc 13.3.0 already on PATH
make -C c glm CUDA=1 CUDA_ARCH=sm_86 CUDA_HOME=$EBROOTCUDA ARCH=native
```

- **`ARCH=native` is load-bearing, not a micro-optimisation.** The Makefile defaults to
  `x86-64-v3`, which is AVX2. Our CPU has `avx512_vnni`, and colibrì selects a different int4
  kernel family at compile time behind `#if defined(__AVX512VNNI__) && defined(__AVX512BW__)` — the
  67.8 → 89.5 GB/s step in §3.4. Build without it and that measurement does not apply to us.
- `CUDA_ARCH=sm_86` — A40 is compute capability 8.6.
- No micromamba needed. colibrì's `BUILD-cuda-glibc241.md` recipe exists for hosts with no module
  system; we have `CUDA/13.1.0`.
- Build on a compute node, not the login node.

### 10.2 The tuning protocol, which is mandatory and not optional

**`.coli_usage` is a persistent learned routing profile that makes naive A/B benchmarking on this
engine invalid.** colibrì's own report measured a byte-for-byte identical configuration at **5.46
and then 2.56 tok/s** with no parameter changed, because the profile had re-tuned itself onto real
usage between the two runs. A specialised profile is worth **≈ ×2**.

Every measurement, without exception:

```
cp -f "$MODEL/.coli_usage" snapshot        # once, before the campaign
# then before EVERY configuration:
stop the backend; sleep 35                 # VRAM is not released immediately
cp -f snapshot "$MODEL/.coli_usage"        # restore byte-for-byte
start the backend; warm up on a fixed corpus; then measure
```

Two rules from the same report, each of which produced a published wrong claim: **never read
cumulative log counters as current state** (count matching lines before and after the window and
report the difference), and **never sample during a cold start** (loading takes minutes, during
which GPU utilisation is legitimately 0 % and one layer may take 45 seconds — a sample there
describes the loader, not the engine).

### 10.3 The starting configuration

Derived from §3, to be replaced by `coli tune`'s answer:

| setting | value | why |
|---|---|---|
| `CUDA_DENSE` | `1` | ×2.8 on the reference host; the single most profitable flag, and undocumented |
| `RAM_GB` | ~450 | the RAM budget is the lever that measurably paid (+25 %); we have 1 TB |
| `PIN=stats PIN_GB=` | large | pin the hottest experts from the measured profile |
| `XEXP` | `1` — **measure** | +11.6 % on 48 cores, neutral/negative on 24 |
| `DIRECT`, `PIPE` | `1`, `1` | keep |
| `URING`, `PILOT*` | **off** | +26 % once resident; they only burn the scarce CPU |
| `CTX` | `131072` | four times the context for −23 % decode, prefill unchanged |
| `COLI_PREFILL_CHUNK` | `2048` | at 512 the per-slice fixed costs dominate |
| `KVSAVE` | `0` | PHI: no conversation state on shared storage |
| `COLI_API_KEY` | set | closes `README.md` §7.20 |
| `COLI_USAGE_DECAY` | on | without it a turn contributes 0.2 % against 18 M recorded selections and the profile stops tracking the workload |
| `DRAFT` | measure | MTP speculation measured a **32 % loss** around 85 % expert hit; it must earn its keep |

Run `coli plan --model <dir> --policy quality` first — it reports the planned tiers, the reason for
each placement, the expected bottleneck, and a machine-readable `next_actions` list. Then `coli tune`
for the OpenMP and NUMA sweep. Do not hand-tune past what those two produce without a controlled A/B.

---

## 11. Verify before writing code (P0)

| # | test | settles |
|---|---|---|
| 1 | Fill a `c3` node's CPUs, then submit a `c3_short` job needing them. Watch for state `S`. | §4 — whether `c3` preemption is real. **Touches a shared queue: confirm with the user first.** |
| 2 | Build with `ARCH=native CUDA=1`; run colibrì's `AVX512 i4 selftest`. | §10.1 — that the VNNI kernel family compiles in |
| 3 | Stage the 372 GB container; time the download and one cold load. | §1 — the 27-minute figure |
| 4 | **Restart on the same node and time the second load.** | §4 — whether page cache kills most of the cold start |
| 5 | `coli plan`, then `coli tune`, under the §10.2 protocol. | §3 — the real tok/s, and the NUMA and thread answers |
| 6 | A/B `numactl --membind=0` (24c, local) against `COLI_NUMA=1` (48c, interleaved). | §3.6 — ours alone to answer |
| 7 | A/B `XEXP=1`. | §3.4 — +11.6 % or negative |
| 8 | Point Claude Code at `/v1/messages` with `COLI_API_KEY` set; run one tool call end to end. | §6 — the front door |
| 9 | Job A submits B with `afterany`; cancel A; confirm B runs. `--signal=B:TERM@120` reaches a trap. | §5 — the chain |
| 10 | Read `AllocTRES` on the real backend job. | §4 — what 500 GB actually costs in CPUs |

Tests 3–7 are the campaign that decides whether this service is worth running. **Do them before any
supervisor code.** The previous revision could build its control plane first because ollama was
already proven; nothing here is.

---

## 12. Build order

| phase | what lands | exit criterion |
|---|---|---|
| **P0** | the ten tests above | a real tok/s number on our hardware, under the snapshot protocol |
| **P1** | one hand-run colibrì backend, tuned | Claude Code completes a real coding task against it, with a tool call |
| **P2** | the sbatch, the heartbeat, `fleet up` / `status` / `down` | one command brings it up and refuses to claim success before a token is generated |
| **P3** | supervisor, chain, kill switch | survives two walltime rollovers; `fleet down` stops it and nothing restarts |
| **P4** | idle release, caps, the yield ladder's one rung, hold-off | yields on a real `Resources` job and does not take the node back early |
| **P5** | vLLM + the filesystem batch queue (§8) | a corpus pass completes with a worker killed mid-run and no item lost |

**Stop after P1 and you already have the thing the user asked for**, run by hand. P2–P4 are what make
it survive being left alone. P5 is a different project that happens to share a repository.

---

## 13. Decisions that are yours

1. **Partition.** `c3_short` (9 h, safe, 5 % duty lost to reloads) or `c3_accel` (7 d, no preemption,
   but holds the cluster's only four-GPU node for a service that does not need four GPUs)? Plan says
   `c3_short`, and says it reluctantly. Test 4 may make this easy.
2. **Is ~92 CPUs and 500 GB on one of six nodes, continuously, acceptable?** That is the real ask
   (§4). If not, the service does not exist in this form.
3. **GLM-5.2 only, or measure DeepSeek V4 Flash first?** 13B active against 40B is a large potential
   speed difference and the evidence for it is one unattributed number (§9).
4. **Claude Code or opencode as the client?** colibrì speaks the Anthropic API natively, so Claude
   Code works with three environment variables. Plan says Claude Code, opencode retained as fallback.
5. **Is 6–12 tok/s acceptable for the work you have in mind?** If the intended use is an agent loop
   rather than a consultant, the honest answer is that this service will not do it, and no
   configuration in this document changes that.

---

## 14. Carried forward unchanged

From the previous revision, still true and still load-bearing:

- `c3` can `SIGSTOP` a server and the client sees silence, not an error (test 1).
- Memory asks silently buy CPUs: `MaxMemPerCPU=12000`, and the minimum billable unit is two CPUs
  because cores carry two threads (proven by job 2070710: asked `cpu=1`, got `cpu=2`).
- Almost every pending job here is `BeginTime`, not `Resources`; the yield filter is the load-bearing
  part.
- Scrub `SLURM_*` before any nested `sbatch` — inherited variables **override the `#SBATCH`
  directives in the file** (`README.md` §7.19).
- Truncate a log before grepping it for readiness (`README.md` §7.17).
- Never report success from a submission; success is a health check answering (`DESIGN.md` §7.4).
- `config/fleet.json` needs a `!config/fleet.json` line in `.gitignore`, which ignores `*.json`.
- Durable facts graduate into `README.md` when built **and verified**; the corresponding
  `DESIGN.md` entry is deleted. Commits carry no assistant attribution. Never push unasked.
