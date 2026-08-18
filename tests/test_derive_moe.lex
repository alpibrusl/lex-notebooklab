# tests/test_derive_moe.lex — signed evidence, and what its verdict means
#
# The loom deriver proved the seam between "verify a trail" and "interpret a
# trail" was in the right place. This file proves something different: that
# the split above BOTH of those — how a piece of evidence establishes its own
# integrity — is also a seam, and that a second family fits through it without
# the chain machinery being bent to accommodate it.
#
# The cases below are chosen for the ways this can go quietly wrong:
#   * a signature that verifies, over the bytes as carried
#   * an edited claim inside those bytes, which must REPUDIATE rather than
#     re-derive — the failure a JSON-shaped verifier would sail through
#   * a swapped signer, likewise
#   * `pass` recomputed from the numbers rather than read back, so a signed
#     statement that contradicts itself cannot present as verified
#
# Fixture provenance, in full, in the spirit of the README's own section:
# `fixtures/moe_parity_attestation.env.json` was produced by lex-moe's real
# `moe attest` — not authored here — running the actual pipeline
# (`gen-fixture` -> `ingest` -> `quantize --scheme q8_0` -> `attest`) over a
# deterministic 2-layer/4-expert OLMoE-shaped checkpoint. The MEASUREMENT is
# therefore real code measuring real tensors, and the signature is a real
# ed25519 signature over the bytes it signed. What is synthetic is the model:
# a generated fixture, not a trained checkpoint. Nothing here claims a
# quantization result about any published model.

import "../src/attest" as attest

import "../src/metric" as met

import "../src/derive" as derive

import "../src/derive/moe" as moe

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "std.io" as io

fn envelope_path() -> Str {
  "fixtures/moe_parity_attestation.env.json"
}

fn statement() -> [io] Result[Str, Str] {
  match io.read(envelope_path()) {
    Err(e) => Err(e),
    Ok(content) => attest.statement_of_content(content),
  }
}

fn derived() -> [io] Result[List[met.Metric], Str] {
  match statement() {
    Err(e) => Err(e),
    Ok(text) => derive.metrics_signed("moe_parity_attestation", text),
  }
}

fn expect_metric(ms :: List[met.Metric], key :: Str, want :: Int) -> Result[Unit, Str] {
  match met.lookup(ms, key) {
    None => Err(str.concat("no derived metric for ", key)),
    Some(got) => if got == want {
      Ok(())
    } else {
      Err(str.join([key, ": expected ", int.to_str(want), ", derived ", int.to_str(got)], ""))
    },
  }
}

fn expect_all(ms :: List[met.Metric], pairs :: List[{ key :: Str, value :: Int }]) -> Result[Unit, Str] {
  list.fold(pairs, Ok(()), fn (acc :: Result[Unit, Str], p :: { key :: Str, value :: Int }) -> Result[Unit, Str] {
    match acc {
      Err(e) => Err(e),
      Ok(_) => expect_metric(ms, p.key, p.value),
    }
  })
}

# ---- The happy path ------------------------------------------------------
fn test_signature_verifies_over_carried_bytes() -> [io] Result[Unit, Str] {
  match statement() {
    Err(e) => Err(str.concat("the committed envelope did not verify: ", e)),
    Ok(text) => if str.contains(text, "\"max_rel_l2\"") {
      Ok(())
    } else {
      Err("verified statement does not look like a parity statement")
    },
  }
}

fn test_statement_numbers_are_derived() -> [io] Result[Unit, Str] {
  match derived() {
    Err(e) => Err(e),
    Ok(ms) => expect_all(ms, [{ key: "version", value: 1 }, { key: "heads", value: 4 }, { key: "top_k", value: 2 }, { key: "prompts", value: 3 }, { key: "tokens_match", value: 1 }, { key: "tolerance_micro", value: 50000 }, { key: "max_rel_l2_micro", value: 13 }]),
  }
}

# `pass` is RECOMPUTED (tokens matched, and 13 <= 50000), and the statement's
# own bit is published beside it under a different key. Both being 1 here is
# the agreement case; the point is that they are two different numbers.
fn test_pass_is_recomputed_not_echoed() -> [io] Result[Unit, Str] {
  match derived() {
    Err(e) => Err(e),
    Ok(ms) => expect_all(ms, [{ key: "pass", value: 1 }, { key: "pass_stated", value: 1 }]),
  }
}

# A statement whose own pass bit contradicts its own numbers: `pass` must
# follow the numbers, so the contradiction surfaces instead of being echoed.
fn contradictory_statement() -> Str {
  "{\"version\":1,\"heads\":4,\"top_k\":2,\"suite\":\"aa\",\"prompts\":3,\"tokens_match\":true,\"max_rel_l2\":0.5,\"tolerance\":0.05,\"pass\":true}"
}

