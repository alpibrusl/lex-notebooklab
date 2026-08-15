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

# Evidence kinds this package can interpret.
#
#   replay_trail       a lex-robot governed-replay trail
#   loom_sprint_trail  an exported lex-loom sprint trail
fn known_kinds() -> List[Str]
  examples {
    known_kinds() => ["replay_trail", "loom_sprint_trail"]
  }
{
  ["replay_trail", "loom_sprint_trail"]
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

