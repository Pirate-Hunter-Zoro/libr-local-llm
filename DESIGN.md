# The fleet — design for a good-citizen, multi-engine local inference service

**Status: design only. Nothing in this document is built.** It is the plan for the next phase of
this repo, written before the code so the arguments survive the implementation. `README.md`
documents what *exists*; this file documents what is *intended*, and the two must not be confused.
When a piece of the fleet is built and verified, its durable facts graduate into `README.md` and
its planning entry is deleted from `Research-Journey/planning/LOCAL-LLM_TODO.txt`.

Every projected number below is labelled as a projection. Measurements are labelled as
measurements and cite where they came from. Do not let the two blur together — that is exactly the
error the colibrì project documents at length in its own experiment logs.

(Added 2026-08-22.)

---

## 1. What we are trying to build, and the one thing that makes it hard

An inference service on LIBR compute that is fast enough to work against interactively, big enough
to be worth having, robust enough to survive its own components dying, and **polite enough that
nobody else on the cluster has a reason to complain about it**. One front door, several engines
behind it, resources acquired when free and given back when someone else needs them.

The hardware is already bought and already powered. The marginal cost of running a model on it is
not money — it is **other people's queue time**. That reframing is the whole design:

> The fleet's real cost is measured in jobs other researchers could not start. Citizenship is
> therefore the core feature, not a courtesy bolted on at the end. A fleet that must be manually
> torn down when a colleague complains has already failed.

There is a second, quieter cost that is easy to miss and lands entirely on us: **fair-share**.
Slurm's scheduler weighs recent usage. A fleet that squats on nodes for days drives down our own
priority, which means the TRD-EHR and PSYCH-ASR pipeline jobs — the actual research — schedule
*worse*. The fleet competes with its own reason for existing. Hard caps and idle release are not
altruism; they are self-defence.

### Goals

1. **One stable front door.** A client points at one place, names a model, and gets an answer. It
   does not know or care which node, engine, or Slurm job served it, or how many times the backend
   was replaced mid-session.
2. **Right engine per workload.** Interactive coding, high-throughput batch corpus passes, and
   frontier-scale single questions are three different jobs with three different best answers.
3. **Elastic and self-healing.** Converges toward a target capacity when the cluster is free;
   shrinks without human intervention when it is not; regrows when it can.
4. **Yields on evidence, not on complaint.** Detects that another user's job is blocked by what the
   fleet holds, and gives back the specific resource that unblocks it.
5. **No admin rights anywhere.** Same constraint as everything else in this repo. It has not
   stopped us yet.
6. **The PHI boundary gets stronger, not weaker.** More moving parts must not mean more places for
   a transcript to escape.

### Non-goals

- **Not a multi-tenant production service.** One or two humans, plus batch jobs. Sizing, auth, and
  audit for lab-wide use is a separate decision with a separate security conversation.
- **Not PHI-approved by its own existence.** Running locally is a technical control. Whether
  identifiable data may go to a given model is an IRB and data-use question, and lives outside this
  repo.
- **No admin-only mechanisms.** No Slurm preemption or QoS configuration, no cgroup manipulation,
  no systemd units, no node-level daemons. Where a design wants one of those, it needs a
  user-space substitute or it does not go in.
- **Not a replacement for the hosted assistant.** See §11. The honest end state is two tools with a
  clean split, which is the same conclusion this repo reached in a smaller form already.

---

## 2. Three engines, three jobs

| engine | best at | worst at | status |
|---|---|---|---|
| **ollama** | one user, instant model switching, auto load/evict, zero ceremony | throughput, batch work, models over ~46 GB per card | live (`README.md` §4) |
| **vLLM** | many concurrent requests, batch corpora, schema-guided decoding, prefix caching | anything that does not fit in VRAM; CPU offload exists and is bad | not installed |
| **colibrì** | models that do not fit in VRAM at all — a 744B MoE on this hardware | concurrency; it serves exactly one generation at a time | not installed |

The three are complementary and not interchangeable, and the fleet's value is precisely that a
caller does not have to know which is which. Nothing here blends models together — there is no
arrangement of three engines that is smarter than the best model among them. What the fleet buys is
**coverage, throughput, and uptime**, not intelligence we did not already have.

### On colibrì specifically

