# src/record.lex — the run record (issue #3)
#
# A run record is a CLAIM plus the EVIDENCE the claim is supposed to follow
# from. `results_json` is what the trainer asserted; `evidence` is what a third
# party can recompute it from (src/verify.lex). The two are deliberately
# separate fields: a record with no evidence is legal, but it is permanently
# and visibly unverifiable — never silently equivalent to a verified one.
#
# `run_id` is a content address: the SHA-256 of the record's canonical
# encoding with `run_id` itself excluded. That makes ids stable (the same
# logical entry hashes the same anywhere) and tamper-evident (editing any
# field of a stored record breaks its id), the same property lex-trail's
# `event.compute_id` gives individual trail events.
#
# `config` and `results` are open maps held as canonical JSON strings rather
# than as typed records. That is what lets the v0 format round-trip an
# arbitrary upstream ledger entry field-for-field (issue #7's requirement)
# without this repo having to know every key a trainer might log.
#
# Effects: none. Every function here is pure and carries `examples {}`.

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.crypto" as crypto

import "std.json" as json

# One piece of evidence bound to a run. `kind` selects the deriver that can
# interpret it (src/derive.lex); `path` is where the artifact lives.
#
# The remaining two fields are BINDINGS — the commitments that make later
# tampering detectable — and which one applies depends on what the artifact is:
#
#   sha256      the digest of the bytes. The only binding possible for an
#               opaque artifact such as a checkpoint, where there is no
#               internal structure to commit to.
#   trail_head  the id of the last event in a hash-chained trail. Because
#               `event.compute_id` folds the parent id into every event, the
#               head transitively commits to the whole chain — so this binds
#               the EVIDENCE rather than its container, and the same chain
#               verifies whether it arrives as a JSONL file, a range of
#               database rows, or bytes over a socket. Prefer it for trails: a
#               byte digest also fails on a harmless re-serialization, which is
#               a false alarm, and it forces the producer to keep an immutable
#               file around forever, which is a real constraint.
#
# Either may be "" (absent). Both may be set, and then both are checked. An
# evidence entry with neither is unbound and settles nothing.
type Evidence = { kind :: Str, path :: Str, sha256 :: Str, trail_head :: Str }

# The v0 run record.
#
# `supersedes` is "" when the record supersedes nothing. The store is
# append-only (see src/store.lex): a correction is a NEW record naming the one
# it replaces, never an edit of the original.
#
# `extra_json` carries any fields an imported entry had that this schema does
# not name, as a JSON object body without the enclosing braces (`"k":v,...`, ""
# when there are none). Round-tripping it is what makes import → export
# field-preserving.
type Run = { run_id :: Str, attempt :: Str, series :: Str, trainer :: Str, config_json :: Str, results_json :: Str, evidence :: List[Evidence], notes :: Str, supersedes :: Str, created_at :: Int, extra_json :: Str }

# ---- JSON escaping -------------------------------------------------------
# Mirrors lex-games' arena/trail_file `esc` and extends it to the control
# characters a `notes` field realistically contains. Order matters: the
# backslash substitution must run first or it would re-escape its own output.
fn esc(s :: Str) -> Str
  examples {
    esc("plain") => "plain",
    esc("a\"b") => "a\\\"b",
    esc("a\\b") => "a\\\\b",
    esc("a\nb") => "a\\nb",
    esc("a\tb") => "a\\tb"
  }
{
  str.replace(str.replace(str.replace(str.replace(s, "\\", "\\\\"), "\"", "\\\""), "\n", "\\n"), "\t", "\\t")
}

fn quoted(s :: Str) -> Str
  examples {
    quoted("x") => "\"x\"",
    quoted("") => "\"\""
  }
{
  str.join(["\"", esc(s), "\""], "")
}

