#!/usr/bin/env bash
# scripts/smoke_http.sh — the HTTP door end to end (issue #6).
#
# Deliberately bash + python3 STDLIB ONLY: no curl in the client path, no pip
# install. That is the whole claim the door makes — a trainer already running
# Python can log a run without taking on a new dependency — so the test proves
# it rather than asserting it.
#
# Covers the acceptance criteria (start the server, POST a fixture run, GET it
# back, POST verify, assert the verdict) plus the two rejection paths, because
# "never a silent partial write" is only worth claiming if something checks it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PORT="${NOTEBOOKLAB_PORT:-8137}"
STORE="$(mktemp -d)/runs.jsonl"
EFFECTS=approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time

NOTEBOOKLAB_STORE="$STORE" lex run --allow-effects "$EFFECTS" src/server.lex main \
  >/tmp/notebooklab-door.log 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

python3 - "$PORT" <<'PY'
import json, sys, time, urllib.error, urllib.request

port = sys.argv[1]
base = f"http://localhost:{port}"


def call(method, path, payload=None):
    """Returns (status, parsed_body). A 4xx is a result, not an exception."""
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        base + path, data=data, method=method,
        headers={"Content-Type": "application/json"} if data else {},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode())


def check(label, got, want):
    assert got == want, f"{label}: expected {want!r}, got {got!r}"
    print(f"  ok: {label}")


# The server binds asynchronously; poll /health rather than sleeping blind.
for _ in range(60):
    try:
        if call("GET", "/health")[0] == 200:
            break
    except Exception:
        time.sleep(0.25)
else:
    raise SystemExit("server never became healthy — see /tmp/notebooklab-door.log")
print("  ok: GET /health")

entry = json.load(open("fixtures/entry_attempt4.json"))
status, created = call("POST", "/runs", entry)
check("POST /runs -> 201", status, 201)
run_id = created["run_id"]

status, listing = call("GET", "/runs")
check("GET /runs -> 200", status, 200)
check("GET /runs count", listing["count"], 1)

status, record = call("GET", f"/runs/{run_id}")
check("GET /runs/{id} -> 200", status, 200)
check("GET /runs/{id} round-trips the id", record["run_id"], run_id)

status, result = call("POST", f"/runs/{run_id}/verify")
check("POST /runs/{id}/verify -> 200", status, 200)
check("verify status", result["verdict"]["status"], "VERIFIED")
check("verify exit_code", result["exit_code"], 0)
assert all(c["status"] == "VERIFIED" for c in result["verdict"]["claims"]), result
print("  ok: every claim VERIFIED")

# The same run submitted twice is one record: run_id is a content address.
status, again = call("POST", "/runs", entry)
check("re-POST is idempotent", again["run_id"], run_id)
check("store did not grow", call("GET", "/runs")[1]["count"], 1)

# Rejections. Both must be 400 AND must leave the store untouched.
before = call("GET", "/runs")[1]["count"]

status, err = call("POST", "/runs", {"attempt": "incomplete"})
check("POST /runs missing fields -> 400", status, 400)
check("error is structured", err["error"]["code"], "invalid_run")

broken = json.loads(json.dumps(entry))
broken["attempt"] = "broken-chain"
broken["evidence"][0] = {
    "kind": "replay_trail",
    "path": "fixtures/xlerobot_rl_trail_tampered.jsonl",
    "sha256": "", "trail_head": "",
}
status, err = call("POST", "/runs", broken)
check("POST /runs with a broken chain -> 400", status, 400)
assert "hash chain is already broken" in err["error"]["message"], err
print("  ok: a broken chain is refused at submission, not at verify")

check("rejections wrote nothing", call("GET", "/runs")[1]["count"], before)

status, _ = call("GET", "/runs/deadbeef")
check("GET unknown run -> 404", status, 404)

print("\nhttp door: all green")
PY
