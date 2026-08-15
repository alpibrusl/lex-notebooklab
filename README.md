# lex-notebooklab

**A run is a trail, not a score.**

An experiment tracker for the Lex ecosystem. What separates it from
MLflow/W&B is one property: **a recorded experiment is verifiable evidence,
not a trusted claim.** Every run can be bound to the hash-chained trail its
metrics were derived from, and `verify` re-derives those metrics from that
evidence — so "50% denial rate, y-violations eliminated" is something a third
party can recompute, not something the logger asserted.

It is **not a robot tracker**. Anything in the ecosystem that emits a
lex-trail event chain can be recorded and verified here: today a lex-robot
governed rollout and a lex-loom sprint, tomorrow whatever comes next. The
integrity machinery is shared; only the interpretation is per-domain.

```sh
$ notebooklab verify
29229dbd26e2  VERIFIED  (evidence: VERIFIED — digest matches and the hash chain is intact)
    actions                     VERIFIED
    denial_rate_pct             VERIFIED
    denials                     VERIFIED
    move_base.y.violations      VERIFIED
    move_to.x.violations        VERIFIED
```

Those five numbers were not read back from the record. They were recomputed
from a 21-event governed-replay trail, and they match what
[lex-robot](https://github.com/alpibrusl/lex-robot)'s `docs/RL_TRAINING.md`
published for that rollout.

## Why not stock MLflow

The training containers are ephemeral (an uncommitted `mlruns/` dies with
them), headless (nobody opens the UI), and egress-blocked (no hosted tracker).
The durable store is git. And none of those tools can re-derive a claim from a
tamper-evident trail, which is the capability this ecosystem is uniquely
positioned to provide.

## One verifier, many domains

Verification splits in two, and the split is the whole design:

- **Shared, and security-critical.** Is this a well-formed lex-trail? Does
  every event id recompute? Does every `parent` link hold? Does the file's
  digest match what the record committed to? None of this knows or cares what
  the events mean, so it is written once and reused verbatim.
- **Per-domain, and small.** What do these events MEAN? That lives in
  `src/derive/`, one module per evidence kind, each publishing a flat list of
  named integers. `src/verify.lex` only ever looks a key up and diffs it.

A run's evidence entries already carry a `kind`, and that kind selects the
deriver. Adding a domain is a new module under `src/derive/` plus one arm in
`src/derive.lex` — nothing in the record, the store, the verifier or the CLI
changes.

| Evidence kind | Deriver | Publishes |
|---|---|---|
| `replay_trail` | `src/derive/robot.lex` | `actions`, `denials`, `denial_rate_pct`, `<skill>.<axis>.violations` / `.mean_overshoot_milli` / `.max_overshoot_milli` |
| `loom_sprint_trail` | `src/derive/loom.lex` | `nodes_started`, `nodes_accepted`, `nodes_denied`, `denial_rate_pct`, `bounces`, `graph_rejections`, `phases_advanced`, `sprint_success`, `fully_sealed`, `gate.<gate>.denials`, `phase.<phase>.bounces` |

The two domains are more alike than they look: loom's `loom.node.denied` is a
gate refusing an artifact exactly as the robot's grant refuses an out-of-box
reach, and `loom.phase.bounced` counts rework the way overshoot counts
violation.

**Status of the loom side, stated plainly.** The event kinds it reads are
loom's real ones. What loom's `main` does not yet do is hand a sprint trail
over as a standalone artifact — it writes into a SQLite database, which is the
right home for a running sprint and the wrong thing to give a third party.

That is *not* a binding problem: a record commits to the chain's
[head event id](#bindings-what-a-record-commits-to), not to any file's bytes,
so the container is irrelevant and nobody has to keep an immutable file
around. Only the handover is missing. [lex-loom PR #237](https://github.com/alpibrusl/lex-loom/pull/237)
adds it, and its output verifies here unchanged; until that merges the deriver
is proven against a fixture in loom's own event format, and nothing more is
claimed.

## The four verdicts

Collapsing verification to pass/fail would let very different failures look
alike, so the vocabulary is four-valued:

| Verdict | Meaning | Exit code |
|---|---|---|
| `VERIFIED` | Recomputed from the trail and equal to the claim. | 0 |
| `UNVERIFIABLE` | Nothing to check against — no evidence bound, no evidence of a kind any deriver understands, file missing, or the claim names a quantity no trail can settle. | 0 |
| `MISMATCH` | Recomputed and **not** equal. The claim is wrong. | 3 |
| `TAMPERED` | The evidence itself does not hold up: its digest differs from the one recorded, or its hash chain is broken. No claim is scored. | 4 |

`UNVERIFIABLE` is a first-class, honest outcome — not a soft pass. A record
with no evidence reports every claim as unverifiable forever; it never quietly
reads as verified. That is deliberate: several of the early lex-robot attempts
wrote their trails to `/tmp` and have no surviving evidence, and the ledger has
to say so rather than fake a green check.

The exit codes are semantic so `notebooklab verify` works as a CI gate that
distinguishes a bookkeeping error (3) from an integrity failure (4).

## Install and run

Requires the pinned toolchain, `lex` v0.10.10.

```sh
lex pkg install
bash scripts/smoke.sh            # check + fmt + test + the full CLI loop

export NOTEBOOKLAB_STORE=runs.jsonl
./bin/notebooklab record fixtures/entry_attempt4.json
./bin/notebooklab list
./bin/notebooklab verify         # exit 0 / 3 / 4
```

`bin/notebooklab` is a thin wrapper: `lex run` prints a function's return value
but always exits 0 itself, so the wrapper lifts the returned code into a real
process exit status.

## How a claim gets checked

A record's `results` map is **claims**; its `evidence` list is what those
claims are checked against.

1. Find the first bound artifact some deriver understands. None → every claim
   `UNVERIFIABLE`. (A checkpoint digest is legitimate evidence to record but
   settles no claim on its own, so it has no deriver.)
2. Check whatever **bindings** the record committed to (see below). Any
   mismatch is `TAMPERED` — repudiated evidence, not weak evidence — and
   nothing is derived from it. Same stance lex-games' referee takes when it
   disqualifies a forged trail instead of scoring it. Evidence bound by
   *nothing* is `UNVERIFIABLE`, not tampered: it was never committed to.
3. Check the trail's own hash chain: every event id must recompute (via
   `lex-trail`'s `event.compute_id`) and every `parent` must be the previous
   event's id, starting from a root. This catches an edit, a reorder, an
   insertion or a deletion.
4. Hand the events to the deriver for that evidence kind, and diff what it
   publishes against each claim.

### Bindings: what a record commits to

An evidence entry carries two optional commitments, and which one applies
depends on what the artifact is.

| Binding | Commits to | Use for |
|---|---|---|
| `sha256` | the exact bytes | opaque artifacts — a checkpoint has no internal structure to commit to |
| `trail_head` | the id of the chain's last event | **trails** |

`trail_head` is the better binding for a trail, and the reason is the chain
itself: `compute_id` folds the parent id into every event, so the head
**transitively commits to every event before it**. Truncate, extend, edit or
reorder and the head changes.

Two things follow. First, the evidence's *container* stops mattering — the
same chain verifies whether it arrives as a JSONL file, a range of database
rows, or bytes over a socket, which means a producer is not forced to keep an
immutable file around forever. Second, a harmless re-serialization (different
whitespace, different field order) no longer reads as tampering, which a byte
digest would flag as a false alarm.

It is also strictly stronger than chain integrity alone. A **prefix** of a real
trail is a perfectly valid chain — every id recomputes, every link holds, it is
root-anchored — so integrity checks pass. Only the recorded head reveals that
events were dropped:

```
$ notebooklab verify
67802d3f4cd0  TAMPERED  (evidence: TAMPERED — trail head mismatch:
              recorded 8add8b4a511c…, presented chain ends at 406253eadf02…)
```

`notebooklab record` fills `trail_head` in automatically for any evidence kind
that has a deriver, and **refuses to record a trail whose chain is already
broken** — the right place to catch that is at recording time, not months later.
Opaque artifacts get `sha256` filled in instead. Both may be set, and then both
are checked.

**Bounds come from the grant recorded in the trail**, not from constants in the
verifier. lex-robot's `gym_env/xlerobot_usage_log.py` hardcodes `ARM_BOUNDS` /
`BASE_BOUNDS` to mirror the grant, which is correct only until someone changes
the grant. The trail already carries the grant each action was checked against,
so reading it there is correct by construction and lets a third party verify a
run whose grant differed.

### The claim vocabulary — `replay_trail`

Each deriver publishes its own keys; these are the robot deriver's:

| Key | Meaning |
|---|---|
| `actions` | Spatially gated actions (grasp excluded) — `xlerobot_usage_log.py`'s `total`. |
| `actions_all` | Every `execute` event — what the lex-games referee counts. |
| `denials` | Actions the grant denied. |
| `denial_rate_pct` | `denials / actions`, integer percent. |
| `<skill>.<axis>.violations` | e.g. `move_to.x.violations`. Emitted for every axis the trail exercised, so a claim of `0` on a clean axis resolves to `0`, not "cannot say" — which is exactly the "y-violations eliminated" claim. |
| `<skill>.<axis>.mean_overshoot_milli` | Mean overshoot past the granted bound, milli-units. |
| `<skill>.<axis>.max_overshoot_milli` | Worst overshoot, milli-units. |

Distances are integer milli-units, exactly as the trail encodes them
(`x: 499` means 0.499 m); everything else is a plain count. Integers
throughout, so two verifiers always agree bit for bit with no rounding policy
to argue about. Any key no deriver published — a string like
`"eval": "FAILED"`, or a fractional value — is reported `UNVERIFIABLE` with a
reason. A MuJoCo SUCCESS/FAILED verdict has no trail
representation, and inventing a check for it would be worse than admitting it.

## The HTTP door

For when the run happens somewhere this package cannot reach — sb3/PyTorch on
another machine, a CI job, anything that is not already a Lex program. A Lex
caller should use `src/entry.lex` directly; there is no reason to cross a
socket to reach a library in the same runtime.

```sh
NOTEBOOKLAB_STORE=runs.jsonl lex run \
  --allow-effects approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time \
  src/server.lex main
```

| Route | Behaviour |
|---|---|
| `POST /runs` | Submit a run record. `201` + `run_id`, or `400` with a structured error body. |
| `GET /runs` | Summaries of every stored run. |
| `GET /runs/{id}` | One full record, or `404`. |
| `POST /runs/{id}/verify` | Re-derive the claims. Always `200` when the run exists — a MISMATCH is a successful verification that returned bad news. The body carries the verdict and the exit code the CLI would have used. |
| `GET /health` | Liveness. |

Submission goes through the same `entry.ingest` the CLI uses, so a run
submitted here and on the command line validate identically and land on the
**same `run_id`** — it is a content address, so re-POSTing a run is idempotent
rather than a duplicate. Everything that can fail does so before the append,
so a rejected POST leaves nothing behind; `scripts/smoke_http.sh` asserts that
rather than trusting it.

### Logging a run from Python, with no new dependency

The point of the door: `urllib` is in the standard library, so a trainer takes
on nothing to use it.

```python
import json, urllib.request

def log_run(entry, base="http://localhost:8137"):
    req = urllib.request.Request(
        f"{base}/runs",
        data=json.dumps(entry).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())["run_id"]

run_id = log_run({
    "attempt": "4", "series": "usage-informed-finetune",
    "trainer": "sidecar/xlerobot_rl_finetune.py",
    "config": {"timesteps": 100_000},
    "results": {"actions": 16, "denials": 8, "denial_rate_pct": 50},
    # sha256/trail_head are computed server-side when left empty
    "evidence": [{"kind": "replay_trail", "path": "trail.jsonl",
                  "sha256": "", "trail_head": ""}],
    "notes": "", "supersedes": "", "created_at": 1750000000000,
})
```

Evidence paths are resolved **server-side**, so the trail must be readable by
the server — the same filesystem, or a shared mount. Shipping trail bytes in
the request body is the obvious next step and is not implemented.

## Dependency pinning — measured, not assumed

Issue #2 left this open after lex-robot lost two CI days to unpinned
default-branch dependencies picking up the `[approval]` effect migration
mid-flight. Here is what `lex pkg` actually does:

- **No dependency repo publishes git tags.** `git ls-remote --tags` is empty
  for lex-trail, lex-schema, lex-web and lex-games. Tag pinning is not
  available; `rev = "<sha>"` is.
- **`lex pkg` honours `rev` / `tag` / `branch`** on a git dependency.
- **But the installer uses a flat package layout.** Pinning a package that
  anything else in the closure requires *unpinned* is a hard error:

  ```
  error: version conflict: `lex-schema` is required as rev:460629be… but
  `lex-web` requires git:…/lex-schema — flat layout can only hold one copy
  ```

So a package can only be pinned if it is a **leaf** of the closure. That, plus
"keep a verifier's closure small", decides the dependency set:

- **`lex-trail` is pinned** to an exact rev. It supplies `event.compute_id`,
  the hash every tamper check rests on — the one dependency where silent drift
  would turn a red verdict green.
- **`lex-schema` is unpinned and cannot be otherwise**: lex-orm, lex-crypto,
  lex-log and lex-fix all declare it unpinned. This is the accepted residual
  risk, written down rather than hidden.
- **`lex-games` is deliberately not a dependency**, though it defines the
  trail-file JSONL format we read. Depending on it would force lex-trail back
  to unpinned (lex-games requires it unpinned) and drag
  lex-positions/lex-money/lex-orm into a verifier's closure. `src/trail.lex`
  re-implements the ~15-line line format instead, and `tests/test_trail.lex`
  holds the two in agreement against a real trail rather than trusting them to
  stay in sync.

The toolchain is pinned everywhere (`lex.toml` and `LEX_VERSION` in CI) — the
one pin that is always available and always honoured.

## Trust model and limitations

Stated plainly, in the spirit of lex-robot's fleet arbiter documenting its own:

- **Single operator.** No auth, no multi-tenancy. Anyone who can write the
  store can append to it — and with the HTTP door running, anyone who can
  reach the port can too. There is no TLS; reverse-proxy it if it leaves
  localhost. Both are deliberate non-goals of #6, not oversights.
- **The store is append-only by API, not by syscall.** `std.io` offers `read`
  and `write` but no `O_APPEND`, so `append` is read-modify-write: not atomic,
  and two concurrent writers can lose a record. Fine for a lab tool; the first
  thing to fix if this takes concurrent writers.
- **`verify` proves derivation, not provenance.** It proves the recorded
  numbers follow from the bound trail and that the trail has not been edited.
  It does not prove the trail came from the run it claims to — nothing here is
  signed yet. Signing the trail at emission (lex-jose is already in the
  ecosystem) is the natural next step.
- **`results` must be a flat JSON object.** Claims are extracted by pattern;
  keys nested inside a sub-object would be lifted to the top level.

## The reference fixture

`fixtures/xlerobot_rl_trail.jsonl` is the trail everything is tested against.
Its provenance, in full:

- The **input is real**: lex-robot's committed
  `examples/fixtures/xlerobot_rl_rollout.json` is the recorded 17-step
  governed rollout of the actual 300k-timestep PPO policy from
  `docs/RL_TRAINING.md`.
- The **trail itself is a faithful reconstruction, not a captured artifact.**
  lex-robot commits no trail JSONL — the real ones were written to `/tmp` by
  `examples/xlerobot_policy_rollout.lex` and died with their containers.
  `tools/make_fixture.lex` replays the committed rollout through the same grant
  gate and emits the same events.
- It is written **in Lex** so the event ids come from `lex-trail`'s own
  `event.make`. A Python re-implementation of that hash would be a second,
  unversioned copy of a security-critical function and would disagree the
  moment lex-trail changed its canonical form.
- `scripts/smoke.sh` regenerates it and asserts the result is byte-identical.

The derivation lands on lex-robot's published numbers exactly — 16 spatial
actions, 17 total, 8 denials, 50% — which is the check that stops the verifier
from being self-consistent but wrong. If lex-robot ever commits a real trail,
delete `tools/make_fixture.lex` and the fixture and use the real one.

## Layout

```
src/record.lex      run record, canonical encoding, content address  (#3)
src/store.lex       append-only JSONL store                          (#3)
src/trail.lex       trail parsing + hash chain — domain-neutral      (#4)
src/metric.lex      the deriver/verifier interface: named integers   (#4)
src/derive.lex      evidence kind -> deriver dispatch                (#4)
src/derive/robot.lex  lex-robot governed rollouts                    (#4)
src/derive/loom.lex   lex-loom sprint trails                         (#4)
src/verify.lex      claims vs evidence, the four verdicts            (#4)
src/entry.lex       submit -> validate -> bind evidence -> append    (#3)
src/cli.lex         record / list / show / verify, acli envelopes    (#5)
src/server.lex      HTTP door over lex-web                           (#6)
bin/notebooklab     exit-code wrapper around `lex run`               (#5)
tools/              fixture generation, in Lex
fixtures/           reference trails, a tampered twin, entries
```

No Python anywhere, deliberately: the fixture generators are Lex so event ids
come from lex-trail's own `event.make` rather than a second copy of that hash.

## Conventions

`AGENTS.md` is the verbatim output of `lex agent-guidelines` — the authoritative
contract for writing Lex in this ecosystem. Do not edit it; regenerate it.
Narrow effects, `examples {}` on pure functions, stdlib first.