fn test_self_contradicting_statement_is_visible() -> Result[Unit, Str] {
  match moe.metrics(contradictory_statement()) {
    Err(e) => Err(str.concat("a well-formed statement failed to derive: ", e)),
    Ok(ms) => match expect_metric(ms, "pass_stated", 1) {
      Err(e) => Err(e),
      Ok(_) => expect_metric(ms, "pass", 0),
    },
  }
}

# ---- The repudiation paths ----------------------------------------------
# Each of these is a case a verifier that merely PARSED the JSON would report
# as a healthy claim.
fn edited_envelope() -> [io] Result[Str, Str] {
  match io.read(envelope_path()) {
    Err(e) => Err(e),
    Ok(content) => Ok(str.replace(content, "\"statement_hex\": \"7b22", "\"statement_hex\": \"7b23")),
  }
}

fn test_edited_statement_bytes_are_repudiated() -> [io] Result[Unit, Str] {
  match edited_envelope() {
    Err(e) => Err(e),
    Ok(content) => match attest.statement_of_content(content) {
      Ok(_) => Err("an edited statement verified"),
      Err(_) => Ok(()),
    },
  }
}

fn test_swapped_signer_is_repudiated() -> [io] Result[Unit, Str] {
  match io.read(envelope_path()) {
    Err(e) => Err(e),
    Ok(content) => match attest.parse(content) {
      Err(e) => Err(e),
      Ok(env) => {
        let other := { envelope_version: env.envelope_version, alg: env.alg, statement_hex: env.statement_hex, signer: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", signature: env.signature }
        match attest.statement_of(other) {
          Ok(_) => Err("a statement verified against a key that did not sign it"),
          Err(_) => Ok(()),
        }
      },
    },
  }
}

fn test_unknown_algorithm_is_refused_not_guessed() -> [io] Result[Unit, Str] {
  match io.read(envelope_path()) {
    Err(e) => Err(e),
    Ok(content) => match attest.parse(content) {
      Err(e) => Err(e),
      Ok(env) => {
        let future := { envelope_version: env.envelope_version, alg: "p256", statement_hex: env.statement_hex, signer: env.signer, signature: env.signature }
        match attest.statement_of(future) {
          Ok(_) => Err("an unimplemented algorithm was checked anyway"),
          Err(_) => Ok(()),
        }
      },
    },
  }
}

fn test_future_envelope_version_is_refused() -> [io] Result[Unit, Str] {
  match io.read(envelope_path()) {
    Err(e) => Err(e),
    Ok(content) => match attest.parse(content) {
      Err(e) => Err(e),
      Ok(env) => {
        let future := { envelope_version: env.envelope_version + 1, alg: env.alg, statement_hex: env.statement_hex, signer: env.signer, signature: env.signature }
        match attest.statement_of(future) {
          Ok(_) => Err("an envelope version this reader does not know was read anyway"),
          Err(_) => Ok(()),
        }
      },
    },
  }
}

# ---- The seam ------------------------------------------------------------
fn test_kind_is_registered_as_a_signed_family() -> Result[Unit, Str] {
  if not derive.has_deriver("moe_parity_attestation") {
    Err("the moe evidence kind is not registered")
  } else {
    if not derive.is_signed_statement("moe_parity_attestation") {
      Err("the moe evidence kind is not marked as a signed statement")
    } else {
      if derive.is_signed_statement("replay_trail") {
        Err("a trail kind was misclassified as a signed statement")
      } else {
        Ok(())
      }
    }
  }
}

# No robot or loom concept can be derived from a parity statement, and no moe
# concept leaks into a trail deriver: the interpretation stays per-domain.
fn test_no_cross_domain_leakage() -> [io] Result[Unit, Str] {
  match derived() {
    Err(e) => Err(e),
    Ok(ms) => match met.lookup(ms, "denials") {
      Some(_) => Err("a robot metric was derived from a parity statement"),
      None => match derive.metrics_signed("replay_trail", "{}") {
        Ok(_) => Err("a trail kind was accepted by the signed-statement dispatch"),
        Err(_) => Ok(()),
      },
    },
  }
}

fn results() -> [io] List[Result[Unit, Str]] {
  [test_signature_verifies_over_carried_bytes(), test_statement_numbers_are_derived(), test_pass_is_recomputed_not_echoed(), test_self_contradicting_statement_is_visible(), test_edited_statement_bytes_are_repudiated(), test_swapped_signer_is_repudiated(), test_unknown_algorithm_is_refused_not_guessed(), test_future_envelope_version_is_refused(), test_kind_is_registered_as_a_signed_family(), test_no_cross_domain_leakage()]
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
      Err(e) => io.print(str.concat("FAIL test_derive_moe: ", e)),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

