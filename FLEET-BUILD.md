# FLEET-BUILD.md — the build runbook for the fleet

**Point a fresh session at this file.** It is the implementation plan for the service designed in
[`DESIGN.md`](DESIGN.md): an always-available local inference endpoint that acquires cluster
resources when they are free, gives them back when somebody else needs them, restarts itself when
it dies, and is reachable from an opencode TUI on any node.

**A 16-slide walkthrough of the same system, for humans rather than implementers, is
[`docs/fleet_walkthrough.pdf`](docs/fleet_walkthrough.pdf)** (source `docs/fleet_walkthrough.tex`,
built with `pdflatex`). Read it first if you want the shape before the detail.

Read in this order before writing a line: [`AI_INSTRUCTIONS.md`](AI_INSTRUCTIONS.md) (the operating
contract), [`README.md`](README.md) (what exists), [`DESIGN.md`](DESIGN.md) (why the fleet is
shaped this way), then this file (what to build, in what order, and how each piece is proven).

`DESIGN.md` is the argument. This is the work order. Where they disagree, this file wins and says
why — three of its assumptions did not survive contact with the live cluster, and §2 lists them.

**No sudo, anywhere, at any step.** Same constraint as everything else in this repo.

(Written 2026-09-09. Cluster facts in §2 were read off the live scheduler that day.)

---

## 1. The verdict, before anything else

**Buildable and shippable: yes.** Every mechanism the service needs exists in user space on this
cluster. Nothing in the plan requires an admin, a daemon on a login node, cron, or a privileged
port. The riskiest component is the cross-node front door (§7), and there is a working fallback
for it that ships on day one.

**"Claude Fable caliber": no. Not on this hardware, not with these weights, not at any speed.**
That has to be said once, plainly, because every design decision below follows from it.

Here is the honest model menu, and it is the whole menu:

| tier | model | resident | where it fits | speed | what it actually is |
|---|---|---|---|---|---|
| fast | `qwen3-coder:30b` | 18.6 GB | any one A40, six candidate nodes | ~40–60 tok/s *(projected)* | a competent mid-tier coding assistant |
| big | `gpt-oss:120b` | 70 GB | **4× A40, compute306 only** | **34.1 tok/s** *(measured, `README.md` §4)* | the strongest thing we can serve interactively |
| huge | GLM-5.2 744B int4 via colibrì | 429 GB on disk, ~500 GB RAM | 1 A40 + most of a node's RAM | high single digits *(projected)* | frontier-scale weights, at typing-is-faster speed |

None of those is Fable. The gap is not a serving problem that better plumbing closes — it is the
weights. `gpt-oss:120b` is the ceiling for interactive work here, it is roughly a good open
120B-class coder, and it requires the cluster's only four-GPU node, which is exactly the resource
`DESIGN.md` §4.3 says never to hold.

So the service this plan ships is **not** a local Fable. It is:

> An endpoint that is always there, always polite, always reachable from a TUI, serving the best
> model that currently fits the resources nobody else wants — with an explicit escalation path to
> the big model when compute306 is free, and to the huge model as a consultant that answers one
> hard question at a time.

That is genuinely worth having, it is the thing PSYCH-ASR needs (a frontier-ish model that may
read PHI, which no hosted service will ever be allowed to do here — `DESIGN.md` §11), and it is
achievable in the phases below. Do not let anyone, including the user, describe it as the other
thing.

**The structural use of the big models is as consultants, not loop drivers** (`DESIGN.md` §11).
An agent loop makes dozens of tool calls; at 8 tok/s that is unusable, and at 34 tok/s on a node
we should not be holding it is antisocial. The loop runs on the fast model. The big model gets
asked one question and answers it. Build for that shape.

---

## 2. What changed since `DESIGN.md` was written

Four findings from the live cluster on 2026-09-09. Each one invalidates or sharpens something in
the design. Verify each again at the start of P0 — a scheduler config can change under you — but
plan as though they hold.

### 2.1 The `c3` partition can silently freeze our server. Never use it for a backend.

`scontrol show config` reports `PreemptType=preempt/partition_prio`, `PreemptMode=GANG,SUSPEND`.
The partitions carry different priority tiers:

