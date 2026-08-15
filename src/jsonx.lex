# src/jsonx.lex — reading fields out of JSON *text*
#
# Lex can parse JSON into a typed record, but not inspect one generically:
# there is no value-level Json API, and a record type with a field the input
# lacks fails at RUNTIME when that field is read. So for genuinely optional or
# open-shaped input — an upstream ledger entry whose schema this repo does not
# own — the workable approach is to read the text.
#
# std.regex rather than a hand-rolled scanner, per the guidelines' stdlib-first
# rule. The one thing regex cannot do is find a nested object's end, because
# that needs brace counting; `object_at` does exactly that and nothing more.
#
# Scope of what this is for: compact, machine-written JSON (lex-robot's ledger
# is emitted with `json.dumps(..., separators=(",",":"))`). It is not a
# general JSON parser and should not grow into one — when a shape is known and
# required, use `json.parse` and let the type checker do the work.
#
# Effects: none.

import "std.str" as str

import "std.list" as list

import "std.float" as flt

import "std.regex" as regex

type Match = { text :: Str, start :: Int, end :: Int, groups :: List[Str] }

type GroupPick = { idx :: Int, found :: Str }

fn nth_str(xs :: List[Str], i :: Int) -> Str
  examples {
    nth_str([], 0) => "",
    nth_str(["a", "b"], 0) => "a",
    nth_str(["a", "b"], 1) => "b",
    nth_str(["a", "b"], 5) => ""
  }
{
  let picked := list.fold(xs, { idx: 0, found: "" }, fn (acc :: GroupPick, g :: Str) -> GroupPick {
    if acc.idx == i {
      { idx: acc.idx + 1, found: g }
    } else {
      { idx: acc.idx + 1, found: acc.found }
    }
  })
  picked.found
}

fn group_at(m :: Match, i :: Int) -> Str {
  nth_str(m.groups, i)
}

fn matches_of(pattern :: Str, src :: Str) -> List[Match] {
  match regex.compile(pattern) {
    Err(_) => [],
    Ok(re) => regex.find_all(re, src),
  }
}

fn first_match(pattern :: Str, src :: Str) -> Option[Match] {
  match regex.compile(pattern) {
    Err(_) => None,
    Ok(re) => regex.find(re, src),
  }
}

# ---- Scalar fields -------------------------------------------------------
# A string-valued field, or "" when absent. The trailing `":` in the pattern
# is what stops `"violations"` from also matching `"violations_after"`.
fn str_field(src :: Str, key :: Str) -> Str {
  match first_match(str.join(["\"", key, "\"[ ]*:[ ]*\"([^\"]*)\""], ""), src) {
    None => "",
    Some(m) => group_at(m, 0),
  }
}

# A numeric field as its literal text, so the caller decides how to scale it.
# `None` covers both "absent" and "present but null" — for a ledger, a null is
# "not recorded", which is not a claim and must not become one.
fn num_field(src :: Str, key :: Str) -> Option[Str] {
  match first_match(str.join(["\"", key, "\"[ ]*:[ ]*(-?[0-9]+\\.?[0-9]*)"], ""), src) {
    None => None,
    Some(m) => Some(group_at(m, 0)),
  }
}

fn has_key(src :: Str, key :: Str) -> Bool {
  match first_match(str.join(["\"", key, "\"[ ]*:"], ""), src) {
    None => false,
    Some(_) => true,
  }
}

# ---- Nested objects ------------------------------------------------------
# The value of `key` as raw text, brace-matched, or "" when absent. Needed
# because a regex cannot tell which `}` closes an object, and reading a nested
# `violations` map without it would also sweep up the identically-shaped one
# inside a `ckpt_*_replay` sibling — silently doubling every count.
type Scan = { i :: Int, depth :: Int, in_str :: Bool, esc :: Bool, done :: Bool }

fn scan_step(src :: Str, st :: Scan) -> Scan {
  let c := str.char_at(src, st.i)
  if st.esc {
    { i: st.i + 1, depth: st.depth, in_str: st.in_str, esc: false, done: false }
  } else {
    if st.in_str {
      if c == "\\" {
        { i: st.i + 1, depth: st.depth, in_str: true, esc: true, done: false }
      } else {
        { i: st.i + 1, depth: st.depth, in_str: not (c == "\""), esc: false, done: false }
      }
    } else {
      if c == "\"" {
        { i: st.i + 1, depth: st.depth, in_str: true, esc: false, done: false }
      } else {
        if c == "{" {
          { i: st.i + 1, depth: st.depth + 1, in_str: false, esc: false, done: false }
        } else {
          if c == "}" {
            { i: st.i + 1, depth: st.depth - 1, in_str: false, esc: false, done: st.depth - 1 == 0 }
          } else {
            { i: st.i + 1, depth: st.depth, in_str: false, esc: false, done: false }
          }
        }
      }
    }
  }
}

