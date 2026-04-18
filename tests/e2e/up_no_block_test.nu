#!/usr/bin/env nu
# pctl up --no-block — async batch start.
#
# Two oneshot services: one succeeds, one fails. With --no-block, pctl issues
# a single `systemctl --user start --no-block <unit1> <unit2>` call. The job
# is enqueued; the failure of `fail` must NOT propagate to the caller, and
# `ok` must still be started (unlike the default synchronous path, where the
# failing start aborts the loop before later units are reached).
#
# Also asserts the default synchronous semantics are preserved: `pctl up`
# (without --no-block) on the same tree throws.

use std assert
use harness.nu *
use ../../pctl/lib/identity.nu derive-id

const true_bin = "/run/current-system/sw/bin/true"
const false_bin = "/run/current-system/sw/bin/false"

def make-ok-fail-tree []: nothing -> record {
  setup {
    ok: $"[Unit]
Description=up-no-block ok @@PROJECT@@

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=($true_bin)
Slice=pctl-@@PROJECT@@.slice
"
    fail: $"[Unit]
Description=up-no-block fail @@PROJECT@@

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=($false_bin)
Slice=pctl-@@PROJECT@@.slice
"
  }
}

# ----- scenario 1: --no-block exits 0 despite fail; both units reach terminal -----

let scratch = make-ok-fail-tree

try {
  let up = run-pctl $scratch.project_dir "up" "--no-block" "--tree" $scratch.tree_dir "--quiet"

  # --no-block must NOT inherit the failing unit's non-zero — the single
  # `systemctl start --no-block` call only reports queueing errors, not
  # ExecStart outcomes.
  assert ($up.exit_code == 0) $"expected up --no-block exit 0, got ($up.exit_code); stdout=($up.stdout) stderr=($up.stderr)"
  assert ($up.stdout | str contains "(async)") $"expected print suffix '\(async\)' in stdout, got: ($up.stdout)"

  # The batch was enqueued; wait for terminal states. `ok` reaches active via
  # wait-active; `fail` is polled directly (wait-active treats only 'active'
  # as success, but here we want 'failed').
  let id = (derive-id $scratch.project_dir).id
  let ok_unit = $"pctl-($id)-ok.service"
  let fail_unit = $"pctl-($id)-fail.service"

  assert (wait-active $ok_unit 5) $"ok service ($ok_unit) did not become active"

  # Poll up to 3s for fail to reach 'failed'. `do -i` suppresses pipefail —
  # systemctl is-active exits non-zero for any state other than 'active', and
  # with pipefail enabled that would abort before `| complete` captures.
  mut reached_failed = false
  for _ in 0..30 {
    let r = do -i { ^systemctl --user is-active $fail_unit | complete }
    let state = $r.stdout | str trim
    if $state == "failed" {
      $reached_failed = true
      break
    }
    sleep 100ms
  }
  assert $reached_failed $"fail service ($fail_unit) did not reach 'failed' state within 3s"

  # `pctl results` collects outcomes for the whole batch.
  let rj = run-pctl $scratch.project_dir "results" "--timeout" "5" "--json" "--quiet"
  assert ($rj.exit_code != 0) $"expected pctl results exit non-zero \(fail present\), got ($rj.exit_code); stdout=($rj.stdout) stderr=($rj.stderr)"
  let records = $rj.stdout | from json
  assert (($records | length) == 2) $"expected 2 records, got ($records | length): ($rj.stdout)"
  let ok_row = $records | where name == "ok" | first
  let fail_row = $records | where name == "fail" | first
  assert ($ok_row.state == "active") $"ok state should be 'active', got ($ok_row.state)"
  assert ($fail_row.state == "failed") $"fail state should be 'failed', got ($fail_row.state)"

  print "up_no_block_test OK — scenario 1 (--no-block) passed"
} catch { |e|
  teardown $scratch
  error make { msg: $"up_no_block_test \(scenario 1\) failed: ($e.msg)" }
}

teardown $scratch

# ----- scenario 2: default synchronous pctl up STILL throws on the same tree -----

let scratch2 = make-ok-fail-tree

try {
  let up = run-pctl $scratch2.project_dir "up" "--tree" $scratch2.tree_dir "--quiet"

  # Synchronous path must inherit the failing unit's non-zero exit —
  # regression guard that --no-block did not change the default behaviour.
  assert ($up.exit_code != 0) $"expected plain up to fail on failing oneshot, got exit=0; stdout=($up.stdout) stderr=($up.stderr)"

  print "up_no_block_test OK — scenario 2 (default sync still throws) passed"
} catch { |e|
  teardown $scratch2
  error make { msg: $"up_no_block_test \(scenario 2\) failed: ($e.msg)" }
}

teardown $scratch2
