#!/usr/bin/env nu

use std assert
use ../../pctl/lib/manifest.nu *

# unchanged: same unit → same hash
let d1 = diff-manifest {a: "h1"} {a: "h1"}
assert equal ($d1 | length) 1
assert equal ($d1 | first | get unit) "a"
assert equal ($d1 | first | get action) "unchanged"

# changed
let d2 = diff-manifest {a: "h1"} {a: "h2"}
assert equal ($d2 | first | get action) "changed"
assert equal ($d2 | first | get old_hash) "h1"
assert equal ($d2 | first | get new_hash) "h2"

# added
let d3 = diff-manifest {} {a: "h1"}
assert equal ($d3 | first | get action) "added"
assert equal ($d3 | first | get new_hash) "h1"

# removed
let d4 = diff-manifest {a: "h1"} {}
assert equal ($d4 | first | get action) "removed"
assert equal ($d4 | first | get old_hash) "h1"

# mixed + sorted order
let d5 = diff-manifest {a: "1", b: "2", c: "3"} {b: "2", c: "9", d: "4"}
assert equal ($d5 | get unit) ["a" "b" "c" "d"]
assert equal ($d5 | get action) ["removed" "unchanged" "changed" "added"]

# summary formats: "+N ~N =N -N"
assert equal (summary $d5) "+1 ~1 =1 -1"
