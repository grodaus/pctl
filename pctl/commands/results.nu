use ../lib/context.nu *
use ../lib/identity.nu *
use ../lib/probe.nu *
use ../lib/registry.nu *

# pctl results — block until every service in the project reaches a terminal
# state, then report one row per service.
#
# Unlike `pctl up --wait`, this command does not throw on the first failure:
# it waits for every service (up to --timeout, shared across all services),
# collects an outcome per service, and prints a summary. Use it after starting
# N parallel oneshot services to collect all N outcomes in one call.
#
# Default output: plain text, one row per service: STATE  ELAPSED  NAME.
# Exit code 0 iff every service ended in state 'active'.
# --json: emit the raw record list as JSON on stdout.
export def main [
  --timeout: int = 600   # overall timeout in seconds
  --json                 # emit JSON list of records
  --path: string         # override project path (default: cwd)
  --quiet
] {
  let runtime_dir = require-runtime-dir
  let project_path = resolve-project-path $path
  let id = (derive-id $project_path).id

  if not ((registry-path $runtime_dir $id) | path exists) {
    error make { msg: $"pctl: project ($id) is not registered — run `pctl up` first" }
  }

  let reg = registry-read $runtime_dir $id
  let host = $reg.host

  # Service names: derived from manifest entries, mirroring up.nu:87-90.
  let service_names = $reg.manifest
    | columns
    | where { |n| $n | str ends-with ".service" }
    | each { |n| $n | str replace -r $"^pctl-($id)-" "" | str replace -r '\.service$' "" }
    | sort

  # Option (a): re-read probes.json from the store tree recorded on `up`.
  # Legacy registry entries (pre-store_tree) store "" — fall back to no probes,
  # equivalent to option (b): every service waits via systemctl is-active, which
  # is usually fine because the probe only gates activeness anyway.
  let probes = if ($reg.store_tree | is-empty) {
    {}
  } else if ($reg.store_tree | path exists) {
    load-probes $reg.store_tree
  } else {
    # store_tree was recorded but the path is gone (tmpdir cleanup, nix gc).
    # Degrade gracefully instead of exploding — the wait still works via
    # unit-state, we just can't run the declared probes.
    if not $quiet {
      print $"(ansi yellow)warning(ansi reset): store_tree ($reg.store_tree) missing; falling back to unit-state polling"
    }
    {}
  }

  let env_vars = { PCTL_HOST: $host, PCTL_ID: $id }
  let results = wait-all $id $probes $service_names $env_vars ($timeout * 1sec)

  if $json {
    print ($results | to json)
  } else {
    for r in $results {
      # Fixed-column plain text for grep-friendly output.
      let state_col = $r.state | fill -a l -w 12
      let elapsed_col = ($r.elapsed | into string) | fill -a l -w 10
      print $"($state_col)  ($elapsed_col)  ($r.name)"
    }
  }

  let failures = $results | where state != "active"
  if ($failures | is-not-empty) {
    exit 1
  }
}