# ---- Evidence ------------------------------------------------------------
fn evidence_json(e :: Evidence) -> Str
  examples {
    evidence_json({ kind: "replay_trail", path: "t.jsonl", sha256: "ab", trail_head: "cd" }) => "{\"kind\":\"replay_trail\",\"path\":\"t.jsonl\",\"sha256\":\"ab\",\"trail_head\":\"cd\"}"
  }
{
  str.join(["{\"kind\":", quoted(e.kind), ",\"path\":", quoted(e.path), ",\"sha256\":", quoted(e.sha256), ",\"trail_head\":", quoted(e.trail_head), "}"], "")
}

fn evidence_list_json(es :: List[Evidence]) -> Str
  examples {
    evidence_list_json([]) => "[]",
    evidence_list_json([{ kind: "k", path: "p", sha256: "s", trail_head: "" }]) => "[{\"kind\":\"k\",\"path\":\"p\",\"sha256\":\"s\",\"trail_head\":\"\"}]"
  }
{
  str.join(["[", str.join(list.map(es, evidence_json), ","), "]"], "")
}

# Find the first piece of evidence of a given kind. `verify` uses this to
# locate the replay trail among however many artifacts a run bound.
fn evidence_of_kind(es :: List[Evidence], kind :: Str) -> Option[Evidence]
  examples {
    evidence_of_kind([], "replay_trail") => None,
    evidence_of_kind([{ kind: "checkpoint", path: "p", sha256: "s", trail_head: "" }], "replay_trail") => None,
    evidence_of_kind([{ kind: "replay_trail", path: "p", sha256: "s", trail_head: "" }], "replay_trail") => Some({ kind: "replay_trail", path: "p", sha256: "s", trail_head: "" })
  }
{
  list.head(list.filter(es, fn (e :: Evidence) -> Bool {
    e.kind == kind
  }))
}

# ---- Construction --------------------------------------------------------
# An empty, unsealed record. Exists so the encoders below can carry honest
# `examples {}` blocks without a twelve-field literal in every one of them.
fn blank() -> Run
  examples {
    blank() => { run_id: "", attempt: "", series: "", trainer: "", config_json: "{}", results_json: "{}", evidence: [], notes: "", supersedes: "", created_at: 0, extra_json: "" }
  }
{
  { run_id: "", attempt: "", series: "", trainer: "", config_json: "{}", results_json: "{}", evidence: [], notes: "", supersedes: "", created_at: 0, extra_json: "" }
}

# ---- Canonical encoding + content address --------------------------------
# The `extra_json` tail is appended verbatim inside the object so that unknown
# imported fields survive a round trip. It is part of the canonical form, and
# therefore part of the id: dropping a field an upstream ledger carried would
# change the record's identity rather than silently lose data.
fn extra_tail(extra_json :: Str) -> Str
  examples {
    extra_tail("") => "",
    extra_tail("\"seed\":7") => ",\"seed\":7"
  }
{
  if str.is_empty(str.trim(extra_json)) {
    ""
  } else {
    str.concat(",", str.trim(extra_json))
  }
}

# The canonical field list EXCLUDING run_id, without the enclosing braces, so
# that the hashed form and the stored form can share one encoder instead of
# drifting apart.
fn canonical_fields(r :: Run) -> Str
  examples {
    canonical_fields(blank()) => "\"attempt\":\"\",\"series\":\"\",\"trainer\":\"\",\"config\":{},\"results\":{},\"evidence\":[],\"notes\":\"\",\"supersedes\":\"\",\"created_at\":0"
  }
{
  str.join(["\"attempt\":", quoted(r.attempt), ",\"series\":", quoted(r.series), ",\"trainer\":", quoted(r.trainer), ",\"config\":", r.config_json, ",\"results\":", r.results_json, ",\"evidence\":", evidence_list_json(r.evidence), ",\"notes\":", quoted(r.notes), ",\"supersedes\":", quoted(r.supersedes), ",\"created_at\":", int.to_str(r.created_at), extra_tail(r.extra_json)], "")
}

