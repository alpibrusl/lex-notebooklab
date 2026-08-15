# tests/test_verify.lex — the four verdicts (#4)
#
# Issue #4's acceptance list, one test each: a real trail (VERIFIED), a
# tampered copy (TAMPERED), a claim that does not match its own trail
# (MISMATCH), and a record with no evidence (UNVERIFIABLE).

import "../src/record" as rec

import "../src/verify" as vfy

import "../src/trail" as tr

import "std.list" as list

import "std.str" as str

import "std.io" as io

fn trail_sha() -> Str {
  "e6a2b0c7077a1a78c71208e6e3d6b49e7fa2ce7a6c9e24cc8fae19157d0e493e"
}

# The id of the reference trail's last event. Because every event id folds in
# its parent's, this one value commits to all 21 events.
fn trail_head() -> Str {
  "8add8b4a511cbf5a671f13e149cb323614c5b82b76a59711f8340b288c1ff1b2"
}

fn tampered_sha() -> Str {
  "fad33c1a702abdfb60ca3d1c786315c59924997b86e06a4a3935225d0a98f0d2"
}

fn run_with(results_json :: Str, evidence :: List[rec.Evidence]) -> rec.Run {
  rec.seal({ run_id: "", attempt: "ppo-300k", series: "rl", trainer: "sidecar/xlerobot_rl_train.py", config_json: "{\"timesteps\":300000}", results_json: results_json, evidence: evidence, notes: "", supersedes: "", created_at: 1750000000000, extra_json: "", source_json: "{}" })
}

fn good_evidence() -> List[rec.Evidence] {
  [{ kind: "replay_trail", path: "fixtures/xlerobot_rl_trail.jsonl", sha256: trail_sha(), trail_head: trail_head() }]
}

fn expect(v :: vfy.RunVerdict, want :: vfy.Status, label :: Str) -> Result[Unit, Str] {
  let got := vfy.overall(v)
  if got == want {
    Ok(())
  } else {
    Err(str.join([label, ": expected ", vfy.status_str(want), ", got ", vfy.status_str(got), " (", v.trail_detail, ")"], ""))
  }
}

# Claims that ARE what the trail says. This is the end-to-end demonstration:
# the numbers in lex-robot's write-up, recomputed from the evidence.
fn test_true_claims_verify() -> [io] Result[Unit, Str] {
  let r := run_with("{\"actions\":16,\"denials\":8,\"denial_rate_pct\":50}", good_evidence())
  expect(vfy.verify_run(r), Verified, "true claims")
}

fn test_false_claim_mismatches() -> [io] Result[Unit, Str] {
  let r := run_with("{\"actions\":16,\"denials\":0}", good_evidence())
  expect(vfy.verify_run(r), Mismatch, "a run claiming zero denials")
}

# The forged trail: one denial rewritten to "reached". Its digest no longer
# matches what the record committed to, so it is repudiated before any number
# is derived from it.
fn test_tampered_evidence_is_repudiated() -> [io] Result[Unit, Str] {
  let r := run_with("{\"actions\":16,\"denials\":8}", [{ kind: "replay_trail", path: "fixtures/xlerobot_rl_trail_tampered.jsonl", sha256: trail_sha(), trail_head: trail_head() }])
  expect(vfy.verify_run(r), Tampered, "an edited trail")
}

# Even if the forger updates the recorded digest to match their edited file,
# the trail's own hash chain still catches it. Belt and braces: the digest
# binds the file to the record, the chain binds the events to each other.
fn test_rehashed_forgery_still_caught() -> [io] Result[Unit, Str] {
  let r := run_with("{\"actions\":16,\"denials\":8}", [{ kind: "replay_trail", path: "fixtures/xlerobot_rl_trail_tampered.jsonl", sha256: tampered_sha(), trail_head: "" }])
  expect(vfy.verify_run(r), Tampered, "an edited trail with a refreshed digest")
}

fn test_no_evidence_is_unverifiable() -> [io] Result[Unit, Str] {
  let r := run_with("{\"actions\":16,\"denials\":8}", [])
  expect(vfy.verify_run(r), Unverifiable, "a record with no evidence")
}

fn test_missing_file_is_unverifiable_not_tampered() -> [io] Result[Unit, Str] {
  let r := run_with("{\"actions\":16}", [{ kind: "replay_trail", path: "fixtures/does_not_exist.jsonl", sha256: trail_sha(), trail_head: "" }])
  expect(vfy.verify_run(r), Unverifiable, "a missing evidence file")
}

# Issue #4's non-goal, made explicit: a MuJoCo SUCCESS/FAILED verdict has no
# trail representation. It must be reported honestly as unverifiable rather
# than quietly ignored or optimistically passed.
fn test_underivable_claim_is_unverifiable() -> [io] Result[Unit, Str] {
  let r := run_with("{\"eval\":\"FAILED\",\"episode_return\":-109.91}", good_evidence())
  let v := vfy.verify_run(r)
  let unverifiable := list.filter(v.claims, fn (c :: vfy.ClaimVerdict) -> Bool {
    c.status == Unverifiable
  })
  if list.len(unverifiable) == 2 {
    expect(v, Unverifiable, "a record of only sim-side claims")
  } else {
    Err("sim-side claims were not each reported unverifiable")
  }
}

