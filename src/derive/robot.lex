# src/derive/robot.lex — deriving metrics from a governed-robot replay trail
#
# Reads the trail lex-robot's `examples/xlerobot_policy_rollout.lex` writes and
# recomputes what a run record merely *claims*: how many governed actions were
# attempted, how many the grant denied, and how far out of bounds each denied
# axis reached.
#
# Two properties are deliberate:
#
#   1. Bounds come from the GRANT RECORDED IN THE TRAIL, not from constants in
#      this file. `gym_env/xlerobot_usage_log.py` hardcodes ARM_BOUNDS /
#      BASE_BOUNDS to mirror the grant; that copy is correct only while nobody
#      changes the grant. The trail already carries the grant each action was
#      checked against, so reading it there is correct by construction and lets
#      a third party verify a run whose grant differed.
#
#   2. Everything is integer milli-units, exactly as the trail encodes them
#      (`x: 499` means 0.499 m — see lex-robot src/wire.lex).
#
# Metric keys published by this deriver:
#
#   actions                            spatially gated actions (grasp excluded)
#   actions_all                        every execute event
#   denials                            actions the grant denied
#   denial_rate_pct                    denials / actions
#   <skill>.<axis>.violations          e.g. move_to.x.violations
#   <skill>.<axis>.mean_overshoot_milli
#   <skill>.<axis>.max_overshoot_milli
#
# Rows are emitted for every (skill, axis) the trail exercised, INCLUDING the
# ones with no violations. That is what makes "y-violations eliminated" — the
# headline claim of lex-robot's attempt 4 — a checkable zero rather than an
# absent key the verifier would have to report as unverifiable.
#
# Effects: none.

import "std.str" as str

import "std.list" as list

import "std.json" as json

import "../trail" as trail

import "../metric" as met

type Vec3M = { x :: Int, y :: Int, z :: Int }

type GrantM = { ws_min :: Vec3M, ws_max :: Vec3M, max_force :: Int, max_grip :: Int }

type ArgsM = { x :: Int, y :: Int, z :: Int, force :: Int }

# One axis's granted interval, inclusive on both ends (lex-robot's
# src/grant.lex `in_workspace` compares with `<` / `>`, so a value sitting
# exactly on the bound is inside the box).
type Bounds = { lo :: Int, hi :: Int }

type Action = { skill :: Str, args :: ArgsM, grant :: GrantM, outcome :: Str }

# ---- Decoding ------------------------------------------------------------
fn decode_action(l :: trail.Line) -> Result[Action, Str] {
  let parsed :: Result[Action, Str] := json.parse(l.payload_json)
  parsed
}

# Decode every `execute` event. A payload that does not decode is an error
# rather than a skipped line: silently dropping an action would understate the
# denominator and flatter the denial rate.
fn actions_of(ls :: List[trail.Line]) -> Result[List[Action], Str] {
  list.fold(trail.of_kind(ls, "execute"), Ok([]), fn (acc :: Result[List[Action], Str], l :: trail.Line) -> Result[List[Action], Str] {
    match acc {
      Err(e) => Err(e),
      Ok(done) => match decode_action(l) {
        Err(e) => Err(str.concat("bad execute payload: ", e)),
        Ok(a) => Ok(list.concat(done, [a])),
      },
    }
  })
}

fn is_denied(a :: Action) -> Bool
  examples {
    is_denied({ skill: "move_to", args: { x: 0, y: 0, z: 0, force: 0 }, grant: unit_grant(), outcome: "reached" }) => false,
    is_denied({ skill: "move_to", args: { x: 0, y: 0, z: 0, force: 0 }, grant: unit_grant(), outcome: "denied: out of box" }) => true
  }
{
  str.starts_with(a.outcome, "denied")
}

# `grasp` is force-only — not a spatial bound, and excluded from the denial
# denominator exactly as xlerobot_usage_log.py excludes it.
fn is_spatial(a :: Action) -> Bool
  examples {
    is_spatial({ skill: "grasp", args: { x: 0, y: 0, z: 0, force: 0 }, grant: unit_grant(), outcome: "reached" }) => false,
    is_spatial({ skill: "move_base", args: { x: 0, y: 0, z: 0, force: 0 }, grant: unit_grant(), outcome: "reached" }) => true
  }
{
  not (a.skill == "grasp")
}

# A grant of [0, 100] on every axis — the fixed reference box the examples in
# this file are stated against.
fn unit_grant() -> GrantM
  examples {
    unit_grant() => { ws_min: { x: 0, y: 0, z: 0 }, ws_max: { x: 100, y: 100, z: 100 }, max_force: 0, max_grip: 0 }
  }
{
  { ws_min: { x: 0, y: 0, z: 0 }, ws_max: { x: 100, y: 100, z: 100 }, max_force: 0, max_grip: 0 }
}

# ---- Axis geometry -------------------------------------------------------
# A base move is gated on the floor plane only; an arm move on all three axes.
# Mirrors xlerobot_usage_log.py's `_bounds_for`.
fn axes_for(skill :: Str) -> List[Str]
  examples {
    axes_for("move_base") => ["x", "y"],
    axes_for("move_to") => ["x", "y", "z"],
    axes_for("move_arm") => ["x", "y", "z"]
  }
{
  if skill == "move_base" {
    ["x", "y"]
  } else {
    ["x", "y", "z"]
  }
}