| partition | PriorityTier | PreemptMode | OverSubscribe |
|---|---|---|---|
| `c3_short` | **20** | OFF | NO |
| `c3` | **10** | **SUSPEND** | FORCE:1 |
| `c3_accel` | **10** | **SUSPEND** | FORCE:1 |

`c3` and `c3_short` are the same six nodes. A job in `c3` is therefore preemptible by any job in
`c3_short`, and the configured preemption action is **suspend** — `SIGSTOP`, not requeue, not
cancel.

Two consequences, and the second is worse than the first:

- A suspended process **keeps its GPU memory**. Slurm's suspend does not release VRAM, so the
  `c3_short` job that preempted us cannot use the card anyway. The preemption helps nobody.
- A suspended `ollama serve` is frozen mid-generation with an open socket. The client does not get
  an error. It gets **nothing**, indefinitely, and the symptom reads as a hung model.

`README.md` §4 currently advises "switch the file to `c3` if you want a server to outlive 9 hours."
**That advice is a trap and must be corrected.** The fleet lives on `c3_short` and buys longevity
from the restart chain (§5), not from a longer walltime in a preemptible partition.

`c3_accel` is also tier 10 with SUSPEND, but no higher-tier partition contains compute306, so
nothing can preempt there. It is safe for the reason that it is the only partition on that node —
which is not a reason that will survive a scheduler reconfiguration. Check it in P0 each time.

*Status: inferred from partition configuration, not observed. P0 test 1 observes it.*

### 2.2 Memory asks silently buy CPUs, and the minimum billable unit is two.

`DefMemPerCPU=6000, MaxMemPerCPU=12000` on all three partitions, `SelectTypeParameters=CR_CORE_MEMORY`,
`ThreadsPerCore=2`. Two separate effects:

- **Whole-core allocation, proven.** Live job 2070710 requested `cpu=1,mem=6000M,billing=1` and was
  allocated `cpu=2,mem=12000M,billing=2`. A one-CPU ask costs two. There is no smaller unit.
- **`MaxMemPerCPU` inflation, inferred.** A memory ask above 12 GB per requested CPU forces Slurm to
  raise the CPU count. `ollama_serve.sbatch` asks `--cpus-per-task=4 --mem=64G`, which is 16 GB per
  CPU, so it should actually allocate **6** CPUs. `ollama_serve_accel.sbatch` asks 8 CPUs and 128 GB
  and should allocate **11**.

This matters because `README.md` §4 and `DESIGN.md` §6.3 both build an argument on right-sizing the
CPU ask — an 8-CPU ask once left a job queued behind nodes with an idle A40 and four free CPUs. That
argument is correct and the numbers in it are wrong: the memory line was buying CPUs the whole time.

**Action in P0:** read `AllocTRES` off a live `ollama_serve` job and record the real number in
`README.md`. Then either lower `--mem` or raise `--cpus-per-task` deliberately, so the file says what
the job actually takes.

### 2.3 An always-on supervisor costs roughly as much fair-share as everything we currently run.

`sshare` for this account on 2026-09-09: `RawShares=1, NormShares=0.125, RawUsage=548706,
EffectvUsage=0.203247, FairShare=0.146552`. We are already consuming more than our share.
`PriorityWeightFairShare=15000` dominates every other weight (`Partition` 10000, `JobSize` 2000,
`Age` 1000), and `PriorityDecayHalfLife` is 2 days.

A supervisor job holding the two-CPU floor around the clock adds 172,800 billing-seconds per day.
At a two-day half-life that reaches a steady-state RawUsage contribution near 500,000 — **about the
size of our entire current usage.** `DESIGN.md` §1 named fair-share as the quiet cost and was right;
this is the number.

It is not fatal. It is also not nothing, and it lands on the PSYCH-ASR and TRD-EHR jobs the fleet
exists to serve. Hence the design in §5: the supervisor **exits when it has held nothing for a
configured idle period**, and the client commands resurrect it. A fleet that holds no GPUs overnight
is, from the user's seat, identical whether or not a supervisor is watching it hold nothing.

