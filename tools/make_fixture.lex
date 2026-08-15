# tools/make_fixture.lex — build the reference trail fixture, in Lex
#
# PROVENANCE — read before trusting fixtures/xlerobot_rl_trail.jsonl
#
# The INPUT is real: `examples/fixtures/xlerobot_rl_rollout.json` in
# alpibrusl/lex-robot is the recorded 17-step governed rollout of the actual
# 300k-timestep PPO policy written up in that repo's `docs/RL_TRAINING.md`.
#
# The OUTPUT is a faithful RECONSTRUCTION, not a captured artifact. lex-robot
# commits no trail JSONL — the real ones were written to /tmp by
# `examples/xlerobot_policy_rollout.lex` and died with their containers. This
# program replays the committed rollout through the same grant gate and emits
# the same events, so the result is shaped exactly like a real trail and is
# self-consistent under verification.
#
# It is written in Lex, and not as a Python script, for one specific reason:
# the event id must come from `lex-trail`'s own `event.make`. A Python
# re-implementation of that hash would be a second, unversioned copy of a
# security-critical function — the exact thing `lex agent-guidelines` §3.3
# warns against — and would silently disagree the moment lex-trail changed its
# canonical form. Here the ids are correct by construction.
#
# Timestamps are a fixed base plus one per event so the fixture is
# reproducible; a real trail carries wall-clock values.
#
# Run:
#   lex run --allow-effects io tools/make_fixture.lex build \
#     '"../lex-robot/examples/fixtures/xlerobot_rl_rollout.json"' \
#     '"fixtures/xlerobot_rl_trail.jsonl"'

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.json" as json

import "std.float" as flt

import "lex-trail/src/event" as ev

# The rollout format `gym_env/xlerobot_rl_eval.py` writes.
type Step = { skill :: Str, x :: Float, y :: Float, z :: Float, speed :: Float, force :: Float, sim_outcome :: Str }

type Rollout = { policy :: Str, steps :: List[Step] }

# A grant in metres, mirroring examples/xlerobot_policy_rollout.lex.
type Vec3 = { x :: Float, y :: Float, z :: Float }

type Grant = { ws_min :: Vec3, ws_max :: Vec3, max_force :: Float, max_grip :: Float }

fn base_grant() -> Grant
  examples {
    base_grant() => { ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 4.0, y: 3.0, z: 0.0 }, max_force: 0.0, max_grip: 0.0 }
  }
{
  { ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 4.0, y: 3.0, z: 0.0 }, max_force: 0.0, max_grip: 0.0 }
}

fn arm_grant() -> Grant
  examples {
    arm_grant() => { ws_min: { x: 0.05, y: 0.0 - 0.35, z: 0.0 }, ws_max: { x: 0.45, y: 0.35, z: 0.5 }, max_force: 15.0, max_grip: 15.0 }
  }
{
  { ws_min: { x: 0.05, y: 0.0 - 0.35, z: 0.0 }, ws_max: { x: 0.45, y: 0.35, z: 0.5 }, max_force: 15.0, max_grip: 15.0 }
}

# src/grant.lex `in_workspace` — inclusive on both bounds.
fn in_workspace(g :: Grant, x :: Float, y :: Float, z :: Float) -> Bool
  examples {
    in_workspace(arm_grant(), 0.1, 0.0, 0.1) => true,
    in_workspace(arm_grant(), 0.9, 0.0, 0.1) => false,
    in_workspace(arm_grant(), 0.45, 0.35, 0.5) => true
  }
{
  if x < g.ws_min.x {
    false
  } else {
    if x > g.ws_max.x {
      false
    } else {
      if y < g.ws_min.y {
        false
      } else {
        if y > g.ws_max.y {
          false
        } else {
          if z < g.ws_min.z {
            false
          } else {
            not (z > g.ws_max.z)
          }
        }
      }
    }
  }
}

# src/wire.lex `milli` — metres to integer milli-units.
fn milli(x :: Float) -> Str
  examples {
    milli(0.499) => "499",
    milli(0.0) => "0",
    milli(0.0 - 0.328) => "-328"
  }
{
  int.to_str(flt.to_int(x * 1000.0))
}

# src/wire.lex `grant_json` — field order is load-bearing for the id.
fn grant_json(g :: Grant) -> Str {
  str.join(["\"grant\":{\"ws_min\":{\"x\":", milli(g.ws_min.x), ",\"y\":", milli(g.ws_min.y), ",\"z\":", milli(g.ws_min.z), "},\"ws_max\":{\"x\":", milli(g.ws_max.x), ",\"y\":", milli(g.ws_max.y), ",\"z\":", milli(g.ws_max.z), "},\"max_force\":", milli(g.max_force), ",\"max_grip\":", milli(g.max_grip), "}"], "")
}

