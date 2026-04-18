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
        # Distinguish terminal-failure (e.g. oneshot exited non-zero) from
        # genuine timeout: re-read the state so the message names it.
        let final_state = unit-state $unit
        if $final_state in ["failed" "inactive"] {
          error make { msg: $"pctl up --wait: service ($svc) terminated in state '($final_state)' \(expected 'active'\)" }
        } else {
          error make { msg: $"pctl up --wait: service ($svc) did not become active within ($overall_timeout) \(last state: '($final_state)'\)" }
        }
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

# Block until every service named in $service_names reaches a terminal state,
# or $overall_timeout elapses. Unlike wait-ready, never throws on per-service
# failure: the caller aggregates. One record per service is returned, in the
# same order as $service_names.
#
# Record shape: { name, state, elapsed, kind }
#   state: "active" | "failed" | "inactive" | "probe-failed" | "timed-out"
#   kind:  "probe" if a readinessProbe was declared for the service,
#          "unit-state" otherwise (fell through to systemctl is-active polling)
#
# The deadline is shared across all services (same shape as wait-ready). A
# service whose remaining budget is zero when its turn comes gets state
# "timed-out" without consulting systemctl / running the probe.
export def wait-all [
  id: string
  probes: record
  service_names: list<string>
  env_vars: record
  overall_timeout: duration
]: nothing -> list<record> {
  let deadline = (date now) + $overall_timeout
  $service_names | each { |svc|
    let t0 = date now
    let remaining = $deadline - $t0
    if $remaining <= 0sec {
      { name: $svc, state: "timed-out", elapsed: 0sec, kind: "unit-state" }
    } else {
      let probe = $probes | get -o $svc
      if ($probe | is-empty) {
        let unit = $"pctl-($id)-($svc).service"
        let ok = wait-active-unit $unit $remaining
        let elapsed = (date now) - $t0
        if $ok {
          { name: $svc, state: "active", elapsed: $elapsed, kind: "unit-state" }
        } else {
          # wait-active-unit returns false either on terminal failure
          # (failed/inactive) or timeout. Re-read the state to disambiguate.
          let final_state = unit-state $unit
          let state = if $final_state in ["failed" "inactive"] {
            $final_state
          } else {
            "timed-out"
          }
          { name: $svc, state: $state, elapsed: $elapsed, kind: "unit-state" }
        }
      } else {
        let period = (($probe | get -o periodSeconds | default 1) * 1sec)
        let probe_timeout = (($probe | get -o timeoutSeconds | default 30) * 1sec)
        let effective = if $probe_timeout < $remaining { $probe_timeout } else { $remaining }
        let ok = wait-probe $probe.exec $env_vars $period $effective
        let elapsed = (date now) - $t0
        if $ok {
          { name: $svc, state: "active", elapsed: $elapsed, kind: "probe" }
        } else {
          # Distinguish probe timeout from broader overall timeout.
          let state = if $effective < $remaining { "probe-failed" } else { "timed-out" }
          { name: $svc, state: $state, elapsed: $elapsed, kind: "probe" }
        }
      }
    }
  }
}

# Read the current is-active state of $unit as a string ("active",
# "activating", "inactive", "failed", ...). `systemctl is-active` exits
# non-zero for any non-active state but still prints the state to stdout; we
# use `complete` (wrapped in `do -i` to bypass pipefail) so we can read stdout
# regardless of exit code. If the call itself explodes the state is reported
# as "unknown" so callers never crash on a probe read.
def unit-state [unit: string]: nothing -> string {
  let bin = $env.PCTL_SYSTEMCTL? | default "systemctl"
  let r = do -i { ^$bin --user is-active $unit | complete }
  let state = $r.stdout | str trim
  if ($state | is-empty) { "unknown" } else { $state }
}

# Poll unit-state until the unit is active, reaches a terminal failure state,
# or the timeout elapses. Lives here (not sysctl.nu) to keep the probe module
# self-contained.
#
# Terminal states:
#   - "active"            → success (return true)
#   - "failed"            → oneshot exited non-zero, simple crashed, etc.
#   - "inactive"          → oneshot without RemainAfterExit that finished, or
#                           a unit that was never started. pctl's services set
#                           RemainAfterExit=yes so "inactive" here means the
#                           unit never activated — treat as terminal failure.
# Transient states (keep polling): "activating", "reloading", "deactivating".
def wait-active-unit [unit: string, timeout: duration] {
  let deadline = (date now) + $timeout
  loop {
    let state = unit-state $unit
    if $state == "active" { return true }
    if $state in ["failed" "inactive"] { return false }
    if (date now) >= $deadline { return false }
    sleep 100ms
  }
}