Default `idle_exit_minutes: 120`. Set it to `0` for a genuinely permanent daemon and accept the
fair-share bill, which is a decision for the user (§11), not for the assistant.

### 2.4 Nearly every pending job on this cluster is `BeginTime`, not `Resources`.

Of the 27 pending jobs visible on 2026-09-09, **every single one** had `Reason=BeginTime` — jobs
deliberately scheduled to start later, not jobs blocked by anything we hold. Zero were waiting on
`Resources`.

This is the single largest false-positive source for the yield logic, and it is load-bearing:
a naive "somebody is pending, give a node back" rule would yield the entire fleet continuously in
response to jobs that are not waiting on us and would not start any sooner. The predicate in §6.2
filters on `Reason` explicitly and the filter is not optional.

It also means the yield path will be **rarely exercised in normal operation**, so it must be tested
deliberately rather than waited for. §6.4 says how.

---

## 3. The shape of the thing

Five pieces. Build them in this order; each is useful before the next exists.

```
  fleet (bin/fleet)          one client command, runs anywhere including the login node
      |
      | reads               ${FLEET_STATE}/inventory.json   (a cache the supervisor publishes)
      | writes              ${FLEET_STATE}/STOP             (the kill switch)
      |
  fleetd (supervisor)        a 2-CPU Slurm job on c3_short that self-chains across walltimes
      |                      derives everything from squeue; one action per cycle
      |
      +-- acquires/yields -> backend jobs (ollama today; vLLM, colibrì later)
      |                      each writes a heartbeat file; each binds loopback on its own node
      |
  front door                 P4a: fleet code steps onto the backend's node (works day one)
                             P4b: a loopback router on the CLIENT's node, relaying over
                                  srun --overlap stdio (no cross-node socket, no PHI weakening)
```

Two rules inherited from `README.md` §4a and `DESIGN.md` §5.1, and they are absolute:

1. **Inventory is derived from Slurm, never stored.** A state file goes stale the instant a job ends.
2. **Policy state is not inventory state.** The hold-off record (§6.3) *is* a file, and it must be —
   it records a decision the fleet made, which Slurm cannot tell you. Do not let rule 1 delete it.

---

## 4. File layout

Everything user-space, everything tracked, no new runtime dependencies.

```
libr-local-llm/
  bin/
    fleet                       # the one client command
  fleet/
    __main__.py                 # supervisor entry point
    slurmview.py                # squeue/scontrol parsing -> typed records
    inventory.py                # what the fleet holds, derived each cycle
    policy.py                   # caps, idle release, the yield ladder, hold-off
    backends.py                 # engine adapters; ollama first
    relay.py                    # P4b only: the srun stdio relay
  slurm_jobs/
    fleet_supervisor.sbatch
    fleet_ollama.sbatch         # parameterized replacement for ollama_serve.sbatch
  config/
    fleet.json                  # declarative desired capacity, caps, timeouts
```

**Interpreter: `/usr/bin/python3.11`, named explicitly.** `/usr/bin/python3` is 3.9 on these nodes
and lacks `tomllib`; the venv on `PATH` belongs to PSYCH-ASR and must not be a dependency of the
serving layer. Standard library only — no pip install, nothing to break on a node that has not
been set up.

**Config is JSON, not TOML**, matching `config/opencode.json`, so the 3.9-vs-3.11 question never
becomes load-bearing.

**`config/fleet.json` needs a `.gitignore` exception.** The repo ignores `*.json` wholesale with
named exceptions for `config/opencode.json` and `config/claude-settings.json` — a PHI belt-and-
braces rule. Add `!config/fleet.json` in the same block, or the config silently never gets
committed.

**State lives outside the repo:** `FLEET_STATE`, defaulting to `~/.local/state/fleet`. The repo is
public (`README.md` header) and holds no runtime state. Create it in `bin/fleet` on first use.

---

## 5. P1 — the supervisor, the chain, and the kill switch

Ship this first. It is the piece the user actually asked for, and it is testable with no GPU at all.

### 5.1 The job

`slurm_jobs/fleet_supervisor.sbatch`:

