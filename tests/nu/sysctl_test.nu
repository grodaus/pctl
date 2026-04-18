#!/usr/bin/env nu

use std assert
use ../../pctl/lib/sysctl.nu *

# Stub factory: write a shell script that logs argv to $logfile and exits with $code.
# Uses #!/bin/sh (guaranteed in nix build sandbox) rather than #!/usr/bin/env sh.
def make-stub [logfile: string, code: int]: nothing -> string {
  let stub = mktemp -t pctl-stub-XXXXXX
  $"#!/bin/sh\necho \"$@\" > ($logfile)\nexit ($code)\n" | save -f $stub
  chmod +x $stub
  $stub
}

# Stub that prints fixed lines to stdout (one per is-active result), in
# addition to logging argv. Used to test systemctl-active.
def make-active-stub [logfile: string, payload: string, code: int]: nothing -> string {
  let stub = mktemp -t pctl-stub-XXXXXX
  $"#!/bin/sh\necho \"$@\" > ($logfile)\ncat <<'EOF'\n($payload)\nEOF\nexit ($code)\n" | save -f $stub
  chmod +x $stub
  $stub
}

# RED1: stub is called with exactly the forwarded args.
let logfile = mktemp -t pctl-stub-log-XXXXXX
let stub = make-stub $logfile 0
$env.PCTL_SYSTEMCTL = $stub

run-systemctl status foo

let recorded = open $logfile | str trim
assert equal $recorded "--user status foo"

# Streaming wrapper doesn't wrap output in a complete-shaped record.
# In a `let` context nushell still captures the external's stdout as a plain
# string — which is what agents piping `pctl status` will see, instead of the
# old ugly boxed table with stdout/stderr/exit_code cells.
let r = run-systemctl status foo
assert equal ($r | describe) "string"

# Banner goes to STDERR now (keeps stdout clean for agents piping output).
# Capture via a nested nu invocation on an absolute module path.
let module_path = (pwd | path join "pctl/lib/sysctl.nu")
let script = $"$env.PCTL_SYSTEMCTL = '($stub)'; use ($module_path) *; run-systemctl status foo"
let banner_capture = ^nu -c $script | complete
assert ($banner_capture.stderr | str contains $"$ ($stub) --user status foo")
assert not ($banner_capture.stdout | str contains "$ ")

# --quiet suppresses the banner but still calls the stub.
"" | save -f $logfile
let quiet_script = $"$env.PCTL_SYSTEMCTL = '($stub)'; use ($module_path) *; run-systemctl status foo --quiet"
let quiet_capture = ^nu -c $quiet_script | complete
assert not ($quiet_capture.stderr | str contains "$ ")
assert not ($quiet_capture.stdout | str contains "$ ")
let quiet_recorded = open $logfile | str trim
assert equal $quiet_recorded "--user status foo"

# Non-zero exit raises an error that includes the exit code.
let fail_log = mktemp -t pctl-fail-log-XXXXXX
let fail_stub = make-stub $fail_log 17
$env.PCTL_SYSTEMCTL = $fail_stub
let err = try {
  run-systemctl status foo --quiet
  null
} catch {|e| $e.msg }
assert ($err != null)
assert ($err | str contains "17")

# systemctl-active: empty input → empty output, no subprocess.
assert equal (systemctl-active) []

# systemctl-active: parses one bool per stdout line, in input order.
let active_log = mktemp -t pctl-active-log-XXXXXX
let active_stub = make-active-stub $active_log "active\ninactive\nactive" 0
$env.PCTL_SYSTEMCTL = $active_stub
let states = systemctl-active u1 u2 u3
assert equal $states [true, false, true]
let active_recorded = open $active_log | str trim
assert equal $active_recorded "--user is-active u1 u2 u3"

# systemctl-active: non-zero exit (any unit inactive) still yields parsed
# states — the multi-unit form prints per-unit lines regardless of exit code.
let mixed_log = mktemp -t pctl-mixed-log-XXXXXX
let mixed_stub = make-active-stub $mixed_log "inactive\ninactive" 4
$env.PCTL_SYSTEMCTL = $mixed_stub
let mixed = systemctl-active a b
assert equal $mixed [false, false]

# start-async: issues a single `start --no-block <units...>` call with every
# unit in one subprocess, regardless of list length.
let async_log = mktemp -t pctl-async-log-XXXXXX
let async_stub = make-stub $async_log 0
$env.PCTL_SYSTEMCTL = $async_stub
start-async [foo.service bar.service baz.service] --quiet
let async_recorded = open $async_log | str trim
assert equal $async_recorded "--user start --no-block foo.service bar.service baz.service"

# start-async: empty list → no subprocess spawned (log stays empty).
"" | save -f $async_log
start-async [] --quiet
let empty_recorded = open $async_log | str trim
assert equal $empty_recorded ""
