# src/trail.lex — reading a governed-replay trail and deriving metrics from it
#
# This is the half of issue #4 that turns evidence into numbers. It reads the
# hash-chained JSONL that lex-robot's `examples/xlerobot_policy_rollout.lex`
# writes and recomputes, from the events alone, the quantities a run record
# merely *claims*: how many governed actions were attempted, how many the grant
# denied, and how far out of bounds each denied axis reached.
#
# Two properties are deliberate:
#
#   1. Bounds come from the GRANT RECORDED IN THE TRAIL, not from constants in
#      this file. `gym_env/xlerobot_usage_log.py` hardcodes ARM_BOUNDS /
#      BASE_BOUNDS to mirror the grant; that copy is correct only while nobody
#      changes the grant. The trail already carries the grant each action was
#      checked against, so reading it there makes the derivation correct by
#      construction and lets a third party verify a run whose grant differed.
#
#   2. Everything is integer milli-units, exactly as the trail encodes them
#      (`x: 499` means 0.499 m — see lex-robot src/wire.lex). No float
#      round-tripping, so two verifiers always agree bit for bit.
#
# The line format mirrors lex-games' `src/arena/trail_file.lex`. It is
# re-implemented rather than imported so that a verifier's dependency closure
# stays small and `lex-trail` can stay rev-pinned (see lex.toml); the
# compatibility of the two is asserted in tests/test_trail.lex against a real
# committed trail rather than assumed.
#
# Effects: pure except `read`, which is `[io]` for the file itself.

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.json" as json

import "std.io" as io

import "lex-trail/src/event" as ev

# One line of a trail file: the canonical lex-trail Event with `parent`
# flattened to Str ("" = root) so one record type parses every line.
type Line = { id :: Str, kind :: Str, parent :: Str, payload_json :: Str, ts_ms :: Int }

# The decoded payload of an `execute` event. Milli-units throughout.
type Vec3M = { x :: Int, y :: Int, z :: Int }

type GrantM = { ws_min :: Vec3M, ws_max :: Vec3M, max_force :: Int, max_grip :: Int }

type ArgsM = { x :: Int, y :: Int, z :: Int, force :: Int }

# One axis's granted interval, inclusive on both ends (src/grant.lex
# `in_workspace` compares with `<` / `>`, so a value exactly on the bound is
# inside the box).
type Bounds = { lo :: Int, hi :: Int }

type Action = { skill :: Str, args :: ArgsM, grant :: GrantM, outcome :: Str }

# Per-(skill, axis) violation profile, the shape
# `gym_env/xlerobot_usage_log.py` prints.
type AxisStat = { skill :: Str, axis :: Str, violations :: Int, mean_overshoot_milli :: Int, max_overshoot_milli :: Int }

# Everything re-derived from a trail. `actions` counts only the spatially
# gated actions (grasp excluded), matching xlerobot_usage_log.py's `total` —
# the denominator the published denial rates were computed with.
# `actions_all` counts every execute event, which is what the lex-games
# referee reports. Both are exposed because the two numbers legitimately
# differ (17 vs 16 on the reference rollout) and silently picking one would
# make an honest claim look like a mismatch.
type Derived = { actions :: Int, actions_all :: Int, denials :: Int, denial_rate_pct :: Int, axes :: List[AxisStat] }

# ---- Parsing -------------------------------------------------------------
fn parse_line(s :: Str) -> Result[Line, Str] {
  let parsed :: Result[Line, Str] := json.parse(s)
  parsed
}

fn non_empty_lines(content :: Str) -> List[Str]
  examples {
    non_empty_lines("") => [],
    non_empty_lines("a\nb") => ["a", "b"],
    non_empty_lines("a\n\n b \n") => ["a", " b "]
  }
{
  list.filter(str.split(content, "\n"), fn (s :: Str) -> Bool {
    not str.is_empty(str.trim(s))
  })
}

fn parse_jsonl(content :: Str) -> Result[List[Line], Str] {
  list.fold(non_empty_lines(content), Ok([]), fn (acc :: Result[List[Line], Str], s :: Str) -> Result[List[Line], Str] {
    match acc {
      Err(e) => Err(e),
      Ok(ls) => match parse_line(s) {
        Err(e) => Err(str.concat("bad trail line: ", e)),
        Ok(l) => Ok(list.concat(ls, [l])),
      },
    }
  })
}

fn read(path :: Str) -> [io] Result[List[Line], Str] {
  match io.read(path) {
    Err(e) => Err(e),
    Ok(content) => parse_jsonl(content),
  }
}

# Read a trail and derive its metrics in one step. `verify` does not use this
# (it needs the parsed lines for the integrity checks too); it exists for
# callers that only want the numbers, and for eyeballing a trail by hand.
fn derive_file(path :: Str) -> [io] Result[Derived, Str] {
  match read(path) {
    Err(e) => Err(e),
    Ok(ls) => derive(ls),
  }
}

