# tests/test_trail.lex — trail parsing and integrity (#4)
#
# Domain-neutral: this covers what a trail IS and whether it has been
# tampered with. What the events MEAN is a deriver's job, tested in
# tests/test_derive_robot.lex and tests/test_derive_loom.lex.

import "../src/trail" as tr

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "std.io" as io

fn trail_path() -> Str {
  "fixtures/xlerobot_rl_trail.jsonl"
}

fn tampered_path() -> Str {
  "fixtures/xlerobot_rl_trail_tampered.jsonl"
}

fn test_reads_the_fixture() -> [io] Result[Unit, Str] {
  match tr.read(trail_path()) {
    Err(e) => Err(str.concat("could not read fixture: ", e)),
    Ok(ls) => if list.len(ls) == 21 {
      Ok(())
    } else {
      Err(str.concat("expected 21 events, got ", int.to_str(list.len(ls))))
    },
  }
}

fn test_fixture_is_intact() -> [io] Result[Unit, Str] {
  match tr.read(trail_path()) {
    Err(e) => Err(e),
    Ok(ls) => if tr.trail_intact(ls) {
      Ok(())
    } else {
      Err("the reference trail failed its own integrity check")
    },
  }
}

# The forgery: one denial rewritten to "reached" without recomputing the ids.
# This is the cheapest possible way to fake a compliant run, and it must fail.
fn test_tampered_trail_is_rejected() -> [io] Result[Unit, Str] {
  match tr.read(tampered_path()) {
    Err(e) => Err(e),
    Ok(ls) => if tr.trail_intact(ls) {
      Err("a trail with an edited outcome passed the integrity check")
    } else {
      Ok(())
    },
  }
}

fn test_chain_detects_reordering() -> [io] Result[Unit, Str] {
  match tr.read(trail_path()) {
    Err(e) => Err(e),
    Ok(ls) => if tr.chain_linked(list.reverse(ls)) {
      Err("a reversed trail still passed the chain check")
    } else {
      Ok(())
    },
  }
}

fn results() -> [io] List[Result[Unit, Str]] {
  [test_reads_the_fixture(), test_fixture_is_intact(), test_tampered_trail_is_rejected(), test_chain_detects_reordering()]
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
      Err(e) => io.print(str.concat("FAIL test_trail: ", e)),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

