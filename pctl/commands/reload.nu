use ../lib/build.nu *
use ../lib/context.nu *
use ../lib/identity.nu *
use ../lib/install.nu *
use ../lib/manifest.nu *
use ../lib/registry.nu *
use ../lib/sysctl.nu *
use ../lib/units.nu *

# pctl reload — rebuild, diff against the stored manifest, minimally restart.
export def main [
  --tree: string
  --nix: string = ".#pctl"
  --path: string
  --quiet
] {
  let runtime_dir = require-runtime-dir
  let project_path = resolve-project-path $path
  let id = (derive-id $project_path).id

  let reg = registry-read $runtime_dir $id
  let old_manifest = $reg.manifest
  let host = $reg.host

  let store_tree = resolve-store-tree $nix $tree --quiet=$quiet

  # Staging: a tmpdir that looks like an XDG_RUNTIME_DIR. install-units writes
  # into $staging/systemd/user.control/.
  let staging = mktemp -d -t pctl-reload-staging-XXXXXX
  install-units $store_tree $staging {id: $id, host: $host, path: $project_path}
  let staging_unit_dir = unit-dir $staging
  let new_manifest = compute-manifest $staging_unit_dir $id

  let plan = diff-manifest $old_manifest $new_manifest

  let real_unit_dir = unit-dir $runtime_dir
  mkdir $real_unit_dir

  # Copy added/changed units (and their drop-ins) from staging into the live dir.
  for r in ($plan | where { |r| $r.action in ["added" "changed"] }) {
    let src = $staging_unit_dir | path join $r.unit
    let dst = $real_unit_dir | path join $r.unit
    ^cp -f $src $dst
    let src_d = $staging_unit_dir | path join $"($r.unit).d"
    let dst_d = $real_unit_dir | path join $"($r.unit).d"
    mkdir $dst_d
    ^cp -rf $"($src_d)/." $dst_d
  }

  for r in ($plan | where action == "removed") {
    rm -f ($real_unit_dir | path join $r.unit)
    rm -rf ($real_unit_dir | path join $"($r.unit).d")
  }

  run-systemctl daemon-reload --quiet=$quiet

  # Skip the slice for service-level actions — restarting a slice would bounce
  # every service, defeating the whole point of reload.
  let service_actions = $plan | where { |r| not ($r.unit | str ends-with ".slice") }

  for r in ($service_actions | where action == "added") {
    run-systemctl start $r.unit --quiet=$quiet
  }
  for r in ($service_actions | where action == "changed") {
    run-systemctl restart $r.unit --quiet=$quiet
  }
  for r in ($service_actions | where action == "removed") {
    try {
      run-systemctl stop $r.unit --quiet=$quiet
    } catch { |e|
      if not $quiet {
        print $"(ansi yellow)warning(ansi reset): stop ($r.unit) failed: ($e.msg)"
      }
    }
  }

  registry-write $runtime_dir $id {
    path: $reg.path
    host: $host
    manifest: $new_manifest
    started_at: $reg.started_at
  }

  rm -rf $staging

  print (summary $plan)
}
