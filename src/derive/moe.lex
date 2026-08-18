# src/derive/moe.lex — deriving metrics from a signed lex-moe parity attestation
#
# The third deriver, and the first whose evidence is not a trail. lex-moe
# measures a quantized model variant against its f32 source over a fixed
# prompt suite and signs the result: "candidate manifest C matched reference
# manifest R — greedy tokens identical, worst relative-L2 logit distance D,
# judged against tolerance T". `moe attest` writes that as an envelope
# (src/attest.lex) whose ed25519 signature covers the exact statement bytes.
#
# ── What this deriver does and does not settle ────────────────────────────
# Be precise, because "verified" has to keep meaning one thing:
#
#   IT DOES prove provenance and integrity — the signature is checked over
#   the carried bytes, so an edited number or a swapped signer is TAMPERED,
#   not a quiet pass. That is the property the README's trust model lists as
#   missing everywhere else in this package.
#
#   IT DOES prove the record's claims are what was signed: every number below
#   is read out of the signed statement, so a ledger entry that inflates a
#   parity result MISMATCHes against it.
#
#   IT DOES re-derive the statement's own verdict: `pass` is published as
#   RECOMPUTED from the statement's numbers (tokens matched, and the measured
#   distance within the stated tolerance), not read back from its `pass`
#   field. The field as written is published separately as `pass_stated`, so
#   a signed statement that contradicts itself shows up as a mismatch between
#   the two rather than as a green tick.
#
#   IT DOES NOT re-run the measurement. Recomputing `max_rel_l2` means
#   loading both models and replaying the suite — that is `moe attest`'s job,
#   and the signature is what makes its answer worth quoting. A verifier that
#   claimed otherwise would be lying about what it checked.
#
# Metric keys published by this deriver:
#
#   version              statement format version
#   heads / top_k        decode config the suite ran with
#   prompts              prompts in the suite
#   tokens_match         1 or 0 — greedy tokens identical across the suite
#   max_rel_l2_micro     worst relative-L2 logit distance, millionths
#   tolerance_micro      tolerance it was judged against, millionths
#   pass                 RECOMPUTED: tokens_match and distance <= tolerance
#   pass_stated          the statement's own pass bit, as signed
#
# Micro-units, not floats, for the same reason every other deriver publishes
# integers (src/metric.lex): two verifiers agree bit for bit with no rounding
# policy to argue about. The conversion is exact-then-rounded from the decimal
# literal as signed, so it never depends on a float parser's behaviour. A
# literal this scaler cannot represent safely publishes NO key at all, and the
# claim reads UNVERIFIABLE — the honest outcome, never a guess.
#
# Effects: none.

import "std.str" as str

import "std.list" as list

import "std.json" as json

import "std.regex" as regex

import "../metric" as met

# The scalar half of lex-moe's `ParityStatement`. The two float fields are
# deliberately absent here and read from the text below: parsing them as
# floats would make the published integers depend on a float round-trip, and
# `candidate`/`reference`/`suite` are content hashes — identities, not
# quantities, so no integer claim can be made about them.
type Statement = { version :: Int, heads :: Int, top_k :: Int, prompts :: Int, tokens_match :: Bool, pass :: Bool }

fn bit(b :: Bool) -> Int
  examples {
    bit(true) => 1,
    bit(false) => 0
  }
{
  if b {
    1
  } else {
    0
  }
}

# ---- Scaling a decimal literal to millionths -----------------------------
# The statement carries `max_rel_l2` and `tolerance` as JSON numbers written
# by Rust's shortest-roundtrip formatter, so both plain (`0.000012556884`) and
# exponent (`1e-7`) forms are possible and both must scale identically.
#
# The arithmetic is over the DIGITS, never over a parsed float: `digits` is
# every significant digit with the point removed, `point` is how many of them
# precede the decimal point, so the value is `digits x 10^(point - len)`, and
# scaling by a million shifts that exponent by six. Rounding is half-up on the
# first dropped digit, applied once, at the end.
type Decimal = { neg :: Bool, digits :: Str, point :: Int, exp :: Int, ok :: Bool }

fn bad_decimal() -> Decimal {
  { neg: false, digits: "", point: 0, exp: 0, ok: false }
}

fn is_digits(s :: Str) -> Bool
  examples {
    is_digits("0") => true,
    is_digits("0123") => true,
    is_digits("") => false,
    is_digits("1a") => false,
    is_digits("1.2") => false
  }
{
  if str.is_empty(s) {
    false
  } else {
    match regex.compile("^[0-9]+$") {
      Err(_) => false,
      Ok(re) => regex.is_match(re, s),
    }
  }
}

