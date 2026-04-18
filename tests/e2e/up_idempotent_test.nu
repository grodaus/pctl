#!/usr/bin/env nu
# pctl up on an already-up project must reuse the allocated host, not allocate
# a new one. Regression: up was passing the project's own registered host to
# allocate-host via taken-hosts, forcing it into the next slot and desyncing
# the running service env (PCTL_HOST) from disk and registry.

use std assert
use harness.nu *
use ../../pctl/lib/identity.nu derive-id

let scratch = setup {web: null, api: null}

try {
  let up1 = run-pctl $scratch.project_dir "up" "--tree" $scratch.tree_dir "--quiet"
  assert ($up1.exit_code == 0) $"first up failed: stdout=($up1.stdout) stderr=($up1.stderr)"

  let id = (derive-id $scratch.project_dir).id
  let web = $"pctl-($id)-web.service"
  let api = $"pctl-($id)-api.service"

  let reg_dir = $env.XDG_RUNTIME_DIR | path join "pctl" "projects" $id
  let host_file = $reg_dir | path join "host"
  let dropin_path = (unit-path $"($web).d") | path join "pctl-runtime.conf"

  assert (wait-active $web 5) $"web ($web) did not become active after first up"
  assert (wait-active $api 5) $"api ($api) did not become active after first up"

  let host_before = open --raw $host_file | str trim
  let dropin_before = open --raw $dropin_path
  let env_before = ^systemctl --user show $web -p Environment --value
    | complete | get stdout | str trim
  let started_at_before = open --raw ($reg_dir | path join "started_at") | str trim

  assert ($dropin_before | str contains $"PCTL_HOST=($host_before)")
  assert ($env_before | str contains $"PCTL_HOST=($host_before)")

  # Second up: registry entry already exists; must reuse the host.
  let up2 = run-pctl $scratch.project_dir "up" "--tree" $scratch.tree_dir "--quiet"
  assert ($up2.exit_code == 0) $"second up failed: stdout=($up2.stdout) stderr=($up2.stderr)"

  let host_after = open --raw $host_file | str trim
  let dropin_after = open --raw $dropin_path
  let env_after = ^systemctl --user show $web -p Environment --value
    | complete | get stdout | str trim
  let started_at_after = open --raw ($reg_dir | path join "started_at") | str trim

  assert ($host_after == $host_before) $"host drifted across ups: before=($host_before) after=($host_after)"
  assert ($dropin_after == $dropin_before) "drop-in diverged across ups"
  assert ($env_after == $env_before) $"service env diverged from registry: env=($env_after) host=($host_after)"
  assert ($started_at_after == $started_at_before) "started_at rewritten on re-up"

  assert (is-active $web) "web became inactive after second up"
  assert (is-active $api) "api became inactive after second up"

  print $"up_idempotent_test OK — ($id) host=($host_after)"
} catch { |e|
  teardown $scratch
  error make { msg: $"up_idempotent_test failed: ($e.msg)" }
}

teardown $scratch
