# FLEET-BUILD.md — the build runbook for a tiered local inference service

**Point a fresh session at this file.** It is the implementation plan for a local inference service
on LIBR compute that several people can ssh into and work against from a VSCode terminal, with
frontier-scale reasoning available when a question needs it.

**Revised 2026-09-09, third pass.** Pass one planned a three-engine fleet with ollama as the daily
driver; pass two replaced it with colibrì alone on one node. **Both were wrong about the shape.**
Pass two also carried two factual errors, corrected in §2. The service is now **three tiers on
different hardware**, because the bottleneck analysis in §3 says no single engine can be both fast
for many people and deep for one.

Read first: [`AI_INSTRUCTIONS.md`](AI_INSTRUCTIONS.md), [`README.md`](README.md),
[`DESIGN.md`](DESIGN.md). Plain-language walkthrough:
[`docs/fleet_walkthrough.pdf`](docs/fleet_walkthrough.pdf).

**No sudo, anywhere.**

---

## 1. The verdict

**What you can have:** several people, each in their own VSCode terminal, talking to a strong local
model at **20–40 tok/s**, with a **744B model reachable as an escalation** when a question deserves
it. That is close enough to the hosted experience that the difference is noticeable but not
disabling.

**What you cannot have:** the 744B model itself at conversational speed for everyone. §3.3 is the
arithmetic and it is not a tuning problem — it is a property of top-8-of-256 expert routing.

The gap to a hosted frontier assistant, stated once and honestly:

| | hosted | **this service, tier 1** | **this service, tier 2** |
|---|---|---|---|
| speed | 50–100 tok/s | **20–40 tok/s** *(projected)* | **8–12 tok/s** *(projected)* |
| concurrent users | many | **many** | **one** |
| model | frontier | ~200–250B MoE at int4 | **744B at int4** |
| reads PHI | never | **yes** | **yes** |

**Tier 1 is the answer to your actual question.** A ~235B-class MoE with 20-ish billion active
parameters, served by vLLM with continuous batching on compute306's four A40s, is within a small
factor of the hosted experience on both axes and serves everyone at once. Tier 2 is where the 744B
lives, and it is a consultant the agent calls, not the thing you type at.

---

## 2. Two corrections to the previous revision

### 2.1 colibrì is **not** single-user. It has continuous batching, and I said otherwise.

`docs/serve_protocol.md` documents two protocols. **`SERVE_BATCH=1` selects `run_serve_mux`:
continuous batching with up to 16 KV slots** (the code accepts up to 512 on one path). *"Prefill is
serial; decode is continuously batched — every active slot contributes one row per forward."* Each
slot holds one conversation's KV and reuses the common prefix across stateless HTTP turns.

I based "one generation at a time" on `docs/api.md` and on a measured 1.32 / 1.51 / 1.46 tok/s at
1 / 2 / 4 concurrent clients. **That measurement was taken on a host where the experts were not
resident** (151 GB RSS, no VRAM column) — extra slots thrashed the expert cache. It does not
transfer to a fully-resident configuration.

It also does not rescue us, but for a completely different reason, and the reason is §3.3.

### 2.2 "Four GPUs are worth under 2 %" was colibrì's number on a CPU-starved host, not ours.

That A/B was run where the CPU-side expert path sustained **19.67 GB/s against ~85 GB/s of
available memory bandwidth** — 23 % of the machine. Placement could not matter, because the CPU
could not consume faster from either tier. On a host that pulls **131.9 GB/s** the comparison is
open again: A40 HBM is ~696 GB/s, so experts served from VRAM arrive **~5× faster** than from RAM.

Corrected: **the four-GPU question is open and is a measurement we owe** (§9 test 6), not a settled
"one card is enough". The arithmetic in §3.4 says four cards could be worth ~1.6× on the expert
phase. It also says that is not where the biggest win is.

---

## 3. Where the time actually goes — the analysis that drives everything

### 3.1 The split, from colibrì's own instrumentation

On a **2-socket Ice Lake 48-core host with GLM-5.2 int4 fully resident** — our CPU class — colibrì
measures **4.68 tok/s** with `XEXP=1`, and reports expert-matmul running at an effective
**131.9 GB/s** (`c/colibri.c:554`).

```
4.68 tok/s                      = 214 ms per token
expert read: 12.1 GB / 131.9 GB/s =  92 ms   (43 %)
everything else                  = 122 ms   (57 %)   attention, dense, router, orchestration
```

