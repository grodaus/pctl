#!/usr/bin/env nu

use std assert
use ../../pctl/lib/identity.nu *

# determinism: same path → same id across invocations
let a = derive-id "/tmp/my-project"
let b = derive-id "/tmp/my-project"
assert equal $a $b

# different paths → different ids
let c = derive-id "/tmp/other-project"
assert ($a.id != $c.id)
assert equal ($a.hash8 | str length) 8

# basename sanitization: weird chars → legal ids with '_' only
let d = derive-id "/tmp/my project!"
assert equal $d.basename "my_project"
assert ($d.id | str starts-with "my_project_")

let e = derive-id "/tmp/UPPER"
assert equal $e.basename "upper"

let f = derive-id "/tmp/___foo___"
assert equal $f.basename "foo"

# unnamed/all-illegal chars → "project"
let g = derive-id "/tmp/!!!"
assert equal $g.basename "project"

# Bug-4 regression: id must contain no '-' so `pctl-<id>.slice` stays
# single-level under pctl.slice (systemd splits slice names on '-').
let h = derive-id "/tmp/my-cool-repo"
assert equal $h.basename "my_cool_repo"
assert not ($h.id | str contains "-")

# allocate-host deterministic: same id → same IP
let ip1 = allocate-host "some-id-abc12345"
let ip2 = allocate-host "some-id-abc12345"
assert equal $ip1 $ip2
assert ($ip1 | str starts-with "127.0.0.")
let n1 = $ip1 | str replace "127.0.0." "" | into int
assert ($n1 >= 2 and $n1 <= 254)

# collision: if natural IP is taken, bump to next slot
let ip3 = allocate-host "some-id-abc12345" [$ip1]
assert ($ip3 != $ip1)
let n3 = $ip3 | str replace "127.0.0." "" | into int
let expected_next = if $n1 < 254 { $n1 + 1 } else { 2 }
assert equal $n3 $expected_next

# full occupancy (all 253 slots taken) → error
let full_taken = 2..254 | each { |n| $"127.0.0.($n)" }
assert error {|| allocate-host "some-id-abc12345" $full_taken }
