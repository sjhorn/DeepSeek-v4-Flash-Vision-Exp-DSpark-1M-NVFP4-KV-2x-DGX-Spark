# INCIDENTS.md — what went wrong, why, and how to recognise it next time

Each entry carries the symptom, the root cause, the fix, and the **signature** — the thing to grep
for or look at when it happens again. Known issues (live constraints rather than past events) are
at the bottom.

The boot-metrics section for the recovery boot after the watchdog incident lives in
`BOOT-METRICS.md`, with the other boots.

> Moved verbatim from `STATUS.md` during the 2026-09-20 doc split.

## Incidents
### The boot sentinel survived the boot — `set -e` aborted its own cleanup (2026-09-20)

**Found by the test restart that was meant to confirm the sentinel works.** It did work: 363s cold
boot, **0 failed watchdog polls**. But the start script exited without removing
`/tmp/dspark-booting`, so the watchdog stayed **held off after the boot had finished** — blind,
with the cluster healthy and nobody counting.

**Root cause, reproduced with the exact code:**

| condition | result |
|---|---|
| `DROP_PID` unset | sentinel removed — ok |
| `DROP_PID` set, process already dead | **sentinel SURVIVED** |

`cleanup_on_exit` runs under `set -e` and opened with a bare
`[ -n "$DROP_PID" ] && kill "$DROP_PID" 2>/dev/null`. In production the page-cache reclaim **is**
active, so `DROP_PID` is set, and the wait loop already killed that subshell on success — so `kill`
returns non-zero, `set -e` aborts the function, and the `rm -f` on the next line never runs.

**The pre-deploy sandbox test passed because it exercised the `DROP_PID`-unset branch.** It tested
the path that could not fail. A trap that cleans up two things must be tested with both of them
present, not just the one that is convenient to simulate.

**Fix.** `if` instead of `&&`, and `|| true` on everything that can fail, with the reason recorded
inside the function. Every command in an exit trap must be failure-proof.

**Blast radius was bounded by design**, which is the one part that went right: `SENTINEL_MAX_AGE`
(900s) means a stale sentinel expires on its own. In practice it was removed by hand at 16:40 and
the watchdog logged `boot sentinel gone -- resuming normal polling` one poll later. The API stayed
200 throughout and nothing was ever at risk.

**Signature.** `ls -l /tmp/dspark-booting` when no start script is running — from a script file, or
`pgrep -f` will match the ssh command line carrying the pattern and tell you one *is* running when
none is. That trap cost time here too.

### Restarting the watchdog left the cluster with ZERO watchdogs (2026-09-20)

**Hit while deploying the boot sentinel below.** `pkill` the old watchdog, confirm `pgrep` reads 0,
start a new one — and the new one exited immediately with
`another watchdog already holds /tmp/dspark-watchdog.lock`. Net result: **no watchdog at all**, and
the message looks exactly like the singleton working correctly.

```
before: 1 watchdog(s)
after kill: 0 — starting one
now running: 0  (MUST be 1)
[15:37:37] another watchdog already holds /tmp/dspark-watchdog.lock -- exiting
```

**Root cause: `pgrep` and the lock do not go out at the same time.** The lock lives on fd 9, held
for the life of the process (`exec 9>$LOCK_FILE; flock -n 9`). Between SIGTERM and the fd actually
closing, `pgrep -cfx` already reads 0 while the flock is still held — and any child that inherited
fd 9 (the `sleep` in the poll loop) holds it too, and `pgrep -fx "bash ./watchdog-dspark.sh"` never
matches a `sleep`. Checked 40s later: nothing held the lock, confirming a teardown race rather than
a leak.

**This is a worse failure than the one being fixed.** A watchdog that restarts a healthy boot is
loud and recoverable. A cluster silently running with no supervisor is neither — nobody finds out
until an engine death goes unattended.

**Fix: wait for the LOCK, not for the process table.** The readiness condition is "can I take it",
which is exactly what the next instance will ask:

```bash
pkill -fx "bash ./watchdog-dspark.sh"
for i in $(seq 1 30); do flock -n /tmp/dspark-watchdog.lock true 2>/dev/null && break; sleep 1; done
flock -n /tmp/dspark-watchdog.lock true || { echo "ABORT: still held"; exit 1; }
setsid nohup ./watchdog-dspark.sh >> watchdog.log 2>&1 < /dev/null &
sleep 4; pgrep -cfx "bash ./watchdog-dspark.sh"      # MUST print 1
```

It took 1s on the retry. **Always assert the count is 1 afterwards** — this is the whole reason the
failure was caught rather than shipped.

**Signature.** `another watchdog already holds` in `watchdog.log` **immediately followed by no
further lines**. The same message during normal operation (a genuine second instance being refused)
is followed by the first instance continuing to log polls.

> The restart checklist in [`../CLUSTER.md`](../CLUSTER.md) says to confirm `pgrep` prints 0 before
> starting. **That check is necessary but not sufficient**, and this is why.

### A cold boot reached 7 of 8 watchdog failures — 60s of margin (2026-09-20)

**Symptom.** None visible. The cluster booted and served normally. This was found in
`watchdog.log` while recording the boot, not from any alert.

**What happened.** Host timestamps are CEST (UTC+2); the engine logs UTC. Aligned:

| local (CEST) | UTC | event |
|---|---|---|
| 10:57:51 | 08:57:51 | watchdog poll fails — **1/8** |
| 10:58:04 | 08:58:04 | container starts (worker 08:58:03) |
| 11:03:32 | 09:03:32 | KV cache sized, 2,510,051 tokens |
| 11:03:51 | 09:03:51 | **7/8** |
| 11:04:51 | 09:04:51 | API answers → `API recovered (was at 7/8 failures)` |

**A 407s cold boot against a 480s threshold left exactly one poll of margin.** Had weight load run
60 seconds slower — well inside the documented 250–600s range — the watchdog would have issued
`stop` into a healthy boot, which is the signature that boot-looped the cluster for two hours on
2026-09-19.

**An earlier episode the same morning reached 6/8** (09:48:50–09:54:50 CEST), ending exactly when
`/tmp/start.log` records `Minimal chat request succeeded`. So there were two boots on 2026-09-20 and
**both ran with a live watchdog counting against them.**

**Root cause is not the threshold; it is that the watchdog cannot tell "dead" from "not up yet",
and nothing tells it a boot is in progress.** The 2026-09-19 fix raised `FAIL_THRESHOLD` 3 → 8,
which buys 480s — but a cold boot is 250–600s, so the two windows still overlap at the top of the
range. The manual-restart checklist exists precisely because of this, and it was not followed here:
the watchdog was never stopped (`pgrep` confirms one instance, PID 59439, running throughout).

**Signature.** `grep "API recovered (was at" watchdog.log` — any recovery at 6/8 or higher is a
near miss. At 8/8 there is no log line saying "I restarted a healthy boot"; you see a `stop` in the
middle of a weight load instead.

**FIXED the same day — boot sentinel, deployed and verified live 2026-09-20 15:38Z.**

The start script now states its intent instead of the watchdog inferring it. It creates
`/tmp/dspark-booting` after every preflight and before the first compose call, refreshes the mtime
on each wait iteration, and removes it via its EXIT trap. The watchdog skips the poll **and resets
its failure count** while that file is present and fresher than `SENTINEL_MAX_AGE` (900s).

**The count reset is the load-bearing half:** a manual restart's `stop` runs *before* the start
script creates the file, so failures accumulate first and must be discarded, not merely paused.

Verified on the running watchdog, not just in a sandbox:

```
[15:39:15] boot in progress (/tmp/dspark-booting, 45s old) -- holding off, failure count reset
[15:40:15] boot sentinel gone -- resuming normal polling
```

Sandbox matrix beforehand (dummy stop/start scripts, so a threshold hit could not touch the real
cluster): no sentinel → 9 failed polls and the threshold trips; fresh → 0 polls, never trips;
stale 2h → correctly ignored; **appearing mid-count → 3/4 then reset**, which is the manual-restart
case. Sentinel lifecycle: removed on exit 0, exit 1, `set -e` and SIGTERM; left only on SIGKILL,
which is exactly what `SENTINEL_MAX_AGE` bounds. A preflight failure leaves no sentinel at all.

**`FAIL_THRESHOLD` was deliberately NOT raised.** It is a guess against a 250-600s boot, so raising
it only moves the overlap and delays genuine death detection by four minutes.

**Rollback:** `local-ops/rollback/` on the head — **not** `/tmp`, which a reboot wipes (the
2026-09-19 `.pre-singleton` copy was sitting there and has been moved too). Or set
`BOOT_SENTINEL=/nonexistent` to disable the hold-off without reverting anything.

> **Do not read "the watchdog has never fired wrongly" as evidence a threshold is sufficient.** It
> came within one poll on 2026-09-20 and nobody noticed until the log was read.

### Four concurrent watchdogs boot-looped the cluster for two hours (2026-09-19)

**Symptom.** After an engine death at 14:01 the cluster never came back. `/v1/models` refused
connections for over two hours; the container was `Up 2 minutes` every time it was checked, always
dying around the safetensors weight-load stage.

**Root cause — not the engine, and not the watchdog's logic: there were FOUR watchdogs.** Started
15:04:18, 15:04:45, 16:04:10 and 16:04:36 (the 15:04 pair came from background jobs of an earlier
session; none were started by the investigation running at the time). A **single** watchdog is
safe — its restart is blocking (`stop`, then `start` to completion, then a 900s cooldown), so it
cannot interrupt its own boot. With several, instance B's 3-failure timer (~180s) expires *inside*
instance A's boot (250–600s) and issues `stop` mid-weight-load. The boot can never finish.

Four concurrent `start-deepseek-v4-flash-dspark.sh` processes were also running, fighting over the
same compose project.

