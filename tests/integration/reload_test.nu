#!/usr/bin/env nu

use std assert
use harness.nu *
use ../../pctl/lib/identity.nu derive-id

assert ($env.XDG_RUNTIME_DIR? != null)
let runtime_dir = $env.XDG_RUNTIME_DIR

let tmp = mktemp -d -t pctl-reload-test-XXXXXX
let fake_tree = $tmp | path join "store"
let project_dir = $tmp | path join "project"
mkdir $project_dir

# Initial tree: web + db
make-fake-tree $fake_tree {
  web: "[Unit]\nDescription=web v1 @@PROJECT@@\n\n[Service]\nExecStart=/bin/true\nSlice=pctl-@@PROJECT@@.slice\n"
  db: "[Unit]\nDescription=db v1 @@PROJECT@@\n\n[Service]\nExecStart=/bin/true\nSlice=pctl-@@PROJECT@@.slice\n"
}

let log = $tmp | path join "sysctl.log"
"" | save -f $log
let stub = make-sysctl-stub $log 0
$env.PCTL_SYSTEMCTL = $stub

# Up.
let up_r = run-pctl "up" "--tree" $fake_tree "--path" $project_dir
if $up_r.exit_code != 0 {
  print $"up stderr: ($up_r.stderr)"
  error make { msg: "up failed" }
}

let id = (derive-id $project_dir).id

# Capture the initial started_at for later preservation check.
let reg_dir = $runtime_dir | path join "pctl" "projects" $id
let started_at_before = open --raw ($reg_dir | path join "started_at") | str trim

# Mutate web service content in the fake tree; db and slice unchanged.
"[Unit]\nDescription=web V2 @@PROJECT@@\n\n[Service]\nExecStart=/bin/true\nSlice=pctl-@@PROJECT@@.slice\n"
  | save -f ($fake_tree | path join "pctl-@@PROJECT@@-web.service")

# Clear log before reload.
"" | save -f $log

# Reload.
let r = run-pctl "reload" "--tree" $fake_tree "--path" $project_dir
if $r.exit_code != 0 {
  print $"stdout: ($r.stdout)"; print $"stderr: ($r.stderr)"
  error make { msg: $"pctl reload exited non-zero: ($r.exit_code)" }
}

# sysctl log assertions:
let lines = read-log $log

# 1. daemon-reload fired exactly once.
let reload_hits = $lines | where { |l| $l =~ "daemon-reload" } | length
assert equal $reload_hits 1

# 2. web was restarted.
assert (($lines | any { |l| $l =~ $"restart pctl-($id)-web\\.service" }))

# 3. db was NOT restarted.
assert (not ($lines | any { |l| $l =~ $"restart pctl-($id)-db\\.service" }))

# 4. The slice was NOT restarted.
assert (not ($lines | any { |l| $l =~ $"restart pctl-($id)\\.slice" }))

# 5. No "start" or "stop" events for this project (~ only).
assert (not ($lines | any { |l| $l =~ $"^start pctl-($id)" }))
assert (not ($lines | any { |l| $l =~ $"^stop pctl-($id)" }))

# Registry updated:
let manifest_after = open ($reg_dir | path join "manifest.nuon")
let web_hash_after = $manifest_after | get $"pctl-($id)-web.service"
let actual_web = open --raw ($runtime_dir | path join "systemd" "user.control" $"pctl-($id)-web.service") | hash sha256
assert equal $web_hash_after $actual_web

# started_at preserved.
let started_at_after = open --raw ($reg_dir | path join "started_at") | str trim
assert equal $started_at_before $started_at_after

# Web file on disk contains the new v2 content.
let web_disk = open --raw ($runtime_dir | path join "systemd" "user.control" $"pctl-($id)-web.service")
assert ($web_disk | str contains "web V2")
assert (not ($web_disk | str contains "web v1"))

# stdout summary has +0 ~1 =… -0 shape.
let stdout_str = $r.stdout
assert ($stdout_str =~ '\+0 ~1 =\d+ -0')

rm -rf $tmp
