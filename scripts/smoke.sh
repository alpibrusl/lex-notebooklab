#!/usr/bin/env bash
# scripts/smoke.sh — the gate. Type-checks everything, runs the test suite, and
# drives the full CLI loop against the committed fixtures, asserting the
# SEMANTIC EXIT CODES rather than just "it didn't crash".
#
# The three verify cases are the point of the package:
#   * true claims against a real trail        -> 0  (VERIFIED)
#   * a run claiming zero denials             -> 3  (MISMATCH)
#   * a run shipping an edited trail          -> 4  (TAMPERED)
#
# A verifier that cannot fail is not a verifier, so a green run here means the
# red paths were exercised too.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

STORE="$(mktemp -d)/runs.jsonl"
export NOTEBOOKLAB_STORE="$STORE"

say() { printf '\n=== %s ===\n' "$1"; }

# `lex check` takes files, not directories.
say "type-check (strict)"
find src tools tests -name '*.lex' -print0 | xargs -0 -n1 lex check --strict >/dev/null
echo "ok"

say "format check"
lex fmt --check src/ tests/ tools/

say "tests"
lex test

say "record -> list -> show"
./bin/notebooklab record fixtures/entry_attempt4.json
./bin/notebooklab record fixtures/entry_no_evidence.json
./bin/notebooklab list
RUN_ID="$(./bin/notebooklab list-json | tail -n 1 | sed 's/.*"run_id":"\([0-9a-f]*\)".*/\1/')"
./bin/notebooklab show "$RUN_ID" >/dev/null
echo "ok: showed $RUN_ID"

# A run with no surviving trail must report UNVERIFIABLE and still exit 0 —
# honesty is a pass, not a failure.
say "verify: true claims + an evidence-less run (expect 0)"
./bin/notebooklab verify
echo "ok: exit 0"

# A loom sprint trail — a completely different event vocabulary — through the
# same store, the same integrity checks and the same CLI. This is the check
# that the package is an experiment tracker, not a robot tracker.
say "verify: a loom sprint trail (expect 0)"
LOOM_STORE="$(mktemp -d)/runs.jsonl"
./bin/notebooklab --store "$LOOM_STORE" record fixtures/entry_loom_sprint.json >/dev/null
./bin/notebooklab --store "$LOOM_STORE" verify
echo "ok: exit 0"

say "verify: a claim the trail contradicts (expect 3)"
MISMATCH_STORE="$(mktemp -d)/runs.jsonl"
./bin/notebooklab --store "$MISMATCH_STORE" record fixtures/entry_mismatch.json >/dev/null
set +e
./bin/notebooklab --store "$MISMATCH_STORE" verify
code=$?
set -e
[ "$code" -eq 3 ] || { echo "FAIL: expected exit 3 (MISMATCH), got $code" >&2; exit 1; }
echo "ok: exit 3"

# The case chain integrity alone cannot catch: a prefix of the real trail,
# perfectly valid in itself. Only the recorded head reveals it.
say "verify: a truncated but internally valid chain (expect 4)"
TRUNC_STORE="$(mktemp -d)/runs.jsonl"
./bin/notebooklab --store "$TRUNC_STORE" record fixtures/entry_truncated.json >/dev/null
set +e
./bin/notebooklab --store "$TRUNC_STORE" verify
code=$?
set -e
[ "$code" -eq 4 ] || { echo "FAIL: expected exit 4 (TAMPERED), got $code" >&2; exit 1; }
echo "ok: exit 4"

say "verify: an edited trail (expect 4)"
TAMPER_STORE="$(mktemp -d)/runs.jsonl"
./bin/notebooklab --store "$TAMPER_STORE" record fixtures/entry_tampered.json >/dev/null
set +e
./bin/notebooklab --store "$TAMPER_STORE" verify
code=$?
set -e
[ "$code" -eq 4 ] || { echo "FAIL: expected exit 4 (TAMPERED), got $code" >&2; exit 1; }
echo "ok: exit 4"

say "fixture is reproducible from lex-robot's committed rollout"
if [ -f ../lex-robot/examples/fixtures/xlerobot_rl_rollout.json ]; then
  TMP_TRAIL="$(mktemp -d)/trail.jsonl"
  lex run --allow-effects io tools/make_fixture.lex build \
    '"../lex-robot/examples/fixtures/xlerobot_rl_rollout.json"' "\"$TMP_TRAIL\"" >/dev/null
  diff -q "$TMP_TRAIL" fixtures/xlerobot_rl_trail.jsonl \
    && echo "ok: regenerated robot fixture is byte-identical"
else
  echo "skip: lex-robot checkout not alongside this repo"
fi

TMP_LOOM="$(mktemp -d)/loom.jsonl"
lex run --allow-effects io tools/make_loom_fixture.lex build "\"$TMP_LOOM\"" >/dev/null
diff -q "$TMP_LOOM" fixtures/loom_sprint_trail.jsonl \
  && echo "ok: regenerated loom fixture is byte-identical"

# The real corpus: 12 attempts from lex-robot's committed ledger. None has a
# surviving trail, so every one must read UNVERIFIABLE and still exit 0 —
# honesty is a pass. The round-trip is checked field-for-field, since key
# ORDER is deliberately canonicalised (a content address must not depend on
# the order a writer emitted keys in).
say "import: lex-robot's 12-attempt ledger (expect 0, all UNVERIFIABLE)"
IMPORT_STORE="$(mktemp -d)/runs.jsonl"
lex run --allow-effects io src/import.lex import_ledger \
  '"fixtures/lex_robot_experiments.jsonl"' "\"$IMPORT_STORE\""
./bin/notebooklab --store "$IMPORT_STORE" verify >/dev/null
echo "ok: 12 imported, all UNVERIFIABLE, exit 0"

lex run --allow-effects io src/import.lex export_sources "\"$IMPORT_STORE\"" \
  | tail -1 | python3 -c '
import sys, json
exported = json.loads(sys.stdin.read())["args"][0].split("\n")
source = [l for l in open("fixtures/lex_robot_experiments.jsonl") if l.strip()]
a = [json.loads(l) for l in exported]
b = [json.loads(l) for l in source]
assert len(a) == len(b) == 12, f"{len(a)} exported vs {len(b)} source"
assert a == b, "export is not field-for-field identical to the source ledger"
print("ok: import -> export reproduces all 12 entries field for field")
'

say "http door (issue #6)"
bash scripts/smoke_http.sh

printf '\nsmoke: all green\n'
