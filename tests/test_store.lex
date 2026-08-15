# tests/test_store.lex — append → iterate → get round trip (#3)

import "../src/record" as rec

import "../src/store" as store

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "std.io" as io

fn store_path() -> Str {
  "/tmp/lex_notebooklab_test_store.jsonl"
}

# The store treats a missing file as empty, so truncating is enough to reset.
fn reset() -> [io] Result[Unit, Str] {
  match io.write(store_path(), "") {
    Err(e) => Err(e),
    Ok(_) => Ok(()),
  }
}

fn mk(attempt :: Str, denials :: Int) -> rec.Run {
  rec.seal({ run_id: "", attempt: attempt, series: "rl", trainer: "t.py", config_json: "{\"timesteps\":200000}", results_json: str.join(["{\"denials\":", int.to_str(denials), "}"], ""), evidence: [], notes: "", supersedes: "", created_at: 1750000000000, extra_json: "" })
}

fn test_append_iterate_get() -> [io] Result[Unit, Str] {
  match reset() {
    Err(e) => Err(e),
    Ok(_) => match store.append(store_path(), mk("1", 33)) {
      Err(e) => Err(e),
      Ok(first) => match store.append(store_path(), mk("2", 24)) {
        Err(e) => Err(e),
        Ok(second) => match store.read_all(store_path()) {
          Err(e) => Err(e),
          Ok(all_runs) => if not (list.len(all_runs) == 2) {
            Err(str.concat("expected 2 records, got ", int.to_str(list.len(all_runs))))
          } else {
            match store.get(store_path(), second.run_id) {
              Err(e) => Err(e),
              Ok(None) => Err("get could not find a record that was just appended"),
              Ok(Some(got)) => if got == second and not (got.run_id == first.run_id) {
                Ok(())
              } else {
                Err("get returned the wrong record")
              },
            }
          },
        },
      },
    },
  }
}

# Records survive the disk round trip with their content addresses intact —
# which is what lets someone who did not write the file re-verify it.
fn test_stored_records_stay_intact() -> [io] Result[Unit, Str] {
  match reset() {
    Err(e) => Err(e),
    Ok(_) => match store.append(store_path(), mk("1", 33)) {
      Err(e) => Err(e),
      Ok(_) => match store.read_all(store_path()) {
        Err(e) => Err(e),
        Ok(rs) => if list.is_empty(store.tampered_records(rs)) {
          Ok(())
        } else {
          Err("a record did not survive the disk round trip intact")
        },
      },
    },
  }
}

# Appending the same content twice is a no-op: the id is a content address, so
# the second copy carries no information the first did not.
fn test_append_is_idempotent() -> [io] Result[Unit, Str] {
  match reset() {
    Err(e) => Err(e),
    Ok(_) => match store.append(store_path(), mk("1", 33)) {
      Err(e) => Err(e),
      Ok(_) => match store.append(store_path(), mk("1", 33)) {
        Err(e) => Err(e),
        Ok(_) => match store.read_all(store_path()) {
          Err(e) => Err(e),
          Ok(rs) => if list.len(rs) == 1 {
            Ok(())
          } else {
            Err("re-appending identical content created a duplicate")
          },
        },
      },
    },
  }
}

# A correction is a new record, and the original stays on disk. `current`
# hides the superseded entry; `read_all` still shows both.
fn test_supersede_keeps_history() -> [io] Result[Unit, Str] {
  match reset() {
    Err(e) => Err(e),
    Ok(_) => match store.append(store_path(), mk("1", 33)) {
      Err(e) => Err(e),
      Ok(original) => match store.append(store_path(), rec.seal(rec.with_supersedes(mk("1", 24), original.run_id))) {
        Err(e) => Err(e),
        Ok(correction) => match store.read_all(store_path()) {
          Err(e) => Err(e),
          Ok(rs) => if not (list.len(rs) == 2) {
            Err("the superseded record was removed from disk")
          } else {
            let live := store.current(rs)
            if list.len(live) == 1 and list.fold(live, false, fn (acc :: Bool, r :: rec.Run) -> Bool {
              acc or r.run_id == correction.run_id
            }) {
              Ok(())
            } else {
              Err("current() did not resolve to the correcting record")
            }
          },
        },
      },
    },
  }
}

fn test_missing_store_is_empty() -> [io] Result[Unit, Str] {
  match store.read_all("/tmp/lex_notebooklab_no_such_store.jsonl") {
    Err(_) => Err("a missing store file was an error instead of an empty store"),
    Ok(rs) => if list.is_empty(rs) {
      Ok(())
    } else {
      Err("a missing store file produced records")
    },
  }
}

fn results() -> [io] List[Result[Unit, Str]] {
  [test_append_iterate_get(), test_stored_records_stay_intact(), test_append_is_idempotent(), test_supersede_keeps_history(), test_missing_store_is_empty()]
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
      Err(e) => io.print(str.concat("FAIL test_store: ", e)),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

