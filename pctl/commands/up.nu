use ../lib/build.nu *
use ../lib/context.nu *
use ../lib/identity.nu *
use ../lib/install.nu *
use ../lib/probe.nu *
use ../lib/registry.nu *
use ../lib/sysctl.nu *
use ../lib/units.nu *

# pctl up — install units, start the project slice.
#
# Either --tree (pre-built fake store tree, skips `nix build`) or --nix
# (flake attribute to build, default `.#pctl`) provides the rendered unit tree.
#
# --wait blocks until every service is ready: a declared readinessProbe exits 0,
# or (for services without a probe) the unit reaches systemd "active". --timeout
# bounds the whole wait.
export def main [
  --tree: string
  --nix: string = ".#pctl"
  --path: string
  --wait
  --timeout: int = 30
  --quiet
] {
  let runtime_dir = require-runtime-dir
  let project_path = resolve-project-path $path
  let id = (derive-id $project_path).id

  let store_tree = resolve-store-tree $nix $tree --quiet=$quiet

  # Re-up: reuse the host and started_at already in the registry. Otherwise
  # taken-hosts would include the project's own host, forcing allocate-host to
  # pick a new slot — and systemctl start on already-active services is a
  # no-op, so the running env would keep the old PCTL_HOST while disk/registry
  # moved to the new one.
  let existing = if ((registry-path $runtime_dir $id) | path exists) {
    registry-read $runtime_dir $id
  } else {
    null
  }

  let host = if $existing == null {
    allocate-host $id (taken-hosts $runtime_dir)
  } else {
    $existing.host
  }

  let target = unit-dir $runtime_dir
  mkdir $target
  install-units $store_tree $runtime_dir $id $host

  let manifest = compute-manifest $target $id

  let started_at = if $existing == null {
    date now | format date "%Y-%m-%dT%H:%M:%S%:z"
  } else {
    $existing.started_at
  }
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

  if $wait {
    let service_names = $manifest
      | columns
      | where { |n| $n | str ends-with ".service" }
      | each { |n| $n | str replace -r $"^pctl-($id)-" "" | str replace -r '\.service$' "" }
      | sort
    let probes = load-probes $store_tree
    let env_vars = { PCTL_HOST: $host, PCTL_ID: $id }
    wait-ready $id $probes $service_names $env_vars ($timeout * 1sec)
  }
}
