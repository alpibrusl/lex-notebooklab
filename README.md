# lex-notebooklab

**A run is a trail, not a score.**

An experiment tracker for the Lex ecosystem. What separates it from
MLflow/W&B is one property: **a recorded experiment is verifiable evidence,
not a trusted claim.** Every run can be bound to the hash-chained trail its
metrics were derived from, and `verify` re-derives those metrics from that
evidence — so "50% denial rate, y-violations eliminated" is something a third
party can recompute, not something the logger asserted.

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

## The four verdicts

Collapsing verification to pass/fail would let very different failures look
alike, so the vocabulary is four-valued:

| Verdict | Meaning | Exit code |
|---|---|---|
| `VERIFIED` | Recomputed from the trail and equal to the claim. | 0 |
| `UNVERIFIABLE` | Nothing to check against — no evidence bound, file missing, or the claim names a quantity no trail can settle. | 0 |
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

1. Find the `replay_trail` evidence. No evidence → every claim `UNVERIFIABLE`.
2. Hash the file and compare against the digest the record committed to. A
   mismatch is `TAMPERED` — repudiated evidence, not weak evidence — and
   nothing is derived from it. Same stance lex-games' referee takes when it
   disqualifies a forged trail instead of scoring it.
3. Check the trail's own hash chain: every event id must recompute (via
   `lex-trail`'s `event.compute_id`) and every `parent` must be the previous
   event's id. This catches an edit, a reorder, an insertion or a deletion —
   including one where the forger refreshed the recorded digest to match.
4. Derive the metrics and diff them against each claim.

**Bounds come from the grant recorded in the trail**, not from constants in the
verifier. lex-robot's `gym_env/xlerobot_usage_log.py` hardcodes `ARM_BOUNDS` /
`BASE_BOUNDS` to mirror the grant, which is correct only until someone changes
the grant. The trail already carries the grant each action was checked against,
so reading it there is correct by construction and lets a third party verify a
run whose grant differed.

### The claim vocabulary

Keys in `results` that the verifier can re-derive:

| Key | Meaning |
|---|---|
| `actions` | Spatially gated actions (grasp excluded) — `xlerobot_usage_log.py`'s `total`. |
| `actions_all` | Every `execute` event — what the lex-games referee counts. |
| `denials` | Actions the grant denied. |
| `denial_rate_pct` | `denials / actions`, integer percent. |
| `<skill>.<axis>.violations` | e.g. `move_to.x.violations`. A claim of `0` on an axis with no violations resolves to `0`, not "cannot say". |
| `<skill>.<axis>.mean_overshoot_milli` | Mean overshoot past the granted bound, milli-units. |
| `<skill>.<axis>.max_overshoot_milli` | Worst overshoot, milli-units. |

Everything is integer milli-units, exactly as the trail encodes them (`x: 499`
means 0.499 m), so two verifiers always agree bit for bit. Any other key — a
string like `"eval": "FAILED"`, or a fractional value — is reported
`UNVERIFIABLE` with a reason. A MuJoCo SUCCESS/FAILED verdict has no trail
representation, and inventing a check for it would be worse than admitting it.

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
  store can append to it.
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
src/record.lex   run record, canonical encoding, content address   (#3)
src/store.lex    append-only JSONL store                            (#3)
src/trail.lex    trail parsing, hash chain, metric derivation       (#4)
src/verify.lex   claims vs evidence, the four verdicts              (#4)
src/cli.lex      record / list / show / verify, acli envelopes      (#5)
bin/notebooklab  exit-code wrapper around `lex run`                 (#5)
tools/           fixture generation
fixtures/        the reference trail, its tampered twin, entries
```

## Conventions

`AGENTS.md` is the verbatim output of `lex agent-guidelines` — the authoritative
contract for writing Lex in this ecosystem. Do not edit it; regenerate it.
Narrow effects, `examples {}` on pure functions, stdlib first.