fn axis_value(a :: ArgsM, axis :: Str) -> Int
  examples {
    axis_value({ x: 1, y: 2, z: 3, force: 4 }, "x") => 1,
    axis_value({ x: 1, y: 2, z: 3, force: 4 }, "y") => 2,
    axis_value({ x: 1, y: 2, z: 3, force: 4 }, "z") => 3,
    axis_value({ x: 1, y: 2, z: 3, force: 4 }, "unknown") => 0
  }
{
  if axis == "x" {
    a.x
  } else {
    if axis == "y" {
      a.y
    } else {
      if axis == "z" {
        a.z
      } else {
        0
      }
    }
  }
}

fn axis_bounds(g :: GrantM, axis :: Str) -> Bounds
  examples {
    axis_bounds({ ws_min: { x: 1, y: 2, z: 3 }, ws_max: { x: 4, y: 5, z: 6 }, max_force: 0, max_grip: 0 }, "x") => { lo: 1, hi: 4 },
    axis_bounds({ ws_min: { x: 1, y: 2, z: 3 }, ws_max: { x: 4, y: 5, z: 6 }, max_force: 0, max_grip: 0 }, "y") => { lo: 2, hi: 5 },
    axis_bounds({ ws_min: { x: 1, y: 2, z: 3 }, ws_max: { x: 4, y: 5, z: 6 }, max_force: 0, max_grip: 0 }, "z") => { lo: 3, hi: 6 }
  }
{
  if axis == "x" {
    { lo: g.ws_min.x, hi: g.ws_max.x }
  } else {
    if axis == "y" {
      { lo: g.ws_min.y, hi: g.ws_max.y }
    } else {
      { lo: g.ws_min.z, hi: g.ws_max.z }
    }
  }
}

# How far outside its granted bound this axis reached, in milli-units. 0 when
# inside — that axis was not the reason the action was denied.
fn overshoot(a :: Action, axis :: Str) -> Int
  examples {
    overshoot({ skill: "move_to", args: { x: 500, y: 0, z: 0, force: 0 }, grant: unit_grant(), outcome: "denied: x" }, "x") => 400,
    overshoot({ skill: "move_to", args: { x: 0 - 200, y: 0, z: 0, force: 0 }, grant: unit_grant(), outcome: "denied: x" }, "x") => 200,
    overshoot({ skill: "move_to", args: { x: 50, y: 0, z: 0, force: 0 }, grant: unit_grant(), outcome: "denied: y" }, "x") => 0
  }
{
  let b := axis_bounds(a.grant, axis)
  let v := axis_value(a.args, axis)
  if v < b.lo {
    b.lo - v
  } else {
    if v > b.hi {
      v - b.hi
    } else {
      0
    }
  }
}

# ---- Aggregation ---------------------------------------------------------
fn overshoots_for(denied :: List[Action], skill :: Str, axis :: Str) -> List[Int] {
  list.filter(list.map(list.filter(denied, fn (a :: Action) -> Bool {
    a.skill == skill
  }), fn (a :: Action) -> Int {
    overshoot(a, axis)
  }), fn (o :: Int) -> Bool {
    o > 0
  })
}

fn axis_metrics(denied :: List[Action], skill :: Str, axis :: Str) -> List[met.Metric] {
  let os := overshoots_for(denied, skill, axis)
  [met.metric(met.dotted([skill, axis, "violations"]), list.len(os)), met.metric(met.dotted([skill, axis, "mean_overshoot_milli"]), met.mean_of(os)), met.metric(met.dotted([skill, axis, "max_overshoot_milli"]), met.max_of(os))]
}

fn skill_metrics(denied :: List[Action], skill :: Str) -> List[met.Metric] {
  list.fold(axes_for(skill), [], fn (acc :: List[met.Metric], axis :: Str) -> List[met.Metric] {
    list.concat(acc, axis_metrics(denied, skill, axis))
  })
}

# The whole derivation: claims recomputed from evidence.
fn metrics(ls :: List[trail.Line]) -> Result[List[met.Metric], Str] {
  match actions_of(ls) {
    Err(e) => Err(e),
    Ok(all_actions) => {
      let spatial := list.filter(all_actions, is_spatial)
      let denied := list.filter(spatial, is_denied)
      let skills := met.distinct(list.map(spatial, fn (a :: Action) -> Str {
        a.skill
      }))
      let per_axis := list.fold(skills, [], fn (acc :: List[met.Metric], s :: Str) -> List[met.Metric] {
        list.concat(acc, skill_metrics(denied, s))
      })
      Ok(list.concat([met.metric("actions", list.len(spatial)), met.metric("actions_all", list.len(all_actions)), met.metric("denials", list.len(denied)), met.metric("denial_rate_pct", met.rate_pct(list.len(denied), list.len(spatial)))], per_axis))
    },
  }
}

