# src/cli.lex — record / list / show / verify (issue #5)
#
# Each subcommand prints an acli envelope (and, where it helps, a human table
# above it) and RETURNS its exit code. `lex run` prints a function's return
# value last and always exits 0 itself, so returning the code puts it on the
# final line where `bin/notebooklab` can lift it into a real process exit
# status. That wrapper is what makes the codes below usable from CI.
#
# Exit codes (src/verify.lex `exit_code`) are semantic, which is what makes
# `notebooklab verify` usable as a CI compliance gate:
#
#   0  every claim verified, or honestly unverifiable
#   2  usage / input error (bad JSON, unknown run id)
#   3  MISMATCH — a claim contradicts the evidence
#   4  TAMPERED — the evidence itself does not hold up
#
# Effects: `[io]` — reading the store and the entry file, writing the store,
# printing.

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "./record" as rec

import "./store" as store

import "./verify" as vfy

import "./entry" as entry

# ---- Envelopes -----------------------------------------------------------
fn envelope(ok :: Bool, command :: Str, exit_code :: Int, data_json :: Str) -> Str {
  str.join(["{\"ok\":", if ok {
    "true"
  } else {
    "false"
  }, ",\"command\":\"", command, "\",\"exit_code\":", int.to_str(exit_code), ",\"data\":", data_json, "}"], "")
}

fn err_envelope(command :: Str, exit_code :: Int, message :: Str) -> Str {
  envelope(false, command, exit_code, str.join(["{\"error\":", rec.quoted(message), "}"], ""))
}

# Print the envelope and hand back its exit code. The code is what the
# function returns, so it lands on the last line of `lex run` output and
# `bin/notebooklab` can lift it into a real process exit status.
fn emit(s :: Str, code :: Int) -> [io] Int {
  let __p := io.print(s)
  code
}

# ---- record --------------------------------------------------------------
# The submission path itself lives in src/entry.lex, shared with the HTTP
# door, so a run submitted here and the same run submitted over HTTP get
# identical validation, identical evidence bindings and — because `run_id` is
# a content address — the same id.
fn record(store_path :: Str, entry_path :: Str) -> [io] Int {
  match io.read(entry_path) {
    Err(msg) => emit(err_envelope("record", 2, str.join(["cannot read entry ", entry_path, ": ", msg], "")), 2),
    Ok(content) => match entry.ingest(store_path, content) {
      Err(msg) => emit(err_envelope("record", 2, msg), 2),
      Ok(saved) => emit(envelope(true, "record", 0, str.join(["{\"run_id\":", rec.quoted(saved.run_id), ",\"store\":", rec.quoted(store_path), "}"], "")), 0),
    },
  }
}

# ---- list ----------------------------------------------------------------
fn summary_json(r :: rec.Run) -> Str {
  str.join(["{\"run_id\":", rec.quoted(r.run_id), ",\"attempt\":", rec.quoted(r.attempt), ",\"series\":", rec.quoted(r.series), ",\"trainer\":", rec.quoted(r.trainer), ",\"evidence\":", int.to_str(list.len(r.evidence)), ",\"results\":", r.results_json, "}"], "")
}

fn list_json(store_path :: Str) -> [io] Int {
  match store.read_all(store_path) {
    Err(msg) => emit(err_envelope("list", 2, msg), 2),
    Ok(rs) => emit(envelope(true, "list", 0, str.join(["{\"runs\":[", str.join(list.map(rs, summary_json), ","), "],\"count\":", int.to_str(list.len(rs)), "}"], "")), 0),
  }
}

fn short_id(id :: Str) -> Str
  examples {
    short_id("") => "",
    short_id("0123456789abcdef0123") => "0123456789ab"
  }
{
  if str.len(id) <= 12 {
    id
  } else {
    str.slice(id, 0, 12)
  }
}

fn pad(s :: Str, width :: Int) -> Str
  examples {
    pad("ab", 4) => "ab  ",
    pad("abcdef", 4) => "abcdef"
  }
{
  if str.len(s) >= width {
    s
  } else {
    pad(str.concat(s, " "), width)
  }
}

fn table_row(r :: rec.Run) -> Str {
  str.join([pad(short_id(r.run_id), 14), pad(r.attempt, 10), pad(r.series, 26), pad(int.to_str(list.len(r.evidence)), 10), r.results_json], "")
}

