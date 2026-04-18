#!/usr/bin/env nu
# --timeout is an overall bound on `up --wait`, not a per-probe bound. First
# service (`a`) becomes ready slowly; second service (`b`) never becomes ready.
# If --timeout were per-probe, total runtime could be 2× per-probe ≈ 6s; with a
# proper overall deadline the whole thing must fail around the CLI --timeout.

use std assert
use harness.nu *

const bash = "/run/current-system/sw/bin/bash"

let scratch = setup {a: null, b: null}

# `a` writes its readiness flag at t=~1.5s; `b` stays up forever with no flag.
let a_flag = $scratch.tmp | path join "a.ready"
let a_body = $"[Unit]
Description=wait-overall-timeout a @@PROJECT@@

[Service]
Type=simple
ExecStart=($bash) -c 'sleep 1.5; touch ($a_flag); exec ($bash) -c \"while true; do sleep 3600; done\"'
Slice=pctl-@@PROJECT@@.slice
"
$a_body | save -f ($scratch.tree_dir | path join "pctl-@@PROJECT@@-a.service")

let b_body = $"[Unit]
Description=wait-overall-timeout b @@PROJECT@@

[Service]
Type=simple
ExecStart=/run/current-system/sw/bin/sleep infinity
Slice=pctl-@@PROJECT@@.slice
"
$b_body | save -f ($scratch.tree_dir | path join "pctl-@@PROJECT@@-b.service")

{
  a: { exec: [$bash "-c" $"test -f ($a_flag)"], periodSeconds: 1, timeoutSeconds: 60 }
  b: { exec: [$bash "-c" "test -f /definitely/does/not/exist"], periodSeconds: 1, timeoutSeconds: 60 }
} | to json | save -f ($scratch.tree_dir | path join "probes.json")

try {
  let t0 = date now
  let up = run-pctl $scratch.project_dir "up" "--tree" $scratch.tree_dir "--wait" "--timeout" "3" "--quiet"
  let elapsed = (date now) - $t0

  assert ($up.exit_code != 0) "expected up --wait to fail (b's probe never passes)"

  # If the timeout were per-service, elapsed could approach 2 × 3s = 6s.
  # With a proper overall deadline, elapsed stays near 3s (+ poll/startup).
  let max = 5sec
  assert ($elapsed <= $max) $"up --wait exceeded overall --timeout: ($elapsed) > ($max)"

  # Error must still name the failing service, not the slow-but-ready one.
  let combined = $up.stdout + $up.stderr
  assert ($combined | str contains " b ") $"error should name service 'b', got: ($combined)"

  print $"wait_overall_timeout_test OK — ($elapsed)"
} catch { |e|
  teardown $scratch
  error make { msg: $"wait_overall_timeout_test failed: ($e.msg)" }
}

teardown $scratch
