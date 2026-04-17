#!/usr/bin/env nu

use std assert
use harness.nu *
use ../../pctl/lib/identity.nu derive-id

assert ($env.XDG_RUNTIME_DIR? != null)
let runtime_dir = $env.XDG_RUNTIME_DIR

let tmp = mktemp -d -t pctl-down-test-XXXXXX
let fake_tree = $tmp | path join "store"
let project_dir = $tmp | path join "project"
mkdir $project_dir

make-fake-tree $fake_tree {
  web: "[Unit]\nDescription=web @@PROJECT@@\n\n[Service]\nExecStart=/bin/true\nSlice=pctl-@@PROJECT@@.slice\n"
}

let log = $tmp | path join "sysctl.log"
"" | save -f $log
let stub = make-sysctl-stub $log 0
$env.PCTL_SYSTEMCTL = $stub

# First: up.
let up_r = run-pctl "up" "--tree" $fake_tree "--path" $project_dir
if $up_r.exit_code != 0 {
  print $"up stdout: ($up_r.stdout)"; print $"up stderr: ($up_r.stderr)"
  error make { msg: "up failed" }
}

let ident = derive-id $project_dir
let id = $ident.id

let unit_dir = $runtime_dir | path join "systemd" "user.control"
let reg_dir = $runtime_dir | path join "pctl" "projects" $id
assert (($reg_dir | path exists))
assert (($unit_dir | path join $"pctl-($id).slice") | path exists)

# Clear log so we can scrutinize only down's invocations.
"" | save -f $log

# Now: down.
let r = run-pctl "down" "--path" $project_dir
if $r.exit_code != 0 {
  print $"stdout: ($r.stdout)"; print $"stderr: ($r.stderr)"
  error make { msg: $"pctl down exited non-zero: ($r.exit_code)" }
}

# Assertions:
# 1. user.control has none of our files.
let remaining = if ($unit_dir | path exists) { ls $unit_dir | get name | each { path basename } } else { [] }
assert (not ($remaining | any { |n| $n | str starts-with $"pctl-($id)." }))
assert (not ($remaining | any { |n| $n | str starts-with $"pctl-($id)-" }))

# 2. Registry entry gone.
assert (not ($reg_dir | path exists))

# 3. sysctl log shows stop pctl-<id>.slice and daemon-reload.
let lines = read-log $log
assert (($lines | any { |l| $l =~ $"stop pctl-($id)\\.slice" }))
assert (($lines | any { |l| $l =~ "daemon-reload" }))

rm -rf $tmp