# The canonical encoding EXCLUDING run_id — this is what gets hashed.
fn canonical_body(r :: Run) -> Str
  examples {
    canonical_body(blank()) => str.join(["{", canonical_fields(blank()), "}"], "")
  }
{
  str.join(["{", canonical_fields(r), "}"], "")
}

# The content address of a record. Deliberately NOT a function of run_id, so
# `compute_id(with_id(r, x)) == compute_id(r)` for any x — recomputing the id
# of a stored record is how tampering is detected.
fn compute_id(r :: Run) -> Str
  examples {
    compute_id(blank()) => crypto.sha256_str(canonical_body(blank())),
    compute_id(with_id(blank(), "anything")) => compute_id(blank())
  }
{
  crypto.sha256_str(canonical_body(r))
}

fn with_id(r :: Run, id :: Str) -> Run
  examples {
    with_id(blank(), "abc") => { run_id: "abc", attempt: "", series: "", trainer: "", config_json: "{}", results_json: "{}", evidence: [], notes: "", supersedes: "", created_at: 0, extra_json: "" },
    with_id(blank(), "") => blank()
  }
{
  { run_id: id, attempt: r.attempt, series: r.series, trainer: r.trainer, config_json: r.config_json, results_json: r.results_json, evidence: r.evidence, notes: r.notes, supersedes: r.supersedes, created_at: r.created_at, extra_json: r.extra_json }
}

# Stamp a record with its own content address. Records enter the store only
# through here.
fn seal(r :: Run) -> Run
  examples {
    seal(blank()) => with_id(blank(), compute_id(blank())),
    seal(seal(blank())) => seal(blank())
  }
{
  with_id(r, compute_id(r))
}

# A record is intact iff its stored id still matches its content.
fn is_intact(r :: Run) -> Bool
  examples {
    is_intact(seal(blank())) => true,
    is_intact(with_id(blank(), "forged")) => false
  }
{
  r.run_id == compute_id(r)
}

# ---- Wire form -----------------------------------------------------------
# The stored JSONL line: the canonical body with `run_id` spliced in as the
# leading field, so a line is both self-describing and re-hashable.
fn to_json(r :: Run) -> Str
  examples {
    to_json(with_id(blank(), "id1")) => str.join(["{\"run_id\":\"id1\",", canonical_fields(blank()), "}"], "")
  }
{
  str.join(["{\"run_id\":", quoted(r.run_id), ",", canonical_fields(r), "}"], "")
}

# ---- Reading a stored line back ------------------------------------------
# The stored line carries `config` and `results` as real nested JSON objects,
# which is what makes the store readable by anything that speaks JSON (the
# HTTP door in issue #6, the importer in issue #7, `jq`). Lex cannot express
# an open map as a record field, but it CAN hold one as an opaque `Json`
# value — so the parse side uses a mirror type with `Json` where `Run` has a
# string, and `json.stringify` converts back.
#
# That conversion is not merely a cast: `json.stringify` emits keys in sorted
# order, so a record read back from disk is automatically in canonical form.
# `normalize` puts freshly-supplied JSON into the same form on the way in,
# which is what makes `run_id` independent of the key order a client happened
# to send.
type RunWire = { run_id :: Str, attempt :: Str, series :: Str, trainer :: Str, config :: Json, results :: Json, evidence :: List[Evidence], notes :: Str, supersedes :: Str, created_at :: Int }

# Re-render a JSON object string in canonical (key-sorted) form. Invalid JSON
# is an error rather than a silent pass-through: a record whose config cannot
# be parsed would hash whatever bytes it happened to hold, and two clients
# sending the same logical config would get different ids.
fn normalize(src :: Str) -> Result[Str, Str] {
  let parsed :: Result[Json, Str] := json.parse(src)
  match parsed {
    Err(e) => Err(str.concat("not valid JSON: ", e)),
    Ok(j) => Ok(json.stringify(j)),
  }
}

