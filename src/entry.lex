# src/entry.lex — turning a submitted entry into a stored record
#
# Shared by both doors: the CLI (src/cli.lex) and the HTTP server
# (src/server.lex). Keeping it here rather than in either one means a run
# submitted over HTTP and the same run submitted on the command line get the
# same validation, the same evidence bindings and — because `run_id` is a
# content address — the same id.
#
# Effects: `[io]`, to read the entry's evidence files.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.json" as json

import "std.crypto" as crypto

import "./record" as rec

import "./store" as store

import "./trail" as tr

import "./derive" as derive

# The JSON a client submits. `config` and `results` are open maps, held as
# opaque `Json` on the parse side and normalised into canonical strings by
# `rec.build` so that key order cannot change a record's identity.
type EntryInput = { attempt :: Str, series :: Str, trainer :: Str, config :: Json, results :: Json, evidence :: List[rec.Evidence], notes :: Str, supersedes :: Str, created_at :: Int }

# Every field must be present. `json.parse_strict` reports a missing one as a
# clean error instead of letting a field access fail later — which matters
# most on the HTTP door, where the caller needs a 400 explaining what was
# wrong rather than a dropped connection.
fn required_fields() -> List[Str] {
  ["attempt", "series", "trainer", "config", "results", "evidence", "notes", "supersedes", "created_at"]
}

# ---- Evidence binding ----------------------------------------------------
# For a trail, the preferred binding is the chain head rather than the bytes:
# it commits to the same events while leaving the producer free to move or
# re-serialize the artifact. Filled in for any evidence kind that has a
# deriver, unless the submitter pinned one explicitly.
#
# Submission is where a broken chain should be caught, not months later at
# verify time — so a trail that fails its own integrity check is REJECTED
# here rather than stored with a binding to nonsense.
fn bind_trail_head(e :: rec.Evidence, content :: Str) -> Result[rec.Evidence, Str] {
  if not (str.is_empty(e.trail_head) and derive.has_deriver(e.kind)) {
    Ok(e)
  } else {
    match tr.parse_jsonl(content) {
      Err(msg) => Err(str.join(["evidence ", e.path, " is not a readable trail: ", msg], "")),
      Ok(lines) => if not tr.trail_intact(lines) {
        Err(str.join(["refusing to record ", e.path, ": its hash chain is already broken"], ""))
      } else {
        Ok({ kind: e.kind, path: e.path, sha256: e.sha256, trail_head: tr.head_id(lines) })
      },
    }
  }
}

fn bind_evidence(e :: rec.Evidence) -> [io] Result[rec.Evidence, Str] {
  match io.read(e.path) {
    Err(msg) => Err(str.join(["cannot read evidence ", e.path, ": ", msg], "")),
    Ok(content) => {
      let with_digest := if str.is_empty(e.sha256) and not derive.has_deriver(e.kind) {
        { kind: e.kind, path: e.path, sha256: crypto.sha256_str(content), trail_head: e.trail_head }
      } else {
        e
      }
      bind_trail_head(with_digest, content)
    },
  }
}

fn bind_all(es :: List[rec.Evidence]) -> [io] Result[List[rec.Evidence], Str] {
  list.fold(es, Ok([]), fn (acc :: Result[List[rec.Evidence], Str], e :: rec.Evidence) -> [io] Result[List[rec.Evidence], Str] {
    match acc {
      Err(msg) => Err(msg),
      Ok(done) => match bind_evidence(e) {
        Err(msg) => Err(msg),
        Ok(bound) => Ok(list.concat(done, [bound])),
      },
    }
  })
}

# ---- Ingest --------------------------------------------------------------
# Parse → bind evidence → seal → append. Everything that can fail does so
# BEFORE the append, so a rejected submission never leaves a partial write
# behind — the property issue #6 asks for on the HTTP door and which the CLI
# gets for free by sharing this path.
fn ingest(store_path :: Str, entry_json :: Str) -> [io] Result[rec.Run, Str] {
  let parsed :: Result[EntryInput, Str] := json.parse_strict(entry_json, required_fields())
  match parsed {
    Err(msg) => Err(str.concat("invalid entry: ", msg)),
    Ok(input) => match bind_all(input.evidence) {
      Err(msg) => Err(msg),
      Ok(evidence) => match rec.build(input.attempt, input.series, input.trainer, json.stringify(input.config), json.stringify(input.results), evidence, input.notes, input.supersedes, input.created_at) {
        Err(msg) => Err(msg),
        Ok(built) => store.append(store_path, built),
      },
    },
  }
}