The 43/57 split matches the independent profile on the 4×A6000 host (expert-matmul 46.2 %,
attention 26.2 %). **Two halves, roughly equal.** Amdahl therefore caps every single-sided
optimisation at under 2×, and that is the fact pass two missed.

### 3.2 The expert-read half: what raises 131.9 GB/s

| lever | effect on the 92 ms | status |
|---|---|---|
| **VRAM residency** (4× A40 = 184 GB of a 372 GB model, at ~696 GB/s) | 92 → **55 ms** | §2.2 — open, worth measuring |
| **Cluster mode** — N nodes each read their own 1/N slice in parallel | 92 → **~34 ms** at N=6 | §5, real but the code needs work |
| more RAM | nothing. Already fully resident | closed |

### 3.3 Why batching and speculation both fail here — the deep result

Both tricks produce several tokens per forward pass. Both are defeated by the same arithmetic.

GLM-5.2 routes **top-8 of 256** experts per layer. Processing B tokens in one forward reads the
**union** of their experts:

```
E[distinct experts] = 256 × (1 − (1 − 8/256)^B)

B =  1  →   8.0 experts   (1.0× the bytes,  1 token)
B =  5  →  37.6           (4.7× the bytes, ≤5 tokens)
B =  8  →  57.4           (7.2× the bytes,  8 tokens)
B = 16  →  99.5           (12.4× the bytes, 16 tokens)
```

**The union grows almost linearly with the batch.** Expert bytes per token barely fall, so the 43 %
half of the budget does not amortise. Only the 57 % half does.

Working it through at `KV_SLOTS=8`: expert phase 57.4 experts → 86 GB → 652 ms; everything else
~150 ms; total ~800 ms for 8 tokens. That is **10 tok/s aggregate and 1.25 tok/s each** — better
in total than 4.68, far worse for the person waiting.

Speculation is the same shape. MTP with depth 4 verifies ≤5 tokens for 4.7× the expert bytes; at a
70 % acceptance rate it returns roughly **1.35×**. colibrì's own note that MTP *"measured a 32 %
loss around 85 % expert hit"* is this arithmetic biting.

> **Conclusion, and it is the one that reshapes the design:** for a 744B top-8-of-256 model, more
> tokens per pass buys aggregate throughput at the cost of per-user latency. **You cannot batch
> your way to a fast frontier model here.** Multi-user speed has to come from a *different model*,
> not a different setting.

There is one exception worth keeping: **`KV_SLOTS=1` and MTP speculation are mutually exclusive in
the engine** — *"MTP/n-gram speculation is not ragged-safe across KV slots, so multi-slot serve
keeps one scheduler owning every forward (`g_draft=0`)"*. Since we are not batching tier 2 anyway,
run it at `KV_SLOTS=1` and take the speculation. Grammar-forced drafts stay safe at any slot count.

### 3.4 The other half: what raises the 122 ms

`CUDA_DENSE=1` moves the dense and attention tensors to the GPU. Measured **×2.8** end-to-end on a
host whose CPU was the bottleneck (1.53 → 4.26 tok/s), and it is **not mentioned in colibrì's public
README**. Those tensors cost ~12 GB plus ~11 GB of KV at 32k — 23 GB, one A40.

Our CPU is far stronger than that host's, so expect less. Halving 122 ms is a reasonable planning
assumption and is itself a measurement (§9 test 5).

### 3.5 Putting it together for tier 2

| configuration | expert | other | total | tok/s |
|---|---|---|---|---|
| measured, CPU only, fully resident, `XEXP=1` | 92 | 122 | 214 ms | **4.68** (measured) |
| + `CUDA_DENSE=1`, one A40 | 92 | ~61 | 153 ms | ~6.5 |
| + four A40s (VRAM expert tier) | ~55 | ~61 | 116 ms | ~8.6 |
| + MTP speculation at `KV_SLOTS=1` | — | — | — | **~10–12** |
| + cluster mode across 6 nodes *(instead of 4 GPUs)* | ~34 | ~61 | 95 ms | ~10.5 |

**Projected, from measured components.** The first row is the only measurement; every row below it
is a modelled multiplier and the campaign in §9 replaces them.

---

## 4. The architecture: three tiers on different hardware