fn scan_to_close(src :: Str, st :: Scan) -> Int {
  if st.done {
    st.i
  } else {
    if st.i >= str.len(src) {
      0 - 1
    } else {
      scan_to_close(src, scan_step(src, st))
    }
  }
}

fn object_at(src :: Str, key :: Str) -> Str {
  match first_match(str.join(["\"", key, "\"[ ]*:[ ]*\\{"], ""), src) {
    None => "",
    Some(m) => {
      let open_at := m.end - 1
      let close_at := scan_to_close(src, { i: open_at, depth: 0, in_str: false, esc: false, done: false })
      if close_at < 0 {
        ""
      } else {
        str.slice(src, open_at, close_at)
      }
    },
  }
}

# ---- Scaling -------------------------------------------------------------
# Upstream records metres and rates as decimals; this package compares
# integers so that two verifiers agree bit for bit. Both convert by rounding
# to nearest, not truncating — 0.613 m is 613 mm, and `flt.to_int` alone would
# make it 612.
fn scaled(literal :: Str, factor :: Float) -> Option[Int] {
  match str.to_float(literal) {
    None => None,
    Some(x) => Some(if x < 0.0 {
      0 - flt.to_int((0.0 - x) * factor + 0.5)
    } else {
      flt.to_int(x * factor + 0.5)
    }),
  }
}

fn milli(literal :: Str) -> Option[Int]
  examples {
    milli("0.613") => Some(613),
    milli("0.744") => Some(744),
    milli("1.167") => Some(1167),
    milli("0") => Some(0),
    milli("nope") => None
  }
{
  scaled(literal, 1000.0)
}

fn pct(literal :: Str) -> Option[Int]
  examples {
    pct("0.5") => Some(50),
    pct("0.69") => Some(69),
    pct("0.46") => Some(46),
    pct("nope") => None
  }
{
  scaled(literal, 100.0)
}

# ---- Top-level lookup ----------------------------------------------------
# `object_at` finds the FIRST match, which is wrong when a nested sibling
# carries the same key: lex-robot's attempt 9 has a `ckpt_2500000_replay`
# object with its own `violations` map, and it appears in the text before the
# real one. Reading that instead silently substitutes a 4-violation replay
# profile for a 22-violation run. So a key that is meant to be a direct member
# has to be found at depth 1, not merely found.
type KeyScan = { i :: Int, depth :: Int, in_str :: Bool, esc :: Bool, found :: Int }

fn starts_with_at(src :: Str, i :: Int, needle :: Str) -> Bool {
  if i + str.len(needle) > str.len(src) {
    false
  } else {
    str.slice(src, i, i + str.len(needle)) == needle
  }
}

fn key_scan(src :: Str, needle :: Str, st :: KeyScan) -> Int {
  if st.found >= 0 {
    st.found
  } else {
    if st.i >= str.len(src) {
      0 - 1
    } else {
      let c := str.char_at(src, st.i)
      if st.esc {
        key_scan(src, needle, { i: st.i + 1, depth: st.depth, in_str: st.in_str, esc: false, found: 0 - 1 })
      } else {
        if st.in_str {
          key_scan(src, needle, if c == "\\" {
            { i: st.i + 1, depth: st.depth, in_str: true, esc: true, found: 0 - 1 }
          } else {
            { i: st.i + 1, depth: st.depth, in_str: not (c == "\""), esc: false, found: 0 - 1 }
          })
        } else {
          if st.depth == 1 and starts_with_at(src, st.i, needle) {
            st.i
          } else {
            key_scan(src, needle, { i: st.i + 1, depth: if c == "{" {
              st.depth + 1
            } else {
              if c == "}" {
                st.depth - 1
              } else {
                st.depth
              }
            }, in_str: c == "\"", esc: false, found: 0 - 1 })
          }
        }
      }
    }
  }
}

# The value of a DIRECT member `key`, or "" when there is no such member.
fn object_at_top(src :: Str, key :: Str) -> Str {
  let at := key_scan(src, str.join(["\"", key, "\""], ""), { i: 0, depth: 0, in_str: false, esc: false, found: 0 - 1 })
  if at < 0 {
    ""
  } else {
    object_at(str.slice(src, at, str.len(src)), key)
  }
}