fn of_wire(w :: RunWire) -> Run {
  { run_id: w.run_id, attempt: w.attempt, series: w.series, trainer: w.trainer, config_json: json.stringify(w.config), results_json: json.stringify(w.results), evidence: w.evidence, notes: w.notes, supersedes: w.supersedes, created_at: w.created_at, extra_json: "" }
}

fn from_json(line :: Str) -> Result[Run, Str] {
  let parsed :: Result[RunWire, Str] := json.parse(line)
  match parsed {
    Err(e) => Err(str.concat("not a run record: ", e)),
    Ok(w) => Ok(of_wire(w)),
  }
}

# Build a record from client-supplied parts, normalising the open maps and
# stamping the content address. This is the only way a record should be
# created outside of tests — it guarantees the id matches the content.
fn build(attempt :: Str, series :: Str, trainer :: Str, config_src :: Str, results_src :: Str, evidence :: List[Evidence], notes :: Str, supersedes :: Str, created_at :: Int) -> Result[Run, Str] {
  match normalize(config_src) {
    Err(e) => Err(str.concat("config: ", e)),
    Ok(cfg) => match normalize(results_src) {
      Err(e) => Err(str.concat("results: ", e)),
      Ok(res) => Ok(seal({ run_id: "", attempt: attempt, series: series, trainer: trainer, config_json: cfg, results_json: res, evidence: evidence, notes: notes, supersedes: supersedes, created_at: created_at, extra_json: "" })),
    },
  }
}

# ---- Accessors -----------------------------------------------------------
# `supersedes` is stored as "" rather than an absent key so the wire form has a
# fixed shape; this accessor is the idiomatic Option view of it.
fn superseded_run(r :: Run) -> Option[Str]
  examples {
    superseded_run(blank()) => None,
    superseded_run(with_supersedes(blank(), "run_7")) => Some("run_7")
  }
{
  if str.is_empty(r.supersedes) {
    None
  } else {
    Some(r.supersedes)
  }
}

# A run is verifiable only if it bound at least one piece of evidence.
# Everything else is a claim standing on its own authority.
fn has_evidence(r :: Run) -> Bool
  examples {
    has_evidence(blank()) => false,
    has_evidence(with_evidence(blank(), [{ kind: "replay_trail", path: "t", sha256: "s", trail_head: "" }])) => true
  }
{
  not list.is_empty(r.evidence)
}

# ---- Field updates -------------------------------------------------------
# Records are immutable values; these build a new one. Note that both change
# the canonical body, so a record must be re-`seal`ed after either.
fn with_evidence(r :: Run, es :: List[Evidence]) -> Run
  examples {
    with_evidence(blank(), []) => blank(),
    with_evidence(blank(), [{ kind: "k", path: "p", sha256: "s", trail_head: "" }]) => { run_id: "", attempt: "", series: "", trainer: "", config_json: "{}", results_json: "{}", evidence: [{ kind: "k", path: "p", sha256: "s", trail_head: "" }], notes: "", supersedes: "", created_at: 0, extra_json: "" }
  }
{
  { run_id: r.run_id, attempt: r.attempt, series: r.series, trainer: r.trainer, config_json: r.config_json, results_json: r.results_json, evidence: es, notes: r.notes, supersedes: r.supersedes, created_at: r.created_at, extra_json: r.extra_json }
}

fn with_supersedes(r :: Run, prior :: Str) -> Run
  examples {
    with_supersedes(blank(), "") => blank(),
    with_supersedes(blank(), "run_7") => { run_id: "", attempt: "", series: "", trainer: "", config_json: "{}", results_json: "{}", evidence: [], notes: "", supersedes: "run_7", created_at: 0, extra_json: "" }
  }
{
  { run_id: r.run_id, attempt: r.attempt, series: r.series, trainer: r.trainer, config_json: r.config_json, results_json: r.results_json, evidence: r.evidence, notes: r.notes, supersedes: prior, created_at: r.created_at, extra_json: r.extra_json }
}

