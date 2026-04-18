#!/usr/bin/env nu
#
# Unit tests for the persistent known-projects marker. `pctl up` writes one;
# `pctl down` never touches it. `pctl gc` reads them to decide which state
# directories are orphaned vs. just belong to a project that isn't `up` right
# now.

use std assert
use ../../pctl/lib/known.nu *

let tmp = mktemp -d -t pctl-known-test-XXXXXX

# ---- cycle 9: known-write creates marker ----

let project = $tmp | path join "project"
mkdir $project
known-write $tmp "foo_12345678" $project

let marker = $tmp | path join "pctl" "known" "foo_12345678"
assert ($marker | path exists)
assert equal (open --raw $marker | str trim) $project

# known-write is idempotent: overwriting with the same path leaves the marker.
known-write $tmp "foo_12345678" $project
assert equal (open --raw $marker | str trim) $project

# ---- cycle 10: known-list returns every marker ----

known-write $tmp "bar_abcdef12" "/other/path"
let rows = known-list $tmp | sort-by id
assert equal ($rows | length) 2
assert equal ($rows | get id) ["bar_abcdef12" "foo_12345678"]
assert equal ($rows | where id == "foo_12345678" | first | get path) $project

# known-list on a missing tree returns [].
assert equal (known-list ($tmp | path join "nope")) []

rm -rf $tmp
print "known_test ok"
