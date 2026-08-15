# src/store.lex — the append-only run store (issue #3)
#
# One JSON object per line, newest last. There is deliberately no update and no
# delete in this API, mirroring lex-os's audit-log convention: a correction is
# a NEW record naming the one it replaces via `supersedes`, so the history of
# what was believed and when survives. Adding an edit or truncate function here
# would quietly destroy the property the rest of the package is built on.
#
# HONEST LIMITATION, since "append-only" can be read as a stronger promise than
# this implementation makes: `std.io` offers `read` and `write` but no O_APPEND
# primitive, so `append` is read-modify-write. The API is append-only; the file
# operation is not atomic, and two concurrent writers can lose a record. That
# is acceptable for a single-operator lab tool (the same trust model lex-robot's
# fleet arbiter documents for itself) and is the first thing to fix if this ever
# takes concurrent writers — see the README.
#
# Effects: `[io]`, and only on the store path the caller passes in.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "./record" as rec

# ---- Reading -------------------------------------------------------------
fn non_empty_lines(content :: Str) -> List[Str]
  examples {
    non_empty_lines("") => [],
    non_empty_lines("{}\n{}") => ["{}", "{}"],
    non_empty_lines("{}\n\n") => ["{}"]
  }
{
  list.filter(str.split(content, "\n"), fn (s :: Str) -> Bool {
    not str.is_empty(str.trim(s))
  })
}

fn parse_all(content :: Str) -> Result[List[rec.Run], Str] {
  list.fold(non_empty_lines(content), Ok([]), fn (acc :: Result[List[rec.Run], Str], line :: Str) -> Result[List[rec.Run], Str] {
    match acc {
      Err(e) => Err(e),
      Ok(rs) => match rec.from_json(line) {
        Err(e) => Err(e),
        Ok(r) => Ok(list.concat(rs, [r])),
      },
    }
  })
}

# Read every record. A missing store file is an EMPTY store, not an error —
# the first `record` call on a fresh checkout must work.
fn read_all(path :: Str) -> [io] Result[List[rec.Run], Str] {
  match io.read(path) {
    Err(_) => Ok([]),
    Ok(content) => parse_all(content),
  }
}

fn get(path :: Str, run_id :: Str) -> [io] Result[Option[rec.Run], Str] {
  match read_all(path) {
    Err(e) => Err(e),
    Ok(rs) => Ok(list.head(list.filter(rs, fn (r :: rec.Run) -> Bool {
      r.run_id == run_id
    }))),
  }
}

# ---- Writing -------------------------------------------------------------
fn render(rs :: List[rec.Run]) -> Str {
  str.join(list.map(rs, rec.to_json), "\n")
}

# Append a record, sealing it first so the stored id always matches the stored
# content. Re-appending an identical record is a no-op rather than a duplicate:
# the id is a content address, so the second copy carries no new information.
fn append(path :: Str, r :: rec.Run) -> [io] Result[rec.Run, Str] {
  let sealed := rec.seal(r)
  match read_all(path) {
    Err(e) => Err(e),
    Ok(existing) => if already_present(existing, sealed.run_id) {
      Ok(sealed)
    } else {
      match io.write(path, render(list.concat(existing, [sealed]))) {
        Err(e) => Err(e),
        Ok(_) => Ok(sealed),
      }
    },
  }
}

fn already_present(rs :: List[rec.Run], run_id :: Str) -> Bool {
  list.fold(rs, false, fn (acc :: Bool, r :: rec.Run) -> Bool {
    acc or r.run_id == run_id
  })
}

# ---- Integrity -----------------------------------------------------------
# Every stored record's id must still recompute from its content. This is the
# store-level analogue of the trail's hash chain: it catches an edit made to
# `runs.jsonl` with a text editor.
fn tampered_records(rs :: List[rec.Run]) -> List[rec.Run] {
  list.filter(rs, fn (r :: rec.Run) -> Bool {
    not rec.is_intact(r)
  })
}

# The records that nothing supersedes — the current view of the ledger, with
# corrected entries filtered out but still on disk.
fn superseded_ids(rs :: List[rec.Run]) -> List[Str] {
  list.filter(list.map(rs, fn (r :: rec.Run) -> Str {
    r.supersedes
  }), fn (s :: Str) -> Bool {
    not str.is_empty(s)
  })
}

fn current(rs :: List[rec.Run]) -> List[rec.Run] {
  let dead := superseded_ids(rs)
  list.filter(rs, fn (r :: rec.Run) -> Bool {
    not list.fold(dead, false, fn (acc :: Bool, d :: Str) -> Bool {
      acc or d == r.run_id
    })
  })
}

