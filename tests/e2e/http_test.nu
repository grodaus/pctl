#!/usr/bin/env nu
# The darkhttpd-reality test: does PCTL_HOST actually bind the service to the
# pctl-assigned IP, proving systemd expanded the drop-in Environment= value?
# HTTP on the assigned host returns 200; the literal 127.0.0.1 is refused.

use std assert
use harness.nu *
use ../../pctl/lib/identity.nu derive-id
use ../../pctl/lib/registry.nu *

def pick-free-port [] {
  let listeners = ^ss -lnt | complete | get stdout
  for p in 18080..19000 {
    if not ($listeners | str contains $":($p) ") { return $p }
  }
  error make { msg: "no free port in 18080..19000" }
}

let darkhttpd_build = ^nix build "nixpkgs#darkhttpd" --no-link --print-out-paths | complete
assert ($darkhttpd_build.exit_code == 0) $"nix build darkhttpd failed: ($darkhttpd_build.stderr)"
let darkhttpd = $darkhttpd_build.stdout | str trim | $"($in)/bin/darkhttpd"

let port = pick-free-port
let scratch = setup {}  # we write the unit body ourselves
let www = $scratch.tmp | path join "www"
mkdir $www
"<h1>pctl http_test ok</h1>" | save -f ($www | path join "index.html")

# darkhttpd binds to ${PCTL_HOST} — systemd expands it from the drop-in pctl installs.
let web_body = $"[Unit]
Description=darkhttpd @@PROJECT@@

[Service]
Type=simple
ExecStart=($darkhttpd) ($www) --port ($port) --addr ${PCTL_HOST}
Slice=pctl-@@PROJECT@@.slice
"
write-tree $scratch.tree_dir {web: $web_body}

try {
  let up = run-pctl $scratch.project_dir "up" "--tree" $scratch.tree_dir "--quiet"
  assert ($up.exit_code == 0) $"up failed: ($up.stderr)"

  let id = (derive-id $scratch.project_dir).id
  let web = $"pctl-($id)-web.service"
  assert (wait-active $web 10) "darkhttpd did not reach active state"

  let host = (registry-read $env.XDG_RUNTIME_DIR $id).host
  print $"assigned host=($host) port=($port)"

  # Positive: the assigned host serves our file.
  let resp = ^curl -s --max-time 3 -w "%{http_code}" $"http://($host):($port)/index.html" | complete
  let out = $resp.stdout
  let code = $out | str substring (-3)..
  let body = $out | str substring 0..<(($out | str length) - 3)
  assert ($code == "200") $"expected 200, got ($code); body=($body)"
  assert ($body | str contains "http_test ok") $"body mismatch: ($body)"

  # Negative control: 127.0.0.1 must refuse. If the service bound to 0.0.0.0
  # or ignored PCTL_HOST, this would succeed — that's the bug this catches.
  if $host != "127.0.0.1" {
    let neg = ^curl -sS --max-time 2 --connect-timeout 1 -o /dev/null -w "%{http_code}" $"http://127.0.0.1:($port)/" | complete
    let neg_code = $neg.stdout | str trim
    assert ($neg_code != "200") $"127.0.0.1:($port) answered 200 — PCTL_HOST binding is broken"
  }

  print $"http_test OK — ($id) on ($host):($port)"
} catch { |e|
  teardown $scratch
  error make { msg: $"http_test failed: ($e.msg)" }
}

teardown $scratch
