#!/usr/bin/env nu
# Discover and run every *_test.nu under tests/e2e against the host systemd --user.
# Each test is a standalone script; we invoke them sequentially for readable logs.

use harness.nu cleanup-stragglers

if ($env.XDG_RUNTIME_DIR? | is-empty) {
  error make { msg: "XDG_RUNTIME_DIR must be set — run on a host with systemd --user" }
}

cleanup-stragglers

const here = path self | path dirname
let tests = ls $here
  | where name =~ '_test\.nu$'
  | get name
  | sort

mut failed = []
mut passed = []

for t in $tests {
  let name = $t | path basename
  print $"::: ($name)"
  let start = date now
  let r = ^nu $t | complete
  let dur = (date now) - $start
  print $r.stdout
  if $r.exit_code != 0 {
    print $"(ansi red)FAIL(ansi reset) ($name) in ($dur)"
    if ($r.stderr | is-not-empty) { print $r.stderr }
    $failed = $failed ++ [$name]
  } else {
    print $"(ansi green)PASS(ansi reset) ($name) in ($dur)"
    $passed = $passed ++ [$name]
  }
}

print ""
print $"passed: ($passed | length) / ($tests | length)"
if ($failed | is-not-empty) {
  print $"failed: ($failed | str join ', ')"
  exit 1
}