**Fix.** `pkill -fx "bash ./watchdog-dspark.sh"` plus the surplus start scripts — **no stop/start
was issued**. The in-flight boot then completed by itself in ~6 minutes: API 200 at **16:10:42**.

**Signature to recognise it next time.** Container `Up <a few> minutes` with `RestartCount=0` but
a `StartedAt` that keeps moving, the log stuck in weight load, and `watchdog.log` showing
`start: curl: (7) Failed to connect` lines at *two different cadences* — that is two start scripts
running at once. Count the watchdogs first: `pgrep -afx "bash ./watchdog-dspark.sh"`.

> **`pgrep -f watchdog-dspark.sh` matches the shell you typed it in.** So does the `[w]` bracket
> trick if the pattern text is on the same command line. Use `pgrep -fx "bash ./watchdog-dspark.sh"`,
> and put any such check in a **script file**, not on an `ssh` command line. A guard written inline
> reported "REFUSING: 2 watchdogs already running" when there were none.

**Hardened the same day** (script-only, no container restart — `watchdog-dspark.sh` on the head,
backup now at `local-ops/rollback/watchdog-dspark.sh.pre-singleton`, moved there 2026-09-20 —
it had been in `/tmp`, which a reboot wipes):

1. **`flock` singleton** on `/tmp/dspark-watchdog.lock` (`LOCK_FILE` overrides). A second instance
   exits immediately. **Verified live:** the second start printed
   `another watchdog already holds /tmp/dspark-watchdog.lock -- exiting` and the count stayed 1.
2. **`FAIL_THRESHOLD` 3 → 8** (~480s vs a 250–600s cold boot), so it no longer stops a boot it did
   not start. **Verified:** `watchdog.log` now logs `restart after 8 consecutive failures`.
   Still stop the watchdog before a manual restart — the checklist in
   [`../CLUSTER.md`](../CLUSTER.md) stands.
3. **The start pipeline is guarded** (`set +e` … `PIPESTATUS[0]`). Previously `set -euo pipefail`
   meant a failing start script killed the watchdog outright, making the
   "will retry after cooldown" branch unreachable dead code and leaving the cluster unsupervised
   exactly when it needed a supervisor. **Not yet exercised** — it needs a genuinely failing start.

**Rollback:** `cp local-ops/rollback/watchdog-dspark.sh.pre-singleton <repo>/watchdog-dspark.sh`, then restart the
watchdog.

### Engine death: NCCL collective timeout (2026-09-19 14:01)

```
[rank0] ProcessGroupNCCL.cpp:1653  Terminating the process after attempting to dump
        debug info, due to collective timeout or exception.            14:00:49
EngineCore  Worker proc VllmWorker-0 died unexpectedly, shutting down executor.  14:01:14
```

Preceded twice by `shm_broadcast: No available shared memory broadcast block found in 60 seconds`.
All subsequent requests returned `EngineDeadError` 500s.

From the input dump at the moment of death: **2 running requests at 131,023 and 112,943 computed
tokens**, a 12-token decode step, and **`kv_cache_usage = 0.335`** — so **not** KV exhaustion, and
not the long-prefill traffic the prefix-cache investigation was generating (36.7K prompts,
`max_tokens=4`). This is the anatomy `VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=1800` was adopted for:
the worker hangs, the collective times out, rank 0 terminates itself.

**Not established:** whether concurrent load contributed. The box was contended at the time
(probe deltas blended x4.3, one probe took 65s). Recorded as an open question, not a cause.

### The watchdog will sabotage a manual restart (2026-09-18)

`watchdog-dspark.sh` restarts the cluster after 3 consecutive failures at a 60s poll — **~180
seconds** — while a cold boot takes 250–600s. So a watchdog left running during a manual
stop/start tears the cluster down mid-boot and starts it again underneath you. This did not bite
on 2026-09-16 only because the watchdog was dead at the time.

**Always stop the watchdog before a manual restart, and start it again once `/v1/models`
answers:**

```bash
kill $(pgrep -f "bash ./watchdog-dspark.sh")
./stop-deepseek-v4-flash-dspark.sh && ./start-deepseek-v4-flash-dspark.sh
setsid ./watchdog-dspark.sh >> watchdog.log 2>&1 < /dev/null &
```

**The pattern self-matches — and with `pkill` that is destructive.** An SSH command line
containing `watchdog-dspark.sh` is itself a process matching `-f watchdog-dspark.sh`:

- `pgrep -f watchdog-dspark.sh` reports a **false positive** — it finds your own check. Cost: you
  believe the watchdog is up when it is not. Bit us three times on 2026-09-18.
- `pkill -f watchdog-dspark.sh` **kills your own SSH session** (exit 255), mid-sequence, possibly
  between "stop cluster" and "start cluster". Cost: a half-finished restart.

Always use a bracket class so the pattern cannot match itself:

```bash
pgrep -f "[w]atchdog-dspark.sh"      # honest check
pkill -f "[w]atchdog-dspark.sh"      # safe kill
ps -eo pid,cmd | grep "[w]atchdog"   # equivalent
```

The same trap applies to any `pgrep`/`pkill` over a script name you also typed in the command —
`hmmt_eval.py`, `bootmon.sh`, `mirror.sh` all hit it during this work.

### Watchdog was dead for three weeks (found 2026-09-16)

`watchdog-dspark.sh` was not running, and `watchdog.log`'s last entry was **2026-08-23 14:32**.
So from 2026-08-23 to 2026-09-16 nothing polled `/v1/models` and no automatic restart was
possible; any hang in that window needed manual intervention. Restarted 2026-09-16 (PID 2194182).
It dies silently — nothing alerts on its absence. `start-cluster.sh` is the only thing that starts
it, and we had been starting with `start-deepseek-v4-flash-dspark.sh`. **Check
`pgrep -af watchdog-dspark.sh` after every start.** Launch it detached or it dies with the SSH
session: `setsid ./watchdog-dspark.sh >> watchdog.log 2>&1 < /dev/null &`.

### Head unreachable from the Mac (2026-09-16, not a fault)

A firewall blocks the Mac → head path; the worker's port 22 is open. Work around it with
`ssh -o ProxyJump=shorn@spark-da08 shorn@192.168.0.120` (also works for `scp`). Ping succeeding
while port 22 times out is the signature — do not read it as a head hang. Verified the head was
healthy throughout (`models:200`) via the jump host.

### Cross-session prefix reuse: real sessions pay a full cold prefill (2026-09-19)

**Symptom.** Every new Claude Code session starts cold — ~26s of prefill discarded — even though
two sessions in this repo share 99.4-99.6% of their rendered turn-0 prompt. Measured on real
headless sessions, n=3 independent cold heads, **0.0% every time** (26.1s / 25.9s / 31.6s). Within
each pair the `system` hash and conversation key are identical.

**Core observation.** A head written by a real multi-turn session is unretrievable **2 seconds**
after that session ends (0.0%, 22.77s cold prefill, clean delta). A head written by a single
synthetic request survives **5+ minutes**, including through a 777K-token burst of co-tenant
traffic. During the session the head *is* retrievable — turns 1-6 hit 67-99%.

**Two corrections to earlier entries in this file and CLAUDE.md:**

1. An earlier entry claimed cross-session reuse "works at 99.7%" and that there was no defect.
   **Wrong.** Every 99.7% came from synthetic probes; real sessions never reuse.
2. An earlier claim of an "extent rule" (match the whole cached extent or get zero) was also wrong
   and **is still wrong** — lookup is genuinely monotone, `floor(shared/256)*256`, 0 of 26
   exact-token points returned zero. That part of the original correction stands.

**Root cause of both wrong conclusions — one measurement error, worth internalising:**

> **Read the SECONDS, not the hit%.** Two probes that appeared to prove "the head is alive" were
> actually **cold prefills that re-created it** (22.31s, 22.48s, both blended). Every 99.7%
> reading after them was measuring the probe's own work, not the session's. A warm ~42K head
> answers in ~0.7s; ~20s+ is a miss whatever the ratio says.
>
> Corollary: **a probe that misses rebuilds what it was measuring.** You get exactly one
> cold/warm datum per session — hence one run per time-point.

**Eliminated, each with a clean control** (do not re-test without new evidence): prompt bytes
(raw diff 99.64% shared; Patch 12 fingerprints identical across both sessions), session B's real
body (99.7%, 3/3), `max_tokens` 4 vs 32000 and `stream` (2x2, all 99.7%), transport direct vs
tap→mTLS→proxy (99.7% both), session growth to 97K (99.7% before and after), generation/decode
(99.4% after a 388-token generating request), time/pressure eviction (5 min survival), Patch 6 /
`SWA_RECYCLE` / `PROTECTED_FRACTION` (offline A/B identical in four cells; a grow-then-free
session sim reproduces nothing in any arm), and vllm#42948 (does not reproduce — **no upstream
report filed**).

**NOT established: the mechanism.** It is something in a real multi-turn session's lifecycle the
offline harness does not model — chunked prefill across turns, async scheduling, spec-decode
rollback, or preemption under the co-tenant's 285-315K-char requests. Cheapest next probe: a
**single-turn** real session plus a 2s probe, which isolates "multi-turn" from "real session".

**Cost of the defect:** ~26s and ~41,700 tokens of prefill per session start, plus the same on
every subagent and post-compaction turn. **No restart was taken and nothing was deployed.**
Artefacts: `local-ops/xsess/` (see `FINDINGS.md`), `local-ops/kvsim/`.

### Moving the effort prefix to the tail: cache win confirmed, termination risk found (2026-09-19)

**Cache side, settled, no GPU** (`/tokenize` on a real 114K-char captured turn-0): the `high` text
is 79 tokens; at position 0 it shares a **1-token** prefix with `low`, at the tail it shares
**24,854 of 24,857**. A mid-conversation tier switch recomputes 24,856 tokens today, 3 if moved.

