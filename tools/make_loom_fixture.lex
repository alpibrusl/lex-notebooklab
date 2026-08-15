# tools/make_loom_fixture.lex — a lex-loom sprint trail fixture
#
# STATUS — read before trusting fixtures/loom_sprint_trail.jsonl
#
# The event kinds and payload fields below are taken from lex-loom's real
# `src/loom_trail.lex` (`loom.sprint.started`, `loom.node.denied`,
# `loom.phase.bounced`, …). The SEQUENCE is a plausible sprint I authored, not
# a captured one: unlike the robot fixture, loom's `main` commits no trail
# artifact to derive from, because it writes into a SQLite database rather
# than emitting a per-sprint file.
#
# Getting the events out is the only gap, and it is loom's to close — binding
# is already solved here, since a record commits to the chain's HEAD EVENT ID
# rather than to any file's bytes. lex-loom PR #237 adds the export and its
# output verifies unchanged against this deriver; replace this fixture with a
# real export once that lands. Until then it proves the DERIVATION is right
# and claims nothing about the plumbing.
#
# As with the robot fixture, ids come from lex-trail's own `event.make` — never
# from a second copy of that hash.
#
# Run:
#   lex run --allow-effects io tools/make_loom_fixture.lex build \
#     '"fixtures/loom_sprint_trail.jsonl"'

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "lex-trail/src/event" as ev

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

fn sprint() -> Str {
  "sprint_demo_1"
}

# ---- Payload builders, mirroring loom's src/loom_trail.lex ----------------
fn node_started(node :: Str, role :: Str, attempt :: Int) -> Str {
  str.join(["{\"sprint_id\":\"", sprint(), "\",\"node\":\"", node, "\",\"role\":\"", role, "\",\"attempt\":", int.to_str(attempt), "}"], "")
}

fn node_accepted(node :: Str, artifact_hash :: Str) -> Str {
  str.join(["{\"sprint_id\":\"", sprint(), "\",\"node\":\"", node, "\",\"artifact_hash\":\"", artifact_hash, "\"}"], "")
}

fn node_denied(node :: Str, gate :: Str, reason :: Str, attempt :: Int) -> Str {
  str.join(["{\"sprint_id\":\"", sprint(), "\",\"node\":\"", node, "\",\"gate\":\"", gate, "\",\"reason\":\"", reason, "\",\"attempt\":", int.to_str(attempt), "}"], "")
}

fn phase_advanced(from_phase :: Str, to_phase :: Str) -> Str {
  str.join(["{\"sprint_id\":\"", sprint(), "\",\"from\":\"", from_phase, "\",\"to\":\"", to_phase, "\"}"], "")
}

fn phase_bounced(from_phase :: Str, to_phase :: Str, bounce :: Int) -> Str {
  str.join(["{\"sprint_id\":\"", sprint(), "\",\"from\":\"", from_phase, "\",\"to\":\"", to_phase, "\",\"bounce\":", int.to_str(bounce), "}"], "")
}

fn sprint_complete(success :: Bool, sealed :: Bool) -> Str {
  str.join(["{\"sprint_id\":\"", sprint(), "\",\"success\":", if success {
    "true"
  } else {
    "false"
  }, ",\"fully_sealed\":", if sealed {
    "true"
  } else {
    "false"
  }, ",\"demo_ref\":\"demo/1\"}"], "")
}

# A sprint that bounces once out of QA and recovers: 6 node starts,
# 4 acceptances, 2 gate denials, 1 bounce, 3 phase advances, sealed.
fn build_chain() -> Chain {
  let c00 := emit({ parent: "", evs: [] }, "loom.sprint.started", str.join(["{\"sprint_id\":\"", sprint(), "\",\"request_len\":128}"], ""))
  let c01 := emit(c00, "loom.graph.validated", str.join(["{\"sprint_id\":\"", sprint(), "\",\"graph_id\":\"g1\",\"nodes\":3}"], ""))
  let c02 := emit(c01, "loom.node.started", node_started("design-1", "architect", 1))
  let c03 := emit(c02, "loom.node.accepted", node_accepted("design-1", "a1"))
  let c04 := emit(c03, "loom.phase.advanced", phase_advanced("design", "implementation"))
  let c05 := emit(c04, "loom.node.started", node_started("impl-1", "builder", 1))
  let c06 := emit(c05, "loom.node.denied", node_denied("impl-1", "spec", "signature does not match the tightened spec", 1))
  let c07 := emit(c06, "loom.node.started", node_started("impl-1", "builder", 2))
  let c08 := emit(c07, "loom.node.accepted", node_accepted("impl-1", "a2"))
  let c09 := emit(c08, "loom.phase.advanced", phase_advanced("implementation", "qa"))
  let c10 := emit(c09, "loom.node.started", node_started("qa-1", "qa", 1))
  let c11 := emit(c10, "loom.node.denied", node_denied("qa-1", "tests", "two acceptance tests fail", 1))
  let c12 := emit(c11, "loom.phase.bounced", phase_bounced("qa", "implementation", 1))
  let c13 := emit(c12, "loom.node.started", node_started("impl-2", "builder", 1))
  let c14 := emit(c13, "loom.node.accepted", node_accepted("impl-2", "a3"))
  let c15 := emit(c14, "loom.phase.advanced", phase_advanced("implementation", "qa"))
  let c16 := emit(c15, "loom.node.started", node_started("qa-1", "qa", 2))
  let c17 := emit(c16, "loom.node.accepted", node_accepted("qa-1", "a4"))
  emit(c17, "loom.sprint.complete", sprint_complete(true, true))
}

# ---- Trail-file rendering (same wire format as the robot fixture) ---------
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

fn build(out_path :: Str) -> [io] Result[Str, Str] {
  let chain := build_chain()
  match io.write(out_path, str.join(list.map(chain.evs, line_json), "\n")) {
    Err(e) => Err(e),
    Ok(_) => Ok(str.join([out_path, ": ", int.to_str(list.len(chain.evs)), " events"], "")),
  }
}

