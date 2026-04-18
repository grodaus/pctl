#!/usr/bin/env nu
# pctl down stops services, removes units from disk, drops the registry entry.

use std assert
use harness.nu *
use ../../pctl/lib/gc.nu state-home
use ../../pctl/lib/identity.nu derive-id
use ../../pctl/lib/known.nu known-path

let scratch = setup {web: null}

try {
  let up = run-pctl $scratch.project_dir "up" "--tree" $scratch.tree_dir "--quiet"
  assert ($up.exit_code == 0) $"up failed: ($up.stderr)"

  let id = (derive-id $scratch.project_dir).id
  let slice = $"pctl-($id).slice"
  let web = $"pctl-($id)-web.service"
  assert (wait-active $slice 5)
  assert (wait-active $web 5)

  let down = run-pctl $scratch.project_dir "down" "--quiet"
  assert ($down.exit_code == 0) $"down failed: ($down.stderr)"

  # Unit files gone.
  assert (not ((unit-path $slice) | path exists))
  assert (not ((unit-path $web) | path exists))
  assert (not ((unit-path $"($web).d") | path exists))

  # Registry entry gone.
  let reg = $env.XDG_RUNTIME_DIR | path join "pctl" "projects" $id
  assert (not ($reg | path exists))

  # Nothing is running anymore. (systemd keeps inactive slices cached in memory
  # after daemon-reload, so LoadState is not a reliable "forgotten" signal —
  # the unit file being gone on disk is the authoritative check.)
  assert (not (is-active $slice))
  assert (not (is-active $web))

  # `down` must leave the persistent known-marker in place — gc uses it to
  # decide whether a still-present project path means "keep the state dir".
  let marker = known-path (state-home) $id
  assert ($marker | path exists) $"known marker ($marker) wrongly removed by down"

  print $"down_test OK — ($id)"
} catch { |e|
  teardown $scratch
  error make { msg: $"down_test failed: ($e.msg)" }
}

teardown $scratch
