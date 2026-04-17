# Shared helpers for pctl integration tests.
#
# Each test is run with a fresh $env.XDG_RUNTIME_DIR (provided by the wrapper).
# The helpers here build a fake store tree (skipping `nix build`) and a
# fake systemctl stub that logs argv to a file.

export def repo-root []: nothing -> string {
  # tests/integration/*_test.nu → two levels up is the repo root.
  (pwd) | path expand
}

export def pctl-script []: nothing -> string {
  repo-root | path join "pctl" "pctl.nu"
}

# Write a systemctl stub that logs argv (space-joined) to $logfile, one line
# per invocation, and exits with $code.
export def make-sysctl-stub [logfile: string, code: int = 0]: nothing -> string {
  let stub = mktemp -t pctl-sysctl-stub-XXXXXX
  $"#!/bin/sh\necho \"$@\" >> ($logfile)\nexit ($code)\n" | save -f $stub
  chmod +x $stub
  $stub
}

# Build a fake "store tree" on disk containing placeholder-bearing unit files.
# `services` is a record of { svc-name: contents-string }. A slice file is
# always emitted. Files live in `$dir` with @@PROJECT@@ placeholders intact.
export def make-fake-tree [dir: string, services: record] {
  mkdir $dir
  "[Unit]\nDescription=pctl project @@PROJECT@@\n\n[Slice]\n"
    | save -f ($dir | path join "pctl-@@PROJECT@@.slice")
  $services | transpose name body | each { |r|
    $r.body | save -f ($dir | path join $"pctl-@@PROJECT@@-($r.name).service")
  } | ignore
}

# Run `pctl <verb> ...args` in a clean scope. Returns `complete`-shape.
# Requires $env.XDG_RUNTIME_DIR and $env.PCTL_SYSTEMCTL already set.
export def run-pctl [...args: string]: nothing -> record {
  let script = pctl-script
  ^nu $script ...$args | complete
}

# Read the sysctl log and return a list of lines (trimmed, empty removed).
export def read-log [logfile: string]: nothing -> list<string> {
  if not ($logfile | path exists) {
    return []
  }
  open --raw $logfile | lines | where { |l| ($l | str trim) != "" }
}
