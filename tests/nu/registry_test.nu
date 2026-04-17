#!/usr/bin/env nu

use std assert
use ../../pctl/lib/registry.nu *

let tmpbase = mktemp -d -t pctl-registry-test-XXXXXX

# ---- registry-path ----
let p = registry-path $tmpbase "foo-deadbeef"
assert equal $p ($tmpbase | path join "pctl" "projects" "foo-deadbeef")

# ---- registry-read on missing → error ----
let missing = try { registry-read $tmpbase "nope-xxxxxxxx"; null } catch {|e| $e.msg }
assert ($missing != null)

# ---- registry-write + registry-read roundtrip ----
let rec = {
  path: "/tmp/my-project"
  host: "127.0.0.42"
  manifest: {"pctl-foo-deadbeef.slice": "h1", "pctl-foo-deadbeef-web.service": "h2"}
  started_at: "2026-04-17T10:00:00+00:00"
}
registry-write $tmpbase "foo-deadbeef" $rec

# fields land as individual files
let regDir = registry-path $tmpbase "foo-deadbeef"
assert (($regDir | path join "path") | path exists)
assert (($regDir | path join "host") | path exists)
assert (($regDir | path join "manifest.nuon") | path exists)
assert (($regDir | path join "started_at") | path exists)

# path file contains the absolute path (no trailing newline)
let pathFile = open --raw ($regDir | path join "path") | str trim
assert equal $pathFile "/tmp/my-project"

let hostFile = open --raw ($regDir | path join "host") | str trim
assert equal $hostFile "127.0.0.42"

let round = registry-read $tmpbase "foo-deadbeef"
assert equal $round.path "/tmp/my-project"
assert equal $round.host "127.0.0.42"
assert equal $round.started_at "2026-04-17T10:00:00+00:00"
assert equal ($round.manifest | get "pctl-foo-deadbeef.slice") "h1"
assert equal ($round.manifest | get "pctl-foo-deadbeef-web.service") "h2"

# ---- registry-list ----
let rec2 = {
  path: "/tmp/other"
  host: "127.0.0.7"
  manifest: {}
  started_at: "2026-04-17T11:00:00+00:00"
}
registry-write $tmpbase "aaa-11111111" $rec2

let listed = registry-list $tmpbase
assert equal ($listed | length) 2
# sorted by id
assert equal ($listed | get id) ["aaa-11111111" "foo-deadbeef"]
let first_row = $listed | first
assert equal $first_row.path "/tmp/other"
assert equal $first_row.host "127.0.0.7"
assert equal $first_row.started_at "2026-04-17T11:00:00+00:00"

# ---- taken-hosts ----
let taken = taken-hosts $tmpbase
assert equal ($taken | sort) ["127.0.0.42" "127.0.0.7"]

# ---- registry-remove ----
registry-remove $tmpbase "foo-deadbeef"
assert (not ((registry-path $tmpbase "foo-deadbeef") | path exists))
# idempotent
registry-remove $tmpbase "foo-deadbeef"

let after = registry-list $tmpbase
assert equal ($after | length) 1
assert equal ($after | first | get id) "aaa-11111111"

# empty registry dir handled
rm -rf ($tmpbase | path join "pctl")
let empty = registry-list $tmpbase
assert equal $empty []
let empty_taken = taken-hosts $tmpbase
assert equal $empty_taken []

# cleanup
rm -rf $tmpbase
