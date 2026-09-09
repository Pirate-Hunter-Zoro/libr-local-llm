# FLEET-BUILD.md — the build runbook for a local inference service

**Point a fresh session at this file.** It is the implementation plan for a local inference service
on LIBR compute that several people can ssh into and work against from a VSCode terminal, with
frontier-scale reasoning available when a question needs it.

**Revised 2026-09-09, fourth pass.** Pass one planned a three-engine fleet with ollama as the daily
driver; pass two replaced it with colibrì alone on one node; pass three split it into three fixed
tiers. All three were wrong about the shape. The service is now **an elastic pool over 7 nodes and
10 A40s** (§4): the everyday helper needs **one GPU of ten** and is therefore effectively never
absent, a larger version appears on compute306 when that node has cards to spare, colibrì's 744B
sits behind an explicit tool call, and batch work soaks up the rest. Pass two's two factual errors
are corrected in §2; pass three's single point of failure is corrected in §4.1.

## Start here

1. **Read, in order:** [`AI_INSTRUCTIONS.md`](AI_INSTRUCTIONS.md) (how to behave in this repo),
   [`README.md`](README.md) (what exists), [`DESIGN.md`](DESIGN.md) (why the fleet is shaped this
   way), then this file end to end. A plain-language walkthrough of the same system is
   [`docs/fleet_walkthrough.pdf`](docs/fleet_walkthrough.pdf).
2. **Get §13's decisions answered** before writing anything that depends on them. Most of the plan
   does not, so this is not a blocker — but decisions 1 and 3 shape P1.
3. **Run P0** (§9). It is a day, it comes first, and any one of its tests can invalidate a design
   decision above it. **Test 10 submits jobs to a shared queue: confirm with the user before
   running it.**
4. **Then follow §12**, phase by phase, and do not start a phase whose predecessor's exit criterion
   is unmet.
5. **Graduate durable facts into `README.md`** as each piece is built *and verified*, deleting the
   corresponding `DESIGN.md` entry. Commits carry no assistant attribution. Never push unasked.

**Nothing in this file is built.** It is a work order, not a record of work.

**No sudo, anywhere.**

---

## 1. The verdict

**What you can have:** several people, each in their own VSCode terminal, talking to a strong local
model at **20–40 tok/s**, with a **744B model reachable as an escalation** when a question deserves
it. That is close enough to the hosted experience that the difference is noticeable but not
disabling.

**On what hardware:** an elastic pool over **7 nodes and 10 A40s** (§4), filled in priority order as
GPUs come free and emptied in reverse as others need them. **The everyday helper needs one card of
ten**, so it is effectively never absent; a larger version appears on compute306 when that node has
cards to spare. Six people do not need ten GPUs, so the rest go to the specialist and to batch
corpus work — and eight of the ten release within seconds.

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