# ---- Integrity -----------------------------------------------------------
fn line_parent(l :: Line) -> Option[Str]
  examples {
    line_parent({ id: "i", kind: "k", parent: "", payload_json: "{}", ts_ms: 0 }) => None,
    line_parent({ id: "i", kind: "k", parent: "p", payload_json: "{}", ts_ms: 0 }) => Some("p")
  }
{
  if str.is_empty(l.parent) {
    None
  } else {
    Some(l.parent)
  }
}

# A line is intact iff its id recomputes from its own content. The hash comes
# from lex-trail, never from this file — that dependency is rev-pinned exactly
# because a silent change here would turn a red verdict green.
fn line_intact(l :: Line) -> Bool {
  l.id == ev.compute_id(l.kind, line_parent(l), l.payload_json, l.ts_ms)
}

fn all_lines_intact(ls :: List[Line]) -> Bool {
  list.fold(ls, true, fn (acc :: Bool, l :: Line) -> Bool {
    acc and line_intact(l)
  })
}

# The chain is intact iff every line's `parent` is the previous line's `id`
# and the first line is a root. Together with `line_intact` this makes any
# edit, reorder, insertion or deletion detectable.
fn chain_linked(ls :: List[Line]) -> Bool {
  match list.head(ls) {
    None => true,
    Some(first) => if not str.is_empty(first.parent) {
      false
    } else {
      links_ok(first.id, list.tail(ls))
    },
  }
}

fn links_ok(prev_id :: Str, rest :: List[Line]) -> Bool {
  match list.head(rest) {
    None => true,
    Some(l) => if l.parent == prev_id {
      links_ok(l.id, list.tail(rest))
    } else {
      false
    },
  }
}

fn trail_intact(ls :: List[Line]) -> Bool {
  all_lines_intact(ls) and chain_linked(ls)
}

# ---- Action decoding -----------------------------------------------------
fn is_execute(l :: Line) -> Bool
  examples {
    is_execute({ id: "i", kind: "execute", parent: "", payload_json: "{}", ts_ms: 0 }) => true,
    is_execute({ id: "i", kind: "plan", parent: "", payload_json: "{}", ts_ms: 0 }) => false
  }
{
  l.kind == "execute"
}

fn decode_action(l :: Line) -> Result[Action, Str] {
  let parsed :: Result[Action, Str] := json.parse(l.payload_json)
  parsed
}

# Decode every `execute` event. A payload that does not decode is an error
# rather than a skipped line: silently dropping an action would understate the
# denominator and flatter the denial rate.
fn actions_of(ls :: List[Line]) -> Result[List[Action], Str] {
  list.fold(list.filter(ls, is_execute), Ok([]), fn (acc :: Result[List[Action], Str], l :: Line) -> Result[List[Action], Str] {
    match acc {
      Err(e) => Err(e),
      Ok(as_) => match decode_action(l) {
        Err(e) => Err(str.concat("bad execute payload: ", e)),
        Ok(a) => Ok(list.concat(as_, [a])),
      },
    }
  })
}

fn is_denied(a :: Action) -> Bool
  examples {
    is_denied({ skill: "move_to", args: { x: 0, y: 0, z: 0, force: 0 }, grant: zero_grant(), outcome: "reached" }) => false,
    is_denied({ skill: "move_to", args: { x: 0, y: 0, z: 0, force: 0 }, grant: zero_grant(), outcome: "denied: out of box" }) => true
  }
{
  str.starts_with(a.outcome, "denied")
}

# `grasp` is force-only — not a spatial bound, and excluded from the denial
# denominator exactly as xlerobot_usage_log.py excludes it.
fn is_spatial(a :: Action) -> Bool
  examples {
    is_spatial({ skill: "grasp", args: { x: 0, y: 0, z: 0, force: 0 }, grant: zero_grant(), outcome: "reached" }) => false,
    is_spatial({ skill: "move_base", args: { x: 0, y: 0, z: 0, force: 0 }, grant: zero_grant(), outcome: "reached" }) => true
  }
{
  not (a.skill == "grasp")
}

fn zero_grant() -> GrantM
  examples {
    zero_grant() => { ws_min: { x: 0, y: 0, z: 0 }, ws_max: { x: 0, y: 0, z: 0 }, max_force: 0, max_grip: 0 }
  }
{
  { ws_min: { x: 0, y: 0, z: 0 }, ws_max: { x: 0, y: 0, z: 0 }, max_force: 0, max_grip: 0 }
}

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

# How far outside its granted bound this axis reached, in milli-units.
# 0 when inside — the axis was not the reason the action was denied.
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

