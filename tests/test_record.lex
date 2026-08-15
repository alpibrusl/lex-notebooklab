# tests/test_record.lex — run-record schema, content address, round trip (#3)

import "../src/record" as rec

import "std.list" as list

import "std.str" as str

import "std.io" as io

fn sample() -> rec.Run {
  rec.seal({ run_id: "", attempt: "4", series: "usage-informed-finetune", trainer: "sidecar/xlerobot_rl_finetune.py", config_json: "{\"seed\":0,\"timesteps\":100000}", results_json: "{\"actions\":16,\"denials\":8}", evidence: [{ kind: "replay_trail", path: "fixtures/xlerobot_rl_trail.jsonl", sha256: "e6a2b0c7077a1a78c71208e6e3d6b49e7fa2ce7a6c9e24cc8fae19157d0e493e", trail_head: "8add8b4a511cbf5a671f13e149cb323614c5b82b76a59711f8340b288c1ff1b2" }], notes: "y-violations eliminated", supersedes: "", created_at: 1750000000000, extra_json: "", source_json: "{}" })
}

fn test_seal_is_idempotent() -> Result[Unit, Str] {
  if rec.seal(sample()) == sample() {
    Ok(())
  } else {
    Err("sealing an already-sealed record changed it")
  }
}

fn test_sealed_record_is_intact() -> Result[Unit, Str] {
  if rec.is_intact(sample()) {
    Ok(())
  } else {
    Err("a freshly sealed record failed its own integrity check")
  }
}

# The property the whole package leans on: you cannot edit a stored record and
# keep its id. Changing a single claim must break the content address.
fn test_edited_record_is_detected() -> Result[Unit, Str] {
  let s := sample()
  let forged := { run_id: s.run_id, attempt: s.attempt, series: s.series, trainer: s.trainer, config_json: s.config_json, results_json: "{\"actions\":16,\"denials\":0}", evidence: s.evidence, notes: s.notes, supersedes: s.supersedes, created_at: s.created_at, extra_json: s.extra_json, source_json: s.source_json }
  if not rec.is_intact(forged) {
    Ok(())
  } else {
    Err("editing the denial count did not break the record id")
  }
}

fn test_id_ignores_the_id_field() -> Result[Unit, Str] {
  if rec.compute_id(rec.with_id(sample(), "whatever")) == rec.compute_id(sample()) {
    Ok(())
  } else {
    Err("run_id leaked into its own content address")
  }
}

# A record written out and read back must be the same record — including its
# id, which is what makes the store re-verifiable by a third party.
fn test_json_round_trip() -> Result[Unit, Str] {
  match rec.from_json(rec.to_json(sample())) {
    Err(e) => Err(str.concat("round trip failed to parse: ", e)),
    Ok(back) => if back == sample() {
      Ok(())
    } else {
      Err(str.join(["round trip changed the record: ", rec.to_json(back), " != ", rec.to_json(sample())], ""))
    },
  }
}

fn test_round_trip_preserves_id() -> Result[Unit, Str] {
  match rec.from_json(rec.to_json(sample())) {
    Err(e) => Err(e),
    Ok(back) => if rec.is_intact(back) {
      Ok(())
    } else {
      Err("a record read back from its own wire form no longer verifies")
    },
  }
}

# Key order must not change a record's identity: two clients sending the same
# logical config have to agree on the id.
fn test_build_normalises_key_order() -> Result[Unit, Str] {
  let a := rec.build("1", "s", "t", "{\"b\":2,\"a\":1}", "{}", [], "", "", 0)
  let b := rec.build("1", "s", "t", "{\"a\":1,\"b\":2}", "{}", [], "", "", 0)
  match a {
    Err(e) => Err(e),
    Ok(ra) => match b {
      Err(e) => Err(e),
      Ok(rb) => if ra.run_id == rb.run_id {
        Ok(())
      } else {
        Err("key order changed the content address")
      },
    },
  }
}

fn test_build_rejects_bad_json() -> Result[Unit, Str] {
  match rec.build("1", "s", "t", "{not json", "{}", [], "", "", 0) {
    Ok(_) => Err("invalid config JSON was accepted"),
    Err(_) => Ok(()),
  }
}

fn test_evidence_lookup() -> Result[Unit, Str] {
  match rec.evidence_of_kind(sample().evidence, "checkpoint") {
    Some(_) => Err("found a checkpoint that was never bound"),
    None => match rec.evidence_of_kind(sample().evidence, "replay_trail") {
      None => Err("bound replay_trail was not found"),
      Some(_) => Ok(()),
    },
  }
}

fn test_no_evidence_is_visible() -> Result[Unit, Str] {
  if rec.has_evidence(rec.blank()) {
    Err("a record with no evidence claimed to have some")
  } else {
    Ok(())
  }
}

fn results() -> List[Result[Unit, Str]] {
  [test_seal_is_idempotent(), test_sealed_record_is_intact(), test_edited_record_is_detected(), test_id_ignores_the_id_field(), test_json_round_trip(), test_round_trip_preserves_id(), test_build_normalises_key_order(), test_build_rejects_bad_json(), test_evidence_lookup(), test_no_evidence_is_visible()]
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
      Err(e) => io.print(str.concat("FAIL test_record: ", e)),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

