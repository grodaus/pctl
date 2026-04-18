#!/usr/bin/env nu
# pctl host exits non-zero with a helpful message when the project has no
# registry entry (never `up`'d, or already `down`'d).

use std assert
use harness.nu *

let scratch = setup {web: null}

try {
  # Never call `up`. Registry has no entry for this project.
  let out = run-pctl $scratch.project_dir "host"
  assert ($out.exit_code != 0) $"host should fail for unregistered project, got exit=($out.exit_code) stdout=($out.stdout)"

  let combined = $out.stdout + $out.stderr
  assert ($combined | str contains "not registered") $"error message should mention 'not registered', got: ($combined)"

  print "host_not_registered_test OK"
} catch { |e|
  teardown $scratch
  error make { msg: $"host_not_registered_test failed: ($e.msg)" }
}

teardown $scratch
