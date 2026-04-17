use ../lib/identity.nu *
use ../lib/install.nu *
use ../lib/registry.nu *
use ../lib/sysctl.nu *

# pctl up — install units, start the project slice.
#
# Either --tree (pre-built fake store tree, skips `nix build`) or --nix
# (flake attribute to build, default `.#pctl`) provides the rendered unit tree.
# --path overrides cwd for project-id derivation (needed by tests).
export def main [
  --tree: string                   # path to an already-built store tree; skips nix build
  --nix: string = ".#pctl"         # flake attribute to build
  --path: string                   # override project path (default: cwd)
  --quiet                          # suppress systemctl banner
] {
  let runtime_dir = $env.XDG_RUNTIME_DIR? | default ""
  if ($runtime_dir | is-empty) {
    error make { msg: "pctl up: XDG_RUNTIME_DIR is not set (pctl requires Linux + systemd --user)" }
  }

  let project_path = if ($path | is-empty) { pwd | path expand } else { $path | path expand }
  let ident = derive-id $project_path
  let id = $ident.id

  let store_tree = if ($tree | is-empty) {
    # Build via nix.
    if not $quiet {
      print $"$ nix build ($nix) --no-link --print-out-paths"
    }
    let built = ^nix build $nix --no-link --print-out-paths | complete
    if $built.exit_code != 0 {
      error make { msg: $"pctl up: nix build failed: ($built.stderr)" }
    }
    $built.stdout | str trim | lines | last
  } else {
    $tree | path expand
  }

  if not ($store_tree | path exists) {
    error make { msg: $"pctl up: store tree does not exist: ($store_tree)" }
  }

  let host = allocate-host $id (taken-hosts $runtime_dir)

  let unit_dir = $runtime_dir | path join "systemd" "user.control"
  mkdir $unit_dir

  install-units $store_tree $runtime_dir $id $host

  # Compute manifest from the installed files (exclude .d drop-in dirs).
  let manifest = ls $unit_dir
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

  let started_at = date now | format date "%Y-%m-%dT%H:%M:%S%:z"
  registry-write $runtime_dir $id {
    path: $project_path
    host: $host
    manifest: $manifest
    started_at: $started_at
  }

  run-systemctl daemon-reload --quiet=$quiet
  run-systemctl start $"pctl-($id).slice" --quiet=$quiet

  # Starting a slice only activates the cgroup; services inside it do not
  # auto-start. Kick off each .service explicitly. systemd honours the
  # Requires=/After= graph emitted by render.service for dep ordering.
  let services = $manifest | columns | where { |n| $n | str ends-with ".service" } | sort
  $services | each { |svc|
    run-systemctl start $svc --quiet=$quiet
  } | ignore

  let unit_count = $manifest | columns | length
  print $"project ($id) up · ($unit_count) units · host=($host)"
}
