#!/usr/bin/env nu

use std assert
use harness.nu *
use ../../pctl/lib/identity.nu derive-id

# Fresh XDG_RUNTIME_DIR is provided by the wrapper.
assert ($env.XDG_RUNTIME_DIR? != null)
let runtime_dir = $env.XDG_RUNTIME_DIR

# Build fake store tree + project path
let tmp = mktemp -d -t pctl-up-test-XXXXXX
let fake_tree = $tmp | path join "store"
let project_dir = $tmp | path join "project"
mkdir $project_dir

make-fake-tree $fake_tree {
  web: "[Unit]\nDescription=web @@PROJECT@@\n\n[Service]\nExecStart=/bin/true\nSlice=pctl-@@PROJECT@@.slice\n"
}

# Install sysctl stub
let log = $tmp | path join "sysctl.log"
"" | save -f $log
let stub = make-sysctl-stub $log 0
$env.PCTL_SYSTEMCTL = $stub

# Run pctl up --tree <fake_tree> --path <project_dir>
let r = run-pctl "up" "--tree" $fake_tree "--path" $project_dir
if $r.exit_code != 0 {
  print $"stdout: ($r.stdout)"
  print $"stderr: ($r.stderr)"
  error make { msg: $"pctl up exited non-zero: ($r.exit_code)" }
}

# The id should derive deterministically from the project_dir
let ident = derive-id $project_dir
let id = $ident.id

# Expected files in user.control
let unit_dir = $runtime_dir | path join "systemd" "user.control"
assert ($unit_dir | path exists)
let installed = ls $unit_dir | get name | each { path basename } | sort
assert ($"pctl-($id).slice" in $installed)
assert ($"pctl-($id)-web.service" in $installed)
# placeholder not leaking
assert (not ($installed | any { |n| $n =~ '@@PROJECT@@' }))

# Registry entry
let reg_dir = $runtime_dir | path join "pctl" "projects" $id
assert ($reg_dir | path exists)
assert (($reg_dir | path join "path") | path exists)
assert (($reg_dir | path join "host") | path exists)
assert (($reg_dir | path join "manifest.nuon") | path exists)
assert (($reg_dir | path join "started_at") | path exists)

# path file stores the *absolute* project path
let stored_path = open --raw ($reg_dir | path join "path") | str trim
assert equal $stored_path ($project_dir | path expand)

# host is 127.0.0.N for some N in 2..254
let host = open --raw ($reg_dir | path join "host") | str trim
assert ($host | str starts-with "127.0.0.")
let host_n = $host | str replace "127.0.0." "" | into int
assert ($host_n >= 2 and $host_n <= 254)

# manifest has both units
let manifest = open ($reg_dir | path join "manifest.nuon")
assert ($"pctl-($id).slice" in ($manifest | columns))
assert ($"pctl-($id)-web.service" in ($manifest | columns))

# sysctl log: daemon-reload, then start slice, then start every .service
let lines = read-log $log
assert (($lines | any { |l| $l =~ "daemon-reload" }))
assert (($lines | any { |l| $l =~ $"start pctl-($id)\\.slice" }))
# Bug-1 regression: every .service in the manifest must be explicitly started,
# because `systemctl start <slice>` alone does not pull in child services.
assert (($lines | any { |l| $l =~ $"start pctl-($id)-web\\.service" }))
# daemon-reload comes before slice start, slice start before service start
let idx_reload = $lines | enumerate | where { |r| $r.item =~ "daemon-reload" } | first | get index
let idx_slice = $lines | enumerate | where { |r| $r.item =~ $"start pctl-($id)\\.slice" } | first | get index
let idx_svc = $lines | enumerate | where { |r| $r.item =~ $"start pctl-($id)-web\\.service" } | first | get index
assert ($idx_reload < $idx_slice)
assert ($idx_slice < $idx_svc)

# cleanup
rm -rf $tmp