# "y-violations eliminated" is the headline claim of lex-robot's attempt 4, and
# an axis with no violations is absent from the derived profile — so a claim of
# zero must resolve to zero, not to "cannot say".
fn test_zero_violation_claim_is_verifiable() -> [io] Result[Unit, Str] {
  let r := run_with("{\"move_base.y.violations\":0}", good_evidence())
  expect(vfy.verify_run(r), Verified, "a claim that an axis recorded no violations")
}

fn test_axis_claim_mismatch() -> [io] Result[Unit, Str] {
  let r := run_with("{\"move_to.x.violations\":3}", good_evidence())
  expect(vfy.verify_run(r), Mismatch, "a wrong per-axis violation count")
}

# Exit codes must separate "wrong number" from "forged evidence" so CI can
# treat them differently (issue #5).
fn test_exit_codes_are_distinct() -> Result[Unit, Str] {
  if vfy.exit_code(Verified) == 0 and (vfy.exit_code(Unverifiable) == 0 and (vfy.exit_code(Mismatch) == 3 and vfy.exit_code(Tampered) == 4)) {
    Ok(())
  } else {
    Err("exit codes do not distinguish mismatch from tampering")
  }
}

# ---- Binding semantics ---------------------------------------------------
# The head binding's own red path, and the case a chain-integrity check alone
# CANNOT catch: a prefix of the real trail. Every id recomputes, every parent
# link holds, it is root-anchored — it is a perfectly valid chain. Only the
# recorded head reveals that events were dropped from the end.
fn test_truncated_chain_is_caught_by_the_head() -> [io] Result[Unit, Str] {
  let r := run_with("{\"actions\":16,\"denials\":8}", [{ kind: "replay_trail", path: "fixtures/xlerobot_rl_trail_truncated.jsonl", sha256: "", trail_head: trail_head() }])
  expect(vfy.verify_run(r), Tampered, "a truncated but internally valid chain")
}

# ...and the truncated chain really is internally valid, so the previous test
# is testing the head binding rather than accidentally testing chain integrity.
fn test_truncated_chain_is_otherwise_intact() -> [io] Result[Unit, Str] {
  match tr.read("fixtures/xlerobot_rl_trail_truncated.jsonl") {
    Err(e) => Err(e),
    Ok(ls) => if tr.trail_intact(ls) {
      Ok(())
    } else {
      Err("the truncated fixture is not internally intact, so it tests the wrong thing")
    },
  }
}

# A head binding alone is sufficient: no digest recorded, and the real trail
# still verifies. This is what makes the evidence's container irrelevant.
fn test_head_alone_verifies() -> [io] Result[Unit, Str] {
  let r := run_with("{\"denials\":8}", [{ kind: "replay_trail", path: "fixtures/xlerobot_rl_trail.jsonl", sha256: "", trail_head: trail_head() }])
  expect(vfy.verify_run(r), Verified, "a run bound by trail head only")
}

# A digest binding alone still works, for artifacts that have no chain.
fn test_digest_alone_verifies() -> [io] Result[Unit, Str] {
  let r := run_with("{\"denials\":8}", [{ kind: "replay_trail", path: "fixtures/xlerobot_rl_trail.jsonl", sha256: trail_sha(), trail_head: "" }])
  expect(vfy.verify_run(r), Verified, "a run bound by digest only")
}

# Evidence that committed to nothing is not forgery — it is a record with no
# binding at all, and must read as UNVERIFIABLE rather than quietly passing.
fn test_unbound_evidence_is_unverifiable() -> [io] Result[Unit, Str] {
  let r := run_with("{\"denials\":8}", [{ kind: "replay_trail", path: "fixtures/xlerobot_rl_trail.jsonl", sha256: "", trail_head: "" }])
  expect(vfy.verify_run(r), Unverifiable, "evidence recorded with no binding")
}

# Binding to one chain and presenting a different (valid) one is repudiation.
fn test_wrong_chain_is_caught() -> [io] Result[Unit, Str] {
  let r := run_with("{\"denials\":8}", [{ kind: "replay_trail", path: "fixtures/loom_sprint_trail.jsonl", sha256: "", trail_head: trail_head() }])
  expect(vfy.verify_run(r), Tampered, "a valid chain that is not the one bound")
}

fn results() -> [io] List[Result[Unit, Str]] {
  [test_true_claims_verify(), test_false_claim_mismatches(), test_tampered_evidence_is_repudiated(), test_rehashed_forgery_still_caught(), test_no_evidence_is_unverifiable(), test_missing_file_is_unverifiable_not_tampered(), test_underivable_claim_is_unverifiable(), test_zero_violation_claim_is_verifiable(), test_axis_claim_mismatch(), test_exit_codes_are_distinct(), test_truncated_chain_is_caught_by_the_head(), test_truncated_chain_is_otherwise_intact(), test_head_alone_verifies(), test_digest_alone_verifies(), test_unbound_evidence_is_unverifiable(), test_wrong_chain_is_caught()]
}

fn run_all() -> [io] Unit {
  let failures := list.filter(results(), fn (r :: Result[Unit, Str]) -> Bool {
    match r {
      Ok(_) => false,
      Err(_) => true,
    }
  })
  let __p := list.map(failures, fn (r :: Result[Unit, Str]) -> [io] Unit {
    match r {
      Ok(_) => (),
      Err(e) => io.print(str.concat("FAIL test_verify: ", e)),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

