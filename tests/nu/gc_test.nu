#!/usr/bin/env nu
#
# Unit tests for `pctl gc` classification and deletion.
#
# Each cycle adds one behavior; tests below are ordered by the cycle they
# came from. Everything runs in a disposable tmpdir with XDG_STATE_HOME and
# XDG_RUNTIME_DIR redirected so host state is never touched.

use std assert
use ../../pctl/lib/gc.nu *

let tmp = mktemp -d -t pctl-gc-test-XXXXXX

# ---- cycle 1: scan-state on missing/empty dirs ----

# Non-existent path returns [] (not an error).
assert equal (scan-state ($tmp | path join "nope")) []

# Empty dir returns [].
assert equal (scan-state $tmp) []

# ---- cycle 2: scan-state extracts id + service ----

let pg_dir = $tmp | path join "pctl-foo_12345678-pg"
mkdir $pg_dir
let rows = scan-state $tmp
assert equal ($rows | length) 1
let r = $rows | first
assert equal $r.id "foo_12345678"
assert equal $r.service "pg"
assert equal $r.path $pg_dir

# ---- cycle 3: scan-state ignores foreign dirs ----

mkdir ($tmp | path join "pctl-notours")             # no hash suffix
mkdir ($tmp | path join "pctl-bad_ZZZZZZZZ-pg")     # hash not hex
mkdir ($tmp | path join "random")                   # unrelated
let rows = scan-state $tmp
assert equal ($rows | length) 1
assert equal ($rows | first | get id) "foo_12345678"

# ---- cycle 3b: id with dashes in basename is impossible (sanitize-basename) ----
# ids can contain '_' and [a-z0-9]; service parse is greedy on the last '-'.
mkdir ($tmp | path join "pctl-my_app_deadbeef-pg_main")
let rows = scan-state $tmp | sort-by id
assert equal ($rows | length) 2
let svc_row = $rows | where id == "my_app_deadbeef" | first
assert equal $svc_row.service "pg_main"

# ---- cycle 4: classify → unknown when no marker ----

# Fresh setup so we start clean.
rm -rf $tmp
mkdir $tmp
mkdir ($tmp | path join "pctl-foo_12345678-pg")

let classified = classify $tmp
assert equal ($classified | length) 1
assert equal ($classified | first | get status) "unknown"

# ---- cycle 5: classify → live when marker + path both present ----

let kdir = $tmp | path join "pctl" "known"
mkdir $kdir
let project_dir = $tmp | path join "project"
mkdir $project_dir
$project_dir | save -f ($kdir | path join "foo_12345678")

let classified = classify $tmp
assert equal ($classified | first | get status) "live"
assert equal ($classified | first | get project_path) $project_dir

# ---- cycle 6: classify → orphan when marker exists but path gone ----

rm -rf $project_dir
let classified = classify $tmp
assert equal ($classified | first | get status) "orphan"

# ---- cycle 7: dir-size reports bytes, tolerates missing ----

mkdir $tmp
let sized = $tmp | path join "sized"
mkdir $sized
"hello world" | save -f ($sized | path join "f")
let s = dir-size $sized
assert ($s > 0)

# Missing path → 0, no error.
assert equal (dir-size ($tmp | path join "nope")) 0

# ---- cycle 8: slice-active reads systemctl ActiveState ----

# Note: real `systemctl --user show <slice> -p ActiveState --value` returns
# `active` for running slices and `inactive` for anything else (including
# never-loaded paths — systemd synthesizes the slice on query). LoadState
# is useless for "is this real" since it returns `loaded` for every
# well-formed slice path, hence checking ActiveState.
def make-show-stub [active_state: string]: nothing -> string {
  let stub = mktemp -t pctl-show-stub-XXXXXX
  $"#!/bin/sh\necho ($active_state)\nexit 0\n" | save -f $stub
  chmod +x $stub
  $stub
}

$env.PCTL_SYSTEMCTL = (make-show-stub "active")
assert (slice-active "anything")

$env.PCTL_SYSTEMCTL = (make-show-stub "inactive")
assert (not (slice-active "anything"))

hide-env PCTL_SYSTEMCTL

# ---- cycle 11: gc dry-run returns rows, does not delete ----

# Fresh scene with one orphan and one unknown.
rm -rf $tmp
mkdir $tmp
$env.XDG_STATE_HOME = $tmp

let orphan_dir = $tmp | path join "pctl-foo_12345678-pg"
let unknown_dir = $tmp | path join "pctl-bar_abcd1234-pg"
mkdir $orphan_dir
mkdir $unknown_dir

let kdir = $tmp | path join "pctl" "known"
mkdir $kdir
"/does/not/exist" | save -f ($kdir | path join "foo_12345678")

use ../../pctl/commands/gc.nu
let rows = gc --quiet | sort-by id
assert equal ($rows | length) 2
assert equal ($rows | where id == "foo_12345678" | first | get status) "orphan"
assert equal ($rows | where id == "bar_abcd1234" | first | get status) "unknown"
# Sizes reported (every row has a size column, even for empty dirs).
assert (($rows | first | get size) >= 0)
# Dry-run did not delete anything.
assert ($orphan_dir | path exists)
assert ($unknown_dir | path exists)

# ---- cycle 12: gc --yes deletes orphans, keeps live + unknown ----

# Add a live state dir alongside the orphan + unknown from cycle 11.
let live_dir = $tmp | path join "pctl-baz_abcdef01-pg"
mkdir $live_dir
let project_dir = $tmp | path join "real-project"
mkdir $project_dir
$project_dir | save -f ($kdir | path join "baz_abcdef01")

# Stub says "inactive" for every id → no guard blocks delete.
$env.PCTL_SYSTEMCTL = (make-show-stub "inactive")

let deleted = gc --yes --quiet | sort-by id

# Every row carries a deleted: bool column.
assert equal ($deleted | length) 3
let by_id = $deleted | reduce -f {} { |r, acc| $acc | insert $r.id $r }
assert equal ($by_id.foo_12345678.deleted) true          # orphan → deleted
assert equal ($by_id.bar_abcd1234.deleted) false         # unknown → kept
assert equal ($by_id.baz_abcdef01.deleted) false         # live → kept
# On disk, only the orphan is gone.
assert (not ($orphan_dir | path exists))
assert ($unknown_dir | path exists)
assert ($live_dir | path exists)
# Marker for the deleted orphan is also gone (otherwise subsequent runs
# see no state dir but a stale marker that never gets cleaned).
assert (not (($kdir | path join "foo_12345678") | path exists))
# Live and unknown markers/ids untouched.
assert (($kdir | path join "baz_abcdef01") | path exists)

# ---- cycle 13: gc --yes refuses orphan when its slice is active ----

mkdir $orphan_dir                                         # restore the orphan
"/does/not/exist" | save -f ($kdir | path join "foo_12345678")
$env.PCTL_SYSTEMCTL = (make-show-stub "active")
let blocked = gc --yes --quiet
let orphan_row = $blocked | where id == "foo_12345678" | first
assert equal $orphan_row.deleted false
assert equal $orphan_row.reason "slice active"
assert ($orphan_dir | path exists)                       # still there
assert (($kdir | path join "foo_12345678") | path exists) # marker kept too

hide-env PCTL_SYSTEMCTL
hide-env XDG_STATE_HOME

rm -rf $tmp
print "gc_test ok"