```
#SBATCH --job-name=fleetd
#SBATCH --partition=c3_short          # tier 20, PreemptMode=OFF. See §2.1. Never c3.
#SBATCH --time=0-08:45:00             # under the 9 h cap with room for a clean handoff
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1             # allocates 2; there is no smaller unit (§2.2)
#SBATCH --mem-per-cpu=4G              # per-CPU, so it does not silently buy more CPUs
#SBATCH --no-requeue                  # the chain handles restarts; a requeue would fork it
#SBATCH --signal=B:TERM@120           # B: signals the batch shell, not the steps
#SBATCH -o slurm_jobs/logs/fleetd_%j.out
#SBATCH -e slurm_jobs/logs/fleetd_%j.err
```

No `--gres`. The supervisor never touches a GPU.

`--signal=B:TERM@120` is what gives the supervisor two minutes to drain before Slurm kills it.
The `B:` prefix is mandatory — without it the signal goes to the job steps and the batch shell
never sees it. Trap it in the script and in Python (`signal.SIGTERM`), and on receipt: stop
acquiring, publish a final inventory, exit 0.

The script sources `~/.bashrc` **before** `set -e` (`README.md` §7.6) and scrubs `SLURM_*` before
any nested `sbatch` (`README.md` §7.19). Both are non-negotiable and both have already cost this
repo a debugging session.

### 5.2 The chain

At startup, before entering the loop:

1. **Check the kill switch.** If `${FLEET_STATE}/STOP` exists, log its contents and exit 0. Do this
   first, before anything else, or `fleet down` cannot beat a pending successor to the punch.
2. **Check for a duplicate.** `squeue -u $USER -n fleetd -t RUNNING -h -o %i`. If any id other than
   our own is running, log and exit 0. This is the anti-fork lock and it needs no lockfile — Slurm
   already knows.
3. **Submit the successor**, once: `sbatch --parsable --dependency=afterany:$SLURM_JOB_ID
   --kill-on-invalid-dep=yes ...` with `SLURM_*` scrubbed. Skip it if a `fleetd` job is already
   PENDING.

`afterany` fires on *any* termination — walltime, node failure, `scancel`, a crash. That is the
property that makes the chain a restart mechanism rather than just a rollover. It is also why the
STOP check in step 1 has to be the first thing: `fleet down` cancels a generation, the successor
starts anyway, and the STOP file is what turns it around in two seconds.

The pending successor sits in the queue for ~8.75 h. Pending jobs are not billed, so this costs
nothing but a visible line in `squeue`. Leave it visible; a hidden restart mechanism is worse.

### 5.3 The kill switch

`${FLEET_STATE}/STOP`, containing one line: an ISO timestamp and who or what wrote it.

Checked at supervisor startup, at the top of every cycle, and by `fleet up` (which refuses to start
while it exists). `fleet down` writes it *first*, then cancels the PENDING `fleetd`, then the
RUNNING one, then drains and cancels the backends. In that order — reversing it races the chain.

`fleet up` removes it. Nothing else does.

This works when `squeue` is unreachable, when the supervisor is wedged, and when the node it was
on has vanished. A kill switch that depends on the thing it kills is not one.

### 5.4 Backstop resurrection

The chain covers everything except "the chain itself died and nothing noticed" — a `scancel -u` by
an admin, a scheduler restart that flushes the queue, a bad deploy.

Add a systemd `--user` timer on the §2.1/§2.2 pattern already in this repo (`README.md` §2.1 for
why `Persistent=true` is load-bearing and why cron is not available): once a day, if `STOP` is
absent and no `fleetd` job exists, submit one. Tracked copies in `config/`, same as
`colibri-pull` and `harden-claude`, for the same reason — a documented timer whose script is not
tracked rebuilds into a dead unit.

This is a backstop, not the mechanism. If it is firing regularly, the chain is broken; find out why.

### 5.5 The loop

One action per cycle (`DESIGN.md` §5.1). Cadence 30 s — not "every few seconds", which is
`DESIGN.md` §14.8's anticipated trap: a supervisor polling `squeue` hard across six nodes is rude
in a smaller way than squatting, and an admin notices it before we do.

