# Readiness-probe runner.
#
# Probes are declared in the spec (readinessProbe.exec) and emitted by
# mkProject into probes.json alongside the rendered unit files. `pctl up --wait`
# reads probes.json, then polls each probe's exec until it exits 0 or the
# per-probe timeout fires.

# Run the probe's exec once with PCTL_HOST / PCTL_ID in the environment.
# Returns true iff the command exited 0.
export def probe-once [exec: list<string>, env_vars: record]: nothing -> bool {
  if ($exec | is-empty) {
    error make { msg: "probe-once: exec must not be empty" }
  }
  try {
    with-env $env_vars {
      ^($exec | first) ...($exec | skip 1) o+e> /dev/null
    }
    true
  } catch {
    false
  }
}

# Poll probe-once every $period until success, or until $timeout elapses.
# Returns true on success, false on timeout.
export def wait-probe [
  exec: list<string>
  env_vars: record
  period: duration = 1sec
  timeout: duration = 30sec
] {
  let deadline = (date now) + $timeout
  loop {
    if (probe-once $exec $env_vars) { return true }
    if (date now) >= $deadline { return false }
    sleep $period
  }
}

# Load the side-car probes.json from a store tree. Absent → empty record.
export def load-probes [store_tree: string]: nothing -> record {
  let p = $store_tree | path join "probes.json"
  if ($p | path exists) { open $p } else { {} }
}

# Block until every service named in $probes is ready (probe exits 0), falling
# back to systemctl is-active for services without a declared probe.
#
# $probes: record of { svc_name: { exec, periodSeconds?, timeoutSeconds? } }
# $service_names: list of bare service names (no pctl- prefix, no .service)
# $env_vars: record merged into child env (typically {PCTL_HOST, PCTL_ID})
# $overall_timeout: outer ceiling shared across every service in the loop
#
# Throws on the first service that doesn't become ready in time. Message names
# the failing service so the user knows where to look.
export def wait-ready [
  id: string
  probes: record
  service_names: list<string>
  env_vars: record
  overall_timeout: duration
] {
  # Single deadline across every service — `--timeout` must bound the whole
  # wait, not each probe independently. Without this, N probed services would
  # take up to N × overall_timeout in the worst case.
  let deadline = (date now) + $overall_timeout
  for svc in $service_names {
    let remaining = $deadline - (date now)
    if $remaining <= 0sec {
      error make { msg: $"pctl up --wait: overall timeout ($overall_timeout) exceeded before checking ($svc)" }
    }
    let probe = $probes | get -o $svc
    if ($probe | is-empty) {
      let unit = $"pctl-($id)-($svc).service"
      if not (wait-active-unit $unit $remaining) {
        error make { msg: $"pctl up --wait: service ($svc) did not become active within ($overall_timeout)" }
      }
    } else {
      let period = (($probe | get -o periodSeconds | default 1) * 1sec)
      let probe_timeout = (($probe | get -o timeoutSeconds | default 30) * 1sec)
      let effective = if $probe_timeout < $remaining { $probe_timeout } else { $remaining }
      if not (wait-probe $probe.exec $env_vars $period $effective) {
        error make { msg: $"pctl up --wait: service ($svc) readinessProbe did not pass within ($effective)" }
      }
    }
  }
}

# Poll systemctl --user is-active until the unit is active or timeout elapses.
# Lives here (not sysctl.nu) to keep the probe module self-contained.
def wait-active-unit [unit: string, timeout: duration] {
  let deadline = (date now) + $timeout
  let bin = $env.PCTL_SYSTEMCTL? | default "systemctl"
  loop {
    # is-active exits non-zero when the unit isn't active; under pipefail the
    # pipeline errors, so treat a failed call as "not yet active" and keep polling.
    let state = try {
      ^$bin --user is-active $unit | str trim
    } catch {
      "inactive"
    }
    if $state == "active" { return true }
    if (date now) >= $deadline { return false }
    sleep 100ms
  }
}