# src/wire.lex `skill_payload_for`.
fn skill_payload(skill :: Str, g :: Grant, x :: Float, y :: Float, z :: Float, force :: Float, outcome :: Str) -> Str {
  str.join(["{\"skill\":\"", skill, "\",\"args\":{\"x\":", milli(x), ",\"y\":", milli(y), ",\"z\":", milli(z), ",\"force\":", milli(force), "},", grant_json(g), ",\"outcome\":\"", str.replace(outcome, "\"", "'"), "\"}"], "")
}

# src/wire.lex `payload`.
fn detail_payload(detail :: Str) -> Str {
  str.join(["{\"detail\":\"", str.replace(str.replace(detail, "\"", "'"), "\n", " "), "\"}"], "")
}

fn clamp(v :: Float, ceiling :: Float) -> Float
  examples {
    clamp(20.0, 15.0) => 15.0,
    clamp(5.0, 15.0) => 5.0
  }
{
  if v > ceiling {
    ceiling
  } else {
    v
  }
}

# One step's payload, gated exactly as skills.lex gates it. The trail records
# move_arm under the name `move_to`.
fn step_payload(s :: Step) -> Str {
  if s.skill == "move_base" {
    skill_payload("move_base", base_grant(), s.x, s.y, 0.0, 0.0, if in_workspace(base_grant(), s.x, s.y, 0.0) {
      "reached"
    } else {
      "denied: base target outside granted floor area"
    })
  } else {
    if s.skill == "move_arm" {
      skill_payload("move_to", arm_grant(), s.x, s.y, s.z, 0.0, if in_workspace(arm_grant(), s.x, s.y, s.z) {
        "reached"
      } else {
        "denied: left arm target outside granted workspace"
      })
    } else {
      skill_payload("grasp", arm_grant(), 0.0, 0.0, 0.0, clamp(s.force, arm_grant().max_grip), "reached")
    }
  }
}

# ---- Event chain ---------------------------------------------------------
type Chain = { parent :: Str, evs :: List[ev.Event] }

fn base_ts() -> Int {
  1750000000000
}

fn emit(c :: Chain, kind :: Str, payload :: Str) -> Chain {
  let p := if str.is_empty(c.parent) {
    None
  } else {
    Some(c.parent)
  }
  let e := ev.make(kind, p, payload, base_ts() + list.len(c.evs))
  { parent: e.id, evs: list.concat(c.evs, [e]) }
}

# examples/xlerobot_policy_rollout.lex `replay_all`, in order.
fn build_chain(steps :: List[Step]) -> Chain {
  let c0 := emit({ parent: "", evs: [] }, "task_started", "{}")
  let c1 := emit(c0, "perceive", detail_payload("policy rollout: fetch the cup"))
  let c2 := emit(c1, "plan", detail_payload("replay the policy's chosen skill sequence under the grant"))
  let c3 := list.fold(steps, c2, fn (c :: Chain, s :: Step) -> Chain {
    emit(c, "execute", step_payload(s))
  })
  emit(c3, "verify", detail_payload("outcome reached"))
}

# ---- Trail-file rendering ------------------------------------------------
# lex-games src/arena/trail_file.lex `esc` / `line_json` / `to_jsonl`.
fn esc(s :: Str) -> Str
  examples {
    esc("a\"b") => "a\\\"b",
    esc("a\\b") => "a\\\\b"
  }
{
  str.replace(str.replace(s, "\\", "\\\\"), "\"", "\\\"")
}

fn line_json(e :: ev.Event) -> Str {
  str.join(["{\"id\":\"", e.id, "\",\"kind\":\"", e.kind, "\",\"parent\":\"", match e.parent {
    Some(p) => p,
    None => "",
  }, "\",\"payload_json\":\"", esc(e.payload_json), "\",\"ts_ms\":", int.to_str(e.ts_ms), "}"], "")
}

fn to_jsonl(evs :: List[ev.Event]) -> Str {
  str.join(list.map(evs, line_json), "\n")
}

# ---- Entry point ---------------------------------------------------------
fn build(rollout_path :: Str, out_path :: Str) -> [io] Result[Str, Str] {
  match io.read(rollout_path) {
    Err(e) => Err(str.concat("cannot read rollout: ", e)),
    Ok(content) => {
      let parsed :: Result[Rollout, Str] := json.parse(content)
      match parsed {
        Err(e) => Err(str.concat("bad rollout json: ", e)),
        Ok(r) => {
          let chain := build_chain(r.steps)
          match io.write(out_path, to_jsonl(chain.evs)) {
            Err(e) => Err(e),
            Ok(_) => Ok(str.join([out_path, ": ", int.to_str(list.len(chain.evs)), " events from ", int.to_str(list.len(r.steps)), " rollout steps of ", r.policy], "")),
          }
        },
      }
    },
  }
}

