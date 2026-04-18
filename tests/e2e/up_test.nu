#!/usr/bin/env nu
# pctl up materializes units on disk and reaches active state via real systemd --user.

use std assert
use harness.nu *
use ../../pctl/lib/gc.nu state-home
use ../../pctl/lib/identity.nu derive-id
use ../../pctl/lib/known.nu known-path

let scratch = setup {web: null, api: null}

try {
  let up = run-pctl $scratch.project_dir "up" "--tree" $scratch.tree_dir "--quiet"
  assert ($up.exit_code == 0) $"up failed: stdout=($up.stdout) stderr=($up.stderr)"

  let id = (derive-id $scratch.project_dir).id
  let slice = $"pctl-($id).slice"
  let web = $"pctl-($id)-web.service"
  let api = $"pctl-($id)-api.service"

  # Unit files materialized on disk.
  assert ((unit-path $slice) | path exists)
  assert ((unit-path $web) | path exists)
  assert ((unit-path $api) | path exists)

  # Drop-ins carry PCTL_ID (+ PCTL_HOST on services).
  let web_dropin = open --raw ((unit-path $"($web).d") | path join "pctl-runtime.conf")
  assert ($web_dropin | str contains $"PCTL_ID=($id)")
  assert ($web_dropin | str contains "PCTL_HOST=127.0.0.")

  # Real systemd state: slice and services active.
  assert (wait-active $slice 5) $"slice ($slice) did not become active"
  assert (wait-active $web 5) $"web ($web) did not become active"
  assert (wait-active $api 5) $"api ($api) did not become active"

  # Environment landed on the running service.
  let env_out = ^systemctl --user show $web -p Environment --value | complete | get stdout | str trim
  assert ($env_out | str contains $"PCTL_ID=($id)")

  # Persistent known-marker written so `pctl gc` can distinguish this
  # project's state from orphaned leftovers after a future reboot.
  let marker = known-path (state-home) $id
  assert ($marker | path exists) $"known marker ($marker) missing after up"
  assert equal (open --raw $marker | str trim) $scratch.project_dir

  print $"up_test OK — ($id)"
} catch { |e|
  teardown $scratch
  error make { msg: $"up_test failed: ($e.msg)" }
}

teardown $scratch