```
                    ssh + VSCode terminal, any node
                                  |
                        Claude Code / opencode
                                  |
        +-------------------------+--------------------------+
        |                                                    |
   TIER 1  the daily driver                          TIER 2  the consultant
   vLLM, compute306, 4x A40 TP=4                     colibri, one c3 node
   ~200-250B MoE at int4 (~120 GB)                   GLM-5.2 744B int4, 372 GB
   continuous batching, MANY USERS                   KV_SLOTS=1 + MTP speculation
   20-40 tok/s each          (projected)             8-12 tok/s, ONE at a time
        |                                                    ^
        |  the agent loop runs here                          |
        +------------- "ask the big model" tool -------------+

   TIER 3  batch corpus work -- vLLM replicas on the remaining c3 nodes,
           filesystem work queue, no socket at all.  PSYCH-ASR Stage 3c.
```

### 4.1 Why this is the right shape

- **Tier 1 does what colibrì structurally cannot: serve many people fast.** A ~20B-active MoE has a
  far smaller expert union per token and vLLM's continuous batching is built for exactly this. It
  is also a *much* better model than the `qwen3-coder:30b` q4 GGUF that was judged inadequate —
  roughly eight times the parameters, at int4 rather than q4, with vLLM's full-context sampling
  rather than ollama's defaults. Judge the tier, not the memory of the old one.
- **Tier 2 is reached the way a person reaches an expert: deliberately, for one hard question.** An
  agent loop makes dozens of cheap calls and a few expensive ones. Routing every call to a 10 tok/s
  model wastes the model and the person.
- **compute306 finally has a defensible use.** 184 GB of VRAM is the only place on this cluster a
  ~120 GB model fits, and a multi-user service is worth the cluster's only four-GPU node in a way a
  single-user one never was. This **reverses** pass two's recommendation, and the reason is that the
  node is now serving everybody.
- **No router between tier 1 and tier 3.** They share no caller. Tier 2 is reached by an explicit
  tool call, not by a quality heuristic — automatic cascade is research-grade and unreliable
  (`DESIGN.md` §5.5).

### 4.2 Tier 1 model selection — a real task, not a footnote

Requirement: fits in **184 GB minus KV cache**, so a ~110–130 GB checkpoint; MoE with ≲30B active
for speed; **tool calling**; strong at code and reasoning. That points at a 200–250B-parameter MoE
quantized to int4 (AWQ or GPTQ/Marlin — **no FP8, Ampere has no FP8 tensor cores**).

Do not take a model name from this document. **Selecting it is task one of P1**: enumerate what is
actually available at that size with a working AWQ/GPTQ int4 checkpoint and tool-calling support,
then measure two candidates on real tasks from our own repos before committing 120 GB of download.

**Tensor parallelism across four cards has a cost here**: NVLink reports all links inactive, so
TP=4 pays an all-reduce over PCIe on every layer. For a 20B-active MoE that all-reduce is on hidden
states and is small, but it is measured, not assumed (§9 test 8). The alternative — two TP=2
replicas — is worth the A/B.

---

## 5. Cluster mode: real, and not yet ready

colibrì can shard experts across machines. The coordinator keeps token generation, routing and KV
state local; **expert workers on other nodes execute the routed FFNs**; only activations cross the
wire.

**The fabric supports it.** `mlx5_1` / `eth5` is a **40 Gb/s Mellanox link, ACTIVE**, in Ethernet
mode. At S=1 decode the traffic is ~20 KB per expert each way, ~24 MB per token across 75 layers —
about 5 ms at 40 Gb/s.

**How it works** (`c/colibri.c:3146`): expert `e` in layer `l` is owned by worker `(e + l) % N`, a
static hash. Each worker holds 1/N of the model and its reads land in that node's page cache — six
nodes with 1 TB each, caching 62 GB apiece, is comfortable.

**Three reasons it is not the P1 answer:**

1. **The worker loop is synchronous.** The coordinator sends to worker 0, *blocks* for its reply,
   then worker 1. That is `75 layers × N` sequential round trips per token. Parallelising it is an
   upstream patch, and without it the gain is largely eaten.
2. **A worker failure calls `exit(1)`.** One yielded node kills the whole service. Unacceptable for
   a fleet whose entire premise is yielding.
3. **Activations cross the network in plaintext.** Hidden states derived from a PHI prompt on a
   shared cluster fabric is a new exposure, not a config detail. It needs an explicit decision
   (§11) and probably a cluster-network-only bind with `COLI_API_KEY`.

**Verdict: P5, behind a measurement and an upstream patch.** Its ceiling (§3.5) is about the same as
four GPUs on one node, for far more risk. Revisit if the four-GPU measurement disappoints.

