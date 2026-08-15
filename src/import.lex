# src/import.lex — seeding the store from lex-robot's experiment ledger (#7)
#
# `docs/experiments.jsonl` in alpibrusl/lex-robot is an append-only, git-
# committed ledger of the RL training series — one JSON object per line,
# written by `gym_env/xlerobot_experiment_ledger.py`. It is this package's
# first real corpus, and importing it is the honesty test: none of those runs
# has a surviving trail, so every one must land as UNVERIFIABLE rather than as
# a green tick.
#
# Three things this has to get right:
#
#   1. SHAPE. The ledger requires only `attempt` / `trainer` / `config` /
#      `results`; `date` and `headline` are optional, and `attempt` is an Int
#      where a record's is a Str. A Lex record type cannot express an optional
#      field — reading one the input lacks fails at RUNTIME — so the optional
#      scalars are read out of the text (src/jsonx.lex) instead.
#
#   2. NESTING. A record's `results` must be flat: claims are matched by key,
#      and a nested object's keys would be lifted to the top level. The
#      ledger's `violations` map is two levels deep, so it is flattened into
#      the vocabulary src/derive/robot.lex already publishes — which means an
#      imported claim is checkable the moment a trail turns up for it.
#
#   3. UNITS. Upstream records metres and rates as decimals (`0.613`, `0.5`);
#      this package compares integers so two verifiers agree bit for bit. The
#      conversion is a mapping, not a loss: 0.613 m IS 613 mm.
#
# What is deliberately NOT imported as a claim: `checkpoints` and
# `ckpt_*_replay` are nested sub-runs rather than claims about this run, and
# `eval_*` verdicts and returns come from MuJoCo ground truth with no trail
# representation. The first are dropped from `results` (they survive verbatim
# in `source`); the second are carried through and honestly reported
# UNVERIFIABLE, per issue #4's stated non-goal.
#
# Round-trip: every record keeps its upstream entry verbatim in `source`, so
# an export reproduces the source field for field, including keys this schema
# does not name. Key ORDER is canonicalised (sorted) rather than preserved —
# a record's id is a content address, and it must not depend on the order a
# writer happened to emit keys in.
#
# Effects: `[io]`.

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.json" as json

import "./record" as rec

import "./store" as store

import "./jsonx" as jx

# The four keys `xlerobot_experiment_ledger.py` validates on append. Anything
# else in an entry is optional and is read from the text.
type LedgerEntry = { attempt :: Int, trainer :: Str, config :: Json, results :: Json }

fn required_keys() -> List[Str] {
  ["attempt", "trainer", "config", "results"]
}

# The corpus a record came from, recorded as its series so that imported runs
# are distinguishable from ones authored here.
fn series_name() -> Str {
  "lex-robot/experiments"
}

# ---- Dates ---------------------------------------------------------------
# Ledger dates are `YYYY-MM-DD`, or `YYYY-MM` for the earliest entries whose
# exact day nobody recorded. A missing day becomes the 1st and a missing date
# becomes 0 — both are honest: the ledger genuinely does not know, and the
# exact string survives in `source` either way.
fn part_int(date :: Str, from :: Int, to :: Int) -> Int {
  if str.len(date) < to {
    0
  } else {
    match str.to_int(str.slice(date, from, to)) {
      None => 0,
      Some(n) => n,
    }
  }
}

# Days since 1970-01-01, by the standard civil-from-days algorithm. Exact for
# every date the ledger can hold, with no floating point anywhere.
fn days_from_civil(y0 :: Int, m :: Int, d :: Int) -> Int
  examples {
    days_from_civil(1970, 1, 1) => 0,
    days_from_civil(1970, 1, 2) => 1,
    days_from_civil(2000, 3, 1) => 11017,
    days_from_civil(2026, 8, 15) => 20680
  }
{
  let y := if m <= 2 {
    y0 - 1
  } else {
    y0
  }
  let era := y / 400
  let yoe := y - era * 400
  let mp := if m > 2 {
    m - 3
  } else {
    m + 9
  }
  let doy := (153 * mp + 2) / 5 + (d - 1)
  let doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468
}

fn created_at_of(date :: Str) -> Int
  examples {
    created_at_of("") => 0,
    created_at_of("2026-08") => 1785542400000,
    created_at_of("2026-08-15") => 1786752000000
  }
{
  if str.len(date) < 7 {
    0
  } else {
    let day := if str.len(date) >= 10 {
      part_int(date, 8, 10)
    } else {
      1
    }
    days_from_civil(part_int(date, 0, 4), part_int(date, 5, 7), day) * 86400000
  }
}

# ---- Claim flattening ----------------------------------------------------
# One entry of the violations map: an axis key and its sub-object, captured
# whole. The two members are then read BY NAME rather than by position,
# because `json.stringify` sorts keys — the ledger writes
# `{"n":22,"mean_overshoot_m":0.613}` and Lex re-emits it as
# `{"mean_overshoot_m":0.613,"n":22}`. A positional pattern silently matched
# nothing after that round trip, which is exactly the kind of failure that
# looks like "this run had no violations" rather than like a bug.
#
# `[^}]*` is safe here and only here: a violations sub-object is flat.
fn violation_pattern() -> Str {
  "\"([A-Za-z_]+\\.[a-z])\"[ ]*:[ ]*\\{([^}]*)\\}"
}

fn claim_int(key :: Str, value :: Int) -> Str {
  str.join(["\"", key, "\":", int.to_str(value)], "")
}

