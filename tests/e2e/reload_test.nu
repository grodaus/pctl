#!/usr/bin/env nu
# pctl reload restarts only the changed service; slice and unchanged services
# survive — asserted against real systemd ActiveEnterTimestamp values.

use std assert
use harness.nu *
use ../../pctl/lib/identity.nu derive-id

let scratch = setup {web: null, db: null}

try {
  let up = run-pctl $scratch.project_dir "up" "--tree" $scratch.tree_dir "--quiet"
  assert ($up.exit_code == 0) $"up failed: ($up.stderr)"

  let id = (derive-id $scratch.project_dir).id
  let slice = $"pctl-($id).slice"
  let web = $"pctl-($id)-web.service"
  let db = $"pctl-($id)-db.service"

  assert (wait-active $slice 5)
  assert (wait-active $web 5)
  assert (wait-active $db 5)

  # Capture ActiveEnterTimestamp (monotonic µs) before reload for comparison.
  def enter-ts [unit: string]: nothing -> string {
    ^systemctl --user show $unit -p ActiveEnterTimestampMonotonic --value
      | complete | get stdout | str trim
  }
  let web_ts_before = enter-ts $web
  let db_ts_before = enter-ts $db
  let slice_ts_before = enter-ts $slice

  # Mutate only web: change Description. DB and slice content unchanged.
  $"[Unit]
Description=web-v2 @@PROJECT@@

[Service]
Type=simple
ExecStart=/run/current-system/sw/bin/sleep infinity
Slice=pctl-@@PROJECT@@.slice
" | save -f ($scratch.tree_dir | path join "pctl-@@PROJECT@@-web.service")

  let reload = run-pctl $scratch.project_dir "reload" "--tree" $scratch.tree_dir "--quiet"
  assert ($reload.exit_code == 0) $"reload failed: ($reload.stderr)"
  assert ($reload.stdout | str contains "~1") $"expected ~1 in summary, got: ($reload.stdout)"

  # Web should have restarted.
  assert (wait-active $web 5)
  let web_ts_after = enter-ts $web
  assert ($web_ts_after != $web_ts_before) "web was not restarted"

  # DB and slice should NOT have been bounced.
  let db_ts_after = enter-ts $db
  let db_msg = $"db was restarted unexpectedly: before=($db_ts_before) after=($db_ts_after)"
  assert ($db_ts_after == $db_ts_before) $db_msg
  let slice_ts_after = enter-ts $slice
  assert ($slice_ts_after == $slice_ts_before) "slice was restarted unexpectedly"

  # Disk content reflects new web body.
  let web_disk = open --raw (unit-path $web)
  assert ($web_disk | str contains "web-v2")

  print $"reload_test OK — ($id)"
} catch { |e|
  teardown $scratch
  error make { msg: $"reload_test failed: ($e.msg)" }
}

teardown $scratch
