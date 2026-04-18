#!/usr/bin/env nu
#
# Unit tests for the pass-through commands: status, restart, logs, ls.
# Each sets up a sysctl stub that logs argv, invokes the command's main, and
# asserts the logged invocation. These complement the integration tests.

use std assert
use ../../pctl/lib/identity.nu derive-id

let tmpbase = mktemp -d -t pctl-commands-test-XXXXXX
$env.XDG_RUNTIME_DIR = $tmpbase

# ---- helpers ----

def make-stub [logfile: string, code: int = 0]: nothing -> string {
  let stub = mktemp -t pctl-cmds-stub-XXXXXX
  $"#!/bin/sh\necho \"$@\" >> ($logfile)\nexit ($code)\n" | save -f $stub
  chmod +x $stub
  $stub
}

# is-active stub: real systemctl prints one state line per unit. The stub
# emits `state` once per arg following `is-active`, so the helper sees a
# realistic stdout shape regardless of how many units `list` queries.
def make-is-active-stub [logfile: string, state: string, code: int]: nothing -> string {
  let stub = mktemp -t pctl-cmds-stub-XXXXXX
  let body = $'#!/bin/sh
echo "$@" >> ($logfile)
shift          # drop --user
shift          # drop is-active
for _u in "$@"; do
  echo ($state)
done
exit ($code)
'
  $body | save -f $stub
  chmod +x $stub
  $stub
}

def read-last [logfile: string]: nothing -> string {
  open --raw $logfile | lines | where { |l| ($l | str trim) != "" } | last | str trim
}

# Use a deterministic fake project path.
let project_dir = $tmpbase | path join "proj"
mkdir $project_dir
let id = (derive-id $project_dir).id

let log = $tmpbase | path join "cmds.log"
"" | save -f $log
let stub = make-stub $log 0
$env.PCTL_SYSTEMCTL = $stub
$env.PCTL_JOURNALCTL = $stub

# ---- status (slice) ----
use ../../pctl/commands/status.nu
status --path $project_dir --quiet
assert equal (read-last $log) $"--user status pctl-($id).slice"

# ---- status (service) ----
"" | save -f $log
status "web" --path $project_dir --quiet
assert equal (read-last $log) $"--user status pctl-($id)-web.service"

# ---- restart (slice) ----
"" | save -f $log
use ../../pctl/commands/restart.nu
restart --path $project_dir --quiet
assert equal (read-last $log) $"--user restart pctl-($id).slice"

# ---- restart (service) ----
"" | save -f $log
restart "web" --path $project_dir --quiet
assert equal (read-last $log) $"--user restart pctl-($id)-web.service"

# ---- logs (slice, default lines=100, no follow) ----
"" | save -f $log
use ../../pctl/commands/logs.nu
logs --path $project_dir --quiet
assert equal (read-last $log) $"--user -u pctl-($id).slice -n 100"

# ---- logs (service, with --follow and --lines 50) ----
"" | save -f $log
logs "web" --path $project_dir --follow --lines 50 --quiet
assert equal (read-last $log) $"--user -u pctl-($id)-web.service -n 50 -f"

# ---- ls (no projects) ----
"" | save -f $log
use ../../pctl/commands/list.nu
# list returns a table; no projects → prints "no projects registered"
let out = list --quiet

# ---- ls (with one registered project) ----
use ../../pctl/lib/registry.nu *
registry-write $tmpbase $id {
  path: $project_dir
  host: "127.0.0.17"
  manifest: {}
  started_at: "2026-04-17T10:00:00+00:00"
}
let active_log = $tmpbase | path join "active.log"
"" | save -f $active_log
let active_stub = make-is-active-stub $active_log "active" 0
$env.PCTL_SYSTEMCTL = $active_stub
let rows = list --quiet
assert (($rows | length) == 1)
assert equal ($rows | first | get id) $id
assert equal ($rows | first | get host) "127.0.0.17"
let last_log = read-last $active_log
assert equal $last_log $"--user is-active pctl-($id).slice"
assert equal ($rows | first | get running) true

# ---- ls when units are inactive → running=false, no error ----
let fail_log = $tmpbase | path join "fail.log"
"" | save -f $fail_log
let fail_stub = make-is-active-stub $fail_log "inactive" 3
$env.PCTL_SYSTEMCTL = $fail_stub
let rows2 = list --quiet
assert equal ($rows2 | first | get running) false

rm -rf $tmpbase