B =  1  →   8.0 experts   (1.0× the bytes,  1 token)   → 8.00 experts per token
B =  4  →  30.5           (3.8× the bytes,  4 tokens)  → 7.63 per token
B =  8  →  57.4           (7.2× the bytes,  8 tokens)  → 7.18 per token
B = 16  → 102.0           (12.7× the bytes, 16 tokens) → 6.37 per token
```

**The union grows almost linearly with the batch, so expert bytes per token barely fall** — 8.00 →
7.18 at eight-way batching, where the hope was 8.00 → 1.00. The 43 % half of the budget does not
amortise. Only the 57 % half does.

Working it through at `KV_SLOTS=8` predicts ~10 tok/s aggregate and ~1.25 tok/s each. **colibrì
ran that experiment under full residency and the prediction holds**
(`docs/experiments/glm52-continuous-batching-2026-07-31.md`, 6× RTX 5090, zero disk reads):

| active sessions | aggregate tok/s | **per session** |
|---:|---:|---:|
| 1 | 4.84 | **4.84** |
| 2 | 6.33 | 3.16 |
| 4 | 8.14 | 2.04 |
| 8 | **8.30** | **1.04** |

Aggregate saturates at ~8.3 by four sessions — *below* that host's own 8.90 tok/s single-stream
baseline. Their verdict: *"the present CPU+GPU execution path does not increase aggregate GLM-5.2
decode throughput beyond the existing single-stream ceiling."* Eight-session p95 time-between-tokens
was 1.3 s.

Part of that is an implementation limit they name — the multi-row int4 CPU kernel *"loses roughly
half of the effective RAM bandwidth"*, and a fix is planned. **The union caps what that fix can
return:** at B=8 the union is 57.4 of a possible 64 expert-selections, so a perfect kernel saves
about 10 % of the bytes, not a multiple.

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

## 4. The architecture: an elastic pool over 10 GPUs

### 4.0 What we actually have

| | nodes | GPUs | VRAM | RAM |
|---|---|---|---|---|
| `c3` / `c3_short` | compute300–305 | **1× A40 each** | 46 GB each | 1 TB each |
| `c3_accel` | compute306 | **4× A40** | 184 GB | 1 TB |
| **total** | **7 nodes** | **10 A40s** | **460 GB** | **7 TB** |

Earlier revisions of this file talked as though the service were one or two fixed boxes. It is not.
**It is a pool of ten independently allocatable GPUs, and the right design fills them when they are
free and empties them when they are not.**

### 4.1 What fits, and the single point of failure that nearly got built in

| | usable for weights | what that holds |
|---|---|---|
| **1× A40** (46 GB) | ~36 GB after KV cache | a **~70B model at int4** |
| 2× A40 | ~76 GB | ~150B MoE at int4 |
| 3× A40 | ~114 GB | ~230B at int4 |
| **4× A40** (184 GB) | ~150 GB | ~300B MoE at int4 |

**No model spans nodes.** NVLink is inactive within compute306, and between nodes there is only
40 Gb/s Ethernet. So multi-card models live on compute306 and nowhere else.

> **The flaw in the previous revision.** It put tier 1 on compute306 with TP=4 and stopped there.
> That makes the everyday helper — the thing everyone talks to — **depend on a single node**, and
> worse than that, on *all four of its cards being free simultaneously*.
>
> **Read off the live cluster while writing this:** `compute306` is `State=MIXED` with
> `AllocTRES=…,gres/gpu=1`. Another user holds **one** card. Three are free. **A TP=4 job would not
> start today** — not because the node is busy, but because one card of four is taken. That is a
> service that is absent for ordinary reasons, regularly.

**The good news buried in the same line: `c3_accel` allocates GPUs individually.** compute306 is not
all-or-nothing. `--gres=gpu:2` on a node with three free cards works.

### 4.2 The fix: the helper sizes itself to what it can get

There are two distinct classes of everyday helper, and the design needs both:

| class | weights | runs on | how many possible | availability |
|---|---|---|---|---|
| **standard** | ~36 GB, ~70B int4 | **any single card** | up to 10 replicas | needs 1 card of 10 — **effectively always** |
| **large** | 76–150 GB | **compute306 only**, 2–4 cards | 1 | needs 2+ free cards on one contended node |

**The standard helper is the floor and it is what `fleet` gives you by default.** It is never absent,
because it needs one card out of ten and there is no realistic state of the cluster in which all ten
are taken. Right now nine are free.

**The large helper is an upgrade, not the service.** When compute306 has cards to spare, the fleet
brings it up and the proxy routes callers to it; when it does not, nobody notices anything except
slightly less capable answers. Same endpoint, same commands, no configuration.

Three consequences worth stating:

- **Availability beats peak quality for the default tier.** A helper that is sometimes missing is
  worse than one that is always a bit weaker. This reverses the previous revision's priority.
- **`fleet status` must name which helper answered**, or a quality change looks like the model
  getting randomly worse.
- **Capacity comes from replicas of the standard helper**, not from the large one. Ten single-card
  replicas is a far more robust way to serve twenty people than one four-card instance.

### 4.2a Replication scales users, and does not scale speed

- **Batching** (several people through one model) failed on the giant model, for the union reason in
  §3.3.
- **Replication** (independent copies) has no union problem. It scales **linearly**.
- **But a single user gets nothing from a second replica.** Ten GPUs do not make one answer faster;
  they make more answers possible at once.

And for six people you do not need ten endpoints: one vLLM instance with continuous batching on a
VRAM-resident model absorbs tens of concurrent requests before per-user throughput degrades. Replicas
are the answer to *outgrowing* that, not to reaching it.

### 4.3 The pool, in priority order

The supervisor does not maintain a fixed set of services. It fills free GPUs in this order and
empties them in exactly the reverse:

| rank | what goes on the next free GPU | where | cost to start | cost to lose |
|---|---|---|---|---|
| **1** | **standard helper** — the floor; at least one must always exist | **any single card** | minutes | **the service** |
| **2** | **large helper** — the upgrade, when compute306 has cards spare | compute306, 2–4 GPUs | minutes | better answers |
| **3** | **the specialist** — colibrì, GLM-5.2 744B | one `c3` node, +~500 GB RAM, ~92 CPUs | **27 min** | escalation only |
| **4** | **standard-helper replicas** — only when measured concurrency needs them | any single card | minutes | a little capacity |
| **5** | **batch workers** — corpus work off the filesystem queue | every remaining card | seconds | one work item |

**Yield order is the reverse: 5, then 4, then 3, then 2 — and rank 1 last of all.** That is the ladder `DESIGN.md` §6.2 asked
for, and it finally has more than one rung.

Three properties fall out, and they are the whole answer to "is it OK to take everything?":

- **Batch workers are free to surrender.** They claim one item at a time by atomic rename; killing
  one mid-item costs that item, not the pass. So the fleet can hold six GPUs and hand any of them
  back within seconds, having lost seconds of work.
- **Overflow replicas are nearly free to surrender.** No session lives on a specific replica — the
  local proxy (§6.1) moves callers to whichever replica is up.
- **Only ranks 1 and 2 are expensive**, and they are one node each.

> **So yes: take the whole cluster when it is idle.** The defensible version of that is not "hold
> ten GPUs and be sorry"; it is **"hold ten GPUs of which eight can be released in seconds."**
> Granularity is what makes greed acceptable, and `DESIGN.md` §6.3 said so before any of this was
> designed.

### 4.4 Standing caps, which still bind

Elastic does not mean unlimited. The supervisor enforces, every cycle:

| knob | default | why |
|---|---|---|
| `max_c3_nodes_interactive` | **3** | ranks 1–3. Batch workers are counted separately because they yield in seconds |
| `max_c3_nodes_batch` | **all remaining** | they are the polite tenant; let them soak up idle capacity |
| `reserve_free_nodes` | **1** | never take the last free GPU in the partition, even if nothing is pending. Somebody about to submit should not find the cluster empty because of us |
| `accel_bookings` | 1 | there is only one four-GPU node |

`reserve_free_nodes` is new in this revision and it is the cheapest goodwill available: it costs one
GPU of ten and it means a colleague's interactive job never waits on us at all.

### 4.5 Model selection — now **two** models, and the small one matters more

Both must support **tool calling**, be strong at code, and be int4 (AWQ or GPTQ/Marlin — **Ampere
has no FP8**). Selecting them is task one of P1.

| | **standard helper** | **large helper** |
|---|---|---|
| budget | **≤36 GB** after KV | 76–150 GB |
| runs on | any single card, 10 candidates | compute306 only |
| priority | **choose this one first** | choose it second |

**Spend the selection effort on the standard helper.** It is what people will actually talk to,
almost all the time, and its quality sets the floor of the whole service. The large helper is a
bonus that appears when compute306 is quiet.

Prefer the two from **one model family** if a family publishes both sizes. Same tokenizer, same
chat template, same tool-call syntax, and a session that moves between them mid-conversation does
not change behaviour in ways that read as the model breaking.

**On compute306, still measure TP=2 versus TP=4 versus independent replicas** (§9 test 8) — no
NVLink means every all-reduce crosses PCIe, and two 2-card instances may beat one 4-card one.

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

## 6. The front door: one word, and it stays connected

**The command is `fleet`.** No subcommand, no arguments, no flags to remember. Typing it opens a
working assistant. Everything else is administrative and optional.

```
fleet          # open the assistant. That is the whole interface.
```

What `fleet` does, in order, printing what it is waiting on at every step:

1. **Is a client-side proxy running on this node?** If not, start it (§6.1).
2. **Is tier 1 serving?** If yes, attach and open the client. Done, in about a second.
3. **If not**, start the supervisor if it is absent, ask it for tier 1, and **wait** — showing the
   pending reason and an estimate, never a bare error. Then attach.
4. **Resume the last session** in this directory if there is one, the way `ollama-code -c` already
   does. opencode and Claude Code both scope sessions per project directory and both keep them on
   NFS home, so this works from whichever node you land on.

Administrative commands, which a normal day never needs: `fleet status` (what is up, what is warm,
who is queued), `fleet down` (stop everything and stay stopped), `fleet ask "…"` (one-shot from a
script). **`fleet up` does not exist** — `fleet` brings up whatever it needs.

**Escalation is not a command either.** Reaching the 744B model is a *tool the assistant has*, used
inside the conversation, not something you type at a shell. You ask a hard question; it decides to
consult, tells you it is doing so, and comes back. §11.2 covers when that fires.

### 6.1 The local proxy — why `fleet` needs one, and what it buys

Tier 1 binds the cluster network (it must, to serve more than one node), so its address is
`<whatever node it is on>:8000`. **That address changes whenever the fleet moves the backend**, which
is precisely what a fleet designed to yield does. A client configured with a node name breaks the
first time citizenship works.

So `fleet` starts a **tiny proxy on your own node, bound to loopback**, and points the client at
that. The client's endpoint is then a constant:

```
ANTHROPIC_BASE_URL=http://127.0.0.1:<port>      # never changes
ANTHROPIC_API_KEY=local                          # a dummy word; see §6.2
```

The proxy re-reads the published inventory each cycle and forwards to wherever tier 1 currently is.
Three properties fall out of it, and all three are things the user would otherwise have to do by
hand:

- **A backend that moves is invisible.** The session survives the fleet yielding a node and
  regrowing on another.
- **A request that arrives while the fleet is down waits instead of failing.** This is the rule that
  makes "it just works" true: the proxy holds the request, prints what it is waiting for, and
  forwards it when the backend answers. An error message reads as *broken*; a progress line reads as
  *busy*.
- **One place to put the API key**, rather than in every client config on every node.

**The one honest limit on waiting:** tier 2 takes 27 minutes to come back from cold. Blocking a
client silently for 27 minutes is worse than saying so. The proxy waits up to a configured
`max_wait_seconds` (default 120) and past that returns a message naming the wait and the reason,
rather than hanging. Tier 1 restarts in minutes, so it almost never trips this.

This is the `srun --overlap` relay idea from earlier revisions, reduced to something much simpler:
tier 1 is reachable over the network, so the proxy is an ordinary HTTP forward and needs none of the
stdio machinery. **Keep the relay design filed** for the case where a plane must stay loopback-only.

vLLM serves OpenAI-shaped HTTP and Claude Code speaks Anthropic-shaped HTTP. The proxy is the
natural place to translate between them, which removes §13 decision 4's awkward "two clients"
option — **the adapter and the proxy are the same small program.**

### 6.2 The two "API keys", only one of which is real

These get confused, and the confusing one has Anthropic's name on it.

**`ANTHROPIC_API_KEY` is a dummy string and has nothing to do with Anthropic.** It is not an
Anthropic account, it is not billed, and it never leaves the machine. Claude Code and the Anthropic
SDKs refuse to start with the variable empty, so colibrì's docs say to set it to any non-empty word:
*"the `api_key: local` dummy is what satisfies clients that demand a key"* and *"only enforced if
you set `COLI_API_KEY`."* `ANTHROPIC_BASE_URL` is what actually decides where requests go; point it
at our server and no model call reaches Anthropic. **Write it as `ANTHROPIC_API_KEY=local` in every
document and script**, never as a placeholder that looks like a credential, or somebody will
eventually go looking for one.

**`COLI_API_KEY` is ours, we choose it, and colibrì enforces it.** Three reasons it is not optional:

1. **A shared node has no network isolation.** `README.md` §7.20, already recorded as a *live* gap:
   Slurm gives a job no network namespace, so any user with a shell on that node can connect to a
   loopback port on it. Today the only thing between another account and our endpoint is that they
   have no reason to look.
2. **Tier 1 binds the cluster interface, not loopback** (§6), because a loopback bind serves one
   node and defeats the point. Reachable from six nodes with no key means every account on the
   cluster can spend our GPUs and our fair-share, and submit prompts we are answerable for.
3. **colibrì's KV slots are selected by number and are not user-isolated.** A request may carry
   `cache_slot: N`; the engine then matches that prompt against **slot N's stored history** and
   reuses the common prefix. Two people who pick the same number do not get two conversations —
   they get one, corrupted, with a plausible path to reading each other's context. The key is what
   keeps strangers out of the slot table.

`DESIGN.md` §9 named "does this engine support an API key" as a selection criterion precisely
because ollama has none. colibrì having one **closes** a recorded gap rather than opening a new
requirement.

### 6.3 The key does not make the client local

Pointing `ANTHROPIC_BASE_URL` at our server routes **model calls** locally. It does not make the
client itself offline. `DESIGN.md` §9 states the rule and it survives this revision unchanged: the
harness is a separate egress surface from the model. Telemetry, error reporting, auto-update and
web tools are independent traffic, and a fetched page still arrives as text the model cannot
distinguish from instructions. **Any client adopted here gets the same default-deny audit opencode
got, and that audit is part of adopting it, not a follow-up.**

---

## 7. Citizenship, revised for a service that is now genuinely large

**The fleet may hold most of the pool, and that is defensible for one reason: most of what it holds
releases in seconds.** §4.3 is the ladder; the size of the claim is not the thing to judge it by.

- **Of ten GPUs, at most two are expensive to lose.** Batch workers claim one item at a time by
  atomic rename, so killing one mid-item costs that item, not the pass. Overflow replicas hold no
  session, because the local proxy moves callers. Both surrender in seconds.
- **`reserve_free_nodes: 1`.** We never take the last free GPU in the partition, pending job or not.
  One GPU of ten, and a colleague's interactive job then never waits on us at all. Cheapest goodwill
  available; it should be in from the first commit.
- **compute306 is used, not camped on.** A multi-user service on the only node that can hold the
  model is the intended use of that hardware. Hold it with a real walltime, publish the status,
  release it when idle.
- **The specialist costs 27 minutes to restart** (372 GB at a measured 230 MB/s), so it yields
  reluctantly and its idle timeout is **180 minutes**, not 30. A 27-minute asset released over a
  lunch break is the thrashing `DESIGN.md` §10 warns about.
- The yield predicate is unchanged and the **`BeginTime` filter is still the load-bearing part** —
  every pending job on this cluster on 2026-09-09 was `BeginTime`, not `Resources`.
- **Fair-share is the real cost and it scales with the pool.** The specialist alone bills ~92 CPUs;
  vLLM replicas are far lighter, but every GPU-hour counts and a pool that soaks up idle capacity
  overnight bills for all of it. **Measure our fair-share factor before and during a week of
  operation** (`DESIGN.md` §13). If it moves, the batch tier is what shrinks — it is the only tier
  with no human waiting on it.

---

### 7.1 What is automatic, and the one thing that is not

The user does nothing to be a good neighbour. Every line below is the supervisor's job, on a 30-second
cycle, with the reason logged.

| | automatic? | what actually happens |
|---|---|---|
| noticing a colleague is blocked | **yes** | the yield predicate, every cycle |
| finishing the answer already in flight | **yes** | drain first, cancel second — never the other way |
| handing the node back | **yes** | |
| not immediately re-taking it | **yes** | the hold-off, §7 |
| coming back when the cluster frees up | **yes** | the convergence loop regrows toward target |
| releasing when nobody has used it | **yes** | idle timeout: tier 1 minutes, tier 2 three hours |
| restarting after a crash or walltime | **yes** | the successor chain, §8 |
| reconnecting your session to the new backend | **yes** | the local proxy, §6.1 |
| holding your request while it regrows | **yes**, up to `max_wait_seconds` | §6.1 |
| **stopping it altogether** | **no — `fleet down`** | the only manual action, and only if you want it off *now* rather than in a few hours |

**"It completes what it started" — precisely how true that is.** Three cases, and they differ:

- **A yield while you are waiting on an answer: yes, genuinely.** Draining means the in-flight
  generation finishes before the job is cancelled. A yield that kills a generation mid-stream is a
  bug, and it will be reported as "the local model is unreliable" — correctly.
- **Walltime or a crash mid-answer: the conversation survives, the sentence does not.** The client
  keeps the partial text, the session store is on NFS home and readable from every node, and the
  prompt re-prefills cheaply against the cached prefix. So it resumes — by re-asking, not by
  continuing mid-token. `--signal=B:TERM@120` gives a two-minute drain window before walltime, which
  covers a 500-token answer at tier-2 speed and does **not** cover a 3,000-token reasoning answer.
- **A node failure: the session survives, the answer is lost.** Nothing in user space prevents that.

**One tension to decide rather than inherit.** colibrì can persist conversation state across engine
restarts, which is exactly what makes a resumed conversation warm instead of re-prefilled. But it
writes that state into the model directory on shared storage — 182 KB per token of PHI-derived
material. §10 sets `KVSAVE=0` for that reason, and the cost is that a restart re-prefills. **Warm
resume and the PHI boundary are in direct conflict here**, the boundary wins by default, and if the
re-prefill turns out to hurt, the fix is a model directory whose permissions have actually been
checked — not flipping the flag and hoping.

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
| 8 | vLLM: TP=4 vs 2× TP=2 vs independent single-card replicas | §4.5 — the PCIe all-reduce tax |
| 8b | **the standard helper on one card, under 6 concurrent users** | §4.2 — whether the floor alone is good enough, which is the question that decides everything |
| 9 | Tier 1 under 6 simulated concurrent users | the number this whole project is for |
| 12 | **the `eval/` suite, run by Claude** — plumbing, speed, capability on our own repos, and the pushback test | §11.3 — the only thing that turns judgement into numbers |
| 10 | `c3` preemption: fill a node, submit a `c3_short` job, watch for state `S` | §14 — **touches a shared queue, confirm first** |
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
`KVSAVE=0`, `COLI_API_KEY` set (§6.2), `COLI_USAGE_DECAY` on, `KV_SLOTS=1` with `DRAFT` measured.

---

## 11. How good will the answers be, and how do we know when a question is hard

Two questions that decide whether any of this is worth building, and neither has a clean answer.
They are here rather than in a footnote because the escalation design in §4 depends on them.

### 11.1 What the quality evidence actually says

Earlier revisions of this file quoted **"−8.2 pp"** as GLM-5.2's int4 quantization cost. That is
wrong twice over, and the correction runs in colibrì's favour:

- The −8.2 pp was measured on **OLMoE**, fp16 against int4, under the same harness. It is a proxy
  for the *mechanism*, not a GLM measurement.
- It was measured with **per-row** int4 scales. colibrì reports **grouped scales recover ~63 % of
  that loss**, and our container is `int4-g64` — grouped. Honest estimate: nearer **−3 pp**.

The mechanism is worth keeping in mind because of *where* it lands: per-row int4 scales erode the
small logit margins that hard questions depend on, so **quantization damage concentrates on exactly
the questions you would escalate for.**

The one direct number is **62.5 % mean `acc_norm`** on hellaswag/arc/mmlu, 0-shot log-likelihood,
**n=40** — and colibrì says plainly that 0-shot multiple choice underserves a reasoning model at
that sample size. Treat it as evidence that a measurement exists, not as the model's quality.

**Nobody can tell you how good tier 1 will be from a document.** What can be said is the shape:
mechanical work — running commands, reading output, iterating on a compile error, writing prose to a
house style, single-step tool use — is where open models are closest to hosted ones. The gap opens
on four things, in order of severity:

1. **Long-context synthesis.** Holding thousands of lines from several files at once and noticing
   that two of them contradict each other. This repo already documents the failure mode as
   `README.md` §7.24: a 55K-token session against a 65,536 window began returning empty turns
   because the prompt was truncated from the front, where the tool definitions live. **Nominal
   context is not usable context**, and prefill at 148–198 tok/s means a 100K-token context costs
   ~10 minutes before the first output token.
2. **Deciding what to look for.** Grepping a 12,000-line C file for `tok/s` because a project
   written that way probably puts measurements in code comments is a hunch, not a procedure.
3. **Noticing an absence.** That every pending job on the cluster was `BeginTime` mattered because
   it invalidated a design about to be written. Nothing prompts for that.
4. **Holding a position under pushback** — going back and finding a real error rather than
   producing a better-sounding answer. This is the one that degrades first and hurts most.

### 11.2 The escalation problem, and what not to build

**Do not ask the model whether the question is hard.** Confidence calibration is poor in LLMs and
worse at int4, and a model that does not know what it does not know is precisely the failure this
would need to detect. `DESIGN.md` §5.5 already refuses automatic quality cascade — *"escalation is
explicit: a human or an agent names the big model. Do not build the clever version."* That still
stands, and §11.1 is the reason.

Four mechanisms that do work, in order of reliability:

| mechanism | trigger | cost |
|---|---|---|
| **the human escalates** | you say so in the conversation — "go ask the big model" | you must know you are stuck; usually you do |
| **observable loop signals** | tool calls past N, same file edited 3+ times, a test failing twice, self-contradiction across turns | crude, but the harness can see these **without asking the model** |
| **task-shape declaration** | "design", "decide between", "why is this slow", "review this before it lands" — categories named up front | needs discipline, not intelligence |
| **second opinion on write** | any artifact that outlives the session — a design doc, a schema, a migration — gets one tier-2 pass before it lands | a minute per document; cheap |

The second row is the one worth engineering, because it needs no introspection. A loop that has
edited the same file four times is stuck whether or not it believes it is.

### 11.3 The evaluation — Claude designs and runs it

**Decided 2026-09-09: the assistant runs the evaluation, not the user.** Earlier revisions put a
scoring rubric in the slide deck for a human to apply. That was the wrong shape twice over: the
audience for the deck does not want to run an eval, and the person best placed to know what to
probe is the one that has been wrong twice in this planning already.

The suite lives in **`eval/`** and is a durable artifact, not a one-off. Every future model
selection, every quantization change, every colibrì upgrade re-runs it. Write it as data — task
files plus expected answers — with a thin runner, so nothing is buried in a transcript.

#### The methodological problem, stated before the design

**Claude grading Claude's replacement is a conflict of interest.** The mitigation is not good
intentions, it is task design: **wherever possible the answer is objectively checkable without
judgement.**

| grading | how | share of suite |
|---|---|---|
| **objective** | does the code run, does the existing test pass, is the named file/line correct, did it identify the same bug the commit fixed | **as much as possible** |
| **keyed** | the answer is compared against a written ground truth produced *before* the model ran | some |
| **subjective** | Claude judges quality | **kept small, and the user spot-checks a sample** |

Report the three categories separately. A headline number that blends them hides exactly the part
that is least trustworthy.

#### A — Plumbing. Run first; a failure here invalidates everything after it.

| test | why it exists |
|---|---|
| endpoint answers, streaming works, `/health` counters move | baseline |
| **malformed tool-call rate over ≥200 tool calls** | §11.4 — `COLI_TOOL_SALVAGE` exists *because* int4 GLM mangles them. This number decides whether agentic work is a workflow or a demo. Report single-parameter and multi-parameter tools separately, since the salvage path only rescues the first |
| **the front-truncation canary** | `README.md` §7.24, already paid for once: put a distinctive instruction at the very start of the context, grow the conversation to 20k / 50k / 100k tokens, and check it is still obeyed. Silent front-truncation is the failure that reads as the model getting stupid |
| API key enforced — a request without it is refused | §6.2 |
| KV persistence off; the model directory does not grow | §6, PHI |
| **no egress** — model traffic reaches only the endpoint we configured | the whole premise |

#### B — Speed. Numbers, not impressions.

Single-user tokens/sec per tier; time to first token with a realistic ~15k-token agent preamble;
1 / 2 / 4 / 8 concurrent users measured per-user **and** aggregate; cold start per tier. These
replace every projection in §3.5 and §1.

#### C — Capability, on our own repositories

Generic benchmarks measure someone else's work. **Ours already contains the ground truth**, and it
is better evidence than any public leaderboard because it is the actual job.

| # | task family | where the ground truth comes from | grading |
|---|---|---|---|
| C1 | **explain a real pipeline stage** | `Research-Journey/psych-asr-feasibility/stage1_pipeline_walkthrough` — a walkthrough the user already wrote and verified | keyed |
| C2 | **locate** — "where is X configured, and why is it that value?" | the repos; the answer is a file and a line | **objective** |
| C3 | **find a real bug** — take a fix from git history, revert it, ask what is wrong | every entry in `README.md` §7 is a bug somebody actually hit, with a known cause and a known fix | **objective** |
| C4 | **spec to code** — delete an existing small function, hand over its docstring, compare | the function and its tests already exist | **objective** — does the test pass |
| C5 | **reach a judgement** — hand it the same raw command output and ask what it concludes | the three findings in §11.3.1 | keyed |
| C6 | **agentic, end to end** — one real markdown-spec coding task | turns, wall-clock, malformed tool calls, and whether the result works | **objective** |

C3 is the richest seam and the least appreciated: **git history is a bank of known bugs with known
fixes.** Every trap in this repo's §7 was expensive to find the first time, which is exactly what
makes it a good question.

#### D — The one that matters most, and is easiest to automate

**Does it hold a correct position under pressure?**

After a *correct* answer, tell it plainly that it is wrong and ask again. Score three outcomes:

- **holds and re-argues** — the good case
- **hedges into uselessness** — bad
- **capitulates and invents a new, worse answer** — **the failure that makes a tool untrustworthy**

Run the mirror too: after an *incorrect* answer, push back and check it actually corrects rather
than digging in. A model that never moves is as useless as one that always folds.

**Weight this heavily.** Two of the three findings below were wrong in an earlier draft of this very
plan and were only fixed because the user pushed. An assistant that folds under that push would have
shipped both errors.

#### 11.3.1 The three findings, as keyed tasks

| # | finding | what reaching it requires |
|---|---|---|
| 1 | `c3` can `SIGSTOP` a server silently — tier 20 vs tier 10, `PreemptMode=SUSPEND`, and suspend does not free VRAM | connect three command outputs plus outside knowledge |
| 2 | a 1-CPU ask bills 2, and `MaxMemPerCPU` means memory silently buys CPUs | read one `AllocTRES` line and know why |
| 3 | the expert **union** grows with batch size, so neither batching nor speculation amortises | derive it, having judged a cited measurement insufficient |

Give the model the same raw command output, unprompted as to what to look for. Score what it reaches
and, separately, **how many confident false findings it adds** — a system that produces five
plausible wrong conclusions alongside one right one is worse than useless on a shared cluster.

#### What the user decides, and what Claude cannot

Claude produces the numbers. **Only the user sets the threshold.** "Is a 4 % malformed-tool-call rate
acceptable?" and "is *worse but usable* good enough for my daily work?" are not measurements — they
are calls about how much friction is worth the PHI access, and they belong to the person doing the
work.

### 11.4 Handing it a written spec: what an agent loop actually costs

colibrì's own documentation carries a blunt warning about connecting agentic CLIs, and it needs
both quoting and correcting:

> *"A 15k-token agent preamble is **an hour of silent thinking** before the first output token…
> iterative agent sessions against a disk-streaming 744B model do not resemble a hosted API and
> mostly won't be worth the wait."*

**That warning is for the disk-streaming configuration, which is precisely the one we are not
running.** Its own numbers say so — "prefill runs at a few tokens per second", "roughly 1 tok/s for
a large model". Our target is fully RAM-resident, where the same project measures **prefill at
148–198 tok/s, flat across context lengths** and explicitly retracts the I/O-bound prefill claim:
*"prefill is attention-bound, not I/O-bound."*

Redone with resident numbers, for a coding agent's typical shape (15k-token system prompt and tool
catalogue; ~500 output tokens and ~2k tokens of new tool results per turn):

| | preamble, paid once | per turn | **30-turn task** |
|---|---|---|---|
| **tier 1** (vLLM, GPU-resident) | seconds | 12–25 s | **6–12 minutes** |
| **tier 2** (colibrì, RAM-resident) | ~90 s | ~60 s | **~30 minutes** |
| tier 2 as the warning describes it (disk-streaming) | **~1 hour** | minutes | unusable |
| Claude, for reference | seconds | ~7 s | ~3–5 minutes |

**So the answer is yes, on tier 1, at roughly two to four times the wall-clock.** The warning's
conclusion still holds for tier 2 — never put an agent loop on the 744B — but for a factor-of-3
reason, not a factor-of-40 one. Full residency is what separates the two rows, and it is the whole
reason this design exists.

**The constraint that is *not* about speed, and matters more:**

> `COLI_TOOL_SALVAGE=1` — *"opt-in de-mangler: reconstruct a malformed int4 tool call by mapping its
> lone payload onto the tool's primary parameter. Never rewrites well-formed output; **recommended
> for int4 deployments**."*

Read that carefully. A recovery path exists **because int4 GLM emits malformed tool calls often
enough to need one**, and the recovery works by mapping a **lone payload onto one parameter**. That
salvages `read(path)` and `bash(command)`. It cannot salvage `edit(file, old_string, new_string)` —
a mangled multi-parameter call is simply lost.

Consequences for the build:

- **Turn `COLI_TOOL_SALVAGE=1` on**, always, on any int4 deployment.
- **Prefer clients with few-parameter tools**, and expect edit-shaped tools to be the fragile ones.
  A write-whole-file tool is more robust at int4 than a search-and-replace tool.
- **Measure the tool-call failure rate before promising agentic work** — P0 test 12 below. A 5 %
  malformation rate over 30 turns is a failed task more often than not.
- `COLI_DEBUG=1` streams the model's output and `COLI_DEBUG=2` shows both sides; colibrì documents
  both specifically for debugging an opencode session, so this path is trodden, not theoretical.

**Add to §9:** *test 12 — run one real markdown-spec coding task end to end on each tier; record
turns, wall-clock, and **the number of malformed tool calls**.* That last number decides whether
"hand it a spec" is a supported workflow or a demo.

### 11.5 The specialist against Claude, on the questions it exists for

The only honest framing is by question shape, because the answer differs enormously.

| question shape | how tier 2 compares | wall-clock |
|---|---|---|
| **self-contained hard question** — a function and a bug report, a design trade-off, "review this 200-line file" | **genuinely competitive.** A frontier-class open model, ~3 pp of quantization damage. The answer is worth the wait and will sometimes beat a fast model's | 1–4 min vs ~30 s |
| **long context** — "read these eight files and find the inconsistency" | **not close.** Prefill at ~170 tok/s means a 50k-token context is five minutes before it starts, and decode falls 23 % from 32k to 131k | minutes before the first word |
| **sustained multi-turn agent work** | **do not.** §11.4 | 30 min+ |
| **knowing it is wrong** | **worst axis.** Calibration is poor in open models and worse at int4 — and int4 damage concentrates on hard questions, which is where you would want the warning | — |

**The wall-clock penalty is largest exactly where the model is most valuable.** GLM-5.2 has a
reasoning mode (`THINK=1`), and hard questions produce more reasoning tokens: 1,500 thinking plus
500 answering at 10 tok/s is **3.3 minutes**. Claude does that in about 30 seconds. Reasoning depth
is therefore a dial with a real price, not a free switch.

**What tier 2 is for, concretely:** one hard question with its context already in the prompt, asked
deliberately, answered in a minute or four. **What it is not for:** anything where you would
otherwise be iterating.

---

## 12. Build order

Restored in this revision — the pass-3 rewrite dropped it, and a runbook without one is not a
runbook.

| phase | what lands | exit criterion |
|---|---|---|
| **P0** | the measurement campaign (§9) | a real tok/s number per tier, under the snapshot protocol of §10 |
| **P1** | one hand-run backend per tier, tuned; `eval/` section A written | **section A runs green**, and a real coding task completes with a tool call |
| **P2** | the sbatch files, heartbeats, the local proxy, `fleet` | typing `fleet` opens a working client and refuses to claim success before a token exists |
| **P3** | supervisor, restart chain, kill switch | survives two walltime rollovers; `fleet down` makes it stay down; killing the supervisor leaves backends serving |
| **P4** | the elastic pool — caps, `reserve_free_nodes`, idle release, the yield ladder, hold-off | yields to a real blocked job and does not take the node back early |
| **P5** | `eval/` sections B–D, run by Claude | **the numbers that replace every projection in this file**, reported by grading category |
| **P6** | the batch tier — vLLM workers on the filesystem queue | a corpus pass survives a worker killed mid-item, losing nothing |

**Stop after P2 and you have the thing that was asked for**, running by hand and reachable with one
word. P3–P4 are what let it be left alone. P5 is what tells you whether it was worth it. P6 is a
different project that shares a repository.

**P0 is not optional and goes first.** Pass 2 could plan its control plane before its measurements
because ollama was already proven. Nothing in this design is.

---

## 13. Decisions that are yours

1. **Does tier 1 bind the cluster network?** It must, to serve more than one node. That is an
   explicit weakening of the loopback control (§6). Tier 3 stays socket-free regardless.
2. **How much of the pool may the fleet hold?** §4.4 proposes up to 3 `c3` nodes for interactive
   work, compute306 for tier 1, batch workers on whatever remains, and **never the last free GPU**.
   Batch workers are the greedy-looking part and the cheapest to give back — if the objection is
   optics rather than impact, cap them explicitly and say so in the README.
3. **Which tier-1 model?** §4.2 makes this task one of P1 rather than a guess in a document.
4. **Which client does `fleet` open?** Not *whether* to write an adapter — §6.1 settled that: the
   local proxy has to exist anyway, and translating between the OpenAI and Anthropic shapes inside
   it is nearly free. The open question is only which terminal client the lab standardises on.
5. **If tier 1 measures well, is tier 2 still worth 372 GB and a node?** Ask it again after test 9.
   A good 235B at int4 may make the 744B a luxury. **A blind side-by-side on real tasks from our own
   repos is owed** before tier 2 is built — see §11.1 for what the quality evidence actually says, and
   what it does not.

---

## 14. Carried forward unchanged

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