fn list_runs(store_path :: Str) -> [io] Int {
  match store.read_all(store_path) {
    Err(msg) => emit(err_envelope("list", 2, msg), 2),
    Ok(rs) => {
      let __h := io.print(str.join([pad("RUN", 14), pad("ATTEMPT", 10), pad("SERIES", 26), pad("EVIDENCE", 10), "RESULTS"], ""))
      let __rows := list.map(rs, fn (r :: rec.Run) -> [io] Unit {
        io.print(table_row(r))
      })
      emit(envelope(true, "list", 0, str.concat("{\"count\":", str.concat(int.to_str(list.len(rs)), "}"))), 0)
    },
  }
}

# ---- show ----------------------------------------------------------------
fn show(store_path :: Str, run_id :: Str) -> [io] Int {
  match store.get(store_path, run_id) {
    Err(msg) => emit(err_envelope("show", 2, msg), 2),
    Ok(None) => emit(err_envelope("show", 2, str.concat("no such run: ", run_id)), 2),
    Ok(Some(r)) => emit(envelope(true, "show", 0, rec.to_json(r)), 0),
  }
}

# ---- verify --------------------------------------------------------------
fn claim_json(c :: vfy.ClaimVerdict) -> Str {
  str.join(["{\"key\":", rec.quoted(c.key), ",\"status\":\"", vfy.status_str(c.status), "\",\"claimed\":", rec.quoted(c.claimed), ",\"derived\":", rec.quoted(c.derived), ",\"detail\":", rec.quoted(c.detail), "}"], "")
}

fn verdict_json(v :: vfy.RunVerdict) -> Str {
  str.join(["{\"run_id\":", rec.quoted(v.run_id), ",\"status\":\"", vfy.status_str(vfy.overall(v)), "\",\"evidence\":\"", vfy.status_str(v.trail_status), "\",\"evidence_detail\":", rec.quoted(v.trail_detail), ",\"claims\":[", str.join(list.map(v.claims, claim_json), ","), "]}"], "")
}

fn print_verdict(v :: vfy.RunVerdict) -> [io] Unit {
  let __h := io.print(str.join([short_id(v.run_id), "  ", vfy.status_str(vfy.overall(v)), "  (evidence: ", vfy.status_str(v.trail_status), " — ", v.trail_detail, ")"], ""))
  let __rows := list.map(v.claims, fn (c :: vfy.ClaimVerdict) -> [io] Unit {
    io.print(str.join(["    ", pad(c.key, 34), pad(vfy.status_str(c.status), 14), if c.status == Mismatch {
      str.join(["claimed ", c.claimed, ", derived ", c.derived], "")
    } else {
      c.detail
    }], ""))
  })
  ()
}

fn verify_one(store_path :: Str, run_id :: Str) -> [io] Int {
  match store.get(store_path, run_id) {
    Err(msg) => emit(err_envelope("verify", 2, msg), 2),
    Ok(None) => emit(err_envelope("verify", 2, str.concat("no such run: ", run_id)), 2),
    Ok(Some(r)) => {
      let v := vfy.verify_run(r)
      let __p := print_verdict(v)
      let code := vfy.exit_code(vfy.overall(v))
      emit(envelope(code == 0, "verify", code, verdict_json(v)), code)
    },
  }
}

# Verify every record in the store. The exit code is the WORST outcome across
# all runs, so a single forged trail fails the whole check — which is the
# behaviour a CI gate needs.
fn verify_all(store_path :: Str) -> [io] Int {
  match store.read_all(store_path) {
    Err(msg) => emit(err_envelope("verify", 2, msg), 2),
    Ok(rs) => {
      let verdicts := list.map(rs, fn (r :: rec.Run) -> [io] vfy.RunVerdict {
        vfy.verify_run(r)
      })
      let __p := list.map(verdicts, print_verdict)
      let worst := list.fold(verdicts, Verified, fn (acc :: vfy.Status, v :: vfy.RunVerdict) -> vfy.Status {
        vfy.worst(acc, vfy.overall(v))
      })
      let code := vfy.exit_code(worst)
      emit(envelope(code == 0, "verify", code, str.join(["{\"status\":\"", vfy.status_str(worst), "\",\"runs\":[", str.join(list.map(verdicts, verdict_json), ","), "],\"count\":", int.to_str(list.len(rs)), "}"], "")), code)
    },
  }
}

