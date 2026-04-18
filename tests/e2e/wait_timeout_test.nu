#!/usr/bin/env nu
# pctl up --wait exits non-zero within the timeout when a readinessProbe never
# passes, and the error message names the service that failed.

use std assert
use harness.nu *

const bash = "/run/current-system/sw/bin/bash"

let scratch = setup {web: null}

# Service stays active forever (sleep infinity), so the failure is purely the probe.
let web_body = $"[Unit]
Description=wait-timeout-test web @@PROJECT@@

[Service]
Type=simple
ExecStart=/run/current-system/sw/bin/sleep infinity
Slice=pctl-@@PROJECT@@.slice
"
$web_body | save -f ($scratch.tree_dir | path join "pctl-@@PROJECT@@-web.service")

# Probe that can never pass: test -f on a file that nobody will create.
let probe_cmd = [$bash "-c" "test -f /definitely/does/not/exist"]
{
  web: { exec: $probe_cmd, periodSeconds: 1, timeoutSeconds: 10 }
} | to json | save -f ($scratch.tree_dir | path join "probes.json")

try {
  let t0 = date now
  let up = run-pctl $scratch.project_dir "up" "--tree" $scratch.tree_dir "--wait" "--timeout" "2" "--quiet"
  let elapsed = (date now) - $t0

  # Must fail: probe never passes.
  assert ($up.exit_code != 0) $"expected up --wait to fail, got exit=($up.exit_code)"

  # Must fail within ~timeout + overhead (poll granularity is 1s + startup).
  let max = 6sec
  assert ($elapsed <= $max) $"up --wait took too long to time out: ($elapsed) > ($max)"

  # Error message should name the service so the user knows what to fix.
  let combined = $up.stdout + $up.stderr
  assert ($combined | str contains "web") $"error should name service 'web', got: ($combined)"

  print $"wait_timeout_test OK — timed out in ($elapsed)"
} catch { |e|
  teardown $scratch
  error make { msg: $"wait_timeout_test failed: ($e.msg)" }
}

teardown $scratch
