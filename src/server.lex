# src/server.lex — the HTTP door (issue #6)
#
# The door a trainer posts to when the training itself lives somewhere this
# package cannot reach — sb3/PyTorch on another machine, a CI job, anything
# that is not already a Lex program. A Lex caller (lex-loom, say) should call
# src/entry.lex directly instead; there is no reason to go over a socket to
# talk to a library in the same runtime.
#
#   POST /runs              submit a run record; 201 + run_id
#   GET  /runs              summaries of every stored run
#   GET  /runs/{id}         one full record
#   POST /runs/{id}/verify  re-derive the run's claims from its evidence
#   GET  /health
#
# Submission goes through `entry.ingest`, exactly as the CLI does, so the same
# run submitted here and on the command line validates identically and — since
# `run_id` is a content address — lands on the same id. Everything that can
# fail does so before the append, so a rejected POST never leaves a partial
# write behind.
#
# TRUST MODEL, stated the way lex-robot's fleet arbiter states its own: this is
# a single-operator lab tool. There is no auth and no multi-tenancy — anyone
# who can reach the port can append to the store. There is no TLS either; put
# it behind a reverse proxy if it leaves localhost. Both are deliberate
# non-goals of issue #6, not oversights.
#
# Effect rows on handlers: lex-web's `route_effectful` pins the handler's
# effect row by record-field type, and effect rows unify by EQUALITY, not
# subtyping (`lex agent-guidelines` §1.6). So every handler below declares the
# full row verbatim — including `approval`, which v0.10.10 added — while its
# body uses only `io`. Narrowing the declaration is not an option here; the
# row is fixed by the type.

import "std.net" as net

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "lex-web/src/ctx" as ctx

import "lex-web/src/response" as resp

import "lex-web/src/router" as router

import "lex-web/src/body" as body

import "./record" as rec

import "./store" as store

import "./verify" as vfy

import "./entry" as entry

import "./cli" as cli

# The store path cannot be read from the environment inside a handler:
# lex-web pins the handler's effect row, and `env` is not in it. So the path
# is resolved once at startup and CLOSED OVER by each handler instead — which
# is also why the handlers below are functions returning handlers.
fn default_store() -> Str {
  "runs.jsonl"
}

fn store_from_env() -> [env] Str {
  match env.get("NOTEBOOKLAB_STORE") {
    None => default_store(),
    Some(p) => if str.is_empty(p) {
      default_store()
    } else {
      p
    },
  }
}

# ---- Response helpers ----------------------------------------------------
# A structured error body, never a bare string: a trainer that gets a 400 has
# to be able to tell WHY without scraping prose.
fn error_json(code :: Str, message :: Str) -> Str {
  str.join(["{\"error\":{\"code\":", rec.quoted(code), ",\"message\":", rec.quoted(message), "}}"], "")
}

fn bad_request(code :: Str, message :: Str) -> resp.Response {
  resp.json_status(400, error_json(code, message))
}

fn not_found(message :: Str) -> resp.Response {
  resp.json_status(404, error_json("not_found", message))
}

# ---- POST /runs ----------------------------------------------------------
# 201 on success. A submission that fails validation, names an unreadable
# evidence file, or carries a trail whose chain is already broken is a 400 —
# and nothing is written.
fn post_run(store_path :: Str) -> (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
  fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    match entry.ingest(store_path, body.raw_body(c)) {
      Err(msg) => bad_request("invalid_run", msg),
      Ok(saved) => resp.json_status(201, str.join(["{\"run_id\":", rec.quoted(saved.run_id), "}"], "")),
    }
  }
}

# ---- GET /runs -----------------------------------------------------------
fn get_runs(store_path :: Str) -> (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
  fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    match store.read_all(store_path) {
      Err(msg) => resp.json_status(500, error_json("store_unreadable", msg)),
      Ok(rs) => resp.json(str.join(["{\"runs\":[", str.join(list.map(rs, cli.summary_json), ","), "],\"count\":", int.to_str(list.len(rs)), "}"], "")),
    }
  }
}

# ---- GET /runs/{id} ------------------------------------------------------
fn get_run(store_path :: Str) -> (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
  fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    match ctx.require_path_param(c, "id") {
      Err(msg) => bad_request("missing_id", msg),
      Ok(id) => match store.get(store_path, id) {
        Err(msg) => resp.json_status(500, error_json("store_unreadable", msg)),
        Ok(None) => not_found(str.concat("no such run: ", id)),
        Ok(Some(r)) => resp.json(rec.to_json(r)),
      },
    }
  }
}

# ---- POST /runs/{id}/verify ----------------------------------------------
# Always 200 when the run exists: a MISMATCH or TAMPERED verdict is a
# successful verification that returned bad news, not a failed request. The
# verdict is in the body, along with the exit code the CLI would have used, so
# a caller can gate on the same semantics either way.
fn verify_run(store_path :: Str) -> (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
  fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    match ctx.require_path_param(c, "id") {
      Err(msg) => bad_request("missing_id", msg),
      Ok(id) => match store.get(store_path, id) {
        Err(msg) => resp.json_status(500, error_json("store_unreadable", msg)),
        Ok(None) => not_found(str.concat("no such run: ", id)),
        Ok(Some(r)) => {
          let v := vfy.verify_run(r)
          resp.json(str.join(["{\"verdict\":", cli.verdict_json(v), ",\"exit_code\":", int.to_str(vfy.exit_code(vfy.overall(v))), "}"], ""))
        },
      },
    }
  }
}

# ---- GET /health ---------------------------------------------------------
fn health(c :: ctx.Ctx) -> resp.Response {
  resp.json("{\"status\":\"ok\"}")
}

# ---- Router --------------------------------------------------------------
fn app(store_path :: Str) -> router.Router {
  router.route(router.route_effectful(router.route_effectful(router.route_effectful(router.route_effectful(router.new(), "POST", "/runs", post_run(store_path)), "GET", "/runs", get_runs(store_path)), "GET", "/runs/:id", get_run(store_path)), "POST", "/runs/:id/verify", verify_run(store_path)), "GET", "/health", health)
}

fn banner(port :: Int, store_path :: Str) -> [io] Unit {
  let __h := io.print(str.join(["notebooklab door on :", int.to_str(port), " (store: ", store_path, ")"], ""))
  let __r := io.print("  POST /runs              submit a run record")
  let __l := io.print("  GET  /runs              list summaries")
  let __g := io.print("  GET  /runs/{id}         full record")
  let __v := io.print("  POST /runs/{id}/verify  re-derive claims from evidence")
  let __e := io.print("  GET  /health")
  let __w := io.print("  no auth, no TLS — single-operator lab tool; reverse-proxy it if it leaves localhost")
  ()
}

# The row here is dictated from below, not chosen: `router.dispatch` runs
# handlers under lex-web's pinned handler row, so `llm`, `proc` and (as of
# v0.10.10) `approval` propagate all the way out to the socket loop even
# though nothing in this file uses them.
fn serve(port :: Int, store_path :: Str) -> [net, io, time, crypto, random, sql, fs_read, fs_write, concurrent, llm, proc, approval] Unit {
  let __b := banner(port, store_path)
  net.serve_fn(port, fn (req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] Response {
    let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
    let r := router.dispatch(app(store_path), raw)
    { status: r.status, body: BodyStr(r.body), headers: r.headers }
  })
}

# Port and store are read here, at the one place `env` is reachable.
fn main() -> [env, net, io, time, crypto, random, sql, fs_read, fs_write, concurrent, llm, proc, approval] Unit {
  serve(8137, store_from_env())
}

