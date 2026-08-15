# src/verify.lex — re-derive a run's claims from its evidence (issue #4)
#
# This is the file that makes the package more than a JSONL wrapper. A run
# record asserts things ("denial rate 50%, y-violations eliminated"). This
# module recomputes those numbers from the hash-chained trail the record bound
# as evidence and reports, per claim, whether the assertion survives.
#
# The verdict vocabulary is deliberately four-valued, because collapsing it to
# pass/fail would let two very different failures look alike:
#
#   VERIFIED     — recomputed from the trail and equal to the claim.
#   MISMATCH     — recomputed and NOT equal. The claim is wrong.
#   TAMPERED     — the evidence itself does not hold up: its digest differs
#                  from the one recorded, or its hash chain is broken. Nothing
#                  derived from it can be trusted, so no claim is scored.
#   UNVERIFIABLE — there is nothing to check the claim against: no evidence
#                  bound, the file is gone, or the claim names a quantity this
#                  verifier cannot derive (a MuJoCo SUCCESS/FAILED verdict has
#                  no trail representation — see the non-goal in issue #4).
#
# UNVERIFIABLE is a first-class, honest outcome, not a soft pass. A record
# with no evidence reports every claim as UNVERIFIABLE forever; it never
# silently reads as verified.
#
# Effects: `[io]` only, and only to read the evidence file.

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.io" as io

import "std.crypto" as crypto

import "std.regex" as regex

import "./record" as rec

import "./trail" as tr

type Status = Verified | Mismatch | Unverifiable | Tampered

type ClaimVerdict = { key :: Str, status :: Status, claimed :: Str, derived :: Str, detail :: Str }

# The whole verdict for one run. `trail_status` describes the EVIDENCE (is it
# there, does it hold up); `claims` describes the assertions.
type RunVerdict = { run_id :: Str, trail_status :: Status, trail_detail :: Str, claims :: List[ClaimVerdict] }

fn status_str(s :: Status) -> Str
  examples {
    status_str(Verified) => "VERIFIED",
    status_str(Mismatch) => "MISMATCH",
    status_str(Unverifiable) => "UNVERIFIABLE",
    status_str(Tampered) => "TAMPERED"
  }
{
  match s {
    Verified => "VERIFIED",
    Mismatch => "MISMATCH",
    Unverifiable => "UNVERIFIABLE",
    Tampered => "TAMPERED",
  }
}

# ---- Claim extraction ----------------------------------------------------
# `results` is an open map held as a JSON string, so the claims are pulled out
# by pattern rather than by a fixed schema — that is what lets a record carry
# whatever a trainer logged. std.regex rather than a hand-rolled scanner, per
# the guidelines' stdlib-first rule.
#
# Limitation, stated rather than hidden: this expects `results` to be a FLAT
# object. Keys nested inside a sub-object would be lifted to the top level.
# The v0 record vocabulary is flat; the importer keeps it that way.
type RawClaim = { key :: Str, value :: Str, numeric :: Bool }

fn number_claim_pattern() -> Str {
  "\"([A-Za-z0-9_.]+)\"[ ]*:[ ]*(-?[0-9]+\\.?[0-9]*)"
}

fn string_claim_pattern() -> Str {
  "\"([A-Za-z0-9_.]+)\"[ ]*:[ ]*\"([^\"]*)\""
}

type GroupPick = { idx :: Int, found :: Str }

fn nth_str(xs :: List[Str], i :: Int) -> Str
  examples {
    nth_str([], 0) => "",
    nth_str(["a", "b"], 0) => "a",
    nth_str(["a", "b"], 1) => "b",
    nth_str(["a", "b"], 5) => ""
  }
{
  let picked := list.fold(xs, { idx: 0, found: "" }, fn (acc :: GroupPick, g :: Str) -> GroupPick {
    if acc.idx == i {
      { idx: acc.idx + 1, found: g }
    } else {
      { idx: acc.idx + 1, found: acc.found }
    }
  })
  picked.found
}

