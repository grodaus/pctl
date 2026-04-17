#!/usr/bin/env nu

use std assert
use harness.nu *
use ../../pctl/lib/identity.nu derive-id

assert ($env.XDG_RUNTIME_DIR? != null)
let runtime_dir = $env.XDG_RUNTIME_DIR

let tmp = mktemp -d -t pctl-worktree-test-XXXXXX
let fake_tree = $tmp | path join "store"
make-fake-tree $fake_tree {
  web: "[Unit]\nDescription=web @@PROJECT@@\n\n[Service]\nExecStart=/bin/true\nSlice=pctl-@@PROJECT@@.slice\n"
}

# Two distinct project paths that simulate worktrees.
let path_a = $tmp | path join "repo" "trees" "main"
let path_b = $tmp | path join "repo" "trees" "feature"
mkdir $path_a
mkdir $path_b

let log = $tmp | path join "sysctl.log"
"" | save -f $log
let stub = make-sysctl-stub $log 0
$env.PCTL_SYSTEMCTL = $stub

# up from project A
let r_a = run-pctl "up" "--tree" $fake_tree "--path" $path_a
if $r_a.exit_code != 0 { print $"a stderr: ($r_a.stderr)"; error make { msg: "up A failed" } }

# up from project B
let r_b = run-pctl "up" "--tree" $fake_tree "--path" $path_b
if $r_b.exit_code != 0 { print $"b stderr: ($r_b.stderr)"; error make { msg: "up B failed" } }

let id_a = (derive-id $path_a).id
let id_b = (derive-id $path_b).id

# Distinct ids (hash differs per absolute path)
assert ($id_a != $id_b)

# Both registered
let reg_a = registry-path $runtime_dir $id_a
let reg_b = registry-path $runtime_dir $id_b
# harness imports registry-path from the lib
use ../../pctl/lib/registry.nu [registry-path registry-read registry-list]
let list = registry-list $runtime_dir
assert equal ($list | length) 2
assert equal ($list | get id | sort) ([$id_a $id_b] | sort)

# Distinct hosts
let rec_a = registry-read $runtime_dir $id_a
let rec_b = registry-read $runtime_dir $id_b
assert ($rec_a.host != $rec_b.host)
assert ($rec_a.host | str starts-with "127.0.0.")
assert ($rec_b.host | str starts-with "127.0.0.")

# Unit files for both projects coexist in user.control
let unit_dir = $runtime_dir | path join "systemd" "user.control"
let names = ls $unit_dir | get name | each { path basename }
assert ($"pctl-($id_a).slice" in $names)
assert ($"pctl-($id_b).slice" in $names)
assert ($"pctl-($id_a)-web.service" in $names)
assert ($"pctl-($id_b)-web.service" in $names)

rm -rf $tmp