# Split off an exponent suffix, if any. "1.2e-3" -> mantissa "1.2", exp -3.
type Split = { mant :: Str, exp :: Int, ok :: Bool }

fn split_exp(lit :: Str) -> Split
  examples {
    split_exp("0.05") => { mant: "0.05", exp: 0, ok: true },
    split_exp("1e-7") => { mant: "1", exp: -7, ok: true },
    split_exp("1.2E+3") => { mant: "1.2", exp: 3, ok: true },
    split_exp("1e") => { mant: "", exp: 0, ok: false },
    split_exp("1e2e3") => { mant: "", exp: 0, ok: false }
  }
{
  let parts := list.filter(str.split(str.replace(lit, "E", "e"), "e"), fn (p :: Str) -> Bool {
    true
  })
  if list.len(parts) == 1 {
    { mant: lit, exp: 0, ok: true }
  } else {
    if list.len(parts) != 2 {
      { mant: "", exp: 0, ok: false }
    } else {
      let mant := match list.head(parts) {
        None => "",
        Some(m) => m,
      }
      let raw := match list.head(list.reverse(parts)) {
        None => "",
        Some(e) => e,
      }
      let unsigned := match str.strip_prefix(raw, "+") {
        None => raw,
        Some(rest) => rest,
      }
      match str.to_int(unsigned) {
        None => { mant: "", exp: 0, ok: false },
        Some(e) => { mant: mant, exp: e, ok: true },
      }
    }
  }
}

fn parse_decimal(lit :: Str) -> Decimal
  examples {
    parse_decimal("0.05") => { neg: false, digits: "005", point: 1, exp: 0, ok: true },
    parse_decimal("12") => { neg: false, digits: "12", point: 2, exp: 0, ok: true },
    parse_decimal("-0.5") => { neg: true, digits: "05", point: 1, exp: 0, ok: true },
    parse_decimal("1e-7") => { neg: false, digits: "1", point: 1, exp: -7, ok: true },
    parse_decimal("") => { neg: false, digits: "", point: 0, exp: 0, ok: false },
    parse_decimal("1.2.3") => { neg: false, digits: "", point: 0, exp: 0, ok: false }
  }
{
  let split := split_exp(lit)
  if not split.ok {
    bad_decimal()
  } else {
    let neg := str.starts_with(split.mant, "-")
    let body := match str.strip_prefix(split.mant, "-") {
      None => split.mant,
      Some(rest) => rest,
    }
    let parts := str.split(body, ".")
    if list.len(parts) > 2 {
      bad_decimal()
    } else {
      let whole := match list.head(parts) {
        None => "",
        Some(w) => w,
      }
      let frac := if list.len(parts) == 2 {
        match list.head(list.reverse(parts)) {
          None => "",
          Some(f) => f,
        }
      } else {
        ""
      }
      if not is_digits(whole) {
        bad_decimal()
      } else {
        if list.len(parts) == 2 and not is_digits(frac) {
          bad_decimal()
        } else {
          { neg: neg, digits: str.concat(whole, frac), point: str.len(whole), exp: split.exp, ok: true }
        }
      }
    }
  }
}

fn signed(neg :: Bool, n :: Int) -> Int
  examples {
    signed(false, 5) => 5,
    signed(true, 5) => -5
  }
{
  if neg {
    0 - n
  } else {
    n
  }
}

fn pow10(n :: Int) -> Int
  examples {
    pow10(0) => 1,
    pow10(3) => 1000
  }
{
  if n <= 0 {
    1
  } else {
    10 * pow10(n - 1)
  }
}

# Round-half-up at position `keep`, given the digit that falls off. The digit
# is compared as a NUMBER: `str.char_at` returns a Str, and ordering Str is
# lexicographic, which is the same answer here only by accident of ASCII.
fn rounded_head(digits :: Str, keep :: Int) -> Option[Int]
  examples {
    rounded_head("0000012556884", 7) => Some(13),
    rounded_head("0000012456884", 7) => Some(12),
    rounded_head("5", 0) => Some(1),
    rounded_head("4", 0) => Some(0)
  }
{
  let carry := match str.to_int(str.char_at(digits, keep)) {
    None => 0,
    Some(d) => if d >= 5 {
      1
    } else {
      0
    },
  }
  if keep == 0 {
    Some(carry)
  } else {
    match str.to_int(str.slice(digits, 0, keep)) {
      None => None,
      Some(head) => Some(head + carry),
    }
  }
}

