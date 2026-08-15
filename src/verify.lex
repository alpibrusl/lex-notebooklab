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

import "./derive" as derive

import "./metric" as met

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

# ---- Claim scoring -------------------------------------------------------
# Claim keys are resolved against whatever the deriver for this evidence kind
# published (src/derive.lex). A missing key means "no deriver produced this",
# which is the difference between a claim being WRONG and a claim being
# something evidence cannot settle. A deriver that knows a quantity is
# genuinely zero emits it explicitly, so a claim of `move_base.y.violations: 0`
# resolves to 0 rather than to "cannot say".
fn unverifiable(key :: Str, claimed :: Str, detail :: Str) -> ClaimVerdict {
  { key: key, status: Unverifiable, claimed: claimed, derived: "", detail: detail }
}

fn score_claim(ms :: List[met.Metric], c :: RawClaim) -> ClaimVerdict {
  if not c.numeric {
    unverifiable(c.key, c.value, "claim is not a numeric metric; no trail derivation exists for it")
  } else {
    if str.contains(c.value, ".") {
      unverifiable(c.key, c.value, "claim is fractional; this verifier compares integer metrics only")
    } else {
      match str.to_int(c.value) {
        None => unverifiable(c.key, c.value, "claim is not an integer"),
        Some(claimed) => match met.lookup(ms, c.key) {
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

fn score_all(ms :: List[met.Metric], results_json :: Str) -> List[ClaimVerdict] {
  list.map(claims_of(results_json), fn (c :: RawClaim) -> ClaimVerdict {
    score_claim(ms, c)
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

# Verify one record against the evidence it bound. Domain-neutral: the
# evidence `kind` selects the deriver, and everything below it — digest
# binding, chain integrity, the four verdicts — is shared by every domain.
#
# The order of checks is the point: identity of the evidence is settled BEFORE
# anything is derived from it. A trail whose digest does not match the one the
# record committed to is not weak evidence, it is repudiated evidence — the
# same stance lex-games' referee takes when it disqualifies a forged trail
# instead of scoring it.
# The first bound artifact this package knows how to interpret. A run may bind
# several (a trail, a checkpoint hash, …); only some kinds have a deriver, and
# a checkpoint digest settles no claim on its own.
fn derivable_evidence(es :: List[rec.Evidence]) -> Option[rec.Evidence] {
  list.head(list.filter(es, fn (e :: rec.Evidence) -> Bool {
    derive.has_deriver(e.kind)
  }))
}

fn no_evidence_detail(r :: rec.Run) -> Str {
  if not rec.has_evidence(r) {
    "no evidence bound to this run"
  } else {
    "no evidence of a kind this package can interpret; see derive.known_kinds()"
  }
}

fn verify_run(r :: rec.Run) -> [io] RunVerdict {
  match derivable_evidence(r.evidence) {
    None => verdict(r.run_id, Unverifiable, no_evidence_detail(r), all_claims_as(r.results_json, Unverifiable, "no interpretable evidence to derive from")),
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
        match derive.metrics(e.kind, lines) {
          Err(msg) => verdict(r.run_id, Tampered, str.join(["trail intact but a ", e.kind, " payload is malformed: ", msg], ""), all_claims_as(r.results_json, Tampered, "evidence unusable; claim not scored")),
          Ok(ms) => verdict(r.run_id, Verified, "evidence digest matches and the hash chain is intact", score_all(ms, r.results_json)),
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

