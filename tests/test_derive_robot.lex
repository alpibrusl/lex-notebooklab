# tests/test_derive_robot.lex — the robot deriver (#4)
#
# The load-bearing test is `test_matches_published_numbers`. The fixture comes
# from lex-robot's committed 17-step PPO rollout, and lex-robot's own
# `docs/RL_TRAINING.md` publishes what that rollout produced:
#
#     {"total": 16, "denied": 8, "denial_rate": 0.5}      (usage log)
#     [verify] {..., "actions":17, "denials":8, ...}      (referee)
#
# This Lex re-implementation has to land on exactly those numbers, or it is not
# a re-implementation of the same derivation. That is the check that stops the
# verifier from being self-consistent but wrong.

import "../src/trail" as trail

import "../src/metric" as met

import "../src/derive/robot" as robot

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "std.io" as io

fn trail_path() -> Str {
  "fixtures/xlerobot_rl_trail.jsonl"
}

fn derived() -> [io] Result[List[met.Metric], Str] {
  match trail.read(trail_path()) {
    Err(e) => Err(e),
    Ok(ls) => robot.metrics(ls),
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

fn test_matches_published_numbers() -> [io] Result[Unit, Str] {
  match derived() {
    Err(e) => Err(e),
    Ok(ms) => match expect_metric(ms, "actions", 16) {
      Err(e) => Err(e),
      Ok(_) => match expect_metric(ms, "actions_all", 17) {
        Err(e) => Err(e),
        Ok(_) => match expect_metric(ms, "denials", 8) {
          Err(e) => Err(e),
          Ok(_) => expect_metric(ms, "denial_rate_pct", 50),
        },
      },
    },
  }
}

# Every denial in this rollout is an arm reach — lex-robot's write-up says so
# in words ("only move_base and the single grasp are admitted").
fn test_all_violations_are_arm_reaches() -> [io] Result[Unit, Str] {
  match derived() {
    Err(e) => Err(e),
    Ok(ms) => match expect_metric(ms, "move_to.x.violations", 8) {
      Err(e) => Err(e),
      Ok(_) => match expect_metric(ms, "move_base.x.violations", 0) {
        Err(e) => Err(e),
        Ok(_) => expect_metric(ms, "move_base.y.violations", 0),
      },
    },
  }
}

# An axis that recorded no violations must still be PRESENT with value 0.
# "y-violations eliminated" is the headline claim of lex-robot's attempt 4, and
# an absent key would make the verifier report it unverifiable — the wrong
# answer for exactly the claim this package exists to settle.
fn test_clean_axes_are_present_as_zero() -> [io] Result[Unit, Str] {
  match derived() {
    Err(e) => Err(e),
    Ok(ms) => match met.lookup(ms, "move_base.y.violations") {
      None => Err("a clean axis was omitted instead of reported as zero"),
      Some(_) => Ok(()),
    },
  }
}

fn test_axis_profile() -> [io] Result[Unit, Str] {
  match derived() {
    Err(e) => Err(e),
    Ok(ms) => match expect_metric(ms, "move_to.x.max_overshoot_milli", 1542) {
      Err(e) => Err(e),
      Ok(_) => expect_metric(ms, "move_to.x.mean_overshoot_milli", 1111),
    },
  }
}

# Bounds must come from the trail, not from constants in the verifier: a run
# recorded under a wider grant must be scored against THAT grant.
fn test_bounds_come_from_the_trail() -> Result[Unit, Str] {
  let wide := { skill: "move_to", args: { x: 900, y: 0, z: 0, force: 0 }, grant: { ws_min: { x: 0, y: 0, z: 0 }, ws_max: { x: 1000, y: 1000, z: 1000 }, max_force: 0, max_grip: 0 }, outcome: "denied: something else" }
  let narrow := { skill: "move_to", args: { x: 900, y: 0, z: 0, force: 0 }, grant: { ws_min: { x: 0, y: 0, z: 0 }, ws_max: { x: 100, y: 100, z: 100 }, max_force: 0, max_grip: 0 }, outcome: "denied: x out of box" }
  if robot.overshoot(wide, "x") == 0 and robot.overshoot(narrow, "x") == 800 {
    Ok(())
  } else {
    Err("overshoot ignored the grant recorded in the trail")
  }
}

fn results() -> [io] List[Result[Unit, Str]] {
  [test_matches_published_numbers(), test_all_violations_are_arm_reaches(), test_clean_axes_are_present_as_zero(), test_axis_profile(), test_bounds_come_from_the_trail()]
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
      Err(e) => io.print(str.concat("FAIL test_derive_robot: ", e)),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

