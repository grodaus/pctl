#!/usr/bin/env nu
# End-to-end test harness running against the host's real systemd --user.
#
# Each test uses a unique tmpdir, which produces a unique hashed project id via
# pctl's derive-id. Distinct ids → distinct `pctl-<id>.slice` → tests don't
# collide with each other or with the dev's real projects on the same session.
# Cleanup is best-effort via `pctl down`; a stragglers sweep catches crashes.

use std assert

const script_path = path self

export def repo-root []: nothing -> string {
  $script_path | path dirname | path join ".." ".."
}

export def pctl-script []: nothing -> string {
  repo-root | path join "pctl" "pctl.nu"
}

# Binary paths on NixOS hosts. Tests call systemd directly; resolve once.
const sleep_bin = "/run/current-system/sw/bin/sleep"

export def run-pctl [cwd: string, ...args: string]: nothing -> record {
  let script = pctl-script
  cd $cwd
  let r = ^nu $script ...$args | complete
  cd -
  $r
}

# A real systemd-executable .service body under ExecStart=sleep infinity.
# Slice= references pctl-@@PROJECT@@.slice so systemd places it correctly.
export def sleep-service [description: string]: nothing -> string {
  $"[Unit]
Description=($description) @@PROJECT@@

[Service]
Type=simple
ExecStart=($sleep_bin) infinity
Slice=pctl-@@PROJECT@@.slice
"
}

# Write a rendered unit tree on disk that pctl up --tree will consume.
# `services` is a record of { svc-name: unit-body-string }. The slice file is
# always included; pctl's install-units substitutes @@PROJECT@@.
export def write-tree [dir: string, services: record] {
  mkdir $dir
  "[Unit]\nDescription=pctl project @@PROJECT@@\n\n[Slice]\n"
    | save -f ($dir | path join "pctl-@@PROJECT@@.slice")
  $services | transpose name body | each { |r|
    $r.body | save -f ($dir | path join $"pctl-@@PROJECT@@-($r.name).service")
  } | ignore
}

# Create a scratch project directory under /tmp and prebuild a unit tree.
# Returns { tmp, project_dir, tree_dir }.
export def setup [services: record = {web: null}]: nothing -> record {
  let tmp = mktemp -d -t pctl-e2e-XXXXXX
  let project_dir = $tmp | path join "project"
  let tree_dir = $tmp | path join "tree"
  mkdir $project_dir
  let resolved = $services
    | transpose name body
    | each { |r| { name: $r.name, body: (if $r.body == null { sleep-service $r.name } else { $r.body }) } }
    | reduce -f {} { |r, acc| $acc | insert $r.name $r.body }
  write-tree $tree_dir $resolved
  { tmp: $tmp, project_dir: $project_dir, tree_dir: $tree_dir }
}

# Best-effort teardown. Never throws — designed to be called in an `always`
# pattern so a failing assertion doesn't strand services.
export def teardown [scratch: record] {
  try { run-pctl $scratch.project_dir "down" "--quiet" | ignore }
  try { rm -rf $scratch.tmp }
}

# Poll systemctl --user is-active until $unit reaches "active" or $timeout_s.
export def wait-active [unit: string, timeout_s: int = 5]: nothing -> bool {
  mut i = 0
  let max = $timeout_s * 10
  while $i < $max {
    let state = ^systemctl --user is-active $unit | complete | get stdout | str trim
    if $state == "active" { return true }
    sleep 100ms
    $i = $i + 1
  }
  false
}

export def is-active [unit: string]: nothing -> bool {
  let r = ^systemctl --user is-active $unit | complete
  ($r.stdout | str trim) == "active"
}

export def is-loaded [unit: string]: nothing -> bool {
  let r = ^systemctl --user show $unit -p LoadState --value | complete
  ($r.stdout | str trim) == "loaded"
}

# Full path to the installed unit in XDG_RUNTIME_DIR/systemd/user.control.
export def unit-path [basename: string]: nothing -> string {
  $env.XDG_RUNTIME_DIR | path join "systemd" "user.control" $basename
}

# Kill any lingering pctl-e2e-* slices from prior crashed runs. Called by
# run.nu at suite start so a failed test doesn't poison subsequent ones.
export def cleanup-stragglers [] {
  let r = ^systemctl --user list-units --type=slice --all --no-legend --plain | complete
  if $r.exit_code != 0 { return }
  let slices = $r.stdout
    | lines
    | each { |l| $l | split row -r '\s+' | get 0 }
    | where { |s| $s | str starts-with "pctl-" }
  for s in $slices {
    let id = $s | str replace -r '^pctl-' '' | str replace -r '\.slice$' ''
    let reg_dir = $env.XDG_RUNTIME_DIR | path join "pctl" "projects" $id
    if not ($reg_dir | path exists) { continue }
    let path_file = $reg_dir | path join "path"
    if not ($path_file | path exists) { continue }
    let orig_path = open --raw $path_file | str trim
    let is_e2e = ($orig_path | path basename) == "project" and ($orig_path | path dirname | path basename | str starts-with "pctl-e2e-")
    if $is_e2e {
      print $"straggler: ($s) from ($orig_path) — cleaning"
      try { run-pctl $orig_path "down" "--quiet" | ignore }
    }
  }
}
