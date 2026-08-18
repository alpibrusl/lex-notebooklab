# src/derive.lex — which deriver interprets which evidence
#
# The extension point. A run's evidence entries already carry a `kind`
# (src/record.lex `Evidence`), and that kind selects the interpreter. Adding a
# domain means adding a module under src/derive/ and one arm here — nothing in
# src/verify.lex, src/record.lex or src/store.lex changes, because none of them
# knows what a metric means.
#
# Deliberately a plain dispatch and not a plugin registry. Two derivers is
# enough to show the seam is in the right place; a general metric DSL would be
# speculative generality, and the guidelines are clear about not building for
# requirements nobody has yet.
#
# Effects: none.

import "std.list" as list

import "./trail" as trail

import "./metric" as met

import "./derive/robot" as robot

import "./derive/loom" as loom

import "./derive/moe" as moe

# Evidence kinds this package can interpret.
#
#   replay_trail            a lex-robot governed-replay trail
#   loom_sprint_trail       an exported lex-loom sprint trail
#   moe_parity_attestation  a signed lex-moe parity attestation envelope
fn known_kinds() -> List[Str]
  examples {
    known_kinds() => ["replay_trail", "loom_sprint_trail", "moe_parity_attestation"]
  }
{
  ["replay_trail", "loom_sprint_trail", "moe_parity_attestation"]
}

# ---- The two evidence families -------------------------------------------
# Evidence divides by HOW ITS INTEGRITY IS ESTABLISHED, and everything above
# that split is shared:
#
#   a trail chain   — every event id recomputes, every parent link holds, and
#                     the head the record bound transitively covers the rest.
#   a signed statement — one claim plus an ed25519 signature over the exact
#                     bytes it was serialized to (src/attest.lex).
#
# A predicate rather than a sum type, for the same reason `metrics` below is a
# plain dispatch: one non-chain family is not a taxonomy, and the guidelines
# are clear about not building for requirements nobody has yet. A kind with no
# deriver at all answers `false` and never reaches either path — the verifier
# has already reported it UNVERIFIABLE by then.
fn is_signed_statement(kind :: Str) -> Bool
  examples {
    is_signed_statement("moe_parity_attestation") => true,
    is_signed_statement("replay_trail") => false,
    is_signed_statement("loom_sprint_trail") => false,
    is_signed_statement("checkpoint") => false
  }
{
  kind == "moe_parity_attestation"
}

# Whether any deriver claims this evidence kind. The verifier asks first, so
# that unknown evidence is reported UNVERIFIABLE ("nothing here can read it")
# rather than TAMPERED ("it is forged") — a distinction worth keeping sharp.
fn has_deriver(kind :: Str) -> Bool
  examples {
    has_deriver("replay_trail") => true,
    has_deriver("loom_sprint_trail") => true,
    has_deriver("checkpoint") => false,
    has_deriver("") => false
  }
{
  met.has_str(known_kinds(), kind)
}

# Derivers for signed-statement evidence. The argument is the VERIFIED
# statement text: src/verify.lex checks the signature over those exact bytes
# before this is reached, exactly as it checks a chain before calling
# `metrics` below.
fn metrics_signed(kind :: Str, statement_json :: Str) -> Result[List[met.Metric], Str] {
  if kind == "moe_parity_attestation" {
    moe.metrics(statement_json)
  } else {
    Err("no signed-statement deriver for evidence kind")
  }
}

fn metrics(kind :: Str, ls :: List[trail.Line]) -> Result[List[met.Metric], Str] {
  if kind == "replay_trail" {
    robot.metrics(ls)
  } else {
    if kind == "loom_sprint_trail" {
      loom.metrics(ls)
    } else {
      Err("no deriver for evidence kind")
    }
  }
}