```
every 30s:
  if STOP exists                      -> drain, publish, exit 0
  observe   = read squeue + heartbeats           (never a state file)
  desired   = read config/fleet.json
  decide    = policy(observe, desired, holdoff)  -> at most ONE action
  act       = submit | drain | cancel | nothing
  publish   = write inventory.json atomically (write temp, rename)
  log       = one line per decision, WITH ITS REASON
```

"With its reason" is a requirement, not a nicety. `DESIGN.md` §5.1: when somebody asks why the
fleet took a node at 3 a.m., the answer has to exist.

### 5.6 P1 exit criteria

Do not start P2 until all four pass.

1. `fleetd` survives two walltime rollovers — three generations, >18 h of continuous service — with
   no human action and no gap longer than the queue's start latency.
2. `fleet down` stops it within 30 s and **no** generation restarts afterwards. Verify by leaving it
   alone for an hour and checking `squeue`.
3. `scancel` on the running generation, with `STOP` absent, results in the successor taking over.
4. Killing the supervisor never affects a backend. Start a backend by hand, kill the supervisor,
   confirm the backend is still serving, restart the supervisor, confirm it adopts it rather than
   duplicating it. (`DESIGN.md` §5.1: killing the supervisor must never be the thing that takes the
   service down.)

---

## 6. P2 and P3 — backends, caps, and giving them back

### 6.1 Backend management (P2)

Replace the two hand-written sbatch files with one parameterized `fleet_ollama.sbatch` taking model
and profile through `--export`. Keep `ollama_serve.sbatch` and the `ollama-*` commands working
untouched throughout — they are proven, and `DESIGN.md` §8 says the fleet commands are additive.

Each backend job gains one thing the current ones lack: **a heartbeat.** A background loop inside
the sbatch writes `date +%s` plus the node name into
`${FLEET_STATE}/backends/<jobid>.hb` every 30 s, alongside `ollama serve` in the foreground.

The heartbeat is how the supervisor health-checks a backend on another node **without an `srun`
step per backend per cycle**. NFS home is mounted everywhere; a file read costs the scheduler
nothing. Staleness over 120 s means unhealthy.

Read the **contents**, never the mtime. NFS attribute caching will lie to you about mtime for
several seconds; the timestamp written inside the file cannot.

Readiness stays what it already is: grep the stderr log for `Listening on`, after truncating it
(`README.md` §7.17), and refuse to report success unless `AllocTRES` contains `gres/gpu=`
(`README.md` §7.10 and §4a). Never report success from a submission (`DESIGN.md` §7.4).

Standing limits, all from `config/fleet.json`, all enforced every cycle:

| knob | proposed default | why |
|---|---|---|
| `max_c3_nodes` | 2 | six exist; the fleet never gets all six regardless of how idle it looks |
| `max_accel_bookings` | 0 | opportunistic only, and only via `fleet up --big` (§11 decision 3) |
| `idle_release_minutes` | 30 | one level up from ollama's 20-minute VRAM keep-alive: this releases the *node* |
| `accel_idle_minutes` | 10 | the scarcest thing on the cluster gets the shortest leash |
| `idle_exit_minutes` | 120 | the supervisor's own exit when it holds nothing (§2.3) |
| `cycle_seconds` | 30 | §5.5 |

"Idle" means no request has reached the backend, which the supervisor learns from the ollama access
log (`[GIN] ... POST /v1/chat/completions` lines in the job's stdout — visible in the existing logs
today) rather than by polling the API. Reading a log costs nothing and does not itself count as
activity, which polling would.

**P2 exit criteria.** Cancel a backend by hand: a replacement is up and `fleet status` reports the
change without being asked. Leave a replica untouched past `idle_release_minutes`: it is released.
Set the config to ask for more replicas than `max_c3_nodes` allows: the cap holds and the supervisor
logs that it is holding it.

### 6.2 The yield predicate (P3)

A foreign pending job counts as **blocked by us** only when every one of these holds:

- `user != $USER`
- `state == PENDING`
- `reason ∈ {Resources, Priority}` — **`BeginTime` is excluded and this is the filter that matters**
  (§2.4: on the day this was written, every pending job on the cluster was `BeginTime`)
