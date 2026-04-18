use ../lib/build.nu *
use ../lib/context.nu *
use ../lib/gc.nu state-home
use ../lib/identity.nu *
use ../lib/install.nu *
use ../lib/known.nu known-write
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
#
# --no-block enqueues every service start in one `systemctl --user start
# --no-block` call and returns immediately, without waiting for any ExecStart
# to complete. A failing unit does NOT abort the batch. Use this when starting
# N parallel oneshot services and collect outcomes afterwards via `pctl
# results` (or combine with --wait to block on readiness once enqueued).
export def main [
  --tree: string
  --nix: string = ".#pctl"
  --path: string
  --wait
  --no-block
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
  install-units $store_tree $runtime_dir {id: $id, host: $host, path: $project_path}

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
    store_tree: $store_tree
  }

  # Persistent marker — survives `down` and reboot; `pctl gc` reads it to
  # decide which state dirs belong to a project that still exists on disk.
  known-write (state-home) $id $project_path

  run-systemctl daemon-reload --quiet=$quiet
  run-systemctl start (slice-unit $id) --quiet=$quiet

  # Starting a slice only activates the cgroup; child services don't auto-start.
  # Kick each .service explicitly — systemd honours the Requires=/After= graph.
  let services = $manifest | columns | where { |n| $n | str ends-with ".service" } | sort
  if $no_block {
    # Single async batch call: enqueue every service, return immediately. A
    # failing unit does not abort the batch — outcomes are observable via
    # `pctl results` (or --wait below).
    start-async $services --quiet=$quiet
  } else {
    for svc in $services {
      run-systemctl start $svc --quiet=$quiet
    }
  }

  let unit_count = $manifest | columns | length
  let suffix = if $no_block { " (async)" } else { "" }
  print $"project ($id) up · ($unit_count) units · host=($host)($suffix)"

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