fn group_at(m :: { text :: Str, start :: Int, end :: Int, groups :: List[Str] }, i :: Int) -> Str {
  nth_str(m.groups, i)
}

fn matches_of(pattern :: Str, src :: Str) -> List[{ text :: Str, start :: Int, end :: Int, groups :: List[Str] }] {
  match regex.compile(pattern) {
    Err(_) => [],
    Ok(re) => regex.find_all(re, src),
  }
}

fn numeric_claims(results_json :: Str) -> List[RawClaim] {
  list.map(matches_of(number_claim_pattern(), results_json), fn (m :: { text :: Str, start :: Int, end :: Int, groups :: List[Str] }) -> RawClaim {
    { key: group_at(m, 0), value: group_at(m, 1), numeric: true }
  })
}

fn string_claims(results_json :: Str) -> List[RawClaim] {
  list.map(matches_of(string_claim_pattern(), results_json), fn (m :: { text :: Str, start :: Int, end :: Int, groups :: List[Str] }) -> RawClaim {
    { key: group_at(m, 0), value: group_at(m, 1), numeric: false }
  })
}

# Every claim the record makes, in a stable order: numbers first, then strings.
fn claims_of(results_json :: Str) -> List[RawClaim] {
  list.concat(numeric_claims(results_json), string_claims(results_json))
}

# ---- Derived lookup ------------------------------------------------------
# Maps a claim key onto the quantity this verifier can recompute. Returning
# None is meaningful: it is the difference between "wrong" and "not something
# evidence can settle".
#
# Scalar keys name whole-trail quantities. Per-axis keys are
# `<skill>.<axis>.<metric>`, e.g. `move_to.x.violations` — the same naming
# gym_env/xlerobot_usage_log.py prints.
fn derived_value(d :: tr.Derived, key :: Str) -> Option[Int] {
  if key == "actions" {
    Some(d.actions)
  } else {
    if key == "actions_all" {
      Some(d.actions_all)
    } else {
      if key == "denials" {
        Some(d.denials)
      } else {
        if key == "denial_rate_pct" {
          Some(d.denial_rate_pct)
        } else {
          axis_metric(d.axes, key)
        }
      }
    }
  }
}

fn axis_key(s :: tr.AxisStat, metric :: Str) -> Str
  examples {
    axis_key({ skill: "move_to", axis: "x", violations: 1, mean_overshoot_milli: 2, max_overshoot_milli: 3 }, "violations") => "move_to.x.violations"
  }
{
  str.join([s.skill, ".", s.axis, ".", metric], "")
}

fn axis_metric_of(s :: tr.AxisStat, metric :: Str) -> Option[Int]
  examples {
    axis_metric_of({ skill: "m", axis: "x", violations: 1, mean_overshoot_milli: 2, max_overshoot_milli: 3 }, "violations") => Some(1),
    axis_metric_of({ skill: "m", axis: "x", violations: 1, mean_overshoot_milli: 2, max_overshoot_milli: 3 }, "mean_overshoot_milli") => Some(2),
    axis_metric_of({ skill: "m", axis: "x", violations: 1, mean_overshoot_milli: 2, max_overshoot_milli: 3 }, "max_overshoot_milli") => Some(3),
    axis_metric_of({ skill: "m", axis: "x", violations: 1, mean_overshoot_milli: 2, max_overshoot_milli: 3 }, "nope") => None
  }
{
  if metric == "violations" {
    Some(s.violations)
  } else {
    if metric == "mean_overshoot_milli" {
      Some(s.mean_overshoot_milli)
    } else {
      if metric == "max_overshoot_milli" {
        Some(s.max_overshoot_milli)
      } else {
        None
      }
    }
  }
}

