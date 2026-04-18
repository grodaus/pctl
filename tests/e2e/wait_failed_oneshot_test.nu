#!/usr/bin/env nu
# pctl up --wait returns immediately — without burning the full --timeout —
# when a Type=oneshot service has already exited non-zero (systemd state
# 'failed'). No readiness probe: the path under test is wait-active-unit's
# terminal-state detection.

use std assert
use harness.nu *

let scratch = setup {web: null}

# Type=oneshot + RemainAfterExit=yes: on non-zero exit, systemd leaves the unit
# in state 'failed' indefinitely. `/run/current-system/sw/bin/false` is the
# simplest guaranteed non-zero exit on NixOS.
let web_body = "[Unit]
Description=wait-failed-oneshot-test web @@PROJECT@@

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/run/current-system/sw/bin/false
Slice=pctl-@@PROJECT@@.slice
"
$web_body | save -f ($scratch.tree_dir | path join "pctl-@@PROJECT@@-web.service")

try {
  let t0 = date now
  let up = run-pctl $scratch.project_dir "up" "--tree" $scratch.tree_dir "--wait" "--timeout" "10" "--quiet"
  let elapsed = (date now) - $t0

  # Must fail: the oneshot exited non-zero.
  assert ($up.exit_code != 0) $"expected up --wait to fail, got exit=($up.exit_code)"

  # Must return well before --timeout=10s — the fix short-circuits on 'failed'
  # instead of polling until the deadline. 5s gives generous headroom for the
  # up/start roundtrip on a loaded host.
  let max = 5sec
  assert ($elapsed <= $max) $"up --wait took too long to detect failed oneshot: ($elapsed) > ($max)"

  # Error message should name the service and the terminal state so the user
  # can tell terminal-failure apart from genuine timeout.
  let combined = $up.stdout + $up.stderr
  assert ($combined | str contains "web") $"error should name service 'web', got: ($combined)"
  assert ($combined | str contains "failed") $"error should mention state 'failed', got: ($combined)"

  print $"wait_failed_oneshot_test OK — detected failed oneshot in ($elapsed)"
} catch { |e|
  teardown $scratch
  error make { msg: $"wait_failed_oneshot_test failed: ($e.msg)" }
}

teardown $scratch