**Behaviour side, piloted (n=3), and it is not a free win.** Harness
`local-ops/hmmt-effort-20260916/hmmt_tail.py` — no patch, no restart: `reasoning_effort:"low"`
suppresses the encoder's injection, and the byte-identical `high` text (verified against the image
via `--verify-text`) is appended to the end of the user message instead. Grader imported from
`hmmt_eval24.py`, so results are comparable to the 2026-09-16 run.

| arm | correct | truncated | out tokens | think chars |
| --- | --- | ---: | ---: | ---: |
| `off` | 1/3 | 1 | 26,520 | 0 |
| `high-front` | **3/3** | 0 | 12,917 | 32,420 |
| `high-tail` | 2/3 | **1** | 30,473 | 71,878 |

Problems 1 and 2: tail matches front within ±5% on reasoning volume with **identical answers** —
the instruction is plainly not ignored from the tail. Problem 3: front answered correctly at 14,142
think chars; tail produced **54,318** (3.8x) and ran to the 24,000-token cap with no answer.

**Reading:** recency *strengthens* the instruction, so `high` at the tail behaves like `max` at the
front — and `max`'s documented failure is exactly runaway-to-cap (8/12, 33% truncation vs `high`
11/12). The cache win is real; the cost may be termination.

**Weak on its own, deliberately stated as such:** n=1 on the failure; `temperature=0` is documented
as non-deterministic here (the `off` arm gave 0 truncations at a 12k cap and 3 at 24k on identical
prompts); and problem 3 is the hard one — `off` ran away on it too. The pilot also **lacked a `low`
control arm** (thinking on, empty prefix, no tail text), which is what `high-tail` would degrade to
if ignored; it has been added to the harness for the full run.

**Not adopted. No patch written, no restart taken.** Next step if pursued: full 12-problem run with
`--arms off,low,high-front,high-tail`, ~55-100 min of decode contention.

### Tier switches are invisible to `API-12` — and cost a 100% re-prefill (2026-09-19)

Prompted by the user switching a live session from auto to manual (opus only, no sonnet) and
asking whether the model name in the prompt was the cause. **The mechanism is real, and it is
ours, not Anthropic's.**