# An axis that recorded no violations is absent from `axes`, so a claim of
# `move_to.y.violations: 0` must resolve to Some(0) rather than None —
# "y violations eliminated" is exactly the claim this package exists to
# settle, and reporting it UNVERIFIABLE would be the wrong answer.
fn axis_metric(axes :: List[tr.AxisStat], key :: Str) -> Option[Int] {
  let parts := str.split(key, ".")
  if not (list.len(parts) == 3) {
    None
  } else {
    let metric := last_part(parts)
    match list.head(list.filter(axes, fn (s :: tr.AxisStat) -> Bool {
      axis_key(s, metric) == key
    })) {
      Some(s) => axis_metric_of(s, metric),
      None => if is_axis_shaped(parts) and is_known_metric(metric) {
        Some(0)
      } else {
        None
      },
    }
  }
}

fn last_part(parts :: List[Str]) -> Str
  examples {
    last_part([]) => "",
    last_part(["a", "b", "c"]) => "c"
  }
{
  match list.head(list.reverse(parts)) {
    None => "",
    Some(s) => s,
  }
}

fn is_known_metric(metric :: Str) -> Bool
  examples {
    is_known_metric("violations") => true,
    is_known_metric("mean_overshoot_milli") => true,
    is_known_metric("max_overshoot_milli") => true,
    is_known_metric("elephants") => false
  }
{
  metric == "violations" or (metric == "mean_overshoot_milli" or metric == "max_overshoot_milli")
}

# A `<skill>.<axis>.<metric>` key only names a real axis if the middle part is
# one of the axes the grant actually bounds.
fn is_axis_shaped(parts :: List[Str]) -> Bool {
  match list.head(list.tail(parts)) {
    None => false,
    Some(axis) => axis == "x" or (axis == "y" or axis == "z"),
  }
}

# ---- Claim scoring -------------------------------------------------------
fn unverifiable(key :: Str, claimed :: Str, detail :: Str) -> ClaimVerdict {
  { key: key, status: Unverifiable, claimed: claimed, derived: "", detail: detail }
}

fn score_claim(d :: tr.Derived, c :: RawClaim) -> ClaimVerdict {
  if not c.numeric {
    unverifiable(c.key, c.value, "claim is not a numeric metric; no trail derivation exists for it")
  } else {
    if str.contains(c.value, ".") {
      unverifiable(c.key, c.value, "claim is fractional; this verifier compares integer metrics only")
    } else {
      match str.to_int(c.value) {
        None => unverifiable(c.key, c.value, "claim is not an integer"),
        Some(claimed) => match derived_value(d, c.key) {
          None => unverifiable(c.key, c.value, "no derivation for this key; the trail cannot settle it"),
          Some(derived) => if claimed == derived {
            { key: c.key, status: Verified, claimed: c.value, derived: int.to_str(derived), detail: "" }
          } else {
            { key: c.key, status: Mismatch, claimed: c.value, derived: int.to_str(derived), detail: "claim does not match the value derived from the trail" }
          },
        },
      }
    }
  }
}

fn score_all(d :: tr.Derived, results_json :: Str) -> List[ClaimVerdict] {
  list.map(claims_of(results_json), fn (c :: RawClaim) -> ClaimVerdict {
    score_claim(d, c)
  })
}

# Every claim marked with one status — used when the evidence as a whole is
# missing or untrustworthy, so no individual claim can be scored.
fn all_claims_as(results_json :: Str, s :: Status, detail :: Str) -> List[ClaimVerdict] {
  list.map(claims_of(results_json), fn (c :: RawClaim) -> ClaimVerdict {
    { key: c.key, status: s, claimed: c.value, derived: "", detail: detail }
  })
}

# ---- Whole-run verification ----------------------------------------------
fn verdict(run_id :: Str, s :: Status, detail :: Str, claims :: List[ClaimVerdict]) -> RunVerdict {
  { run_id: run_id, trail_status: s, trail_detail: detail, claims: claims }
}

