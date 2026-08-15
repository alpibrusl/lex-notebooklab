# src/derive/loom.lex — deriving metrics from a lex-loom sprint trail
#
# The second deriver, and the reason the deriver interface exists: lex-loom
# already writes lex-trail events with the same content-addressed hash chain
# lex-robot uses (see loom's `src/loom_trail.lex`) — only the event kinds and
# payloads differ. So the security-critical half (line integrity, chain
# integrity, digest binding) is shared verbatim, and only the interpretation
# lives here.
#
# The structural analogy is close: loom's `loom.node.denied` is a gate refusing
# an artifact exactly as the robot's grant refuses an out-of-box reach, and
# `loom.phase.bounced` counts rework the way overshoot counts violation.
#
# Metric keys published by this deriver:
#
#   nodes_started / nodes_accepted / nodes_denied
#   denial_rate_pct              nodes_denied / nodes_started
#   bounces                      total phase bounces
#   graph_rejections             graphs the validator refused
#   phases_advanced
#   sprint_success               1 or 0
#   fully_sealed                 1 or 0
#   gate.<gate>.denials          denials attributed to each gate
#   phase.<phase>.bounces        bounces INTO each phase
#
# ── Status, stated plainly ────────────────────────────────────────────────
# The event kinds and payload fields below are read from loom's real
# `src/loom_trail.lex`. What loom does NOT yet do is EXPORT that trail as a
# standalone file: it writes into a shared, growing SQLite database via
# lex-trail's `log`, and a digest cannot be bound to a file that keeps
# changing. Before a loom sprint can be recorded as verifiable evidence here,
# loom needs to export a per-sprint snapshot — lex-trail already ships
# `src/export.lex`, which emits an integrity-checked document, so the piece
# exists and just needs wiring up on loom's side.
#
# Until then this deriver is exercised against a fixture in loom's own event
# format (tools/make_loom_fixture.lex). That is honest about what is proven —
# the interpretation is real and tested; the plumbing that would feed it real
# sprints is not built yet, and it is not built HERE.
#
# Effects: none.

import "std.str" as str

import "std.list" as list

import "std.json" as json

import "../trail" as trail

import "../metric" as met

type NodeStarted = { sprint_id :: Str, node :: Str, role :: Str, attempt :: Int }

type NodeDenied = { sprint_id :: Str, node :: Str, gate :: Str, reason :: Str, attempt :: Int }

type PhaseBounced = { sprint_id :: Str, from :: Str, to :: Str, bounce :: Int }

type SprintComplete = { sprint_id :: Str, success :: Bool, fully_sealed :: Bool, demo_ref :: Str }

fn bit(b :: Bool) -> Int
  examples {
    bit(true) => 1,
    bit(false) => 0
  }
{
  if b {
    1
  } else {
    0
  }
}

# ---- Typed decoding ------------------------------------------------------
# A payload that does not decode is an error, not a skipped line: dropping a
# denial would flatter the rate, which is the one direction a verifier must
# never fail in.
fn denials_of(ls :: List[trail.Line]) -> Result[List[NodeDenied], Str] {
  list.fold(trail.of_kind(ls, "loom.node.denied"), Ok([]), fn (acc :: Result[List[NodeDenied], Str], l :: trail.Line) -> Result[List[NodeDenied], Str] {
    match acc {
      Err(e) => Err(e),
      Ok(done) => {
        let parsed :: Result[NodeDenied, Str] := json.parse(l.payload_json)
        match parsed {
          Err(e) => Err(str.concat("bad loom.node.denied payload: ", e)),
          Ok(d) => Ok(list.concat(done, [d])),
        }
      },
    }
  })
}

fn bounces_of(ls :: List[trail.Line]) -> Result[List[PhaseBounced], Str] {
  list.fold(trail.of_kind(ls, "loom.phase.bounced"), Ok([]), fn (acc :: Result[List[PhaseBounced], Str], l :: trail.Line) -> Result[List[PhaseBounced], Str] {
    match acc {
      Err(e) => Err(e),
      Ok(done) => {
        let parsed :: Result[PhaseBounced, Str] := json.parse(l.payload_json)
        match parsed {
          Err(e) => Err(str.concat("bad loom.phase.bounced payload: ", e)),
          Ok(b) => Ok(list.concat(done, [b])),
        }
      },
    }
  })
}

# The sprint's own verdict. Absent (a trail that never completed) is reported
# as an incomplete sprint rather than as a failure — those are different
# things and a record claiming either should be checkable.
fn completion_of(ls :: List[trail.Line]) -> Result[Option[SprintComplete], Str] {
  match list.head(trail.of_kind(ls, "loom.sprint.complete")) {
    None => Ok(None),
    Some(l) => {
      let parsed :: Result[SprintComplete, Str] := json.parse(l.payload_json)
      match parsed {
        Err(e) => Err(str.concat("bad loom.sprint.complete payload: ", e)),
        Ok(c) => Ok(Some(c)),
      }
    },
  }
}

# ---- Per-category breakdowns ---------------------------------------------
fn denials_per_gate(ds :: List[NodeDenied]) -> List[met.Metric] {
  let gates := met.distinct(list.map(ds, fn (d :: NodeDenied) -> Str {
    d.gate
  }))
  list.map(gates, fn (g :: Str) -> met.Metric {
    met.metric(met.dotted(["gate", g, "denials"]), list.len(list.filter(ds, fn (d :: NodeDenied) -> Bool {
      d.gate == g
    })))
  })
}

# Bounces are attributed to the phase they land IN — the phase that has to
# redo work — which is the number a retro actually cares about.
fn bounces_per_phase(bs :: List[PhaseBounced]) -> List[met.Metric] {
  let phases := met.distinct(list.map(bs, fn (b :: PhaseBounced) -> Str {
    b.to
  }))
  list.map(phases, fn (p :: Str) -> met.Metric {
    met.metric(met.dotted(["phase", p, "bounces"]), list.len(list.filter(bs, fn (b :: PhaseBounced) -> Bool {
      b.to == p
    })))
  })
}

fn completion_metrics(c :: Option[SprintComplete]) -> List[met.Metric] {
  match c {
    None => [met.metric("sprint_complete", 0)],
    Some(done) => [met.metric("sprint_complete", 1), met.metric("sprint_success", bit(done.success)), met.metric("fully_sealed", bit(done.fully_sealed))],
  }
}

fn metrics(ls :: List[trail.Line]) -> Result[List[met.Metric], Str] {
  match denials_of(ls) {
    Err(e) => Err(e),
    Ok(denied) => match bounces_of(ls) {
      Err(e) => Err(e),
      Ok(bounced) => match completion_of(ls) {
        Err(e) => Err(e),
        Ok(completion) => {
          let started := list.len(trail.of_kind(ls, "loom.node.started"))
          let accepted := list.len(trail.of_kind(ls, "loom.node.accepted"))
          let base := [met.metric("nodes_started", started), met.metric("nodes_accepted", accepted), met.metric("nodes_denied", list.len(denied)), met.metric("denial_rate_pct", met.rate_pct(list.len(denied), started)), met.metric("bounces", list.len(bounced)), met.metric("graph_rejections", list.len(trail.of_kind(ls, "loom.graph.rejected"))), met.metric("phases_advanced", list.len(trail.of_kind(ls, "loom.phase.advanced")))]
          Ok(list.concat(list.concat(base, completion_metrics(completion)), list.concat(denials_per_gate(denied), bounces_per_phase(bounced))))
        },
      },
    },
  }
}

