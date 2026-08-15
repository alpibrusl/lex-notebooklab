# tests/test_import.lex — importing lex-robot's experiment ledger (#7)
#
# The corpus under test is a committed copy of the real thing
# (`fixtures/lex_robot_experiments.jsonl` ← lex-robot `docs/experiments.jsonl`,
# 12 attempts). Two properties matter more than the counts:
#
#   * Nothing in that ledger has a surviving trail, so every imported record
#     must read UNVERIFIABLE. An import that produced green ticks would be
#     worse than no import at all.
#   * The upstream entry survives verbatim, so the corpus can be handed back
#     field for field.

import "../src/import" as imp

import "../src/store" as store

import "../src/verify" as vfy

import "../src/record" as rec

import "../src/jsonx" as jx

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "std.io" as io

fn ledger() -> Str {
  "fixtures/lex_robot_experiments.jsonl"
}

fn store_path() -> Str {
  "/tmp/lex_notebooklab_test_import.jsonl"
}

fn fresh() -> [io] Result[List[rec.Run], Str] {
  match io.write(store_path(), "") {
    Err(e) => Err(e),
    Ok(_) => match imp.import_ledger(ledger(), store_path()) {
      Err(e) => Err(e),
      Ok(_) => store.read_all(store_path()),
    },
  }
}

fn by_attempt(rs :: List[rec.Run], attempt :: Str) -> Option[rec.Run] {
  list.head(list.filter(rs, fn (r :: rec.Run) -> Bool {
    r.attempt == attempt
  }))
}

fn test_imports_the_whole_corpus() -> [io] Result[Unit, Str] {
  match fresh() {
    Err(e) => Err(e),
    Ok(rs) => if list.len(rs) == 12 {
      Ok(())
    } else {
      Err(str.concat("expected 12 imported records, got ", int.to_str(list.len(rs))))
    },
  }
}

# The honesty test. None of these runs kept a trail, so a green tick anywhere
# would mean the importer had invented evidence.
fn test_every_import_is_unverifiable() -> [io] Result[Unit, Str] {
  match fresh() {
    Err(e) => Err(e),
    Ok(rs) => {
      let verdicts := list.map(rs, fn (r :: rec.Run) -> [io] vfy.Status {
        vfy.overall(vfy.verify_run(r))
      })
      let not_unverifiable := list.filter(verdicts, fn (s :: vfy.Status) -> Bool {
        not (s == Unverifiable)
      })
      if list.is_empty(not_unverifiable) {
        Ok(())
      } else {
        Err("an imported run reported something other than UNVERIFIABLE")
      }
    },
  }
}

# ...and UNVERIFIABLE must still exit 0: "we checked what could be checked" is
# a pass, so importing this corpus does not turn CI red.
fn test_unverifiable_corpus_exits_zero() -> Result[Unit, Str] {
  if vfy.exit_code(Unverifiable) == 0 {
    Ok(())
  } else {
    Err("an honestly unverifiable corpus would fail CI")
  }
}

fn expect_claim(rs :: List[rec.Run], attempt :: Str, key :: Str, want :: Str) -> Result[Unit, Str] {
  match by_attempt(rs, attempt) {
    None => Err(str.concat("no imported record for attempt ", attempt)),
    Some(r) => match jx.num_field(r.results_json, key) {
      None => Err(str.join(["attempt ", attempt, ": no claim ", key], "")),
      Some(got) => if got == want {
        Ok(())
      } else {
        Err(str.join(["attempt ", attempt, " ", key, ": expected ", want, ", got ", got], ""))
      },
    },
  }
}

# Attempt 9 carries BOTH a top-level violations map (22 violations on x) and a
# `ckpt_2500000_replay` sub-object with its own (4 on x), and the replay one
# comes first in the text. Reading the wrong one would quietly substitute a
# checkpoint's profile for the run's — the single subtlest failure in this
# importer, so it gets its own test.
fn test_nested_replay_profile_is_not_mistaken_for_the_run() -> [io] Result[Unit, Str] {
  match fresh() {
    Err(e) => Err(e),
    Ok(rs) => match expect_claim(rs, "9", "move_to.x.violations", "22") {
      Err(e) => Err(e),
      Ok(_) => expect_claim(rs, "9", "move_to.x.mean_overshoot_milli", "613"),
    },
  }
}

