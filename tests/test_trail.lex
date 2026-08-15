# tests/test_trail.lex — trail parsing, integrity, metric derivation (#4)
#
# The load-bearing test here is `test_derivation_matches_published_numbers`.
# The fixture is derived from lex-robot's committed 17-step PPO rollout, and
# lex-robot's own `docs/RL_TRAINING.md` publishes what that rollout produced:
#
#     {"total": 16, "denied": 8, "denial_rate": 0.5}      (usage log)
#     [verify] {..., "actions":17, "denials":8, ...}      (referee)
#
# This Lex re-implementation has to land on exactly those numbers, or it is not
# a re-implementation of the same derivation. That is the check that stops the
# verifier from being self-consistent but wrong.

import "../src/trail" as tr

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "std.io" as io

fn trail_path() -> Str {
  "fixtures/xlerobot_rl_trail.jsonl"
}

fn tampered_path() -> Str {
  "fixtures/xlerobot_rl_trail_tampered.jsonl"
}

fn test_reads_the_fixture() -> [io] Result[Unit, Str] {
  match tr.read(trail_path()) {
    Err(e) => Err(str.concat("could not read fixture: ", e)),
    Ok(ls) => if list.len(ls) == 21 {
      Ok(())
    } else {
      Err(str.concat("expected 21 events, got ", int.to_str(list.len(ls))))
    },
  }
}

fn test_fixture_is_intact() -> [io] Result[Unit, Str] {
  match tr.read(trail_path()) {
    Err(e) => Err(e),
    Ok(ls) => if tr.trail_intact(ls) {
      Ok(())
    } else {
      Err("the reference trail failed its own integrity check")
    },
  }
}

# The forgery: one denial rewritten to "reached" without recomputing the ids.
# This is the cheapest possible way to fake a compliant run, and it must fail.
fn test_tampered_trail_is_rejected() -> [io] Result[Unit, Str] {
  match tr.read(tampered_path()) {
    Err(e) => Err(e),
    Ok(ls) => if tr.trail_intact(ls) {
      Err("a trail with an edited outcome passed the integrity check")
    } else {
      Ok(())
    },
  }
}

fn test_derivation_matches_published_numbers() -> [io] Result[Unit, Str] {
  match tr.derive_file(trail_path()) {
    Err(e) => Err(e),
    Ok(d) => if not (d.actions == 16) {
      Err(str.concat("actions: expected 16, derived ", int.to_str(d.actions)))
    } else {
      if not (d.actions_all == 17) {
        Err(str.concat("actions_all: expected 17, derived ", int.to_str(d.actions_all)))
      } else {
        if not (d.denials == 8) {
          Err(str.concat("denials: expected 8, derived ", int.to_str(d.denials)))
        } else {
          if not (d.denial_rate_pct == 50) {
            Err(str.concat("denial_rate_pct: expected 50, derived ", int.to_str(d.denial_rate_pct)))
          } else {
            Ok(())
          }
        }
      }
    },
  }
}

# Every denial in this rollout is an arm reach — lex-robot's write-up says so
# in words ("only move_base and the single grasp are admitted"), and the
# derivation has to agree.
fn test_all_violations_are_arm_reaches() -> [io] Result[Unit, Str] {
  match tr.derive_file(trail_path()) {
    Err(e) => Err(e),
    Ok(d) => {
      let non_arm := list.filter(d.axes, fn (s :: tr.AxisStat) -> Bool {
        not (s.skill == "move_to")
      })
      if list.is_empty(non_arm) {
        Ok(())
      } else {
        Err("a non-arm skill recorded workspace violations")
      }
    },
  }
}

# x is the axis the policy overshot hardest; this pins the per-axis profile so
# a refactor of the aggregation cannot quietly change the numbers.
fn test_axis_profile() -> [io] Result[Unit, Str] {
  match tr.derive_file(trail_path()) {
    Err(e) => Err(e),
    Ok(d) => match list.head(list.filter(d.axes, fn (s :: tr.AxisStat) -> Bool {
      s.skill == "move_to" and s.axis == "x"
    })) {
      None => Err("no move_to.x row in the derived axis profile"),
      Some(s) => if s.violations == 8 and s.max_overshoot_milli == 1542 {
        Ok(())
      } else {
        Err(str.join(["move_to.x: got ", int.to_str(s.violations), " violations, max ", int.to_str(s.max_overshoot_milli), "mm"], ""))
      },
    },
  }
}

# Bounds must come from the trail, not from constants in the verifier: a run
# recorded under a wider grant must be scored against THAT grant.
fn test_bounds_come_from_the_trail() -> Result[Unit, Str] {
  let wide := { skill: "move_to", args: { x: 900, y: 0, z: 0, force: 0 }, grant: { ws_min: { x: 0, y: 0, z: 0 }, ws_max: { x: 1000, y: 1000, z: 1000 }, max_force: 0, max_grip: 0 }, outcome: "denied: something else" }
  let narrow := { skill: "move_to", args: { x: 900, y: 0, z: 0, force: 0 }, grant: { ws_min: { x: 0, y: 0, z: 0 }, ws_max: { x: 100, y: 100, z: 100 }, max_force: 0, max_grip: 0 }, outcome: "denied: x out of box" }
  if tr.overshoot(wide, "x") == 0 and tr.overshoot(narrow, "x") == 800 {
    Ok(())
  } else {
    Err("overshoot ignored the grant recorded in the trail")
  }
}

fn test_chain_detects_reordering() -> [io] Result[Unit, Str] {
  match tr.read(trail_path()) {
    Err(e) => Err(e),
    Ok(ls) => if tr.chain_linked(list.reverse(ls)) {
      Err("a reversed trail still passed the chain check")
    } else {
      Ok(())
    },
  }
}

fn results() -> [io] List[Result[Unit, Str]] {
  [test_reads_the_fixture(), test_fixture_is_intact(), test_tampered_trail_is_rejected(), test_derivation_matches_published_numbers(), test_all_violations_are_arm_reaches(), test_axis_profile(), test_bounds_come_from_the_trail(), test_chain_detects_reordering()]
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
      Err(e) => io.print(str.concat("FAIL test_trail: ", e)),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