The engine treats VRAM, RAM, and storage as one placement hierarchy and streams MoE experts on
demand, which is what lets a 744B-parameter model run on hardware that cannot hold it. Two
properties of it drive fleet design more than its speed does:

- **It serves one generation at a time.** Its own gateway uses a bounded FIFO admission queue
  rather than pretending to run parallel sequences. Measured on the reference 4×A6000 host:
  1.32 / 1.51 / 1.46 tok/s *aggregate* at 1 / 2 / 4 concurrent clients — concurrency does not scale
  throughput, it divides it. The fleet must therefore treat a colibrì backend as a **single-slot
  resource**, queue for it explicitly, and never load-balance onto it.
- **Its cold start is enormous here.** The GLM-5.2 int4 container is ~429 GB. Our studies share
  measured ~230 MB/s during the `gpt-oss:120b` load (`README.md` §4), which projects to **~31
  minutes** before the first token. That is a projection, not a measurement. Either way it cannot be
  started on demand inside a request, which makes colibrì a *booked* resource rather than an
  autoscaled one, and makes it the most expensive thing in the fleet to yield.

Quality is the other half of the honesty. The int4 container is not free: the colibrì project's own
measurements put the pure quantization cost at **−8.2 percentage points**, concentrated on the
hardest questions, and its 0-shot multiple-choice harness scored the container at 62.5% mean
`acc_norm`. A 744B model at int4 is not automatically better than a well-served 27–120B model at
8-bit for careful work. **Deciding which is better for our tasks is a measurement we owe ourselves
before the big model gets promoted past "interesting".**

---

## 3. The cluster as a resource model

Facts the design is built on. Everything here was read off the live cluster on 2026-08-22 except
where noted; the partition facts restate `README.md` §1 and are repeated only because the placement
argument below is unreadable without them.

| | |
|---|---|
| `c3` / `c3_short` | six nodes, compute300–305, **1× A40 46 GB each** |
| `c3_accel` | **compute306 only**, 4× A40, the cluster's only multi-GPU node |
| every node | 2 sockets × 24 cores, **96 threads**, ~1 TB RAM, 2 NUMA nodes |
| CPU | Intel Xeon Gold 6342 @ 2.80 GHz — **AVX-512 with VNNI** |
| GPU | A40, compute capability **8.6**, driver 610.43.02 |
| GPU interconnect | **NVLink reports all links inactive** — cross-GPU traffic goes over PCIe |
| node-local scratch | **none**. `TmpDisk=0`, and `/` is a RAM-backed tmpfs that dies with the node |
| model store | studies share, ~16 TB free, **~230 MB/s measured** during a real model load |
| time limits | `c3_short` 9 h, `c3` 7 d, `c3_accel` 7 d |
| GPU isolation | **none** — a node's cards are visible whether or not you reserved them |

Five consequences that the placement decisions in §4 fall out of:

1. **The CPU is unusually good for expert-streaming inference.** AVX-512 with VNNI and 48 physical
   cores is the best case for colibrì's CPU-side expert kernels; the reference 4×A6000 host that
   produced its most careful experiment log had 24 AVX2-only Zen 2 cores and no VNNI.
2. **1 TB of RAM removes disk from the decode path entirely.** GLM-5.2's routed experts are ~407 GB.
   They fit resident in RAM with room to spare, and full residency is the configuration behind every
   good number in colibrì's experiment set.
3. **No NVLink means tensor parallelism pays an all-reduce tax on every layer.** Prefer independent
   replicas over sharding wherever a model fits on one card.
4. **No node-local scratch means every cold load is an NFS read.** Load time is a function of the
   studies share, not of the GPU. This is the single largest operational cost in the fleet and it
   sets the price of every yield decision.
5. **Six single-GPU nodes are a more flexible asset than one four-GPU node** — six units of
   independently yieldable capacity versus one all-or-nothing unit.

---

## 4. Placement decisions

### 4.1 colibrì goes on a *single*-GPU node

Counter-intuitive, and the most consequential decision in this document. The reasoning is drawn
from colibrì's own controlled measurements on 4×A6000 (its `docs/experiments/glm52-4xa6000-2026-08-02.md`):

- Under a controlled profile-restore protocol, a VRAM-heavy placement (188 GB) and a balanced one
  (176 GB) measured **indistinguishably** — 2.81 vs 2.78 tok/s. Moving 12 GB between tiers changed
  nothing.
