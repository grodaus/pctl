#!/usr/bin/env nu
# Probes are executed with PCTL_HOST / PCTL_ID in the environment, matching the
# drop-in that systemd applies to the service itself.

use std assert
use harness.nu *
use ../../pctl/lib/identity.nu derive-id
use ../../pctl/lib/registry.nu registry-read

const bash = "/run/current-system/sw/bin/bash"

let scratch = setup {web: null}

# Probe writes whatever PCTL_HOST and PCTL_ID it sees to a file, then succeeds.
let seen = $scratch.tmp | path join "seen"
let probe_cmd = [$bash "-c" $"printf '%s %s' \"$PCTL_HOST\" \"$PCTL_ID\" > ($seen)"]
{
  web: { exec: $probe_cmd, periodSeconds: 1, timeoutSeconds: 5 }
} | to json | save -f ($scratch.tree_dir | path join "probes.json")

try {
  let up = run-pctl $scratch.project_dir "up" "--tree" $scratch.tree_dir "--wait" "--quiet"
  assert ($up.exit_code == 0) $"up --wait failed: stdout=($up.stdout) stderr=($up.stderr)"

  let id = (derive-id $scratch.project_dir).id
  let reg = registry-read $env.XDG_RUNTIME_DIR $id
  let expected = $"($reg.host) ($id)"

  assert ($seen | path exists) "probe never wrote the seen file"
  let actual = open --raw $seen | str trim
  assert equal $actual $expected $"probe saw wrong env: got ($actual), want ($expected)"

  print $"wait_pctl_host_test OK — probe saw PCTL_HOST=($reg.host) PCTL_ID=($id)"
} catch { |e|
  teardown $scratch
  error make { msg: $"wait_pctl_host_test failed: ($e.msg)" }
}

teardown $scratch