# One axis becomes two claims, both in the vocabulary the robot deriver
# publishes — so if a trail for this run ever surfaces, these are checkable
# without touching the importer.
fn axis_claims(m :: jx.Match) -> List[Str] {
  let axis := jx.group_at(m, 0)
  let members := jx.group_at(m, 1)
  list.concat(match jx.num_field(members, "n") {
    None => [],
    Some(n) => match str.to_int(n) {
      None => [],
      Some(count) => [claim_int(str.concat(axis, ".violations"), count)],
    },
  }, match jx.num_field(members, "mean_overshoot_m") {
    None => [],
    Some(overshoot) => match jx.milli(overshoot) {
      None => [],
      Some(mm) => [claim_int(str.concat(axis, ".mean_overshoot_milli"), mm)],
    },
  })
}

# Attempt 4 reports its post-finetune profile under `violations_after`;
# everything from attempt 5 on uses `violations`. Both mean "the violation
# profile of the run this entry describes".
fn violations_object(results :: Str) -> Str {
  let primary := jx.object_at_top(results, "violations")
  if not str.is_empty(primary) {
    primary
  } else {
    jx.object_at_top(results, "violations_after")
  }
}

fn violation_claims(results :: Str) -> List[Str] {
  list.fold(jx.matches_of(violation_pattern(), violations_object(results)), [], fn (acc :: List[Str], m :: jx.Match) -> List[Str] {
    list.concat(acc, axis_claims(m))
  })
}

# A null denial rate means the run did not record one — not a rate of zero.
# Dropping it is the difference between "unknown" and a claim that would then
# be checked against evidence and found wrong.
fn rate_claims(results :: Str) -> List[Str] {
  match jx.num_field(results, "denial_rate") {
    None => [],
    Some(literal) => match jx.pct(literal) {
      None => [],
      Some(p) => [claim_int("denial_rate_pct", p)],
    },
  }
}

# Sim-side outcomes: carried through so they are visible, and honestly
# reported UNVERIFIABLE by the verifier because no trail can settle them.
fn passthrough_str(results :: Str, key :: Str) -> List[Str] {
  let v := jx.str_field(results, key)
  if str.is_empty(v) {
    []
  } else {
    [str.join(["\"", key, "\":", rec.quoted(v)], "")]
  }
}

fn passthrough_num(results :: Str, key :: Str) -> List[Str] {
  match jx.num_field(results, key) {
    None => [],
    Some(literal) => [str.join(["\"", key, "\":", literal], "")],
  }
}

fn eval_claims(results :: Str) -> List[Str] {
  list.fold(["eval_det", "eval_stoch"], [], fn (acc :: List[Str], k :: Str) -> List[Str] {
    list.concat(acc, passthrough_str(results, k))
  })
}

fn return_claims(results :: Str) -> List[Str] {
  list.fold(["eval_return_det", "eval_return_stoch"], [], fn (acc :: List[Str], k :: Str) -> List[Str] {
    list.concat(acc, passthrough_num(results, k))
  })
}

fn claims_json(results :: Str) -> Str {
  str.join(["{", str.join(list.concat(list.concat(rate_claims(results), violation_claims(results)), list.concat(eval_claims(results), return_claims(results))), ","), "}"], "")
}

# ---- One entry -----------------------------------------------------------
fn record_of_line(line :: Str) -> Result[rec.Run, Str] {
  let parsed :: Result[LedgerEntry, Str] := json.parse_strict(line, required_keys())
  match parsed {
    Err(msg) => Err(str.concat("not a ledger entry: ", msg)),
    Ok(e) => rec.make(int.to_str(e.attempt), series_name(), e.trainer, json.stringify(e.config), claims_json(json.stringify(e.results)), [], jx.str_field(line, "headline"), "", created_at_of(jx.str_field(line, "date")), line),
  }
}

fn import_lines(store_path :: Str, lines :: List[Str]) -> [io] Result[Int, Str] {
  list.fold(lines, Ok(0), fn (acc :: Result[Int, Str], line :: Str) -> [io] Result[Int, Str] {
    match acc {
      Err(msg) => Err(msg),
      Ok(n) => match record_of_line(line) {
        Err(msg) => Err(msg),
        Ok(r) => match store.append(store_path, r) {
          Err(msg) => Err(msg),
          Ok(_) => Ok(n + 1),
        },
      },
    }
  })
}

# Import every entry, or none: a ledger with one malformed line is a problem
# to fix, not a corpus to partially absorb.
fn import_ledger(ledger_path :: Str, store_path :: Str) -> [io] Result[Int, Str] {
  match io.read(ledger_path) {
    Err(msg) => Err(str.join(["cannot read ledger ", ledger_path, ": ", msg], "")),
    Ok(content) => import_lines(store_path, store.non_empty_lines(content)),
  }
}

# ---- Export --------------------------------------------------------------
# The other half of the round-trip guarantee: every imported record still
# carries its upstream entry, so the corpus can be handed back field for field.
# Records authored here rather than imported carry `{}` and are skipped.
fn export_sources(store_path :: Str) -> [io] Result[Str, Str] {
  match store.read_all(store_path) {
    Err(msg) => Err(msg),
    Ok(rs) => Ok(str.join(list.filter(list.map(rs, fn (r :: rec.Run) -> Str {
      r.source_json
    }), fn (s :: Str) -> Bool {
      not (s == "{}")
    }), "\n")),
  }
}

