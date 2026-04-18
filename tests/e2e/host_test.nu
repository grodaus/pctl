#!/usr/bin/env nu
# pctl host prints the allocated 127.0.0.N matching the registry entry.

use std assert
use harness.nu *
use ../../pctl/lib/identity.nu derive-id
use ../../pctl/lib/registry.nu registry-read

let scratch = setup {web: null}

try {
  let up = run-pctl $scratch.project_dir "up" "--tree" $scratch.tree_dir "--quiet"
  assert ($up.exit_code == 0) $"up failed: stdout=($up.stdout) stderr=($up.stderr)"

  let id = (derive-id $scratch.project_dir).id
  let reg = registry-read $env.XDG_RUNTIME_DIR $id
  let expected_host = $reg.host

  let out = run-pctl $scratch.project_dir "host"
  assert ($out.exit_code == 0) $"host failed: stdout=($out.stdout) stderr=($out.stderr)"
  let printed = $out.stdout | str trim
  assert equal $printed $expected_host $"host output ($printed) != registry ($expected_host)"

  # Must match 127.0.0.N shape (2..254).
  assert ($printed =~ '^127\.0\.0\.\d+$') $"host ($printed) not a loopback"

  print $"host_test OK — ($id) ($printed)"
} catch { |e|
  teardown $scratch
  error make { msg: $"host_test failed: ($e.msg)" }
}

teardown $scratch
