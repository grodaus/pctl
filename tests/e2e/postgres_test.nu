#!/usr/bin/env nu
# The postgres-reality test: a real multi-service project (pg + dbmate + ruby)
# installs, starts in dependency order, runs migrations, and serves a row
# selected from postgres — exercising StateDirectory, RuntimeDirectory, unit
# sandbox, dependsOn graph, and Type=oneshot on one run.
#
# The fixture flake at tests/e2e/fixtures/pg is built once per test; nix caches
# everything after the first invocation on a given host.

use std assert
use harness.nu *
use ../../pctl/lib/identity.nu derive-id
use ../../pctl/lib/registry.nu *

const here = path self | path dirname
let fixture = $here | path join "fixtures" "pg"
let web_port = 18080

def port-free [port: int]: nothing -> bool {
  let listeners = ^ss -lnt | complete | get stdout
  not ($listeners | str contains $":($port) ")
}

if not (port-free $web_port) {
  error make { msg: $"port ($web_port) is in use — postgres_test expects it free on the dev host" }
}

let build = ^nix build $"($fixture)#pctl" --no-link --print-out-paths | complete
assert ($build.exit_code == 0) $"fixture nix build failed: ($build.stderr)"
let tree = $build.stdout | str trim

let scratch = setup {}

try {
  let up = run-pctl $scratch.project_dir "up" "--tree" $tree "--quiet"
  assert ($up.exit_code == 0) $"up failed: ($up.stderr)"

  let id = (derive-id $scratch.project_dir).id
  let pg = $"pctl-($id)-pg.service"
  let migrate = $"pctl-($id)-migrate.service"
  let web = $"pctl-($id)-web.service"

  assert (wait-active $pg 10) "pg did not reach active"
  assert (wait-active $migrate 15) "migrate did not reach active — dbmate likely failed"
  assert (wait-active $web 10) "web did not reach active"

  let host = (registry-read $env.XDG_RUNTIME_DIR $id).host
  let url = $"http://($host):($web_port)/"

  mut body = null
  for _ in 0..50 {
    let r = try { http get $url } catch { null }
    if $r != null { $body = $r; break }
    sleep 100ms
  }
  assert ($body != null) $"web did not answer on ($url)"

  assert ($body.conn_mode == "tcp") $"expected conn_mode=tcp, got ($body.conn_mode)"
  assert ($body.host == $host) $"host mismatch: expected ($host), got ($body.host)"
  assert ($body.port == $web_port) $"port mismatch: expected ($web_port), got ($body.port)"
  assert ($body.row.name == "hello from pctl") $"row name mismatch: ($body.row.name)"

  print $"postgres_test OK — ($id) on ($host):($web_port), row=($body.row.name)"
} catch { |e|
  teardown $scratch
  error make { msg: $"postgres_test failed: ($e.msg)" }
}

teardown $scratch