---

## 6. The front door

colibrì serves the **Anthropic Messages API at `/v1/messages`** alongside OpenAI
`/v1/chat/completions`, with GLM-5.2 supporting tools in both shapes. **Claude Code points at it
with three environment variables** — `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL` —
no shim. vLLM serves OpenAI-compatible HTTP, which Claude Code does not speak natively, so tier 1
needs either opencode or a thin Anthropic-shaped adapter in front of vLLM. **Deciding that is §11
decision 4** and it materially affects the daily experience.

**Multi-user changes the network question.** A loopback bind means one user per node, which defeats
the point. Tier 1 must be reachable from other nodes, so it binds the cluster interface **with an
API key**, and that is a deliberate, recorded weakening of the current control — `DESIGN.md` §5.4
option C, which it says needs an explicit decision rather than a config edit.

The mitigation is the two-plane split `DESIGN.md` §5.4 recommends and it should be built in from the
start: **tier 3 (PHI corpus work) stays on the filesystem queue with no socket at all**, and tier 1
is the conversational plane. One router serving both is how they get confused.

`COLI_API_KEY` and `KVSAVE=0` are mandatory on tier 2. colibrì persists conversation KV to a
dot-file **inside the model directory** by default — roughly 182 KB per token of PHI-derived state
on a shared filesystem.

---

## 7. Citizenship, revised for a service that is now genuinely large

The standing claim is now **compute306 entire, plus one c3 node**. That is a much bigger ask than
either previous revision and it has to be argued rather than assumed.

- **compute306 is used, not camped on.** A multi-user service on the only node that can hold the
  model is the intended use of that hardware. Hold it with a real walltime, publish the status, and
  release it when idle.
- **Tier 2 costs 27 minutes to restart** (372 GB at a measured 230 MB/s), so it yields reluctantly
  and its idle timeout is **180 minutes**, not 30. A 27-minute asset released over a lunch break is
  the thrashing `DESIGN.md` §10 warns about.
- **Tier 1 costs minutes, so it is the rung that gets pulled.** The yield ladder finally has more
  than one rung again: idle tier-3 replica, then tier 1, then tier 2 last.
- The yield predicate is unchanged and the **`BeginTime` filter is still the load-bearing part** —
  every pending job on this cluster on 2026-09-09 was `BeginTime`, not `Resources`.
- **Fair-share.** Tier 1 bills ~92 CPUs and 4 GPUs; tier 2 bills ~92 CPUs and 1 GPU. This is no
  longer a rounding error against our own pipeline jobs and must be measured before and during
  (`DESIGN.md` §13).

---

## 8. Supervisor, chain, kill switch — unchanged

A 2-CPU job on `c3_short` that derives everything from `squeue`, keeps no inventory state, submits
its successor at birth with `--dependency=afterany:$SLURM_JOB_ID`, checks `${FLEET_STATE}/STOP`
first, takes one action per 30 s cycle with the reason logged, and is backstopped by a daily
systemd `--user` timer with `Persistent=true`. `fleet down` writes `STOP`, then cancels.

Two tier-2 adjustments: **readiness is a generated token, not a listening socket** (27-minute load;
a timeout written for ollama fires at 3 % — `DESIGN.md` §14.3 anticipated this), timeout 45 minutes.
And **heartbeats go in a file on NFS home**, read by content and never by mtime, so health checking
costs the scheduler nothing.

---

## 9. The measurement campaign (P0) — this is the phase that decides the design

| # | test | settles |
|---|---|---|
| 1 | Build colibrì `ARCH=native CUDA=1 CUDA_ARCH=sm_86`, run the `AVX512 i4 selftest` | the VNNI kernel family is compiled in |
| 2 | Stage GLM-5.2 (372 GB); time the download and one cold load | the 27-minute figure |
| 3 | Restart on the **same node**; time the second load | whether 1 TB of page cache kills the cold start |
| 4 | `coli plan`, then `coli tune`, under the snapshot protocol (§10) | the real tok/s, plus the OpenMP and NUMA answers |
| 5 | A/B `CUDA_DENSE=1` on one A40 | §3.4 — how much of the 122 ms the GPU takes |
| 6 | **A/B one A40 against four** | §2.2 — the question pass two closed prematurely |
| 7 | A/B `XEXP=1`, `numactl --membind=0` vs `COLI_NUMA=1`, MTP `DRAFT` depth | §3 — the remaining tier-2 levers |
| 8 | vLLM tier 1: TP=4 against 2× TP=2, same model, aggregate tokens | §4.2 — the PCIe all-reduce tax |
| 9 | Tier 1 under 6 simulated concurrent users | the number this whole project is for |
| 10 | `c3` preemption: fill a node, submit a `c3_short` job, watch for state `S` | §12 — **touches a shared queue, confirm first** |
| 11 | Chain: job A submits B with `afterany`; cancel A; confirm B runs | the restart mechanism |

