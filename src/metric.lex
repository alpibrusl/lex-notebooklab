# src/metric.lex — the currency between a deriver and the verifier
#
# A deriver's whole job is to turn a trail into a list of named integers. The
# verifier's whole job is to diff those against what a record claimed. Keeping
# the interface this thin is what lets a new domain (loom, and whatever comes
# after) plug in without touching src/verify.lex.
#
# Integers, not floats, on purpose: trails encode quantities as integers
# already (milli-units for distances, plain counts for everything else), so two
# verifiers agree bit for bit with no rounding policy to argue about.
#
# Effects: none.

import "std.str" as str

import "std.list" as list

type Metric = { key :: Str, value :: Int }

# Look up a derived metric. `None` is meaningful and distinct from `Some(0)`:
# it means "no deriver produced this key", which the verifier reports as
# UNVERIFIABLE rather than as a failed comparison. A deriver that knows a
# quantity is genuinely zero must emit it explicitly.
fn lookup(ms :: List[Metric], key :: Str) -> Option[Int]
  examples {
    lookup([], "a") => None,
    lookup([{ key: "a", value: 1 }], "a") => Some(1),
    lookup([{ key: "a", value: 0 }], "a") => Some(0),
    lookup([{ key: "a", value: 1 }], "b") => None
  }
{
  match list.head(list.filter(ms, fn (m :: Metric) -> Bool {
    m.key == key
  })) {
    None => None,
    Some(m) => Some(m.value),
  }
}

fn metric(key :: Str, value :: Int) -> Metric
  examples {
    metric("a", 1) => { key: "a", value: 1 }
  }
{
  { key: key, value: value }
}

# Namespaced key, e.g. `move_to.x.violations` or `design.bounces`.
fn dotted(parts :: List[Str]) -> Str
  examples {
    dotted(["a"]) => "a",
    dotted(["move_to", "x", "violations"]) => "move_to.x.violations"
  }
{
  str.join(parts, ".")
}

# ---- Aggregation helpers shared by every deriver --------------------------
fn has_str(xs :: List[Str], needle :: Str) -> Bool
  examples {
    has_str([], "a") => false,
    has_str(["a", "b"], "b") => true,
    has_str(["a", "b"], "c") => false
  }
{
  list.fold(xs, false, fn (acc :: Bool, x :: Str) -> Bool {
    acc or x == needle
  })
}

# Order-preserving dedupe, so derived rows come out in the order the trail
# first mentions each category and two runs of `verify` print the same table.
fn distinct(xs :: List[Str]) -> List[Str]
  examples {
    distinct([]) => [],
    distinct(["a", "b", "a"]) => ["a", "b"],
    distinct(["a", "a", "a"]) => ["a"]
  }
{
  list.fold(xs, [], fn (acc :: List[Str], x :: Str) -> List[Str] {
    if has_str(acc, x) {
      acc
    } else {
      list.concat(acc, [x])
    }
  })
}

fn sum(xs :: List[Int]) -> Int
  examples {
    sum([]) => 0,
    sum([1, 2, 3]) => 6
  }
{
  list.fold(xs, 0, fn (acc :: Int, x :: Int) -> Int {
    acc + x
  })
}

fn max_of(xs :: List[Int]) -> Int
  examples {
    max_of([]) => 0,
    max_of([3, 9, 4]) => 9
  }
{
  list.fold(xs, 0, fn (acc :: Int, x :: Int) -> Int {
    if x > acc {
      x
    } else {
      acc
    }
  })
}

fn mean_of(xs :: List[Int]) -> Int
  examples {
    mean_of([]) => 0,
    mean_of([2, 4]) => 3,
    mean_of([1, 2]) => 1
  }
{
  if list.is_empty(xs) {
    0
  } else {
    sum(xs) / list.len(xs)
  }
}

# Integer percent, rounded to nearest. Safe to round only because the raw
# numerator and denominator always travel alongside it as their own metrics.
fn rate_pct(part :: Int, whole :: Int) -> Int
  examples {
    rate_pct(0, 0) => 0,
    rate_pct(8, 16) => 50,
    rate_pct(33, 48) => 69,
    rate_pct(24, 48) => 50
  }
{
  if whole == 0 {
    0
  } else {
    (part * 200 + whole) / (whole * 2)
  }
}

