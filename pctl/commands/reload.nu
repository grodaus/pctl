use ../lib/identity.nu *
use ../lib/install.nu *
use ../lib/manifest.nu *
use ../lib/registry.nu *
use ../lib/sysctl.nu *

# pctl reload — rebuild, diff against the stored manifest, minimally restart.
#
# Flow:
#   1. Obtain a rendered store tree (either --tree or --nix build).
#   2. Install into a *staging* directory (not the real user.control).
#   3. Compute staging manifest; diff against stored manifest.
#   4. Copy changed/added files from staging → real user.control; remove missing.
#   5. Single daemon-reload.
#   6. systemctl start (+), restart (~), stop (-) — skipping the slice.
#   7. Write new manifest; print +N ~N =N -N summary.
export def main [
  --tree: string
  --nix: string = ".#pctl"
  --path: string
  --quiet
] {
  let runtime_dir = $env.XDG_RUNTIME_DIR? | default ""
  if ($runtime_dir | is-empty) {
    error make { msg: "pctl reload: XDG_RUNTIME_DIR is not set" }
  }

  let project_path = if ($path | is-empty) { pwd | path expand } else { $path | path expand }
  let id = (derive-id $project_path).id

  let reg = registry-read $runtime_dir $id
  let old_manifest = $reg.manifest
  let host = $reg.host

  let store_tree = if ($tree | is-empty) {
    if not $quiet { print $"$ nix build ($nix) --no-link --print-out-paths" }
    let built = ^nix build $nix --no-link --print-out-paths | complete
    if $built.exit_code != 0 {
      error make { msg: $"pctl reload: nix build failed: ($built.stderr)" }
    }
    $built.stdout | str trim | lines | last
  } else {
    $tree | path expand
  }

  # Staging: a tmpdir that looks like an XDG_RUNTIME_DIR. install-units writes
  # into $staging/systemd/user.control/.
  let staging = mktemp -d -t pctl-reload-staging-XXXXXX
  install-units $store_tree $staging $id $host
  let staging_unit_dir = $staging | path join "systemd" "user.control"

  # New manifest: hash every top-level file (exclude .d drop-in dirs).
  let new_manifest = ls $staging_unit_dir
    | where type == file
    | get name
    | where { |p|
      let base = $p | path basename
      ($base | str starts-with $"pctl-($id).") or ($base | str starts-with $"pctl-($id)-")
    }
    | reduce -f {} { |p, acc|
      let base = $p | path basename
      let h = open --raw $p | hash sha256
      $acc | insert $base $h
    }

  let plan = diff-manifest $old_manifest $new_manifest

  let real_unit_dir = $runtime_dir | path join "systemd" "user.control"
  mkdir $real_unit_dir

  # Copy over added / changed units (and their drop-ins).
  $plan | where { |r| $r.action == "added" or $r.action == "changed" } | each { |r|
    let src = $staging_unit_dir | path join $r.unit
    let dst = $real_unit_dir | path join $r.unit
    open --raw $src | save -f $dst
    let src_d = $staging_unit_dir | path join $"($r.unit).d"
    let dst_d = $real_unit_dir | path join $"($r.unit).d"
    if ($src_d | path exists) {
      if not ($dst_d | path exists) { mkdir $dst_d }
      ls $src_d | where type == file | get name | each { |f|
        let base = $f | path basename
        open --raw $f | save -f ($dst_d | path join $base)
      } | ignore
    }
    null
  } | ignore

  # Remove units that are no longer present.
  $plan | where action == "removed" | each { |r|
    let dst = $real_unit_dir | path join $r.unit
    if ($dst | path exists) { rm -f $dst }
    let dst_d = $real_unit_dir | path join $"($r.unit).d"
    if ($dst_d | path exists) { rm -rf $dst_d }
    null
  } | ignore

  # Single daemon-reload.
  run-systemctl daemon-reload --quiet=$quiet

  # Service-level actions: start/restart/stop. Skip the slice file — restarting
  # a slice would bounce every service, defeating the whole point of reload.
  let service_actions = $plan | where { |r| not ($r.unit | str ends-with ".slice") }

  $service_actions | where action == "added" | each { |r|
    run-systemctl start $r.unit --quiet=$quiet
    null
  } | ignore

  $service_actions | where action == "changed" | each { |r|
    run-systemctl restart $r.unit --quiet=$quiet
    null
  } | ignore

  $service_actions | where action == "removed" | each { |r|
    try {
      run-systemctl stop $r.unit --quiet=$quiet
    } catch { |e|
      if not $quiet {
        print $"(ansi yellow)warning(ansi reset): stop ($r.unit) failed: ($e.msg)"
      }
    }
    null
  } | ignore

  # Persist new manifest; preserve started_at.
  registry-write $runtime_dir $id {
    path: $reg.path
    host: $host
    manifest: $new_manifest
    started_at: $reg.started_at
  }

  # Cleanup staging.
  rm -rf $staging

  print (summary $plan)
}
