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
#
# Beyond `pctl down`, teardown also scrubs anything the test wrote under
# `$XDG_STATE_HOME`: the known-marker `pctl up` persists, and any state
# directories systemd created from `StateDirectory=` on service units
# (postgres fixtures do this, ~11MB per run). Without that scrub every
# pg e2e run leaks real disk until someone runs `pctl gc`.
export def teardown [scratch: record] {
  try { run-pctl $scratch.project_dir "down" "--quiet" | ignore }
  try {
    use ../../pctl/lib/identity.nu derive-id
    use ../../pctl/lib/gc.nu state-home
    use ../../pctl/lib/known.nu known-path
    let id = (derive-id $scratch.project_dir).id
    let sh = state-home
    let marker = known-path $sh $id
    if ($marker | path exists) { rm -f $marker }
    # Sweep every `pctl-<id>-*` state dir this test's services may have made.
    let prefix = $"pctl-($id)-"
    if ($sh | path exists) {
      ls $sh
        | where type == dir
        | get name
        | where { |p| ($p | path basename) | str starts-with $prefix }
        | each { |p| rm -rf $p }
        | ignore
    }
  }
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
  if $r.exit_code == 0 {
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

  # Sweep stale known-markers left by crashed e2e runs: any marker whose path
  # points at a removed pctl-e2e-* tmpdir is ours and safe to drop. Keeps
  # pctl gc's "unknown"/"orphan" counts honest across subsequent runs.
  use ../../pctl/lib/gc.nu state-home
  use ../../pctl/lib/known.nu [known-list known-path]
  let known = try { known-list (state-home) } catch { [] }
  for k in $known {
    let is_e2e = ($k.path | path basename) == "project" and ($k.path | path dirname | path basename | str starts-with "pctl-e2e-")
    if $is_e2e and (not ($k.path | path exists)) {
      let marker = known-path (state-home) $k.id
      print $"straggler: marker ($marker) from ($k.path) — removing"
      try { rm -f $marker }
    }
  }
}
