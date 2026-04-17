#!/usr/bin/env nu

use std assert
use harness.nu *

let tmp = mktemp -d -t pctl-init-test-XXXXXX

# Run pctl init in an empty dir. cd first using a subshell invocation.
let script = pctl-script
cd $tmp
let r = ^nu $script init | complete
if $r.exit_code != 0 {
  print $"stdout: ($r.stdout)"
  print $"stderr: ($r.stderr)"
  error make { msg: $"pctl init exited non-zero: ($r.exit_code)" }
}

assert (($tmp | path join "flake.nix") | path exists)
assert (($tmp | path join ".gitignore") | path exists)

let flake = open --raw ($tmp | path join "flake.nix")
assert ($flake | str contains "pctl.url")
assert ($flake | str contains "mkProject")
# Must reference per-system lib: pctl.lib.${system}.mkProject, not pctl.lib.mkProject.
assert ($flake | str contains "pctl.lib.${system}.mkProject")

let gitignore = open --raw ($tmp | path join ".gitignore")
assert ($gitignore | str contains "result")

# Running again without --force fails
let r2 = ^nu $script init | complete
assert ($r2.exit_code != 0)
assert ($r2.stderr | str contains "already exists")

# With --force, overwrites
let r3 = ^nu $script init --force | complete
assert equal $r3.exit_code 0

cd /
rm -rf $tmp