# A grant of [0, 100] on every axis — the fixed reference box the `overshoot`
# examples above are stated against.
fn unit_grant() -> GrantM
  examples {
    unit_grant() => { ws_min: { x: 0, y: 0, z: 0 }, ws_max: { x: 100, y: 100, z: 100 }, max_force: 0, max_grip: 0 }
  }
{
  { ws_min: { x: 0, y: 0, z: 0 }, ws_max: { x: 100, y: 100, z: 100 }, max_force: 0, max_grip: 0 }
}

# ---- Aggregation ---------------------------------------------------------
fn has_str(xs :: List[Str], needle :: Str) -> Bool
  examples {
    has_str([], "a") => false,
    has_str(["a", "b"], "b") => true,
    has_str(["a", "b"], "c") => false
  }
{
  list.fold(xs, false, fn (acc :: Bool, x :: Str) -> Bool {
    acc or x == needle
  })
}

# Order-preserving dedupe — the axis rows come out in the order the skills
# first appear in the trail, so two runs of `verify` print the same table.
fn distinct(xs :: List[Str]) -> List[Str]
  examples {
    distinct([]) => [],
    distinct(["a", "b", "a"]) => ["a", "b"],
    distinct(["a", "a", "a"]) => ["a"]
  }
{
  list.fold(xs, [], fn (acc :: List[Str], x :: Str) -> List[Str] {
    if has_str(acc, x) {
      acc
    } else {
      list.concat(acc, [x])
    }
  })
}

fn sum(xs :: List[Int]) -> Int
  examples {
    sum([]) => 0,
    sum([1, 2, 3]) => 6
  }
{
  list.fold(xs, 0, fn (acc :: Int, x :: Int) -> Int {
    acc + x
  })
}

fn max_of(xs :: List[Int]) -> Int
  examples {
    max_of([]) => 0,
    max_of([3, 9, 4]) => 9
  }
{
  list.fold(xs, 0, fn (acc :: Int, x :: Int) -> Int {
    if x > acc {
      x
    } else {
      acc
    }
  })
}

fn mean_of(xs :: List[Int]) -> Int
  examples {
    mean_of([]) => 0,
    mean_of([2, 4]) => 3,
    mean_of([1, 2]) => 1
  }
{
  if list.is_empty(xs) {
    0
  } else {
    sum(xs) / list.len(xs)
  }
}

# The overshoots recorded for one (skill, axis) across every denied action.
# Only nonzero entries count as violations: an action denied because x was out
# of bounds is not a y violation.
fn overshoots_for(denied :: List[Action], skill :: Str, axis :: Str) -> List[Int] {
  list.filter(list.map(list.filter(denied, fn (a :: Action) -> Bool {
    a.skill == skill
  }), fn (a :: Action) -> Int {
    overshoot(a, axis)
  }), fn (o :: Int) -> Bool {
    o > 0
  })
}

fn axis_stat(denied :: List[Action], skill :: Str, axis :: Str) -> AxisStat {
  let os := overshoots_for(denied, skill, axis)
  { skill: skill, axis: axis, violations: list.len(os), mean_overshoot_milli: mean_of(os), max_overshoot_milli: max_of(os) }
}

fn stats_for_skill(denied :: List[Action], skill :: Str) -> List[AxisStat] {
  list.filter(list.map(axes_for(skill), fn (axis :: Str) -> AxisStat {
    axis_stat(denied, skill, axis)
  }), fn (s :: AxisStat) -> Bool {
    s.violations > 0
  })
}

# Integer percent, rounded to nearest — 8/16 is exactly 50, and a rate that
# rounds is honest as long as the raw counts travel alongside it (they do).
fn rate_pct(denials :: Int, actions :: Int) -> Int
  examples {
    rate_pct(0, 0) => 0,
    rate_pct(8, 16) => 50,
    rate_pct(33, 48) => 69,
    rate_pct(24, 48) => 50
  }
{
  if actions == 0 {
    0
  } else {
    (denials * 200 + actions) / (actions * 2)
  }
}

# The whole derivation: claims recomputed from evidence.
fn derive(ls :: List[Line]) -> Result[Derived, Str] {
  match actions_of(ls) {
    Err(e) => Err(e),
    Ok(all_actions) => {
      let spatial := list.filter(all_actions, is_spatial)
      let denied := list.filter(spatial, is_denied)
      let skills := distinct(list.map(denied, fn (a :: Action) -> Str {
        a.skill
      }))
      let axes := list.fold(skills, [], fn (acc :: List[AxisStat], s :: Str) -> List[AxisStat] {
        list.concat(acc, stats_for_skill(denied, s))
      })
      Ok({ actions: list.len(spatial), actions_all: list.len(all_actions), denials: list.len(denied), denial_rate_pct: rate_pct(list.len(denied), list.len(spatial)), axes: axes })
    },
  }
}

