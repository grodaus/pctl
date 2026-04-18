#!/usr/bin/env nu
# pctl up --wait blocks until every service's readinessProbe returns 0.
# Happy path: the probe passes after ~500ms, --wait must not return sooner.

use std assert
use harness.nu *
use ../../pctl/lib/identity.nu derive-id

const bash = "/run/current-system/sw/bin/bash"

let scratch = setup {web: null}

# Service body that creates a readiness flag file after 500ms, then stays up.
let flag = $scratch.tmp | path join "ready.flag"
let web_body = $"[Unit]
Description=wait-test web @@PROJECT@@

[Service]
Type=simple
ExecStart=($bash) -c 'sleep 0.5; touch ($flag); exec ($bash) -c \"while true; do sleep 3600; done\"'
Slice=pctl-@@PROJECT@@.slice
"
$web_body | save -f ($scratch.tree_dir | path join "pctl-@@PROJECT@@-web.service")

# Sidecar probes.json — exec probe that returns 0 iff the flag exists.
let probe_cmd = [$bash "-c" $"test -f ($flag)"]
{
  web: { exec: $probe_cmd, periodSeconds: 1, timeoutSeconds: 10 }
} | to json | save -f ($scratch.tree_dir | path join "probes.json")

try {
  let t0 = date now
  let up = run-pctl $scratch.project_dir "up" "--tree" $scratch.tree_dir "--wait" "--quiet"
  let elapsed = (date now) - $t0
  assert ($up.exit_code == 0) $"up --wait failed: stdout=($up.stdout) stderr=($up.stderr)"

  # The flag only exists if --wait actually polled and the probe passed.
  assert ($flag | path exists) "flag file missing — service never became ready"

  # --wait must have blocked at least ~400ms (flag appears at 500ms).
  let min_wait = 400ms
  assert ($elapsed >= $min_wait) $"up --wait returned too fast: ($elapsed) < ($min_wait)"

  # But not dramatically longer than needed — probe interval is 1s, timeout 10s.
  let max_wait = 5sec
  assert ($elapsed <= $max_wait) $"up --wait took too long: ($elapsed) > ($max_wait)"

  let id = (derive-id $scratch.project_dir).id
  print $"wait_test OK — ($id) waited ($elapsed)"
} catch { |e|
  teardown $scratch
  error make { msg: $"wait_test failed: ($e.msg)" }
}

teardown $scratch
