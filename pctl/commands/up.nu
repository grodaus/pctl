use ../lib/build.nu *
use ../lib/context.nu *
use ../lib/identity.nu *
use ../lib/install.nu *
use ../lib/registry.nu *
use ../lib/sysctl.nu *
use ../lib/units.nu *

# pctl up — install units, start the project slice.
#
# Either --tree (pre-built fake store tree, skips `nix build`) or --nix
# (flake attribute to build, default `.#pctl`) provides the rendered unit tree.
export def main [
  --tree: string
  --nix: string = ".#pctl"
  --path: string
  --quiet
] {
  let runtime_dir = require-runtime-dir
  let project_path = resolve-project-path $path
  let id = (derive-id $project_path).id

  let store_tree = resolve-store-tree $nix $tree --quiet=$quiet

  let host = allocate-host $id (taken-hosts $runtime_dir)

  let target = unit-dir $runtime_dir
  mkdir $target
  install-units $store_tree $runtime_dir $id $host

  let manifest = compute-manifest $target $id

  let started_at = date now | format date "%Y-%m-%dT%H:%M:%S%:z"
  registry-write $runtime_dir $id {
    path: $project_path
    host: $host
    manifest: $manifest
    started_at: $started_at
  }

  run-systemctl daemon-reload --quiet=$quiet
  run-systemctl start (slice-unit $id) --quiet=$quiet

  # Starting a slice only activates the cgroup; child services don't auto-start.
  # Kick each .service explicitly — systemd honours the Requires=/After= graph.
  let services = $manifest | columns | where { |n| $n | str ends-with ".service" } | sort
  for svc in $services {
    run-systemctl start $svc --quiet=$quiet
  }

  let unit_count = $manifest | columns | length
  print $"project ($id) up · ($unit_count) units · host=($host)"
}