- its partition is one of `c3`, `c3_short`, `c3_accel`
- its ask includes a GPU (`tres-per-node` contains `gpu:`, or `ReqTRES` contains `gres/gpu`)
- it has held that state for ≥ 120 s — a job about to start does not need our help
- the fleet currently holds ≥ 1 GPU in a partition that overlaps its own

Treat the two reasons differently. `Resources` means the scheduler cannot find what the job needs
and is the strong signal: yield immediately. `Priority` means something outranks it, which may have
nothing to do with us: yield only if it persists ≥ 10 minutes **and** we hold ≥ 2 nodes. Both
thresholds are config knobs.

Cross-check with `squeue --start`, which gives Slurm's own estimated start time. A job with a start
estimate inside the next few minutes does not need a yield.

We will sometimes yield for nothing. `DESIGN.md` §6.1 already settled that trade: yielding
occasionally for nothing is correct against being the group that has to be emailed.

### 6.3 Drain, then cancel, then hold off

Yielding is two steps and never one (`DESIGN.md` §6.4). Mark the backend draining so no new work is
routed to it, let in-flight generations finish, **then** cancel. A yield that kills a generation
mid-stream will be reported as "the local model is unreliable", and the report will be correct.

Release order is the ladder in `DESIGN.md` §6.2, unchanged: idle vLLM replica, idle ollama server,
`c3_accel` booking, busy vLLM replica, colibrì last. In P3 only the ollama rungs exist.

Then the hold-off, which is the fleet's first real bug waiting to happen (`DESIGN.md` §6.5 and
§14.1): the supervisor releases a node, its own convergence loop notices it is below target, and
re-submits — beating the pending job it was trying to help.

`${FLEET_STATE}/holdoff.json`, one record per released resource class:

```json
{"c3_short:gpu1": {"job": "2070999", "user": "someone", "until": 1757450000, "released": 1757448200}}
```

The rule: **do not re-request that class until the triggering job is no longer PENDING, and in no
case sooner than `holdoff_floor_minutes` (default 15).** Whichever is later. If the job is still
pending an hour on, it was never blocked by us — expire the record and let the loop regrow, logging
that the yield did not help.

This file is the exception to "keep no state file" and §3 rule 2 explains why: it records a decision
the fleet made, and Slurm has no memory of it.

### 6.4 Proving the yield works, when the cluster will not cooperate

§2.4 means the yield path may not fire for weeks. `DESIGN.md` M3's exit criterion — "demonstrably
yields a node to a pending foreign job" — cannot be manufactured, because we cannot submit as
another user.

Test it with our own second job behind an explicit flag: `fleet test-yield`, which flips the
`user != $USER` filter off for one run. Submit a GPU job of our own while the fleet holds every
eligible node, watch the supervisor detect it as blocked, watch the drain, the cancel, the hold-off
record, and the refusal to re-acquire until our test job starts. Then check that the hold-off count
of "reacquisitions that beat the job they yielded to" is **zero**, which is `DESIGN.md` §13's
stated bar.

Instrument every real yield permanently: the triggering job id, whether it subsequently started,
and how long after. `DESIGN.md` §13 lists that as the fleet's central unmeasured claim. It stays
unmeasured until this logging exists.

**P3 exit criteria.** The `fleet test-yield` sequence completes with a clean drain, a correct
hold-off, and no early reacquisition. The `BeginTime` filter is verified against the live queue:
with 20+ `BeginTime` jobs pending, the supervisor yields nothing.

---

## 7. P4 — the front door

`DESIGN.md` §5.4 leaves this open and it is the only genuinely hard problem in the plan. Backends
bind loopback on their own node, which is the PHI control, and loopback does not compose across
nodes.

### 7.1 P4a — attach, don't route (ships first, works today)

`fleet code` is `ollama-code` with the node lookup widened: instead of finding *the* ollama job, it
reads the published `inventory.json`, picks the backend serving the model asked for, and
`srun --overlap`s the opencode TUI onto that node. Everything else — the `SLURM_*` scrub, the
resident-model adoption, the session flags — carries over unchanged from `bin/ollama-code`.

What the user gets: one command, no node names, no ports, no job ids. What they do not get: a
session that survives its backend being yielded. When the node goes, the TUI goes.

