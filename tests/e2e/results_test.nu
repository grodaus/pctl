#!/usr/bin/env nu
# pctl results — batch outcome reporting.
#
# Three services in one project — each represents a distinct terminal state:
#   - web-ok:   oneshot + RemainAfterExit=yes, ExecStart=true   → active
#   - web-fail: oneshot + RemainAfterExit=yes, ExecStart=false  → failed
#   - web-slow: Type=simple, ExecStart=sleep infinity           → active (via unit-state)
#
# `pctl results` must wait for every service to reach a terminal state and
# print one row per service, even when one fails. Exit non-zero because of
# web-fail, but all three must appear in the output.
#
# Also exercises the happy-path variant: same project minus web-fail → exit 0.

use std assert
use harness.nu *

const bash = "/run/current-system/sw/bin/bash"

# ----- mixed outcome: fail expected -----

let scratch = setup {
  web-ok: $"[Unit]
Description=results-test web-ok @@PROJECT@@

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/run/current-system/sw/bin/true
Slice=pctl-@@PROJECT@@.slice
"
  web-fail: $"[Unit]
Description=results-test web-fail @@PROJECT@@

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/run/current-system/sw/bin/false
Slice=pctl-@@PROJECT@@.slice
"
  web-slow: $"[Unit]
Description=results-test web-slow @@PROJECT@@

[Service]
Type=simple
ExecStart=($bash) -c 'sleep 0.5; exec ($bash) -c \"while true; do sleep 3600; done\"'
Slice=pctl-@@PROJECT@@.slice
"
}

try {
  # `pctl up` stops on the first failing service. That's by design — `results`
  # is what the user runs afterwards to collect outcomes. So we tolerate the
  # up failure, then start any services the up loop didn't get to (alphabetical
  # sort: web-fail aborts the loop before web-ok and web-slow are reached).
  use ../../pctl/lib/identity.nu derive-id
  let up = run-pctl $scratch.project_dir "up" "--tree" $scratch.tree_dir "--quiet"
  # up may exit non-zero because web-fail's ExecStart=false, but the registry
  # entry and every unit file are already on disk by then.
  let id = (derive-id $scratch.project_dir).id
  try { ^systemctl --user start $"pctl-($id)-web-ok.service" } catch { }
  try { ^systemctl --user start $"pctl-($id)-web-slow.service" } catch { }

  let t0 = date now
  let r = run-pctl $scratch.project_dir "results" "--timeout" "5" "--quiet"
  let elapsed = (date now) - $t0

  # web-fail causes non-zero exit; the command still prints every service.
  assert ($r.exit_code != 0) $"expected results to exit non-zero for mixed outcome, got: ($r.exit_code); stdout=($r.stdout) stderr=($r.stderr)"

  let out = $r.stdout
  assert ($out | str contains "web-ok") $"stdout should contain 'web-ok': ($out)"
  assert ($out | str contains "web-fail") $"stdout should contain 'web-fail': ($out)"
  assert ($out | str contains "web-slow") $"stdout should contain 'web-slow': ($out)"
  assert ($out | str contains "failed") $"stdout should mention 'failed': ($out)"

  let active_count = $out | lines | where { |l| $l | str contains "active" } | length
  assert ($active_count >= 2) $"expected 'active' to appear in at least 2 rows, got ($active_count): ($out)"

  # Wall-clock must be far below the 5s ceiling — the slow service stabilises
  # at ~0.5s, the oneshots complete instantly. A generous 5s bound catches
  # regressions where wait-all unexpectedly burns the full --timeout.
  let max_wait = 5sec
  assert ($elapsed < $max_wait) $"results took too long: ($elapsed) >= ($max_wait)"

  # --json variant: same wait, record-shaped output.
  let rj = run-pctl $scratch.project_dir "results" "--timeout" "5" "--json" "--quiet"
  assert ($rj.exit_code != 0) "expected --json results to exit non-zero"
  let records = $rj.stdout | from json
  assert (($records | length) == 3) $"expected 3 records, got ($records | length): ($rj.stdout)"
  let names = $records | get name | sort
  assert ($names == ["web-fail", "web-ok", "web-slow"]) $"unexpected names: ($names)"
  let fail_row = $records | where name == "web-fail" | first
  assert ($fail_row.state == "failed") $"web-fail state should be 'failed', got ($fail_row.state)"

  print "results_test OK — mixed outcome reported, exit non-zero"
} catch { |e|
  teardown $scratch
  error make { msg: $"results_test failed: ($e.msg)" }
}

teardown $scratch

# ----- happy path: all succeed -----

let scratch2 = setup {
  web-ok: $"[Unit]
Description=results-test-happy web-ok @@PROJECT@@

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/run/current-system/sw/bin/true
Slice=pctl-@@PROJECT@@.slice
"
  web-slow: $"[Unit]
Description=results-test-happy web-slow @@PROJECT@@

[Service]
Type=simple
ExecStart=($bash) -c 'sleep 0.5; exec ($bash) -c \"while true; do sleep 3600; done\"'
Slice=pctl-@@PROJECT@@.slice
"
}

try {
  let up = run-pctl $scratch2.project_dir "up" "--tree" $scratch2.tree_dir "--quiet"
  assert ($up.exit_code == 0) $"up failed: stdout=($up.stdout) stderr=($up.stderr)"

  let r = run-pctl $scratch2.project_dir "results" "--timeout" "5" "--quiet"
  assert ($r.exit_code == 0) $"expected happy-path results to exit 0, got: ($r.exit_code); stdout=($r.stdout) stderr=($r.stderr)"
  assert ($r.stdout | str contains "web-ok") $"stdout should contain 'web-ok': ($r.stdout)"
  assert ($r.stdout | str contains "web-slow") $"stdout should contain 'web-slow': ($r.stdout)"
  assert (not ($r.stdout | str contains "failed")) $"happy path should not mention 'failed': ($r.stdout)"

  print "results_test OK — happy path exit 0"
} catch { |e|
  teardown $scratch2
  error make { msg: $"results_test (happy path) failed: ($e.msg)" }
}

teardown $scratch2
