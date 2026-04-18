#!/usr/bin/env nu
# Regression guard: pctl up (without --wait) returns immediately even when a
# readinessProbe would never pass. --wait must stay strictly opt-in.

use std assert
use harness.nu *

const bash = "/run/current-system/sw/bin/bash"

let scratch = setup {web: null}

# Probe that can never pass.
let probe_cmd = [$bash "-c" "test -f /definitely/does/not/exist"]
{
  web: { exec: $probe_cmd, periodSeconds: 1, timeoutSeconds: 10 }
} | to json | save -f ($scratch.tree_dir | path join "probes.json")

try {
  let t0 = date now
  let up = run-pctl $scratch.project_dir "up" "--tree" $scratch.tree_dir "--quiet"
  let elapsed = (date now) - $t0

  assert ($up.exit_code == 0) $"plain up failed: stdout=($up.stdout) stderr=($up.stderr)"

  # Plain `up` must return fast (no readiness polling). Generous bound — systemctl
  # calls dominate — but must be well under one probe period (1s).
  let max = 3sec
  assert ($elapsed <= $max) $"plain up was slow, maybe waiting by accident: ($elapsed) > ($max)"

  print $"up_no_wait_test OK — ($elapsed)"
} catch { |e|
  teardown $scratch
  error make { msg: $"up_no_wait_test failed: ($e.msg)" }
}

teardown $scratch