# Verify one record against the evidence it bound.
#
# The order of checks is the point: identity of the evidence is settled BEFORE
# anything is derived from it. A trail whose digest does not match the one the
# record committed to is not weak evidence, it is repudiated evidence — the
# same stance lex-games' referee takes when it disqualifies a forged trail
# instead of scoring it.
fn verify_run(r :: rec.Run) -> [io] RunVerdict {
  match rec.evidence_of_kind(r.evidence, "replay_trail") {
    None => verdict(r.run_id, Unverifiable, if rec.has_evidence(r) {
      "no evidence of kind 'replay_trail' bound to this run"
    } else {
      "no evidence bound to this run"
    }, all_claims_as(r.results_json, Unverifiable, "no replay trail to derive from")),
    Some(e) => match io.read(e.path) {
      Err(msg) => verdict(r.run_id, Unverifiable, str.join(["evidence file unreadable: ", e.path, " (", msg, ")"], ""), all_claims_as(r.results_json, Unverifiable, "evidence file missing")),
      Ok(content) => verify_content(r, e, content),
    },
  }
}

fn verify_content(r :: rec.Run, e :: rec.Evidence, content :: Str) -> RunVerdict {
  let digest := crypto.sha256_str(content)
  if not (digest == e.sha256) {
    verdict(r.run_id, Tampered, str.join(["evidence digest mismatch: recorded ", e.sha256, ", file hashes to ", digest], ""), all_claims_as(r.results_json, Tampered, "evidence repudiated; claim not scored"))
  } else {
    match tr.parse_jsonl(content) {
      Err(msg) => verdict(r.run_id, Tampered, str.concat("evidence is not a readable trail: ", msg), all_claims_as(r.results_json, Tampered, "evidence unparseable; claim not scored")),
      Ok(lines) => if not tr.trail_intact(lines) {
        verdict(r.run_id, Tampered, "trail hash chain is broken: an event id does not recompute, or a parent link is wrong", all_claims_as(r.results_json, Tampered, "evidence repudiated; claim not scored"))
      } else {
        match tr.derive(lines) {
          Err(msg) => verdict(r.run_id, Tampered, str.concat("trail intact but an action payload is malformed: ", msg), all_claims_as(r.results_json, Tampered, "evidence unusable; claim not scored")),
          Ok(d) => verdict(r.run_id, Verified, "evidence digest matches and the hash chain is intact", score_all(d, r.results_json)),
        }
      },
    }
  }
}

# ---- Roll-up -------------------------------------------------------------
# The single status for a whole run, and the basis for the CLI's exit code.
# Severity order is TAMPERED > MISMATCH > UNVERIFIABLE > VERIFIED: a forged
# trail outranks a wrong number, and both outrank an honest "cannot say".
fn severity(s :: Status) -> Int
  examples {
    severity(Verified) => 0,
    severity(Unverifiable) => 1,
    severity(Mismatch) => 2,
    severity(Tampered) => 3
  }
{
  match s {
    Verified => 0,
    Unverifiable => 1,
    Mismatch => 2,
    Tampered => 3,
  }
}

fn worst(a :: Status, b :: Status) -> Status {
  if severity(b) > severity(a) {
    b
  } else {
    a
  }
}

fn overall(v :: RunVerdict) -> Status {
  list.fold(v.claims, v.trail_status, fn (acc :: Status, c :: ClaimVerdict) -> Status {
    worst(acc, c.status)
  })
}

# Semantic exit codes (issue #5). 0 covers both VERIFIED and UNVERIFIABLE:
# "we checked what could be checked and nothing contradicted the record" is a
# pass. A wrong claim and a forged trail get distinct nonzero codes so CI can
# tell a bookkeeping error from an integrity failure.
fn exit_code(s :: Status) -> Int
  examples {
    exit_code(Verified) => 0,
    exit_code(Unverifiable) => 0,
    exit_code(Mismatch) => 3,
    exit_code(Tampered) => 4
  }
{
  match s {
    Verified => 0,
    Unverifiable => 0,
    Mismatch => 3,
    Tampered => 4,
  }
}