- The lever that actually paid was the **RAM budget**: raising it from 205 GB to 235 GB bought 25%.
- The single most profitable flag, worth ×2.8, moves the **dense and attention** tensors to the GPU.
  Those cost ~12 GB, plus ~11 GB of KV cache at 32k context. **23 GB — it fits on one A40.**

So the part of colibrì that genuinely wants a GPU fits on one card, and the part that wants
capacity wants *RAM*, which every node has a terabyte of. What a single card costs us is expert
residency in VRAM: roughly 4% instead of the ~45% four cards would give, raising the per-token
CPU-side read from about 7.4 GB to about 11.5 GB. **Projected cost: 35–40% of throughput.**
Projected absolute rates: high single digits on one card, low teens on four. Both are projections
from another machine's measurements and must be replaced with our own numbers before anything is
built on top of them (§12).

Trading 40% of the throughput of the slowest engine to free the cluster's only four-GPU node is a
trade worth making, and `c3`'s 7-day limit applies to all six single-GPU nodes. It also removes the
fleet's worst contention problem before it exists.

### 4.2 vLLM runs as replicas, not shards

For any model that fits on one card, run N independent single-GPU replicas behind a round-robin
rather than one tensor-parallel server. Strictly more aggregate throughput on a PCIe-only host, no
interconnect tax, and — the property that matters for citizenship — **a replica is a unit we can
give back one at a time**. A four-GPU tensor-parallel job can only be surrendered whole.

Tensor parallelism is reserved for models that genuinely do not fit on one card. MedGemma 27B at
bf16 is ~54 GB and does not; at 8-bit it does, so even that one wants replicas. This supersedes the
"two A40s with tensor parallelism" assumption carried in `README.md` §8 and in
`planning/LOCAL-LLM_TODO.txt` item 3 — not because sharding does not work (it is verified working,
`README.md` §4) but because replicas are both faster and more yieldable here.

### 4.3 `c3_accel` is booked, never held

The four-GPU node is requested only for work that genuinely needs 184 GB of VRAM in one address
space — a large MoE at int4, or a batch sweep that wants all four cards under one scheduler. It is
never the default, never held idle, and never the home of a long-lived interactive server. This
tightens the existing rule in `planning/LOCAL-LLM_TODO.txt` rather than changing it.

### 4.4 Ampere constrains the quantization menu

Compute capability 8.6 has no FP8 tensor cores. FP8 weight and KV-cache formats are out; AWQ,
GPTQ/Marlin int4, int8, and bf16 are in. FlashAttention-2 is fine. Anything gated on Hopper or
Blackwell kernels either refuses or silently falls back to something slow — and "silently" is the
operative word, so a new model's first run needs its resident-set and fallback diagnostics read,
not just its output eyeballed.

---

## 5. Architecture

Two planes, deliberately separate, because they have irreconcilable requirements. One control loop
above them.

### 5.1 The control plane — the supervisor

A single user-space process (a Slurm job of its own, or a foreground process in a terminal — it must
not require a login-node daemon) that runs a convergence loop:

1. Ask Slurm what the fleet currently has. **Never** read a state file. `README.md` §4a already
   establishes why: a state file goes stale the moment a job ends or a second one is submitted, and
   `squeue` never does. The fleet extends that principle rather than reinventing it.
2. Compare against the desired capacity — a small declarative description of how many replicas of
   what, and which single-slot resources should exist.
3. Compare against the citizenship rules (§6) and the caps.
4. Take **one** action toward convergence, then loop.

Properties this loop must have:

- **Idempotent and stateless.** It derives everything from Slurm and from backend health checks each
  cycle. It never assumes its last action succeeded.
- **Survivable.** If the supervisor dies, every backend keeps serving; restarting it reconciles.
  Killing the supervisor must never be the thing that takes the service down.
- **One action per cycle.** Batch changes are how a control loop oscillates and how it converts one
  transient error into a stampede.
- **Loud about what it did.** Every acquire, drain, yield, and hold-off decision is logged with its
  reason. When somebody asks why the fleet took a node at 3 a.m., the answer has to exist.

### 5.2 The interactive plane — loopback, one node, proven

