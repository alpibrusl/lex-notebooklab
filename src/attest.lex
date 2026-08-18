# src/attest.lex — evidence that is signed rather than chained
#
# Until now every kind of evidence this package understood was a lex-trail:
# integrity meant "every event id recomputes and every parent link holds", and
# a record committed to it through a head id. That machinery answers one
# question — were these bytes edited? — and deliberately not the other one the
# README lists first under Trust model and limitations: *verify proves
# derivation, not provenance*. Nothing said WHO produced the trail.
#
# A signed statement answers that instead. It is not a chain and has no head;
# it is a single claim plus an ed25519 signature over the exact bytes the
# claim was serialized to. Verifying it proves both halves at once: the bytes
# are intact (any edit breaks the signature) AND a specific key vouched for
# them. What it does not prove is that the key is one anybody should trust —
# that is a trust list, and this package does not have one yet. What it gives
# the record instead is the ordinary `sha256` binding: committing to the
# envelope's bytes transitively commits to the signer it names, so swapping in
# a different signer's envelope is caught as a digest mismatch.
#
# The envelope shape is the detached-JWS idea without the JOSE dependency:
# the SIGNED BYTES travel beside the signature. That is the whole reason it
# exists, and it is worth being explicit about. lex-moe already writes an
# attestation as `{statement, signer, signature}` where `statement` is a typed
# struct — but the signature covers `serde_json` over that struct, so checking
# it from here would mean re-implementing Rust's field order, its BlobHash
# encoding and its shortest-roundtrip float formatter, byte for byte. A second
# unversioned copy of a security-critical encoding is exactly what this repo
# refused to write for `event.compute_id` (see the note in lex.toml about
# never hand-rolling that hash), and the same reasoning applies here. Carrying
# the bytes means there is nothing to reproduce: decode, check, then read.
#
# Effects: none. Reading the file is the caller's business.

import "std.str" as str

import "std.bytes" as bytes

import "std.crypto" as crypto

import "std.json" as json

# The envelope, as written by `moe attest` (lex-moe, crates/moe-serve/src/attest.rs).
#
#   envelope_version  format version of THIS wrapper, not of the statement
#   alg               signature algorithm; only "ed25519" is implemented
#   statement_hex     hex of the exact bytes the signature covers
#   signer            ed25519 public key, hex
#   signature         ed25519 signature over the decoded statement_hex, hex
type Envelope = { envelope_version :: Int, alg :: Str, statement_hex :: Str, signer :: Str, signature :: Str }

fn required_fields() -> List[Str] {
  ["envelope_version", "alg", "statement_hex", "signer", "signature"]
}

fn supported_alg() -> Str {
  "ed25519"
}

# The only version whose field meanings this reader knows. A future version is
# refused by name rather than read with today's assumptions.
fn supported_version() -> Int {
  1
}

fn parse(content :: Str) -> Result[Envelope, Str] {
  let parsed :: Result[Envelope, Str] := json.parse_strict(content, required_fields())
  match parsed {
    Err(e) => Err(str.concat("not a signed-statement envelope: ", e)),
    Ok(env) => Ok(env),
  }
}

# ---- Verification --------------------------------------------------------
# The order here is the point, and it is the same order the trail path uses:
# settle the identity of the evidence BEFORE anything reads what it says. A
# statement handed back from unverified bytes is how an unsigned number ends
# up being read as a signed one, so there is deliberately no way to get the
# statement out of this module without the signature having been checked.
fn unsupported(env :: Envelope) -> Option[Str] {
  if env.envelope_version != supported_version() {
    Some("envelope version is newer than this verifier understands")
  } else {
    if env.alg != supported_alg() {
      Some(str.join(["unsupported signature algorithm \"", env.alg, "\"; this verifier implements ", supported_alg(), " only"], ""))
    } else {
      None
    }
  }
}

# Verify and return the signed statement as text. Err is always a REPUDIATION
# ("these bytes are not what the signer signed"), never a soft failure — the
# caller maps it straight onto TAMPERED, exactly as a broken hash chain is
# mapped today.
fn statement_of(env :: Envelope) -> Result[Str, Str] {
  match unsupported(env) {
    Some(why) => Err(why),
    None => match crypto.hex_decode(env.statement_hex) {
      Err(e) => Err(str.concat("statement is not hex: ", e)),
      Ok(msg) => match crypto.hex_decode(env.signer) {
        Err(e) => Err(str.concat("signer key is not hex: ", e)),
        Ok(pk) => match crypto.hex_decode(env.signature) {
          Err(e) => Err(str.concat("signature is not hex: ", e)),
          Ok(sig) => if not crypto.ed25519_verify(pk, msg, sig) {
            Err(str.join(["signature does not verify: the statement is not what ", env.signer, " signed"], ""))
          } else {
            match bytes.to_str(msg) {
              Err(e) => Err(str.concat("signed bytes are not text: ", e)),
              Ok(text) => Ok(text),
            }
          },
        },
      },
    },
  }
}

# Parse-then-verify in one step, for callers holding raw file content.
fn statement_of_content(content :: Str) -> Result[Str, Str] {
  match parse(content) {
    Err(e) => Err(e),
    Ok(env) => statement_of(env),
  }
}

# Who signed it. Only meaningful once `statement_of` has succeeded; a caller
# that reports this without verifying first is reporting an unchecked claim.
fn signer_of(env :: Envelope) -> Str {
  env.signer
}

