#!/usr/bin/env nu
# Two distinct project paths coexist on the same systemd --user session with
# distinct ids, distinct hosts, and independently-managed slices.

use std assert
use harness.nu *
use ../../pctl/lib/identity.nu derive-id
use ../../pctl/lib/registry.nu *

let a = setup {web: null}
let b = setup {web: null}

try {
  let up_a = run-pctl $a.project_dir "up" "--tree" $a.tree_dir "--quiet"
  assert ($up_a.exit_code == 0) $"up A failed: ($up_a.stderr)"
  let up_b = run-pctl $b.project_dir "up" "--tree" $b.tree_dir "--quiet"
  assert ($up_b.exit_code == 0) $"up B failed: ($up_b.stderr)"

  let id_a = (derive-id $a.project_dir).id
  let id_b = (derive-id $b.project_dir).id
  assert ($id_a != $id_b)

  assert (wait-active $"pctl-($id_a).slice" 5)
  assert (wait-active $"pctl-($id_b).slice" 5)
  assert (wait-active $"pctl-($id_a)-web.service" 5)
  assert (wait-active $"pctl-($id_b)-web.service" 5)

  let rec_a = registry-read $env.XDG_RUNTIME_DIR $id_a
  let rec_b = registry-read $env.XDG_RUNTIME_DIR $id_b
  assert ($rec_a.host != $rec_b.host) "hosts collided across worktrees"
  assert ($rec_a.host | str starts-with "127.0.0.")
  assert ($rec_b.host | str starts-with "127.0.0.")

  # Taking one down must not affect the other.
  let down_a = run-pctl $a.project_dir "down" "--quiet"
  assert ($down_a.exit_code == 0) $"down A failed: ($down_a.stderr)"
  assert (is-active $"pctl-($id_b).slice") "B was torn down with A"
  assert (is-active $"pctl-($id_b)-web.service")

  print $"worktree_test OK — a=($id_a) b=($id_b)"
} catch { |e|
  teardown $a
  teardown $b
  error make { msg: $"worktree_test failed: ($e.msg)" }
}

teardown $a
teardown $b