# Metres in, milli-units out: 0.613 m IS 613 mm, and the rate 0.5 IS 50%.
fn test_units_are_scaled_not_truncated() -> [io] Result[Unit, Str] {
  match fresh() {
    Err(e) => Err(e),
    Ok(rs) => match expect_claim(rs, "9", "denial_rate_pct", "50") {
      Err(e) => Err(e),
      Ok(_) => match expect_claim(rs, "8", "denial_rate_pct", "73") {
        Err(e) => Err(e),
        Ok(_) => expect_claim(rs, "10", "denial_rate_pct", "46"),
      },
    },
  }
}

# Attempt 4 reports its profile under `violations_after` rather than
# `violations`; it must still be imported.
fn test_violations_after_is_imported() -> [io] Result[Unit, Str] {
  match fresh() {
    Err(e) => Err(e),
    Ok(rs) => expect_claim(rs, "4", "move_to.x.violations", "22"),
  }
}

# Attempts 1-3 record `"denial_rate": null` — the run did not measure one.
# That is not a claim of zero, and must not become one.
fn test_null_rate_is_not_a_claim() -> [io] Result[Unit, Str] {
  match fresh() {
    Err(e) => Err(e),
    Ok(rs) => match by_attempt(rs, "1") {
      None => Err("no imported record for attempt 1"),
      Some(r) => match jx.num_field(r.results_json, "denial_rate_pct") {
        Some(v) => Err(str.concat("a null denial_rate became a claim of ", v)),
        None => Ok(()),
      },
    },
  }
}

# Partial dates are real in this ledger: attempts 1-3 record only "2026-08".
fn test_partial_dates_resolve() -> [io] Result[Unit, Str] {
  match fresh() {
    Err(e) => Err(e),
    Ok(rs) => match by_attempt(rs, "1") {
      None => Err("no imported record for attempt 1"),
      Some(r) => if r.created_at == 1785542400000 {
        Ok(())
      } else {
        Err(str.concat("a month-only date resolved to ", int.to_str(r.created_at)))
      },
    },
  }
}

# The round-trip guarantee: every record still carries its upstream entry, and
# an export produces one line per imported run.
fn test_sources_are_preserved_for_export() -> [io] Result[Unit, Str] {
  match fresh() {
    Err(e) => Err(e),
    Ok(rs) => {
      let sourceless := list.filter(rs, fn (r :: rec.Run) -> Bool {
        r.source_json == "{}"
      })
      if not list.is_empty(sourceless) {
        Err("an imported record lost its upstream entry")
      } else {
        match imp.export_sources(store_path()) {
          Err(e) => Err(e),
          Ok(text) => if list.len(store.non_empty_lines(text)) == 12 {
            Ok(())
          } else {
            Err("export did not reproduce one line per imported run")
          },
        }
      }
    },
  }
}

# Re-importing is a no-op rather than a duplicate: run_id is a content
# address, so the same ledger entry always hashes to the same record.
fn test_reimport_is_idempotent() -> [io] Result[Unit, Str] {
  match fresh() {
    Err(e) => Err(e),
    Ok(_) => match imp.import_ledger(ledger(), store_path()) {
      Err(e) => Err(e),
      Ok(_) => match store.read_all(store_path()) {
        Err(e) => Err(e),
        Ok(rs) => if list.len(rs) == 12 {
          Ok(())
        } else {
          Err(str.concat("re-import duplicated records: now ", int.to_str(list.len(rs))))
        },
      },
    },
  }
}

fn results() -> [io] List[Result[Unit, Str]] {
  [test_imports_the_whole_corpus(), test_every_import_is_unverifiable(), test_unverifiable_corpus_exits_zero(), test_nested_replay_profile_is_not_mistaken_for_the_run(), test_units_are_scaled_not_truncated(), test_violations_after_is_imported(), test_null_rate_is_not_a_claim(), test_partial_dates_resolve(), test_sources_are_preserved_for_export(), test_reimport_is_idempotent()]
}

fn run_all() -> [io] Unit {
  let failures := list.filter(results(), fn (r :: Result[Unit, Str]) -> Bool {
    match r {
      Ok(_) => false,
      Err(_) => true,
    }
  })
  let __p := list.map(failures, fn (r :: Result[Unit, Str]) -> [io] Unit {
    match r {
      Ok(_) => (),
      Err(e) => io.print(str.concat("FAIL test_import: ", e)),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

