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

# RED1: stub is called with exactly the forwarded args
let logfile = mktemp -t pctl-stub-log-XXXXXX
let stub = make-stub $logfile 0
$env.PCTL_SYSTEMCTL = $stub

run-systemctl status foo

let recorded = open $logfile | str trim
assert equal $recorded "--user status foo"

# return record shape
let r = run-systemctl status foo
assert ("stdout" in ($r | columns))
assert ("stderr" in ($r | columns))
assert ("exit_code" in ($r | columns))
assert equal $r.exit_code 0

# Banner printed: capture stdout via nested nu invocation on an absolute module path.
let module_path = (pwd | path join "pctl/lib/sysctl.nu")
let script = $"$env.PCTL_SYSTEMCTL = '($stub)'; use ($module_path) *; run-systemctl status foo"
let banner_capture = ^nu -c $script | complete
assert ($banner_capture.stdout | str contains $"$ ($stub) --user status foo")

# --quiet suppresses the banner but still calls the stub.
"" | save -f $logfile
let quiet_script = $"$env.PCTL_SYSTEMCTL = '($stub)'; use ($module_path) *; run-systemctl status foo --quiet"
let quiet_capture = ^nu -c $quiet_script | complete
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