Patch 9 maps the served model name to `chat_template_kwargs`; `deepseek_v4_encoding.py` then injects
a reasoning-effort prefix at render time. Patch 12 hashes **before** that injection
(`anthropic_serving_inline_system.py:908`), so it is blind to it. Measured via `/tokenize`
(CPU-only, no GPU/KV impact), one body, five tiers: default/haiku/**sonnet = 21 tokens, identical
token ids**; **opus = 100**; fable = 113. The divergence is at **token index 1**, so a tier switch
invalidates the entire prompt, not a suffix.

**Correction to the entry below.** That entry concluded the live session's two full-prefill misses
were "eviction, not invalidation" because head/tools/sys were constant across all 69 requests.
**Constant hashes do not establish that** — a sonnet↔opus switch leaves all three identical while
changing the prompt from token 1. The eviction reading is now one of two live hypotheses, not a
finding.

**It cannot be settled from the existing logs**: the model name appears in no log line — not Patch
12, not the access log, not the throughput or spec-decode metrics. Options, cheapest first:

1. **The running live tail is already a natural before/after** — auto (mixed tiers) until ~18:30
   local, manual/opus-only after. If MISS turns stop, the tier hypothesis is supported at no cost.
2. **Tap the next session** (`prompt-tap.py` records `body["model"]`); only works for a session
   launched through it.
3. **Add `model=` to the PREFIX_WATCH line** — closes the blind spot permanently, but it is a
   bind-mounted `.py` change and so **needs a restart**. Bundle with any Phase B restart.

**First before/after datum, same session, same boot:**

| mode | span | turns | MISS | partial | HIT |
| --- | --- | ---: | ---: | ---: | ---: |
| **auto** (classifier at sonnet, session at opus) | 15:05-16:14 UTC | 69 | **2** | **8** | 59 |
| **manual** (opus only) | 16:17-16:33 UTC | 29 | **0** | **0** | **29** |

Suggestive, not yet conclusive: the auto-mode misses ran at roughly one per 35 minutes, so 16
clean minutes is under one expected interval. The partials vanishing too (8 -> 0) is the stronger
half of the signal. The live tail keeps accumulating.

**The classifier was found in the log, and it is NOT the invalidation path.** Conversation
`c32c3255d746`: 9 requests, **no tools**, **73,519 rendered chars every time** (≈20,422 tokens),
14:48-15:14 UTC — stateless and repeated, i.e. the auto-mode permission classifier. (CLAUDE.md's
114,476 figure is the RAW body; 73,519 is what survives the billing-header strip and
`normalize_system_prompt`.) It is its **own conversation**, so it can never move the main
conversation's head, and Patch 9d already forces `thinking:false` on it (Claude Code sends
`{"type":"disabled"}` on classifier calls), so it pays no effort prefix either. **Its only cost is
KV footprint** — ~20.4K tokens per call, competing with a 104K-token session. That makes eviction,
not invalidation, the more likely reading of the auto-mode misses after all.

**Do NOT strip the served aliases to "fix" caching (assessed 2026-09-19).** They are labels on one
engine — `--served-model-name` takes a list, same weights, same KV pool — so they cost the cache
nothing. The cost is the **effort prefix differing between tiers**, and only when a tier switch
happens **inside one conversation**. Removing `claude-sonnet-5` specifically is strictly worse: the
classifier 404s, Claude Code retries on the session model, and every permission check becomes a
full opus-effort reasoning pass — the documented "auto mode is slow / stalls" symptom.

**Operational rule that falls out of this:** haiku and sonnet are mutually free (byte-identical
rendering), but **never mix haiku/sonnet with opus/fable, or opus with fable, inside one
conversation** — each switch is a full re-prefill.

### Phase A: the client gap closed — beta path acquitted, and MULTI-TURN is required (2026-09-19)

Follow-up to the entry above, run against the **same boot** (`StartedAt 2026-09-19T14:04:41Z`,
`RestartCount=0`). **No restart; the cluster was not touched.** `cache-probe.py --selftest` 3/3
PASS before any measurement.

**A1 — the tap now records request headers, and the blind spot is closed.** `prompt-tap.py` logged
only `{ts, path, body}`, so in every analysis to date we had *never seen* what Claude Code actually
sends in its headers. It now records `headers` too, with `authorization` / `x-api-key` /
`proxy-authorization` / `cookie` redacted (`REDACT_HEADERS` + `_safe_headers()`). Forwarding is
unchanged. What a real session sends:

```
POST /v1/messages?beta=true
anthropic-version: 2023-06-01
anthropic-beta: claude-code-20250219,interleaved-thinking-2025-05-14,
                context-management-2025-06-27,prompt-caching-scope-2026-01-05
X-Claude-Code-Session-Id: <uuid, unique per session>
User-Agent: claude-cli/2.1.104 (external, cli)   x-app: cli   X-Stainless-*: ...
```

Body-side, for the record: 4 `cache_control: ephemeral` blocks (system[1], system[2],
messages[0].content[2]), `context_management: {"edits":[{"type":"clear_thinking_20251015","keep":"all"}]}`,
`thinking: {"type":"enabled","budget_tokens":31999}`, and **`metadata.user_id` carries a per-session
`session_id`**. No `cache_salt` anywhere.

> `prompt-caching-scope-2026-01-05` and a per-session `X-Claude-Code-Session-Id` looked like exactly
> the mechanism we were hunting — a per-session cache scope. **They are not** (A2). Note also that
> `prompt-tap.py` forwards only `content-type`, `anthropic-version`, `anthropic-beta` and `accept`,
> so `X-Claude-Code-Session-Id` never even reaches the engine in a tapped session — yet tapped
> sessions fail. It could not have been the cause.

**A2 — the beta path and headers are ACQUITTED.** `transport-probe.py` rebuilt with four arms, all
sent **direct to the engine** so transport is held constant and only the path and headers vary.
Prime the head, then one fresh-tail request per arm:

| arm | path | headers | hit | secs | delta |
| --- | --- | --- | ---: | ---: | --- |
| control | `/v1/messages` | minimal | 99.6% | 0.77s | clean |
| beta-path | `/v1/messages?beta=true` | minimal | 99.6% | 0.76s | clean |
| beta-header | `/v1/messages` | + captured `anthropic-beta` | 99.6% | 0.77s | clean |
| full-live | `/v1/messages?beta=true` | full captured header set | 99.6% | 0.76s | clean |

41,984 hit tokens on 42,166 input, identical in all four; `queries == input_tokens` on every row.
So the `?beta=true` query param, the `anthropic-beta` header (`prompt-caching-scope-*` included)
and the complete live header set **do not** move the head or scope the cache. The `cache_salt`
hypothesis (`kv_cache_utils.py:524-532` — the salt chains through every later block hash) is
**disproven from the outside**: no salt is being set on any client-reachable path.
Artefact: `local-ops/xsess/beta-arms.json`.

**A3 — a SINGLE-TURN real session's head SURVIVES. Multi-turn is required to trigger the death.**
`death-probe.sh` now takes `[delay] [workload] [tag]`; run with `workload-trivial.txt` (one prompt,
"reply with exactly the word: ok", no tools, no file reads), each run forced onto a head nobody has
seen via the unique repo-root scratch file:

| run | session | turn-0 | probe at +2s | verdict |
| --- | --- | --- | --- | --- |
| `a3single` | 1 agent turn, 0 tools | 0.0% hit, 42,157 q (cold) | **99.6%, 0.57s, clean** | **ALIVE** |
| `a3single2` | 1 agent turn, 0 tools | cold | **99.6%, 0.57s, clean** | **ALIVE** |
| *(prior, multi-turn)* | 6 tool-using turns | cold | 0.0%, **22.77s**, clean | dead |

Read the seconds: 0.57s is a warm head, not a probe rebuilding one. n=2, both clean.

**What this buys.** The suspect list collapses from "something about a real session" to
"something a real session does across **turns**". Single-turn real sessions behave exactly like
synthetic probes. Everything that a one-turn session already exercises is therefore out: the real
client, the beta path, the full header set, `cache_control` blocks, `context_management`,
`thinking: enabled`, the per-session `metadata.session_id`, streaming at `max_tokens=32000`, and a
cold turn-0 prefill followed by a re-reference of the same head. What is left is genuinely
multi-turn: **chunked prefill across turns, spec-decode rollback accumulated over turns, or the
free/allocate churn of repeatedly extending one conversation's block chain.**

**Caveat, stated plainly.** The paired multi-turn positive control **on this boot** was started and
then stopped at the user's request (our probes were evicting a co-tenant session's cache). So the
"dead" row above is from earlier today on the same boot, not run back-to-back with the two "alive"
rows. Until that control runs, the A3 conclusion rests on a same-boot but not same-sitting
comparison. Everything else here is self-contained.

**Phase B (server-side `enable_kv_cache_events`) was NOT executed and is NOT authorised.** It needs
a 250-600s cold boot and a compose change; it remains the specified follow-up if the multi-turn
control confirms A3.

### Live session: head stable, misses are EVICTION (2026-09-19)

A running interactive session reported the classic symptom — a few cache hits, then a full reset
with a long prefill. A session already in flight **cannot be tapped** (`ANTHROPIC_BASE_URL` is
fixed at launch), so it was measured from the server log alone: Patch 12's per-request line plus
the engine's 10s prompt-throughput gauge. New tool: `local-ops/prefill-attribute.py`.

Result over 70 minutes, conversation `fe9a3621a5e6`, 69 requests, 323,411 → 360,718 chars
(~90K → ~100K tokens): **head/tools/sys hashes identical on all 69 requests**, and
**59 cached HIT / 8 partial / 2 full-prefill MISS**.

**So the resets are eviction, not head movement.** The prompt was a strict prefix every turn and
two turns still re-prefilled from cold. Context: 11 conversations in the window (two above 150K
tokens, one at 580K chars), KV usage 34-55% of the 2,510,942-token pool, `num_preemptions_total`
still 0. Not exhaustion — prefix-cache block turnover.

**Also: our own Phase A probes were part of that pressure**, which is what prompted the user to
flag it. All probe processes were stopped and confirmed gone (`ps` clean) before this analysis,
which adds no load at all.

**A live tail is running** (`local-ops/prefill-watch/live-20260919-1823.log`), started 2026-09-19
18:23 local, so the next eviction is captured with the concurrency that caused it rather than
reconstructed afterwards. `prefill-attribute.py --follow` reads `docker logs -f -t` and judges each
turn ~30-40s after it lands. Verified cost on the head: **0.21s wall, 35% of one core of 20, 25 MB
RSS** per 90-minute read, journald driver, read-only; the parser is stdlib-only with no network and
no engine calls, so it cannot itself evict anything. `--follow` was self-tested by replaying the
captured hour through it and reproducing file-mode's verdicts.

**Correction made in-session.** The first read of this log blamed head movement, citing four
`prefix-watch.py` "HEAD MOVED" alerts. Those were all in bucket `1bf734cbb2a0` — the documented
`user0` collision — which had absorbed `cache-probe --selftest`, the A2 beta arms and both A3
sessions. They were our probes, not the live session. Two lessons, now in
[`../PREFIX-CACHE.md`](../PREFIX-CACHE.md):
`prefix-watch.py` ignores `docker -t` timestamps (it uses its own clock, so backfilled logs read
as one instant), and a bucket is only one conversation if its `len` grows monotonically.

### `local-ops/baseline-20260914/pristine-single_type_kv_cache_manager.py` was NOT pristine (fixed 2026-09-19)

It was a byte-for-byte copy of `patches/patch6-single_type_kv_cache_manager.py` (1,504 lines,
65,425 bytes, contains `_RECYCLE_ENABLED`) — captured by reading the path *through* the
bind-mount, which returns the patched file. Replaced with the genuine 1,421-line image file; the
old one kept as `MISLABELLED-was-patched-...py`. `pristine-block_pool.py` and
`pristine-kv_cache_coordinator.py` were re-checked and are genuine. See
`local-ops/baseline-20260914/PRISTINE-README.md`. Always re-pull with
`docker run --rm --entrypoint cat <image> <path>`.

### A push makes a single-file bind mount STALE, and `check-local-patches.sh` reads the stale copy (2026-09-20)

**Symptom.** Immediately after `git push head local/main && git push worker local/main`, with both
nodes reporting the new commit and 0 dirty, `scripts/check-local-patches.sh` reports `FAIL` for
rows whose code is demonstrably present in the pushed file.

**Root cause.** A `:ro` bind mount of a single FILE binds that file's **inode**. `updateInstead`
checks out by REPLACING files, so the working tree gets a new inode and the container keeps the
old one. Measured on `spark-45ea` right after the `MNT-8`/`MNT-9` push:

```
host      inode 7864609   patches/patch6-single_type_kv_cache_manager.py   1,749 lines
container inode 7864612   .../v1/core/single_type_kv_cache_manager.py      1,506 lines
```

The container is not reading a cached copy — it is reading a *different file* that no longer has a
name in the working tree. `docker exec … cat` confirms the old content.

**Consequences, in the order they bite:**

1. **Expected `FAIL`s after a push are not a defect.** A newly added marker cannot appear in the
   container until the container is **recreated** (a restart re-binds the path). Read
   `check-local-patches.sh` between a push and the next restart as "what the RUNNING engine has",
   never as "what the branch has" — for that, read the file, or `regen-local-patches.sh --check`.
2. **It also means the reverse**: a row that passes after a push may be passing on the *old* file.
   The check is a statement about the running container, full stop.
3. It is a stronger version of "a push is not a restart": not only are imported modules pinned, the
   files themselves are.

**What is NOT affected:** the flags file (`/var/tmp/vllm-kv-flags/flags.json`), because the compose
mounts its **directory**. A directory mount follows replacement, which is exactly why `MNT-8` and
`MNT-9` are gated on a file in a mounted directory rather than on a mounted file.

### `check-local-patches.sh` could not fail on a marker containing a space (2026-09-20)

**Symptom.** A newly added row, `MNT-8|v1/core/kv_cache_utils.py|def prepend_n|…`, reported `OK`
against a container whose `kv_cache_utils.py` had no `prepend_n` at all — `grep -c` said `0` while
the checker said `OK`.

**Root cause.** `dk()` ran `ssh -n "$REMOTE" docker "$@"`, and **ssh hands the command to a remote
shell that re-splits it**. The marker's space made it two arguments:

```
grep -qF -- def prepend_n FILE      # pattern "def", files "prepend_n" (absent) and FILE
```

so the row passed on any file containing `def`. Three existing rows had space-bearing markers and
had been passing the same way: `API-9d` (`def client_disabled_thinking`), `API-10b`
(`def recover_dsml_arguments`), `API-11b` (`def leading_system_boundary`). All three do genuinely
hold — verified after the fix — so nothing was actually missing, but the backstop could not have
told us.

**Fix.** `dk()` now `printf '%q'`-quotes every argument before handing it to ssh, and the two new
rows use space-free markers as well. **Signature to recognise it again:** a `check-local-patches.sh`
row that passes while `docker exec <c> grep -c '<marker>' <file>` returns 0.

**The general lesson** — a fail-closed check is only fail-closed if you have watched it fail. This
one was added as a backstop after a near-miss, and had a whole class of rows it could not fail on.

### A synthetic benchmark ranked the tuning knob backwards (2026-09-21)

**Symptom.** `MNT-10`'s dose-response curve, run against a controlled victim/attacker pair, ranked
**512 as the best** cap (2.53 tok/s victim, 0.48 s worst stall). On live traffic 512 is the
**worst** of the three settings tested — aggregate decode median **37.5 tok/s against 2048's
60.7**, starved windows three times deeper (1.0 vs 4.5 tok/s), plus scheduler-loop stalls of **40 s
and 80 s** with no stats line emitted at all.

**Root cause — the benchmark scored one half of a two-sided trade.** The cap trades *sharing*
(other requests get budget) against *duration* (the prefill itself takes more steps). The synthetic
test had exactly **one** decoder to protect and measured it directly, while the duration cost —
already visible as **+49% prefill time at 512** — only showed up as a number in a column, not as
harm. On real traffic that duration is the dominant term: everything stays degraded half again as
long, and at 512 a 144K prefill becomes 282 chunks each paying fixed per-step cost (attention
metadata, indexer top-k, kernel launches) at ~140K context.

**The deeper error: the benchmark's victim was never the common case.** Splitting live low-decode
windows by `Running` shows most of them have **`Running: 1`** — the single request in the engine is
*itself* prefilling. Nobody is being starved; somebody is waiting on their own prompt. A smaller
cap makes that strictly worse. The synthetic test could not contain this case by construction,
because it always had a victim decoding alongside the attacker.

**Signature.** A low `Avg generation throughput` with `Running: 1` is **not** starvation and
`MNT-10` will not help it. Only `Running >= 2` windows are this patch's problem. Check that split
before touching the knob.

**What to do instead.** Treat a synthetic curve as evidence that a mechanism *works*, never as a
guide to its production value. Tune on real traffic, split by `Running`, and prefer a long
alternating A/B — the four-block one run here was **confounded** (the 2048 arm drew 3.2x the
prefill tokens of the 1024 arm, 525,191 vs 166,182) and had to be discarded.

**Two claims retracted in the same session**, both from reading too few samples: an apparent decode
regression at `Running=4` (12.5 tok/s) was **n=2** and reads **70.6** at n=7; and the CUDA-graph
hypothesis built to explain it is unsupported.

### `MNT-10`'s gate read the HOST path and silently did nothing (2026-09-21)

**Symptom.** The `MNT-10` A/B returned **identical numbers in both arms** — victim 0.95 vs 0.93
tok/s, attacker prefill 87.3 s vs 87.0 s. It reads like "the knob has no effect", which is the most
expensive wrong conclusion available: it would have retired a fix that works.

**Root cause.** The gate hardcoded the **host** path:

```python
_MNT10_FLAGS = "/var/tmp/vllm-kv-flags/flags.json"     # WRONG inside the container
```

The host keeps the file at `/var/tmp/vllm-kv-flags/`, but the compose mounts that directory at
**`/etc/vllm-kv-flags`** (`docker-compose.dspark.yml`), which is what `patch6` reads via
`_FLAGS_PATH`. Inside the container the host path does not exist, so every read raised, fell back
to "no opinion", and returned the boot value. **Both arms ran at 2048.**

**Why it was invisible.** The patch logged only when an override was *applied*. A gate that can
never see an override is indistinguishable from a gate with nothing to override — same silence.
`check-local-patches.sh` passed too, because the marker was present; the marker proves the file is
mounted, never that its logic reaches anything.

**What exposed it.** Asking for positive proof rather than absence of failure: `grep MNT-10` in the
container log after deliberately setting the flag. Zero lines where there should have been an
override line. Re-running against the path the code actually read then produced clean separation
(0.33 → 1.55 tok/s), confirming both the bug and the mechanism.

**Fix.** Use the same expression as `patch6`, env override included, and **log once when the gate
first executes** — naming the path and whether it exists — so "armed but idle" and "dead" stop
looking alike:

```python
_MNT10_FLAGS = os.environ.get("VLLM_KV_FLAGS_FILE", "/etc/vllm-kv-flags/flags.json")
```

**Signature.** After a restart, `docker logs <container> | grep 'MNT-10: armed'` must print exactly
one line, and it must say `present`. If it says `ABSENT — live override unavailable`, the directory
mount is missing and only the boot value applies.

**The general rule.** Any patch that reads a file from inside the container must take the path from
the same place the existing patches do. A wrong path fails **silently** — the documented failure
mode for bind mounts in [`../CLUSTER.md`](../CLUSTER.md) — and a patch with no positive liveness
signal cannot be distinguished from one that is working and has nothing to say.

**Cleanup this created.** Testing drove the gate through a file written *inside* the container at
the wrong path. That file vanishes with the container, but the host flags file had also been
written with `long_prefill_token_threshold: 0`, which would have **disabled the cap at the next
restart** once the path was fixed. The key was removed so the value falls through to the boot
default. Check for it: the host flags file should carry **no** `long_prefill_token_threshold` key.

### "Another session rewrote our flags" — MISDIAGNOSED. It was `kv-flags.sh` itself (corrected 2026-09-21)

**The entry below is wrong about the cause and is kept only as a record of the error.** No other
session was involved on either occasion. `local-ops/kv-flags.sh` carried two example lines in its
header that had **lost their leading `#`**, above `set -uo pipefail`:

```
  bash local-ops/kv-flags.sh swa_recycle 0          # line 12 — no '#'
  bash local-ops/kv-flags.sh pin_static_head 1      # line 13 — no '#'
```

Those were the first executable statements in the file, so **every** invocation ran them —
including the no-argument one whose only job is to *print* the flags. See the fork-bomb entry
below for the mechanism.

**Why it looked like another session.** The original trace captured
`+ bash local-ops/kv-flags.sh swa_recycle 0` looping and concluded someone else was issuing it.
That command was the *script running its own header*. And the flags it left —
`swa_recycle: 0, pin_static_head: 1` — are exactly the arguments on those two lines, which is the
signature to recognise: **if the flags ever read precisely that pair, suspect this bug, not a
colleague.** As the recursion unwinds, each level falls through to the real script and reaches
`ssh`, so the writes really did land on both nodes.

Confirmed 2026-09-21: the bug was present in the file at commit `b1dd333`, i.e. before any of that
day's edits, and reproduced identically at 08:10:47Z — same two keys, same values, both nodes.

**What survives from the entry below:** rules 1, 2 and 4 are good practice regardless of cause, and
rule 4 especially — check `docker exec … cat /etc/vllm-kv-flags/flags.json`, because it proves what
the *engine* sees. What does not survive is the attribution, and the conclusion that a shared box
means unattributable flag changes.

### An experiment's flags were being rewritten by ANOTHER session on the same box (2026-09-20/21) — SUPERSEDED, see above

**Symptom.** Mid-experiment, `/var/tmp/vllm-kv-flags/flags.json` changed on both nodes to settings
nobody in this session had set (`pin_static_head: 1, swa_recycle: 0` — two arms mixed). It happened
again the next morning at 08:08. A trace started here captured a command this session never issued,
looping: `+ bash local-ops/kv-flags.sh swa_recycle 0`. The node reported 3-4 users logged in.

**Cause.** The cluster is shared, and so is the flags file. Nothing about the flags mechanism is
per-session — it is global engine state, like the engine itself.

**Consequences.** Any arm measured while another party writes the flags is void, and *their*
measurement is equally void. Two sessions can also silently interleave arms without either noticing.

**What to do.**

1. **Read the flags immediately before AND after every arm**, and record both in the write-up. A
   changed value between the two invalidates that run.
2. **Set flags explicitly rather than trusting a prior state** — write every key you depend on, not
   just the one you are changing. `kv-flags.sh` merges, so an unwritten key keeps whatever the last
   writer left.
3. **Ask before taking the engine.** It was taken here only after the user said to.
4. Prefer `docker exec … cat /etc/vllm-kv-flags/flags.json` for the final check: it proves what the
   *engine* sees, not what the host file says.

### `kv-flags.sh` fork-bombed the laptop from its own header comment (2026-09-21)

**Symptom.** The Mac becomes unable to fork: `(eval):1: fork failed: resource temporarily
unavailable` on almost any command, intermittently recovering and failing again. `ulimit -u` shows
8000 and a normal `ps` shows only ~450 processes — **because `ps` itself cannot fork to produce the
real count.** Nothing on the cluster is affected; the engine serves normally throughout.

**Root cause.** Two example lines in the script's header had lost their leading `#`:

```
  bash local-ops/kv-flags.sh swa_recycle 0          # line 12 — no '#'
  bash local-ops/kv-flags.sh pin_static_head 1      # line 13 — no '#'
```

They sat **above `set -uo pipefail`**, making them the first executable statements in the file. So
every invocation ran line 12, which re-ran the script, which reached its own line 12.

**Not an exponential fork bomb — an infinitely deep chain**, one child per level, each parent
blocked on a child that never returns. The evidence distinguishes the two:

| observation | meaning |
|---|---|
| consecutive ppids (66037 → 66038 → 66039 …), exactly one child each | a chain, not a tree |
| **6,518** procs with `swa_recycle 0` vs **3** with `pin_static_head 1` | line 12 recurses; line 13 is all but unreachable |
| 8,000-process cap reached in seconds | too fast to catch interactively |

**The no-argument invocation was the dangerous one.** `bash local-ops/kv-flags.sh` with no args
exists purely to *print* the current flags — the most innocuous call in the file — and it detonated
identically. It does not take running an experiment to trigger.

**It reached the nodes.** As the chain unwinds (a child exits when `fork` fails), each level falls
through to the real script and executes it with its own arguments, reaching the `ssh` calls. Both
nodes' flags files were rewritten to exactly `swa_recycle: 0, pin_static_head: 1` — the two lines'
arguments — at 08:10:47Z. **This is what the "another session rewrote our flags" incident above
actually was, on both occasions.**

**It defeats its own cleanup.** The process table is full, so the `pkill` that would fix it cannot
fork either. What works is retrying `pkill -9 -f '[k]v-flags'` until one attempt gets a slot — the
bracket form matters, because `pkill -f kv-flags` also matches the shell you typed it in and can
kill your own session.

**Fix.** Both lines commented, with a note above them recording this. Verified:

```bash
awk 'NR<71 && /^[^#]/ && NF' local-ops/kv-flags.sh | wc -l   # MUST be 0
bash -n local-ops/kv-flags.sh
```

**The general rule this establishes:** in any script here, **executable content must never appear
above `set -uo pipefail`**, and a usage block full of copy-pasteable command lines is exactly where
a dropped `#` becomes self-execution. Present in the file at `b1dd333` and earlier — it was not
introduced by the edits of the day it was found.

### `kv-flags.sh` leaked a stuck `ssh` per call, and exhausted the Mac's process table (2026-09-20) — CAUSE CORRECTED, see above

**Symptom.** `local-ops/kv-flags.sh: fork: Resource temporarily unavailable`, hundreds of lines,
then every local command failed — `echo` included. A single `kv-flags.sh` invocation also hit a
300s timeout with no output.

**Cause.** The script called `ssh` **without `-n`**. Without it ssh reads the caller's stdin, which
never arrives in a non-interactive context (a background job), so the process hangs forever. Each
call leaked one or two stuck `ssh` processes. Combined with the foreign loop above re-invoking the
script, that accumulated until no process could fork.

**Fix.** `ssh -n` everywhere in `kv-flags.sh`. **Signature to recognise it:** a script that works
when typed by hand and hangs when run from a background task or a loop.

**Measured afterwards for reference:** the Mac's limits are `kern.maxproc` 12000 and
`kern.maxprocperuid` 8000; normal usage during this work was ~350 processes. So exhaustion means a
leak, never ordinary load. For a multi-node flag write, one `ssh` per node beats four script
invocations (~16 ssh).

### Decode collapses to ~2 tok/s beside a long prefill — scheduler budget starvation, NOT KV and NOT the cache bug (2026-09-21)

**Symptom.** A real Claude Code session with subagents running reports decode at ~2 tok/s where it
should sit near 30. KV usage looks "fine" (44-67%), so it does not match the KV-exhaustion
signature above.

**Signature to recognise it.** In `docker logs`, a `loggers.py:271` line with **`Running: 2-5 reqs`,
`Avg generation throughput` under ~3 tok/s, and `GPU KV cache usage` well under 90%** — paired with
a `metrics.py:101` line reading **`Drafted: 10 tokens`** for the whole 10-second window. At k=5 that
is **two engine steps in ten seconds**. Neighbouring windows show `Avg prompt throughput` bursting
to 3,000-8,000 tokens/s. `vllm:num_preemptions_total` stays **0** and the prefix hit rate stays
**~94%** throughout — that pair is what separates this from both KV exhaustion and cache loss.

**Measured, 2026-09-20 19:33 -> 2026-09-21 08:09 (696 ten-second windows, 13h of real traffic):**

| | |
|---|---|
| decode tok/s, single request, median | **36.0** |
| decode tok/s per request, Running=5, median | 12.4 |
| decode tok/s per request, Running=5, p10 | **0.5** |
| prefill tokens : decode tokens over the window | **12.4 : 1** (3,046,770 vs 245,665) |
| preemptions | **0** |
| prefix cache hit rate | 93.8-94.2%, flat |
| max KV usage | 71.5% |

The collapse is not a steady state — it is bursty. Mean decode over all busy windows is 37-39 tok/s;
70 of 594 busy windows (12%) fall under 8 tok/s per running request. A worked example, 08:03:05 ->
08:05:15, exactly two minutes: healthy at `GEN 60-80, KV 44%`, then requests of `len=185834` and
`len=185431` arrive (`PREFIX_WATCH`), KV steps up to 62-67%, `Waiting` rises to 3, and `GEN` sits at
**0.2-2.2 tok/s** until it recovers to 39.6 at 08:05:15.

**Root cause — read from the image, confirmed in source, no restart spent.**
`/opt/env/lib/python3.12/site-packages/vllm/v1/core/sched/scheduler.py`:

```python
token_budget = self.max_num_scheduled_tokens          # = max_num_batched_tokens = 8192
while req_index < len(self.running) and token_budget > 0:
    ...
    if 0 < self.scheduler_config.long_prefill_token_threshold < num_new_tokens:
        num_new_tokens = self.scheduler_config.long_prefill_token_threshold
    num_new_tokens = min(num_new_tokens, token_budget)
    ...
    token_budget -= num_new_tokens
```

The loop walks `self.running` **in order** and the budget is shared. `long_prefill_token_threshold`
is **0**, so that clamp is disabled and a request still mid-prefill takes
`min(remaining_prefill, token_budget)` — **the entire 8192**. The `while` guard then fails and every
request behind it in `self.running` is scheduled **zero tokens that step**. A decoding sequence
needs only ~6 tokens; it gets none.

So a ~186K-token prompt whose uncached remainder is tens of thousands of tokens occupies ~1 second
per 8192-token chunk for tens of consecutive steps, and everything queued behind it emits nothing
for the duration. That is the two-minute flat line, and it is why the per-request rate lands near
0.2-2 tok/s rather than the ~2.9 tok/s (one spec-decode step) that co-scheduling would have given.

**`max_num_partial_prefills` cannot help, and not for the reason it looks like.** It reads as `1`,
which suggests concurrent long prefills are already limited. They are not: the field appears **only**
in `engine/arg_utils.py` and `config/scheduler.py` — grep the whole installed package — and is
**never read by any scheduler code**. It is dead config on this build, exactly as
[`../PATCHES-KV.md`](../PATCHES-KV.md) recorded when assessing `co-l/ds4-prefix-cache-fixes`
`02-schedfix`. So there is **no** limit on concurrent partial prefills, which is why several 185K+
requests pile into `self.running` together — and a *single* one is already enough to zero the
budget. Capping per-request tokens per step is the only lever that works here.

**This exonerates `MNT-6c` (CACHE-TEST.md 10, item 1).** The fix is holding under real concurrent
load: hit rate flat at ~94%, zero preemptions, KV never above 71.5%. The removed eviction is not
what is costing throughput here.

**Fix, not yet applied — needs a restart, so it needs a specific ask.** Set
`long_prefill_token_threshold` to ~2048. A long prefill then takes 2048 tokens per step and leaves
~6144 of budget for the decoders behind it, which need a handful each. Costs ~4 steps per 8192
prefilled instead of 1; buys back decode during prefill. Prefer it to lowering
`max_num_batched_tokens`, which would slow prefill without fixing the ordering.

**This is known upstream, and the fix is confirmed on our exact hardware.**

- [MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks#110](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks/issues/110)
  — **2x DGX Spark GB10, TP=2 over RoCEv2, `max_model_len` 1,000,000**, i.e. our rig. Same
  diagnosis, to the same line: "the scheduler allocated `min(remaining, token_budget)` to each
  chunked prefill without limits". A 325K cold prefill froze a warm 325K session for **440 s**;
  `--long-prefill-token-threshold 1024` (at `MNBT=2048`) cut the victim's follow-ups to
  **17.9-24.9 s**, median 19.8 s, zero evictions. Cost: **+10.6%** on the long prefill *under
  contention only* — no measurable penalty solo. They also note a secondary effect we should expect
  and not misread: **cached blocks are lost while a request waits, which looks like a prefix-cache
  failure and is not one.**
- [vllm-project/vllm#54919](https://github.com/vllm-project/vllm/issues/54919) — same symptom class
  on **2-node DGX Spark TP2**: "aggregate decode throughput falls to ~0.5-5 tok/s for 3-7 minutes"
  with KV free and the waiting queue empty. Open, no maintainer diagnosis. **Caution worth heeding:
  that reporter capped prefill at 4096 against `MNBT=8192` and said the slowdown persisted** — a
  50% cap was not enough. That argues for 2048 or lower against our 8192, not 4096.
- [vllm-project/vllm#54145](https://github.com/vllm-project/vllm/pull/54145) (`--min-prefill-chunk-tokens`)
  is a *different* knob for the inverse problem and is **unmerged** and conflicted. Not ours.
- Nothing about this is DeepSeek-V4-Flash-specific — it is generic V1 scheduler behaviour.

**Pre-flight, checked so we do not spend a boot on a silent no-op** (`vllm/config/scheduler.py`):
the `long_prefill_token_threshold = 0` reset at line 229 fires **only for encoder-decoder models**,
which we are not. The `max_num_partial_prefills > 1` branch only *auto-fills* the value when it is
0; it does **not** clear one we set. So an explicit setting is honoured at
`max_num_partial_prefills=1` and does take effect in the running loop.

**But it logs nothing.** The confirming `logger.info` sits inside the `max_num_partial_prefills > 1`
branch, so at our settings there is **no boot-log line proving the threshold took**. Verify it the
other way — `docker logs <container> | grep 'non-default args'` must show
`'long_prefill_token_threshold': 2048`. Treat a missing entry there as the setting not applied.

**Client-side mitigations that need no restart:** fewer concurrent subagents, and smaller subagent
prompts. Each subagent carries its own `tools` array — four distinct `tools=` hashes were live in
the last 300 requests — so each one's first turn is a cold prefill of 100K+ tokens, and those cold
prefills are the input to this starvation.

## Known issues

### NOT an incident: requests that look stuck for 400s with an empty queue (2026-09-22)

**Signature.** Several requests sit in `Running` producing nothing visible for 400s+. Reads as a
stall, a queue or KV pressure; it is a high-effort **thinking pass** decoding normally.

**Tell it apart in one command** — if all three hold, nothing is wrong:

```bash
curl -s http://127.0.0.1:8888/metrics | grep -E '^vllm:(num_requests_waiting|num_preemptions_total)'
#   waiting 0, waiting_by_reason capacity/deferred 0, preemptions 0  -> not a queue
# and the per-request row shows queued_s ~0, prefill_s a few seconds, decode_s = the rest:
docker exec <container> python3 -c "import urllib.request,json; \
  print(json.load(urllib.request.urlopen('http://127.0.0.1:9094/prefill?since=0&limit=20'))['rows'][-5:])"
```

Measured: 76 requests over 120s in the ring, every one `queued_s` **0.00**, `prefill_s` 0.7-7.2s,
`decode_s` the whole remainder at **17-40 tok/s**, 2,187-8,171 generated tokens. `claude-opus-*`
means effort `high`, which averages **8,243 tokens per correct answer** — 235-485s at those rates,
before the first visible character. Full workup and the levers (all per-request, no restart):
[`THINKING-AND-EFFORT.md`](../THINKING-AND-EFFORT.md#silent-400s).

**What a real stall looks like instead:** `Drafted: 10 tokens` per 10s window with generation
throughput 0.0 (`MNT-10`, tuned live), or 0% acceptance at 0.1-0.2 tok/s (KV exhaustion, below).

### KV pool exhaustion under long-context sessions

With 2+ Claude Code sessions building up long conversation context (500K+ tokens each), the KV pool + prefix cache can fill to 99%+, causing decode throughput to collapse to 0.1-0.2 tok/s and draft acceptance to drop to 0%. Symptoms: extremely slow turns, repeated text in output.

Mitigations applied: enabled CUDA graph profiling, and (2026-08) reduced `MAX_NUM_SEQS` 12 to 4 via 6 — **since reverted to 12 on 2026-09-13**, once the sweep showed slots cost KV almost entirely through CUDA-graph capture and capture was capped at 72. The 3.2M-token pool quoted below was the 2026-08 config; the **2026-09-14 boot measured 2,506,193 tokens** (`Maximum concurrency for 1,048,576 tokens per request: 2.39x`), so two sessions at 1M each now use ~80% of the pool rather than 62%. Per-boot variance is ~11-13%, so read the current boot's own figure before drawing conclusions. Practical limits:

| Context per session | Concurrent sessions | Status |
|---|---|---|
| Under 500K | 3-4 | Comfortable |
| 500K-700K | 2-3 | Workable |
| 800K-1M | 2 | At the limit, expect slow prefills |

The 2 GB display reserved memory (BIOS carveout) cannot be reduced below 2 GB on current firmware.

### KV disk-offload is not viable on this model/version (parked 2026-09-14)

`OffloadingConnector` probe failed before model load: incompatible with
`PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` unless the cumem allocator is on (this
requirement is **not** in the vLLM docs). Beyond that, upstream has three open unfixed issues:
vllm#43093 (two AssertionErrors, DeepSeek-V4-Flash + OffloadingConnector, **v0.21.0 = our
version**), vllm#45663 (OOM in `sparse_attn_indexer` past **~120K tokens** — fatal for our 1M use
case), vllm#56772 (MLA+DSA canonical transfers use TP-dependent row sizes). Re-evaluate if
vllm#43093 and vllm#45663 both close. Runbook and staged mounts: `local-ops/kv-offload-probe.md`.

**RE-CHECKED 2026-10-04 — STILL PARKED, and the trigger above needs rewording because one issue
closed WITHOUT being fixed.**

| | state on 2026-10-04 | |
|---|---|---|
| vllm#43093 | **closed as "not planned"**, stale | the crashes are NOT fixed; upstream declined |
| vllm#45663 | **open**, stale, no fix | the disqualifying one |
| vllm#56772 | not re-checked | MLA+DSA TP-dependent row sizes |

So "re-evaluate when both close" would now read as satisfied by #43093 while the blocker is
untouched. **The real trigger is vllm#45663 alone**: the sparse indexer's
`fp8_fp4_mqa_logits` materialises every KV block at once instead of chunking, so with offloading
on it OOMs past **~120K tokens** against a working set of **570K**. Nothing we configure moves
that.

**#43093's crash is worth recording because it names our own topology:**
`gpu_block_size=64 not divisible by hash_block_size=256`. The offload path hashes on 256-token
blocks while one of the five KV groups uses 64 — so it is the HYBRID GROUP LAYOUT that breaks the
transfer, which is also why this is not a knob.

**And the prize is big enough to keep re-checking.** Measured from this boot: KV is
**6.92 KB/token** (16.66 GiB / 2,523,706 tokens), so a 570K prefix is **4.04 GB** — against a
recompute of **~518s**. Breakeven is **7.8 MB/s**; NVMe does 4 GB in **~1.3s**, and both nodes have
**2.9 TB free**, i.e. ~700 such prefixes. That is a ~400x win on the cold path and it would also
make an engine restart stop costing every client a full cold prefill.

### RE-TESTED ON THE BOX 2026-10-07 — two of the three cited issues DO NOT apply to us, and the real blocker is a different line

The engine was actually started with `OffloadingConnector` today, which the
2026-09-14 entry never managed. **It got three steps further and failed on
something else.** Each correction below is from the running engine or from the
source at our own commit (`1967a5627bc3`, 2026-05-27), not from the issue titles.

**The September blocker is CLEARED, and it was a config error on our side.**
`PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` really is refused — vLLM
raises it in `VllmConfig` validation, in terms:

	Value error, KV connector OffloadingConnector is incompatible with
	PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True unless
	enable_cumem_allocator is also enabled.

Setting `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:False` passes validation.
**It must be EXPLICIT AND NON-EMPTY**: the compose uses
`${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}`, and `:-` substitutes the
default when the value is unset **or empty** — so blanking it in `.env.dspark`
silently re-applies `True`. That cost one boot today.

**vllm#45663 is not the disqualifying issue, and is barely an issue.** Its body
is literally `.` — no repro, no diagnosis, one stale-bot comment — and the
mechanism this file attributed to it ("materialises every KV block at once
instead of chunking") **contradicts the code we run**:
`split_indexer_prefill_chunks` already sub-chunks on the query dimension against
a logits budget, and that budget is the env var
`VLLM_SPARSE_INDEXER_MAX_LOGITS_MB` (ours is 256). So "nothing we configure
moves that" is **wrong** — that is the knob. *(It was never reached today, so
whether a long context OOMs with offloading on is still unmeasured.)*

**vllm#43093's Error 1 is already fixed in our build.** Verified by running the
real `resolve_kv_cache_block_sizes` on our five groups in the offline harness:
it returns scheduler **256** / hash **4** (the GCD), and `kv_offload/base.py`'s
assertion passes for all of 256/64/64/4/8. The reported `hash_block_size=256` is
exactly what the *stale* `cache_config.block_size` produced.

**vllm#56772 is CLOSED as completed (2026-09-17)** and concerns
`canonical_layout: true`, a config option that **does not exist** in our build.
Moot either way — but it is evidence upstream has been working in this exact
area since our tree was cut.

#### THE ACTUAL BLOCKER

	File "vllm/v1/kv_offload/tiering/spec.py", line 113, in get_manager
	    assert len(self.gpu_block_size) == 1
	AssertionError

`gpu_block_size` is the per-group tuple, and ours is **(256, 64, 64, 4, 8)**. So
the hybrid group layout *is* what breaks the transfer — this file was right
about that, and wrong about which line enforces it. Note the scheduler side
raised; the **worker** side had already built its connector successfully.

**IT IS NOT A STRAY ASSERT, AND IT MUST NOT BE DELETED.** The assertion sits
immediately before `CPUPrimaryTierOffloadingManager(...)`, which does not use
the value — so it looks removable. It is not:

- `CPUOffloadingSpec.__init__` derives `kv_bytes_per_offloaded_block` as
  `kv_bytes_per_block * self.block_size_factor`, a **single scalar**.
- `block_size_factor` is defined as "number of sub-blocks per block" and drives
  the pointer arithmetic in `kv_offload/cpu/gpu_worker.py`:
  `sub_block_size = tensor.shape[1] // block_size_factor`, then a vectorised
  expansion over `arange(block_size_factor)`.

With five different GPU block sizes there is no single factor. Deleting the
assert yields pointer arithmetic correct for ONE group and wrong for the other
four — **silently corrupt KV that decodes to plausible-but-wrong output**, which
is the same failure class as the `F8_E8M0` dtype risk and is far worse than
refusing to start.

#### What this changes about the plan

Making the offload path per-group aware is **real engineering inside upstream
code**, not a config flip and not a one-line patch. And because upstream has
been actively reworking exactly this (canonical_layout, #56772 completed
2026-09-17) while our tree is from **2026-05-27**, a **version bump is likely the
better route than forward-porting a per-group `block_size_factor`** into a
four-month-old offload path.

**The trigger is no longer "#45663 closes".** It is: does a newer vLLM support a
hybrid (non-uniform block size) KV layout in `kv_offload`? That is the one
question to ask of any candidate version.

#### IT BOOTED, AND THE EQUIVALENCE GATE PASSED -- 2026-10-07 14:17Z

With the kvmgr hybrid shim (`patches/kvmgr_plugin/kvmgr/offload.py`,
`offload_allow_hybrid=1`) the engine started **with the disk tier configured**:

	GPU KV cache size: 3,377,409 tokens
	kvmgr: relaxing TieringOffloadingSpec's single-block-size assert for a
	       HYBRID layout -- block sizes (256, 64, 64, 4, 8), block_size_factor=1
	Created secondary tier #0 (fs_python)
	Created TieringOffloadingManager with primary tier (lru, 510 blocks)
	       and 1 secondary tier(s)

API up, **zero** ValidationError/AssertionError. So there was **no second
uniformity assertion hiding behind the first** -- the four-file code read held.

**THE GATE PASSED, AND IT MEANS MORE THAN IT LOOKS.** Five prompts, greedy,
`temperature 0`, `seed 12345`, 68-220 output tokens, SHA-256 of the generated
text, offload OFF then ON:

	eq1 d7d4d0cd2baab178   eq2 9f02d84f70a01d77   eq3 123a49edf2a743f5
	eq4 9f2d8698b8f378c2   eq5 c561e43b6abfe72a

**All five identical, and the output token counts too (157/79/149/220/68).**

What makes that meaningful rather than vacuous is the transfer counter:

	vllm:kv_offload_total_bytes_total{transfer_type="GPU_to_CPU"} = 19.28 GB

**19.28 GB really moved through the per-group transfer path** -- roughly a whole
pool's worth cycled through a 1.07 GB CPU window -- and the output did not change
by one byte. That is the per-group slicing validated by use, which is the only
way it could be validated. The counter is the thing to check first on any future
run: without it, "the hashes match" would only mean the tier was idle.

#### WHAT IS STILL NOT EXERCISED: THE DISK ITSELF

	transfer_type counters present : GPU_to_CPU only
	files under ~/kvoffload        : 1
	directories under ~/kvoffload  : 17,222
	du                             : 68M  (almost entirely directory inodes)

The fs tier **built its whole fan-out** (`<base>_r<rank>/<hhh>/<hh>_g<group_idx>`)
and wrote essentially nothing. So the CPU primary tier is being cycled hard and
blocks are **not being promoted to disk**. Until that fires, the headline prize
-- a 570K prefix restored in ~1.3 s instead of ~518 s recomputed -- is untested,
and so is the disk round trip's effect on output.

Two candidate reasons, neither confirmed: the GPU pool is at **3.7% usage**
(3.38M tokens, nothing close to pressure), so eviction may simply never reach
the stage that promotes; and `store_threshold` defaults to 0, which is
documented as "no filter" rather than "store everything". Next step is to drive
real pool pressure and watch for a CPU_to_DISK counter or `.bin` files.

#### WHY NOTHING REACHED DISK: O_DIRECT ALIGNMENT. 13,519 errors, zero bytes.

Diagnosed 2026-10-07 without any further traffic, because the data already on
hand ruled out the obvious answer.

**PRESSURE IS NOT THE BLOCKER, and the counter proves it.** The cascade fires on
STORE, not on eviction -- `tiering/manager.py` says so in its own header:
*"Always offload to all tiers -- When a block is stored to the primary tier, it
is cascaded to ALL secondary tiers"*. And the CPU tier had already cycled **~18x
over**:

	CPU tier         510 blocks, 1.07 GB mmap, 2.10 MB/block
	GPU->CPU moved   19.28 GB  =  ~9,167 blocks stored to CPU
	=> ~8,657 CPU evictions, ~9,167 cascade attempts
	   files on disk: 1

So "drive more pool pressure" would have spent 45 minutes re-doing something
that had already happened nine thousand times.

**THE REAL CAUSE.** `tiering/fs/io.py` opens every block with **`O_DIRECT`**:

	fd = os.open(dest, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_TRUNC | O_DIRECT, ...)

`O_DIRECT` requires the length and offset to be multiples of the device logical
block size. Ours are not:

	per-block CPU page : 2,103,552 bytes
	2,103,552 mod  512 : 256     <- NOT aligned (nvme0n1 LOG-SEC is 512)
	2,103,552 mod 4096 : 2,304

So every write is rejected before a byte reaches the file:

	ERROR [thread_pool.py:150] FileSystemTierManagerPython:
	      job 208 block I/O failed: [Errno 22] Invalid argument

**13,519 such errors this boot.** The directory tree (17,222 dirs, including the
`_g3` and `_g4` small-block groups) was built because `mkdir` succeeds; only the
writes fail.

**IT FAILS SAFE, and that is the one piece of luck here.** EINVAL, nothing
written, errors logged loudly, no corruption. Which also means the equivalence
pass above validates the **GPU<->CPU** path only -- 19.28 GB of real per-group
transfers with byte-identical output, which is worth having -- and says nothing
about a disk round trip, because there wasn't one.

**WHAT IT MEANS FOR THE PLAN.** Fixing this is a SECOND patch to the same
four-month-old subsystem (drop `O_DIRECT`, or pad every write to a 512 boundary
and track the real length). We would then be two relaxations deep into code
upstream has **rewritten** -- `gpu_block_size` and `block_size_factor` are gone
from upstream main's `kv_offload` entirely, replaced by per-group
`group_data_refs`. **That materially strengthens the version-bump case over
continuing to patch locally**, and it is the recommendation: ask of a candidate
release not only "is the single-block-size assert gone" but "does its fs tier
write without O_DIRECT, or align its writes".

#### THE CANDIDATE-VERSION READ: v0.31.0 FIXES BOTH OF OUR PROBLEMS NATIVELY

Done 2026-10-07 as a pure read -- no box, no downtime. Every released tag from
**v0.27.0** onward was checked for the three things that decide a bump.

| | ours, 0.21.1rc1.dev339 (2026-05-27) | v0.30.0 / v0.31.0 / main |
|---|---|---|
| `assert len(gpu_block_size) == 1` | **present** -- we shim it | **GONE** |
| `gpu_block_size` / `block_size_factor` | present | **GONE**, replaced by per-group refs |
| `O_DIRECT` EINVAL on our block size | **fatal, 13,519 errors, 0 bytes** | **PROBED, falls back** |
| `nvfp4_ds_mla` in `config/cache.py` | present | **present** |

**ONE of our two shims becomes unnecessary on a bump. THE O_DIRECT ONE DOES
NOT, and the first version of this note said it did.** Corrected the same day,
by reading `_store_block` rather than stopping at the probe's docstring.

*What upstream's probe actually does:* `probe_o_direct(directory)` writes **one
aligned `mmap.PAGESIZE` (4096-byte) page** and catches `OSError`. It answers
*"does this FILESYSTEM support O_DIRECT"* -- for overlayfs, old tmpfs, some NFS,
which its own docstring names. Our ext4-on-NVMe supports it perfectly well, so
**the probe PASSES** and `use_o_direct` comes back `True`.

*And then v0.31 writes exactly as we do:*

	view_slice = buffer.cast("B")[offset : offset + block_size]
	o_direct = O_DIRECT if use_o_direct else 0
	fd = os.open(tmp_path, ... | o_direct, 0o644)
	written = os.write(fd, view_slice)

**No alignment handling anywhere.** `block_size` is written verbatim. So a
2,103,652-byte -- strictly, 2,103,552-byte -- block still fails with EINVAL on
v0.31.0 just as it does here.

**This is an upstream gap, not our version being old.** It only shows on a
geometry whose per-block byte size is not 512-aligned, which ours is not
(`mod 512 = 256`) because it falls out of NVFP4 MLA over a five-group hybrid
pool. A conventional model's per-block size is a clean power-of-two multiple and
never trips it, which is presumably why it has survived.

So `offload_odirect=False` is **not** a stopgap that a bump supersedes -- it is a
fix for something upstream still has. The one thing upstream does better is
keeping O_DIRECT where it genuinely works; ours drops it unconditionally, and
backporting `probe_o_direct` would NOT help us because the probe passes here.

**AND THE WHOLE FILE CANNOT BE BACKPORTED ANYWAY**, which was the first thing
checked: v0.31's `io.py` exports **`batch_store_block` / `batch_load_block`** and
makes the singular forms private, so our `tiering/fs/manager.py` and
`thread_pool.py` callers break immediately. It also optionally imports a
compiled `vllm.fs_io_C` extension absent from our image -- that part degrades
gracefully via `_HAS_FSIO_C`, but the API change does not.

**What a bump DOES still buy**, and it is the larger half: `v0.31.0`'s `tiering/fs/io.py` is 218 lines
against our 101, and it carries a runtime probe for exactly our failure:

	"""Return whether O_DIRECT I/O works in *directory*.
	   O_DIRECT is unsupported on some filesystems (e.g. the overlayfs
	   backing ...), writing a file with it fails with EINVAL. Probe once
	   with an aligned ..."""
	...
	o_direct = O_DIRECT if use_o_direct else 0

So it keeps O_DIRECT where the filesystem supports it and drops it where it does
not -- per directory. **Ours drops it unconditionally**, which is correct but
gives up the performance everywhere. That is a stopgap and should be described
as one.

**The single-block-size assert is gone from EVERY release >= v0.27.0**, so the
hybrid blocker this file called structural was fixed upstream four releases ago.

**`nvfp4_ds_mla` is present in v0.30.0, v0.31.0 and main** -- the dtype the whole
engine depends on survives the jump. *(It read 0 for v0.27-v0.29, but that is
most likely `config/cache.py` not existing at that path then rather than the
dtype being absent; unresolved and not worth resolving, since those are older
than the version we would pick.)*

#### So the recommendation is the BUMP, and the shims are a bridge

The honest cost has not changed and it is large: **0.21 -> 0.31 is ten minor
versions**, we carry roughly a dozen local patches that must each be re-derived
(patch5-8, mnt10-scheduler, two anthropic files, three plugins, dispram), it
needs a Tier-4 image rebuild, and the 64k-page kernel forces the eager
safetensors loader which needs our own F8_E8M0 dtype plugin. Whether
DSv4-Flash-DSpark runs at all on v0.31 is **unknown** and is the first thing to
establish.

What the shims buy in the meantime is a working GPU<->CPU tier today, validated
by 19.28 GB of transfers with byte-identical output -- and the knowledge that
when the bump happens, both can simply be deleted rather than ported.

#### One cost to carry

The CPU primary tier is a **1.07 GB mmap in `/dev/shm`**, which is host RAM.
`MemAvailable` sits at **1.74 GB** with it live. That is the zero-sum cost this
file has warned about all along, now measured: it holds, but there is not room
for the 4 GiB tier the original probe config asked for.

#### What was kept from today's attempt

Rolled back: `KV_TRANSFER_CONFIG` only. **Kept, because each booted cleanly and
is independently useful** — `GPU_MEMORY_UTILIZATION=0.88`,
`KV_CACHE_MEMORY_BYTES=21789705851` (20.29 GiB → **GPU KV cache size 3,377,409
tokens**, concurrency 3.22x, handing ~1.5 GiB back to host RAM),
`PYTORCH_CUDA_ALLOC_CONF=expandable_segments:False`, and
`PROTECTED_FRACTION` unset so `protected_fraction` is governed by the flags file.
Backups: `.env.dspark.bak-pre-kvoffload-*` on both nodes.

**`GPU_MEMORY_UTILIZATION` DOES NOT GOVERN THE POOL while `KV_CACHE_MEMORY_BYTES`
is set**, and the engine says so itself: *"reserved 20.29 GiB … as specified by
kv_cache_memory_bytes config and skipped memory profiling. This does not respect
the gpu_memory_utilization config."* So util is **not** the lever for freeing
memory here; the byte figure is. Util only bounds what the worker *requests*
(0.88 → 108.93 GiB against 115.33 GiB free).


### GPU thermal management

GPU clock pinned to 300-2200 MHz (`nvidia-smi -lgc 300,2200`) on both nodes to prevent thermal shutdown. This does not survive reboots — `start-cluster.sh` reapplies it automatically, but `start-deepseek-v4-flash-dspark.sh` does not.