That is less bad than it sounds, and the reason is already documented in `README.md` §4a: opencode's
session store is on NFS home and readable from every node, so `fleet code -s <id>` resumes on
whichever node can serve it. The loss is the attach, not the work.

**Ship P4a. It is a small diff against a proven script and it makes the fleet usable.**

### 7.2 P4b — the srun stdio relay (the recommended real answer)

The insight `DESIGN.md` §5.4 misses: the router does not have to open a cross-node socket, because
`srun --overlap` already gives us a process on the backend's node with its stdin and stdout piped
back to us. Slurm is the transport.

```
   client node                            backend node
   ------------------------------         ---------------------------
   opencode  ->  127.0.0.1:11600          (relay_remote.py)
                 fleet-router  ----srun --overlap stdio---->  127.0.0.1:11500 ollama
```

`fleet-router` binds loopback on whatever node the *client* is on and speaks the OpenAI-compatible
HTTP that opencode already talks to. Per backend it holds one long-lived
`srun --jobid=<b> --overlap -n1 /usr/bin/python3.11 -u fleet/relay_remote.py` and exchanges
length-prefixed frames over its stdio. The remote end makes the local HTTP call and streams frames
back; SSE chunks become a frame sequence.

Why this is the right shape:

- **No listening socket on any network interface.** The PHI control in `README.md` §4 and §7.20 is
  unchanged, not weakened. Nothing to authenticate because there is nothing to connect to.
- **No SSH.** `README.md` §7.16: SSH between compute nodes is not reliable here, `srun --overlap`
  is.
- **The session survives a backend swap.** The router re-establishes the relay against the new
  backend; opencode never notices its endpoint moved.
- **One step per backend, not per request.** Step launch is paid once.

Risks, all measurable in P0: step launch latency and reliability under load; stdio buffering (use
`-u` and explicit flushes, never rely on line buffering through srun); the relay dying with the
backend, which the router must detect and rebuild; and step accounting churn against slurmctld.

**P4b exit criteria.** Median added latency under 100 ms on a short completion, measured against
the same prompt run directly on the backend's node. A session that survives a deliberate `scancel`
of its backend, with the fleet regrowing underneath it, and the user noticing only a pause.

### 7.3 What we are NOT doing, and it needs to stay that way

`DESIGN.md` §5.4 option C — bind backends to the node's cluster interface with a bearer token — is
the conventional answer and it is a **deliberate weakening of the current PHI control**. It is not
a config edit and the assistant does not get to make it. It is decision 1 in §11.

---

## 8. P5 — the second and third engines

Unchanged from `DESIGN.md` M0 and M2. Two additions from the live cluster:

**vLLM** installs user-local into a conda prefix; `pypi.org` and `github.com` both answer from the
login node, so nothing about the install is blocked. Run it as single-GPU replicas, not shards
(`DESIGN.md` §4.2) — no NVLink, so tensor parallelism pays an all-reduce tax on every layer, and a
replica can be surrendered one at a time where a four-GPU job cannot.

**colibrì has a resource shape nobody has costed yet.** `DESIGN.md` §4.1 puts it on one A40 with
~500 GB of RAM. On this cluster, `MaxMemPerCPU=12000` (§2.2) means a 500 GB memory ask **drags at
least 42 CPUs along with it** — nearly half a node's cores, for a job whose CPU work is real but
nowhere near 42 cores' worth. That is precisely the ask that `DESIGN.md` §6.3 says schedules badly
and blocks other people. Measure the actual RAM floor before committing to the placement, and
expect the answer to change §4.1.

Do not start P5 until P1–P4a are shipped and the fleet has run unattended for a week.

---

## 9. Verify these before writing code (P0)

Cheap, and every one of them can invalidate something above. A day, at most.

