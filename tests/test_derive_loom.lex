# tests/test_derive_loom.lex — the loom deriver, and the generality claim
#
# The point of this file is not really loom coverage: it is evidence that the
# seam between "verify a trail" and "interpret a trail" is in the right place.
# The integrity machinery under test in tests/test_trail.lex is reused here
# unchanged against a completely different event vocabulary — no robot concept
# appears anywhere below.
#
# See tools/make_loom_fixture.lex for what this fixture is and is not: the
# event kinds are loom's real ones, the sequence is authored, and loom does not
# yet export sprint trails as standalone files.

import "../src/trail" as trail

import "../src/metric" as met

import "../src/derive" as derive

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "std.io" as io

fn trail_path() -> Str {
  "fixtures/loom_sprint_trail.jsonl"
}

fn derived() -> [io] Result[List[met.Metric], Str] {
  match trail.read(trail_path()) {
    Err(e) => Err(e),
    Ok(ls) => derive.metrics("loom_sprint_trail", ls),
  }
}

fn expect_metric(ms :: List[met.Metric], key :: Str, want :: Int) -> Result[Unit, Str] {
  match met.lookup(ms, key) {
    None => Err(str.concat("no derived metric for ", key)),
    Some(got) => if got == want {
      Ok(())
    } else {
      Err(str.join([key, ": expected ", int.to_str(want), ", derived ", int.to_str(got)], ""))
    },
  }
}

fn expect_all(ms :: List[met.Metric], wants :: List[met.Metric]) -> Result[Unit, Str] {
  list.fold(wants, Ok(()), fn (acc :: Result[Unit, Str], w :: met.Metric) -> Result[Unit, Str] {
    match acc {
      Err(e) => Err(e),
      Ok(_) => expect_metric(ms, w.key, w.value),
    }
  })
}

# The same integrity checks the robot trail goes through, on loom's events.
# This is the shared half working unmodified across domains.
fn test_loom_trail_is_intact() -> [io] Result[Unit, Str] {
  match trail.read(trail_path()) {
    Err(e) => Err(e),
    Ok(ls) => if trail.trail_intact(ls) {
      Ok(())
    } else {
      Err("the loom fixture failed the shared integrity check")
    },
  }
}

fn test_sprint_counters() -> [io] Result[Unit, Str] {
  match derived() {
    Err(e) => Err(e),
    Ok(ms) => expect_all(ms, [{ key: "nodes_started", value: 6 }, { key: "nodes_accepted", value: 4 }, { key: "nodes_denied", value: 2 }, { key: "denial_rate_pct", value: 33 }, { key: "bounces", value: 1 }, { key: "graph_rejections", value: 0 }, { key: "phases_advanced", value: 3 }]),
  }
}

# The structural analogy with the robot case: a gate refusing an artifact is
# the same shape as a grant refusing an out-of-box reach, and both break down
# per category.
fn test_per_gate_and_per_phase_breakdown() -> [io] Result[Unit, Str] {
  match derived() {
    Err(e) => Err(e),
    Ok(ms) => expect_all(ms, [{ key: "gate.spec.denials", value: 1 }, { key: "gate.tests.denials", value: 1 }, { key: "phase.implementation.bounces", value: 1 }]),
  }
}

fn test_completion_is_derived() -> [io] Result[Unit, Str] {
  match derived() {
    Err(e) => Err(e),
    Ok(ms) => expect_all(ms, [{ key: "sprint_complete", value: 1 }, { key: "sprint_success", value: 1 }, { key: "fully_sealed", value: 1 }]),
  }
}

# A robot metric key must NOT resolve against a loom trail. If it did, the
# derivers would be leaking into each other and a nonsense claim could pass.
fn test_no_cross_domain_leakage() -> [io] Result[Unit, Str] {
  match derived() {
    Err(e) => Err(e),
    Ok(ms) => match met.lookup(ms, "move_to.x.violations") {
      Some(_) => Err("a robot metric resolved against a loom trail"),
      None => Ok(()),
    },
  }
}

fn test_unknown_evidence_kind_has_no_deriver() -> Result[Unit, Str] {
  if derive.has_deriver("checkpoint") {
    Err("an uninterpretable evidence kind claimed a deriver")
  } else {
    if derive.has_deriver("loom_sprint_trail") {
      Ok(())
    } else {
      Err("the loom evidence kind is not registered")
    }
  }
}

fn results() -> [io] List[Result[Unit, Str]] {
  [test_loom_trail_is_intact(), test_sprint_counters(), test_per_gate_and_per_phase_breakdown(), test_completion_is_derived(), test_no_cross_domain_leakage(), test_unknown_evidence_kind_has_no_deriver()]
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
      Err(e) => io.print(str.concat("FAIL test_derive_loom: ", e)),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