**Tests 4–9 are the campaign that decides whether this service is worth running.** Do them before
any supervisor code.

---

## 10. colibrì build and the mandatory tuning protocol

```
module load CUDA/13.1.0 GCC/13.3.0
make -C c glm CUDA=1 CUDA_ARCH=sm_86 CUDA_HOME=$EBROOTCUDA ARCH=native
```

**`ARCH=native` is load-bearing.** The Makefile defaults to `x86-64-v3`, which is AVX2. Our CPU has
`avx512_vnni`, and colibrì selects a different int4 kernel behind
`#if defined(__AVX512VNNI__) && defined(__AVX512BW__)` — the 67.8 → 89.5 GB/s step. Build without it
and none of §3's numbers apply.

**`.coli_usage` invalidates naive A/B benchmarking.** It is a persistent learned routing profile
that survives restarts. A byte-for-byte identical configuration measured **5.46 and then 2.56 tok/s**
with nothing changed; a specialised profile is worth **≈ ×2**. Before *every* configuration:
snapshot the file, stop the engine, sleep 35 s (VRAM is not released immediately), restore the file
byte-for-byte, restart, warm up on a fixed corpus, then measure. Never read cumulative log counters
as current state. Never sample during a cold start.

Starting configuration, to be replaced by `coli tune`: `CUDA_DENSE=1`, `RAM_GB≈450`, `PIN=stats`
with a large `PIN_GB`, `XEXP=1` (measure), `DIRECT=1 PIPE=1`, **`URING` and `PILOT*` off** (+26 %
once resident — they only burn the scarce CPU), `CTX=131072`, `COLI_PREFILL_CHUNK=2048`,
`KVSAVE=0`, `COLI_API_KEY` set, `COLI_USAGE_DECAY` on, `KV_SLOTS=1` with `DRAFT` measured.

---

## 11. Decisions that are yours

1. **Does tier 1 bind the cluster network?** It must, to serve more than one node. That is an
   explicit weakening of the loopback control (§6). Tier 3 stays socket-free regardless.
2. **Is compute306 entire, plus one c3 node, an acceptable standing claim?** That is the real
   footprint. If not, tier 1 shrinks to a single-GPU model and the quality target moves with it.
3. **Which tier-1 model?** §4.2 makes this task one of P1 rather than a guess in a document.
4. **Claude Code everywhere, or opencode for tier 1?** colibrì speaks Anthropic natively; vLLM does
   not. Either write a thin adapter or accept two clients.
5. **If tier 1 measures well, is tier 2 still worth 372 GB and a node?** Ask it again after test 9.
   A good 235B at int4 may make the 744B a luxury — and GLM-5.2's int4 container carries a measured
   **−8.2 percentage point** quantization cost, so the quality gap is smaller than the parameter
   counts suggest. **A blind side-by-side on real tasks from our own repos is owed** before tier 2
   is built.

---

## 12. Carried forward unchanged

- `c3` can `SIGSTOP` a server and the client sees silence, not an error: `c3_short` is
  `PriorityTier=20`, `c3` is 10 with `PreemptMode=SUSPEND`, same six nodes. **Inferred from
  configuration, not observed** — test 10.
- Memory asks silently buy CPUs (`MaxMemPerCPU=12000`), and the minimum billable unit is two CPUs
  because cores carry two threads (job 2070710: asked `cpu=1`, got `cpu=2`).
- Scrub `SLURM_*` before any nested `sbatch` — inherited variables override the `#SBATCH` directives
  (`README.md` §7.19). Truncate a log before grepping it for readiness (§7.17). Never report success
  from a submission (`DESIGN.md` §7.4).
- Ampere has **no FP8 tensor cores**. AWQ, GPTQ/Marlin int4, int8 and bf16 only.
- `config/fleet.json` needs a `!config/fleet.json` line in `.gitignore`.
- Durable facts graduate into `README.md` when built **and verified**; the `DESIGN.md` entry is then
  deleted. Commits carry no assistant attribution. Never push unasked.