What exists today, generalized: backends bind loopback on their job's node; clients reach them by
stepping into the allocation with `srun --overlap`. This is the PHI-safe path and the pattern is
already verified from a second compute node (`README.md` §4b). It stays exactly as it is.

Its limitation is structural and must be stated rather than designed around: **loopback binding
means the client has to be on the same node as the backend.** That does not compose into a
multi-node fleet by itself. §5.4 is about that, and it is the open architectural question in this
document.

### 5.3 The batch plane — a filesystem work queue, no network at all

For corpus work (the PSYCH-ASR Stage 3c passes, TRD-EHR similarity judging, any "score ten thousand
documents" job) the fleet does not need a network service. It needs a queue.

Requests are files in a directory on the studies share. Workers on N nodes claim an item by atomic
rename — the standard trick, and the only primitive needed for exactly-once claiming on a shared
filesystem — process it against a local vLLM replica bound to their own loopback, and write results
to an output directory. Completion is a file existing.

This is unglamorous and it is the strongest part of the design:

- **No network exposure whatsoever.** Nothing to authenticate, nothing to firewall, nothing to
  accidentally rebind to a routable address. The PHI boundary is enforced by there being no socket.
- **Preemption-tolerant for free.** A worker killed mid-item leaves an unclaimed or stale-claimed
  item; the next worker picks it up. Yielding a node during a batch pass costs one item's work, not
  the pass.
- **Progress is inspectable with `ls`.** No dashboard to build, and restart is not a special case.
- **Latency is irrelevant** for the workload it serves. Do not use it for interactive traffic.

Two things it needs to get right: a claim must carry a heartbeat or a timestamp so a dead worker's
item is eventually reclaimed rather than lost forever, and NFS metadata semantics have to be tested
rather than assumed. Atomic rename on this share is a **claim to verify**, not a fact yet (§12).

### 5.4 The open question: one endpoint across many nodes

Interactive multi-node serving needs the client and the backend to talk across nodes, and loopback
forbids it. Four options, none free:

| option | how | cost |
|---|---|---|
| **A. Stay single-node** | router and client both step onto the backend's node with `srun --overlap` | works today, zero new risk; caps interactive capacity at one node's worth |
| **B. Port-forward tunnels** | forward a backend port to the client's node | `README.md` §7.16 — SSH between compute nodes is not reliable here; `srun --overlap` does not forward ports. Fragile |
| **C. Bind to the node address with a bearer token** | backends listen on the cluster-internal interface; every request is authenticated | the honest "real service" path, and a **deliberate weakening of the current PHI control**. Needs an explicit decision, not a config edit |
| **D. Filesystem queue for interactive too** | §5.3 with a latency budget | round-trip through NFS per turn. Almost certainly too slow to type against |

**Recommendation: A for anything touching PHI, C only for a non-PHI plane and only as an explicit,
recorded decision.** The safest shape is *two fleets*: a single-user, single-node, loopback,
authenticated, KV-persistence-disabled stack for PHI, and a separately configured non-PHI plane that
may be more convenient because the consequences of a mistake there are smaller. One router serving
both is how the two get confused, and confusing them is the failure mode that matters.

This is the decision to make before writing the router, and it is not made yet.

### 5.5 The front door

Whatever plane it fronts, the router's contract:

- **Model id selects the backend.** One namespace across all three engines, so a caller says a name
  and never a host or a port.
- **Health-checked and re-discovered every cycle.** Every backend is ephemeral; a router that caches
  endpoints is a router that serves stale ones.
- **Queue-aware fall-through.** A backend returning a queue-full error is not an error to propagate
  if another replica of the same model is idle.
- **Single-slot resources are queued, not balanced.** colibrì gets a real queue with a visible
  position, not a round-robin slot.
- **No quality-based routing.** Automatic cascade — cheap model answers, a confidence score
  escalates to the expensive one — is research-grade and unreliable. Escalation is explicit: a human
  or an agent names the big model. Do not build the clever version.

Protocol surface: vLLM and ollama speak OpenAI-compatible HTTP; colibrì speaks that **and** the
Anthropic Messages API. That second one is the only reason a Claude-Code-shaped client can be
pointed at local weights without a translating proxy, and it is worth preserving as a first-class
property of the fleet rather than an accident.

---

## 6. Citizenship — how the fleet gives resources back

The heart of the thing. Without admin rights there is no preemption to configure and no QoS to sit
under, so **every yield is voluntary**. That is a weaker position than it sounds, because voluntary
yielding based on real evidence is both possible and rare enough to be a genuine contribution.

### 6.1 What Slurm gives you without privileges

- The pending queue, including each pending job's owner, its resource ask, and its **reason** —
  whether it is waiting on `Resources`, on `Priority`, or on something else entirely.
- Node state and what is allocated where.
- Your own jobs' allocated resources, which is what tells you whether releasing one of *yours* could
  plausibly satisfy one of *theirs*.

That is enough for the core rule:

> **Yield when a pending job belonging to someone else is waiting on resources the fleet is
> holding, and releasing a specific unit would plausibly let it start.**

"Plausibly" is doing real work in that sentence. We cannot see the scheduler's ordering, we cannot
know whether the blocker is actually elsewhere, and we will sometimes yield for nothing. Yielding
for nothing occasionally is the correct trade against being the group that has to be emailed.

### 6.2 The yield ladder

When the fleet must shrink, it gives up in a fixed, documented order. The ordering principle:
**surrender the unit with the highest ratio of resources held to cost of restoring it.**

| rank | unit | resources held | restore cost | notes |
|---|---|---|---|---|
| 1 | an idle vLLM replica | 1 GPU | minutes (a bf16 27B is ~54 GB off the share) | first to go, always |
| 2 | an idle ollama server | 1 GPU | measured 4m46s for a 65 GB model | cheap and trivially restarted |
| 3 | a `c3_accel` booking | 4 GPUs | depends on model | should rarely exist; if it does, it is the biggest single win to release |
| 4 | a busy vLLM replica | 1 GPU | minutes, plus the in-flight work | drain first (§6.4) |
| 5 | the colibrì backend | 1 GPU + ~500 GB RAM | projected ~31 minutes | last resort; holds the least GPU and costs the most to restore |

Note what the ladder does to colibrì: because it needs only one card and takes half an hour to come
back, it is simultaneously the *cheapest* thing to keep and the *most expensive* thing to lose. Its
protection is a consequence of the ordering rule, not a special case in it.

### 6.3 Granularity is a design feature

Many small jobs beat one big job for every reason that matters here:

- **Yieldable one at a time.** A four-GPU job is an all-or-nothing surrender.
- **Schedules sooner.** `README.md` §4 records the lesson already paid for: an 8-CPU ask left a
  single-GPU job **queued behind two nodes whose A40 was idle but which had only 4 free CPUs**.
  Small asks fit in gaps. Right-size CPU and memory to what a job measurably uses.
- **Backfill-friendly.** Short walltimes slot into the scheduler's gaps instead of waiting for a
  large window. A server that lives under 9 hours on `c3_short` schedules sooner than one asking for
  seven days, and the supervisor's regrowth loop makes the shorter life invisible to callers.
- **Failure is partial.** One replica dying degrades throughput; it does not end the service.

### 6.4 Drain, then cancel

Yielding is two steps and never one. The router stops sending new work to the doomed backend and
marks it draining; in-flight requests finish; then the job is cancelled. A yield that kills a
generation mid-stream is a bug that will be reported as "the local model is unreliable", and it will
be right.

Corollary: the supervisor and the router must share a view of which backends exist and what state
they are in. That shared view is derived from Slurm and from health checks — not from a file either
of them writes.

### 6.5 The hold-off, and the trap it exists for

After yielding, the fleet must **refuse to re-request that resource for a cooldown period.**

Without this, the obvious failure is not just possible, it is likely: the supervisor releases a
node, its own convergence loop notices it is now below target capacity, and re-submits — winning the
race against the pending job it was trying to help, because a re-submission from an already-warm
context can hit the scheduler before the next backfill cycle. The fleet then looks maximally
antisocial while running code written to be polite.

The cooldown must outlast at least one full scheduling cycle, and the cleaner rule is: **do not
re-request until the pending job that triggered the yield is no longer pending.** Same principle
applies to a yield that turned out not to help: give up the resource, wait, and let the scheduler
decide, rather than immediately reclaiming and calling it a fair race.

### 6.6 Hard caps and idle release

Standing limits, enforced by the supervisor, that do not depend on anybody noticing a problem:

- **Never hold more than a stated fraction of a partition.** Six single-GPU nodes exist; the fleet
  does not get all six, ever, regardless of how idle the cluster looks.
- **Release on idle.** If nothing has used a replica in N minutes, give the node back. This is the
  same instinct as the 20-minute keep-alive already configured for ollama, moved up a level: there
  it releases VRAM, here it releases a *node*.
- **A `c3_accel` booking has a shorter idle timeout than anything else**, because it is the scarcest
  thing on the cluster.
- **Fair-share budget.** A stated ceiling on how much of our own scheduling priority the fleet is
  allowed to consume, so it cannot starve the pipeline jobs it exists to serve. Mechanism: caps plus
  short walltimes plus idle release; there is no admin knob for this, only restraint.

### 6.7 What the fleet must never do

- Run anything on a login node beyond a short-lived, tiny client process.
- Use GPUs it did not reserve. `README.md` §7.10 — seeing a card is not reserving one, and this
  cluster has no isolation to save us from the mistake. Read the allocation's own
  `CUDA_VISIBLE_DEVICES` and never a physical device index; Slurm remaps them.
- Assume it is alone on a node. Others' CPU jobs may share it.
- Hold a resource because releasing it would be inconvenient. That is the entire point.

---

## 7. Robustness rules

Carried from what this repo already learned, plus what the fleet adds.

1. **Ask Slurm; keep no state file.** Established in `README.md` §4a and load-bearing everywhere in
   the fleet.
2. **Scrub `SLURM_*` before shelling out.** `README.md` §7.19 is the nastiest trap in this repo: a
   nested submission inherits the outer job's variables, and those **override the directives in the
   sbatch file**, so a server can come up with the wrong partition or GPU count and never say so.
   The supervisor will run from inside allocations constantly. This is not optional.
3. **Truncate a log before grepping it for readiness.** `README.md` §7.17 — a stale hit from the
   previous job reports success before the new backend has started.
4. **Never report success from a submission.** Success is a health check answering, and for a GPU
   job it is also the allocation actually containing `gres/gpu`. `ollama-up` already refuses to claim
   success on anything less; the supervisor holds the same bar for every engine.
5. **Cold loads are minutes, and the share is the bottleneck.** Every readiness timeout must be
   sized against ~230 MB/s, not against optimism. The projected 31-minute colibrì load will break
   any timeout written for ollama.
6. **Warm before you need it.** Already learned once: a demo that pays a multi-minute reload live is
   a demo that fails. And the keep-alive subtlety in `README.md` §7.14 — a hold set on one request is
   reset by the next request that omits it — generalizes to any per-request lifetime hint the fleet
   sends.
7. **One action per cycle, and log the reason.**
8. **Every component must be independently killable** without taking the service down. Test that
   deliberately rather than discovering it.

---

## 8. Ease of use

The interface is the product. If the fleet is harder to use than typing a model name into opencode,
it will not get used, and an unused fleet holding a GPU is the worst possible outcome.

- **One command family**, extending the existing shape rather than replacing it: bring the fleet up
  toward a target, show status, attach a client, tear down. `ollama-up` / `ollama-code` /
  `ollama-down` are proven and stay working; the fleet commands are additive, and the design goal is
  that the fleet versions do to three engines what those three commands did to one.
- **One model namespace.** Callers name a model. Never a host, never a port, never a job id.
- **A status view that answers the only three questions anyone asks:** what is up, what is warm, and
  what is it waiting on. Pending reason included, because "why is nothing happening" is the question
  that gets asked most.
- **The client configuration is tracked in this repo**, and the live file is a copy of it — same
  discipline as `config/opencode.json` today, for the same reason.

---

## 9. The PHI boundary under a fleet

Everything in `README.md` §6 and in the locked decisions still holds. The fleet adds surface and
must therefore add controls, not spend the ones we have.

**Carried forward unchanged:** provider allowlists are default-deny; web tools are default-deny with
a single named exception; permissions are per *agent*, not per model, so the boundary is the
workload; the clinical path never runs through a tool-calling agent at all.

**New, and specific to the engines being added:**

- **Loopback is not a boundary against other users on the same node.** Slurm gives a job no network
  namespace, so any user with a shell on that node can connect to a loopback port on it. This repo's
  existing framing treats loopback binding as *the* control; it is necessary and not sufficient. Two
  actions follow: colibrì's API key is set on every backend that exists, and the fact that our
  current ollama endpoint has **no authentication at all** is recorded as a live gap rather than a
  future one (`README.md` §7).
- **colibrì writes conversation state to disk by default.** Its KV-persistence setting defaults to
  on, appending roughly 182 KB per token to a dot-file **inside the model directory** so that
  conversations reopen warm. Pointed at a model on the studies share, that is PHI-derived state
  accumulating on shared storage under whatever the umask gives it. For any PHI path: persistence
  off, or a model directory whose permissions have actually been checked. The related setting that
  lets one serve slot adopt another slot's KV prefix is exactly the cross-conversation path to keep
  disabled.
- **The engines themselves do not phone home.** Verified by inspection on 2026-08-22: colibrì's
  gateway is standard-library only and contains no HTTP client, no outbound socket calls, and no
  telemetry upload; its `telemetry.h` reads `/proc/cpuinfo` and `/proc/meminfo`, which is hardware
  introspection and not reporting. Weight downloads are inbound and one-time. This is worth having
  written down because it is the kind of claim that gets assumed in both directions.
- **The harness is a separate egress surface from the model.** Pointing any assistant client at a
  local endpoint routes *model calls* locally. The client's own telemetry, error reporting,
  auto-update, and web tools are independent traffic, and the ingress risk is unchanged: a fetched
  page arrives as text the model cannot distinguish from instructions, and the agent holding it has
  file and shell access. A local model does not fix prompt injection. Any new client gets the same
  default-deny treatment opencode got, and that audit is part of adopting it, not a follow-up.
- **The filesystem batch plane is the strongest control available** because it removes the socket
  entirely. Prefer it for PHI corpus work over any network service, including ours.

---

## 10. The cost of a yield

The numbers that make yield decisions concrete. Reload cost is what turns citizenship from a slogan
into arithmetic.

| backend | resident size | cold load | basis |
|---|---|---|---|
| ollama, `gpt-oss:120b` | 65.4 GB | **4m46s** | measured 2026-08-20, `README.md` §4 |
| ollama, `qwen3-coder:30b` | 18.6 GB | ~1.5 min | projected at the same ~230 MB/s |
| vLLM, MedGemma 27B bf16 | ~54 GB | ~4 min | projected |
| colibrì, GLM-5.2 int4 | 429 GB on disk | **~31 min** | projected |

Read that table as the yield ladder's justification and as a warning: at these load times, **a fleet
that thrashes is worse than a fleet that is simply smaller.** Every yield/reacquire cycle costs
minutes of GPU time doing nothing but reading NFS. Hysteresis — a cooldown before regrowth, an idle
timeout long enough to absorb a lunch break, a hold-off after every yield — is not tuning, it is
correctness.

---

## 11. Where this lands, honestly

Industrial-grade throughput on hardware we already own: yes, for batch and for a small number of
interactive users. Frontier-scale model access with no data leaving the building: yes, at high single
digits of tokens per second and with measurable int4 quality cost. A drop-in replacement for a
hosted frontier assistant: **no**, and the design should not pretend otherwise. The int4 quality
gap, the single-generation serialization, and the 31-minute cold start are all real, and no routing
layer removes any of them.

The genuinely new capability is not cost. It is that **a frontier-scale model can read PHI**, which
no hosted service will ever be allowed to do here. That is what makes this worth building, and it is
worth stating in the design document so the project is justified by the right argument.

The best structural use of a slow, smart model follows from the same honesty: **as a consultant, not
as the loop driver.** An agent loop runs on a fast local model — dozens of tool calls, file reads,
small edits — and gets one tool that asks the 744B model a single hard question and waits a few
hundred tokens for it. Thirty seconds of consultation inside a five-minute task is invisible;
driving the whole loop at that rate is unusable. That pattern is a milestone, not a v1 feature.

---

## 12. Milestones

Each is useful on its own and has an exit criterion. Do not start the next one until the previous
one's criterion is actually met.

**M0 — vLLM exists.** Installed user-local into a conda prefix, one replica serving one model on one
`c3_short` node, reachable the way ollama already is. *Exit: a schema-guided structured response
comes back from a real prompt, and the resident-set and fallback diagnostics were read, not just the
output.*

**M1 — the batch plane.** The filesystem work queue, N workers, one real corpus pass end to end.
*Exit: a pass completes with a worker deliberately killed mid-run, and no item is lost or
double-processed.* This is the milestone that unblocks PSYCH-ASR Stage 3c, and it delivers the
"no tool-calling surface" PHI layer as a property of the architecture rather than as a config.

**M2 — the colibrì placement measurement.** GLM-5.2 int4 staged on the studies share; the engine
built; decode measured on one `c3` node and on `c3_accel`, under a snapshot-and-restore protocol for
the learned routing profile. *Exit: our own numbers for both placements, and a decision on §4.1 based
on them instead of on another machine's log.*

**M3 — the supervisor.** The convergence loop, the yield ladder, the hold-off, the caps, the idle
release. *Exit: it demonstrably yields a node to a pending foreign job and does not immediately take
it back; and killing the supervisor leaves every backend serving.*

**M4 — the front door.** Router with health checks, one model namespace, queue-aware fall-through,
single-slot queueing for colibrì. *Exit: a client session survives a backend being yielded and
replaced mid-conversation.*

**M5 — the consultant tool.** A fast agent that can ask the big model one question. *Exit: it is
used voluntarily, twice, because it was better than not having it.*

Stop after M1 and the repo is already worth more than it is today.

---

## 13. Open questions — measurements owed, not opinions to have

Written in the form the colibrì project uses, because it is the right form: a hypothesis is not a
finding until a controlled run says so, and negative results are worth recording.

| hypothesis | evidence so far | measurement needed |
|---|---|---|
| colibrì on one A40 is within ~40% of colibrì on four | another host's controlled A/B showing the VRAM split immaterial and the RAM budget decisive | our own paired run, same model, same context, profile snapshotted and restored between conditions |
| atomic rename on the studies share is a safe claim primitive | it is the standard technique; this NFS mount is untested | a deliberate race: many workers, one queue, verify exactly-once claiming and reclaim-after-death |
| vLLM replicas beat tensor parallelism on this PCIe-only host | no NVLink is confirmed; the throughput claim is not | four replicas versus one four-way shard, same model, same batch, aggregate tokens compared |
| yielding on pending-queue evidence actually helps the other job | none. This is the fleet's central claim and it is currently an assumption | instrument every yield: did the triggering job start, and how long after |
| a 744B int4 model is better than a well-served 27–120B at 8-bit for our tasks | the −8.2pp quantization measurement argues against assuming it | blind side-by-side on real tasks from our own repos, scored before anyone looks at which is which |
| the cooldown is long enough | none | count reacquisitions that beat the job they yielded to; that number must be zero |
| the fleet does not starve our own pipeline jobs | none. The fair-share cost is real and unmeasured | track our fair-share factor before and during a week of fleet operation |

---

## 14. Traps anticipated

Not yet paid for, so not in `README.md` §7. Written down so that when one of them bites, it is
recognized in minutes rather than debugged for a day.

1. **The supervisor races its own yield** (§6.5). Expected to be the first real bug.
2. **A yield during a batch pass loses an item** if the claim has no heartbeat and nothing reclaims a
   dead worker's work.
3. **A readiness timeout written for ollama fires during a colibrì load** at ~4% of the way through,
   and the supervisor concludes the backend failed and yields a node it should have kept.
4. **Thrashing looks like a scheduler problem.** Repeated yield/reacquire cycles present as "the
   cluster is busy" while the actual cause is missing hysteresis.
5. **A stale `.coli_usage` profile makes every colibrì comparison meaningless.** The learned routing
   profile persists across restarts and grows monotonically; the reference project measured the *same
   configuration* at 5.46 and then 2.78 tok/s because of it. Snapshot and restore, or measure nothing.
6. **colibrì's KV persistence quietly fills the model directory** with per-token conversation state
   nobody asked for (§9).
7. **A model that silently falls back to CPU still exits 0.** Device discovery printing a line is not
   proof of GPU work; the resident-set count is. This is documented behaviour of the engine, not a
   hypothetical.
8. **The fleet's own convergence loop counts as cluster load.** A supervisor polling Slurm every few
   seconds across six nodes is rude in a smaller way than squatting, and it is the kind of thing an
   admin notices before we do.