| # | test | what it settles |
|---|---|---|
| 1 | Fill a `c3` node's CPUs with a tiny job, then submit a `c3_short` job needing the same CPUs. Watch for state `S`. | §2.1 — whether the preemption inference is real. **Submitting jobs touches a shared queue: confirm with the user first, keep it to one idle node and five minutes.** |
| 2 | Read `AllocTRES` off a live `ollama_serve` job. | §2.2 — the real CPU cost of the current files |
| 3 | Job A submits job B with `--dependency=afterany:$A`; `scancel` A; confirm B runs. | §5.2 — the chain |
| 4 | `--signal=B:TERM@120` with a trap in the batch script. | §5.1 — whether the drain window exists |
| 5 | Write a heartbeat on one node, read it from another; time the delay; read contents and mtime separately. | §6.1 — whether the heartbeat is trustworthy and by how much |
| 6 | Time 20 `srun --jobid --overlap` step launches. | §7.2 — the relay's latency budget |
| 7 | `scancel --signal=TERM` a running `ollama serve`; does it exit cleanly and finish an in-flight generation? | §6.3 — whether drain is possible at all |
| 8 | `squeue` every 30 s for an hour from a compute node; watch for scheduler complaints or throttling. | §5.5 and `DESIGN.md` §14.8 |

Record every result in this file under the relevant section, replacing the *inferred* labels with
*measured* ones and the date. An unverified inference that has quietly become an assumption is how
`DESIGN.md`'s own §14 traps get paid for twice.

---

## 10. Documentation duties

The repo's convention (`README.md` header, `DESIGN.md` preamble) is not optional and it is easy to
skip when the code works:

- **Durable facts graduate into `README.md`** when a phase is built *and verified* — not when it is
  written. Architecture only: no results, no model-quality claims. Sizes, ports, walltimes and
  resource asks belong there.
- **Delete the corresponding entry from `DESIGN.md`** as each piece lands. That file documents what
  is *intended*; leaving built things in it is how the two documents stop meaning anything.
- **§2.1 goes into `README.md` §1 and §7 as soon as P0 test 1 settles it**, whether or not the fleet
  ever ships. It is a live trap in advice the README currently gives.
- **§2.2 corrects the CPU-ask argument in `README.md` §4** and the numbers in `DESIGN.md` §6.3.
- **New traps go into `README.md` §7** in the existing voice: what happened, why it was invisible,
  what the fix was.
- **Commits carry no assistant attribution.** `.githooks/commit-msg` strips it, and
  `AI_INSTRUCTIONS.md` §9 says never add it. The hook is the enforcement; the rule is the reason.
- **Never push without being asked** (`AI_INSTRUCTIONS.md` §9). Offer, do not act.

---

## 11. Decisions the user has to make

The assistant does not get to default these. Ask once, record the answer here with a date, and move
on.

1. **Does a non-PHI plane ever bind a network interface?** (`DESIGN.md` §5.4 option C.) The plan
   says no and routes everything through §7.2's relay. Saying yes buys a conventional HTTP endpoint
   and costs the strongest control we have. If yes, it needs the two-fleet split `DESIGN.md` §5.4
   recommends — one router serving both planes is how they get confused.
2. **How many of the six `c3` nodes may the fleet hold?** Plan proposes 2.
3. **May the fleet book `c3_accel` on its own, or only on explicit request?** Plan proposes explicit
   only, via `fleet up --big`, with a 10-minute idle release. compute306 is the only four-GPU node
   and somebody else was on it while this was written.
4. **Permanent supervisor, or idle-exit?** Plan proposes `idle_exit_minutes: 120` because of §2.3.
   A truly permanent daemon is one config line and roughly doubles our recent-usage number.
5. **Which model is the default fast tier?** Plan proposes `qwen3-coder:30b` — it fits one A40 with
   room for a real context, and six nodes can serve it. A larger q8 model that still fits 46 GB is
   a reasonable alternative and nobody has measured the trade here.

---

## 12. What "done" looks like

The user types `fleet code` on any node, including the login node, and gets a TUI against a local
model in under a minute. They close the laptop. Overnight the fleet releases everything it holds and
the supervisor exits. In the morning `fleet code` brings it back. If a colleague's GPU job goes
pending on `Resources` at 2 p.m., the fleet drains a replica, gives the node back, and does not take
it again until that job is running — and the log says so, with the job id, when anybody asks.

Nothing in that paragraph requires an administrator, a login-node daemon, or a person watching.
That is the whole deliverable, and it is achievable.

What it is not is Fable on a leash. See §1.
