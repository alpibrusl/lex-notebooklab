# src/trail.lex — the trail file itself: parsing and integrity
#
# Domain-neutral by design. This module knows what a lex-trail event line IS
# and whether it has been tampered with; it knows nothing about what the events
# MEAN. Interpreting them is a deriver's job (src/derive/), which is what lets
# one verifier serve lex-robot's governed rollouts and lex-loom's sprint trails
# without either one leaking into the other.
#
# What lives here is the security-critical half:
#
#   * line integrity  — every event id must recompute from its own content,
#     via lex-trail's `event.compute_id`. Never re-implement that hash; the
#     dependency is rev-pinned (see lex.toml) precisely because a silent change
#     would turn a red verdict green.
#   * chain integrity — every `parent` must be the previous event's id, and the
#     first line must be a root. Together with line integrity this makes an
#     edit, a reorder, an insertion or a deletion all detectable.
#
# The line format mirrors lex-games' `src/arena/trail_file.lex`. It is
# re-implemented rather than imported so that a verifier's dependency closure
# stays small and `lex-trail` can stay rev-pinned; the compatibility of the two
# is asserted in tests/test_trail.lex against a real trail rather than assumed.
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

# Every event of a given kind, in order. The one piece of interpretation that
# is genuinely domain-neutral: derivers all start by selecting their own
# event kinds out of the chain.
fn of_kind(ls :: List[Line], kind :: Str) -> List[Line] {
  list.filter(ls, fn (l :: Line) -> Bool {
    l.kind == kind
  })
}

# The chain's head: the id of its last event.
#
# This is the whole point of a hash chain. `event.compute_id` folds the parent
# id into every event, so the head transitively commits to every event before
# it — truncate, extend, edit or reorder the chain and the head changes.
# Binding a run to this rather than to a file digest makes the evidence's
# CONTAINER irrelevant: the same chain verifies whether it arrived as a JSONL
# file, a row range in a database, or bytes over a socket.
#
# Safe against being handed a suffix of a real chain only because
# `chain_linked` separately requires the first line to be root-anchored.
fn head_id(ls :: List[Line]) -> Str {
  match list.head(list.reverse(ls)) {
    None => "",
    Some(l) => l.id,
  }
}