# The magnitudes this scaler will take on. Well outside anything a parity
# measurement produces, and far enough inside Int that no product overflows:
# refusing a literal is a first-class UNVERIFIABLE, so the bound errs tight.
fn max_shift() -> Int {
  12
}

fn max_digits() -> Int {
  17
}

# Scale a decimal literal by a million, rounded half-up. `None` means "this
# verifier will not commit to a value for that literal" — never a fallback.
fn micro_of(lit :: Str) -> Option[Int]
  examples {
    micro_of("0.05") => Some(50000),
    micro_of("0") => Some(0),
    micro_of("1") => Some(1000000),
    micro_of("0.000012556884") => Some(13),
    micro_of("1e-7") => Some(0),
    micro_of("0.0000005") => Some(1),
    micro_of("1.2e-3") => Some(1200),
    micro_of("-0.05") => Some(-50000),
    micro_of("2.5e9") => None,
    micro_of("abc") => None,
    micro_of("") => None
  }
{
  let d := parse_decimal(lit)
  if not d.ok {
    None
  } else {
    if str.len(d.digits) > max_digits() {
      None
    } else {
      let shift := d.point - str.len(d.digits) + 6 + d.exp
      if shift > max_shift() {
        None
      } else {
        if shift >= 0 {
          if str.len(d.digits) + shift > max_digits() {
            None
          } else {
            match str.to_int(d.digits) {
              None => None,
              Some(n) => Some(signed(d.neg, n * pow10(shift))),
            }
          }
        } else {
          let keep := str.len(d.digits) + shift
          if keep < 0 {
            Some(0)
          } else {
            match rounded_head(d.digits, keep) {
              None => None,
              Some(n) => Some(signed(d.neg, n)),
            }
          }
        }
      }
    }
  }
}

# ---- Reading the two float fields out of the signed text -----------------
# By pattern, not by float parse: the literal as signed is the authority, and
# scaling it directly is what keeps two verifiers bit-identical.
fn number_after(key :: Str, statement_json :: Str) -> Option[Str] {
  match regex.compile(str.join(["\"", key, "\"[ ]*:[ ]*(-?[0-9][0-9.eE+-]*)"], "")) {
    Err(_) => None,
    Ok(re) => match regex.find(re, statement_json) {
      None => None,
      Some(m) => list.head(m.groups),
    },
  }
}

fn micro_metric(key :: Str, out_key :: Str, statement_json :: Str) -> List[met.Metric] {
  match number_after(key, statement_json) {
    None => [],
    Some(lit) => match micro_of(lit) {
      None => [],
      Some(v) => [met.metric(out_key, v)],
    },
  }
}

# `pass`, recomputed rather than read back. Published only when BOTH numbers
# scaled: a pass bit that could not be rechecked is a key this deriver does
# not publish, so the claim reads UNVERIFIABLE instead of being waved through
# on the statement's own say-so.
fn pass_metrics(s :: Statement, statement_json :: Str) -> List[met.Metric] {
  let stated := [met.metric("pass_stated", bit(s.pass))]
  match number_after("max_rel_l2", statement_json) {
    None => stated,
    Some(dist_lit) => match number_after("tolerance", statement_json) {
      None => stated,
      Some(tol_lit) => match micro_of(dist_lit) {
        None => stated,
        Some(dist) => match micro_of(tol_lit) {
          None => stated,
          Some(tol) => list.concat([met.metric("pass", bit(s.tokens_match and dist <= tol))], stated),
        },
      },
    },
  }
}

# The evidence text here is the VERIFIED statement — src/attest.lex has
# already checked the signature over these exact bytes, and there is no way
# into this function that skips that step.
fn metrics(statement_json :: Str) -> Result[List[met.Metric], Str] {
  let parsed :: Result[Statement, Str] := json.parse(statement_json)
  match parsed {
    Err(e) => Err(str.concat("bad parity statement payload: ", e)),
    Ok(s) => {
      let base := [met.metric("version", s.version), met.metric("heads", s.heads), met.metric("top_k", s.top_k), met.metric("prompts", s.prompts), met.metric("tokens_match", bit(s.tokens_match))]
      let scaled := list.concat(micro_metric("max_rel_l2", "max_rel_l2_micro", statement_json), micro_metric("tolerance", "tolerance_micro", statement_json))
      Ok(list.concat(list.concat(base, scaled), pass_metrics(s, statement_json)))
    },
  }
}

