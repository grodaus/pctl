#!/usr/bin/env nu

use std assert
use ../../pctl/lib/install.nu *

# ---- helpers ----

def setup-store [dir: string] {
  mkdir $dir
  "[Unit]\nDescription=pctl project @@PROJECT@@\n\n[Slice]\n"
    | save -f ($dir | path join "pctl-@@PROJECT@@.slice")
  "[Unit]\nDescription=pctl service web\n\n[Service]\nExecStart=/bin/w\nSlice=pctl-@@PROJECT@@.slice\nWorkingDirectory=@@PROJECT_PATH@@\n"
    | save -f ($dir | path join "pctl-@@PROJECT@@-web.service")
}

let tmpbase = mktemp -d -t pctl-install-test-XXXXXX
let store = $tmpbase | path join "store"
let runtime = $tmpbase | path join "runtime"
setup-store $store

# ---- RED1/GREEN1: filename substitution ----
let project_path = "/home/somebody/projects/foo"
let result = install-units $store $runtime {id: "foo-deadbeef", host: "127.0.0.42", path: $project_path}
let unitDir = $runtime | path join "systemd/user.control"
let installed_names = ls $unitDir | get name | each { path basename } | sort
assert ("pctl-foo-deadbeef.slice" in $installed_names)
assert ("pctl-foo-deadbeef-web.service" in $installed_names)
# filenames must NOT contain the placeholder
assert (not ($installed_names | any { |n| $n =~ '@@PROJECT@@' }))

# ---- RED2/GREEN2: in-file content substitution ----
let sliceContent = open --raw ($unitDir | path join "pctl-foo-deadbeef.slice")
assert (not ($sliceContent | str contains "@@PROJECT@@"))
assert ($sliceContent | str contains "pctl project foo-deadbeef")
let webContent = open --raw ($unitDir | path join "pctl-foo-deadbeef-web.service")
assert (not ($webContent | str contains "@@PROJECT@@"))
assert (not ($webContent | str contains "@@PROJECT_PATH@@"))
assert ($webContent | str contains "Slice=pctl-foo-deadbeef.slice")
assert ($webContent | str contains $"WorkingDirectory=($project_path)")

# ---- RED3/GREEN3: drop-ins present with PCTL_HOST (service) + PCTL_ID (both) ----
let webDropin = $unitDir | path join "pctl-foo-deadbeef-web.service.d/pctl-runtime.conf"
assert ($webDropin | path exists)
let webDropinContent = open --raw $webDropin
assert ($webDropinContent | str contains "[Service]")
assert ($webDropinContent | str contains "Environment=PCTL_HOST=127.0.0.42")
assert ($webDropinContent | str contains "Environment=PCTL_ID=foo-deadbeef")

let sliceDropin = $unitDir | path join "pctl-foo-deadbeef.slice.d/pctl-runtime.conf"
assert ($sliceDropin | path exists)
let sliceDropinContent = open --raw $sliceDropin
# slice drop-in carries PCTL_ID only, no host
assert ($sliceDropinContent | str contains "PCTL_ID=foo-deadbeef")
assert (not ($sliceDropinContent | str contains "PCTL_HOST"))

# returned record shape: installed + dropins, sorted
assert ("installed" in ($result | columns))
assert ("dropins" in ($result | columns))
assert equal $result.installed ($result.installed | sort)
assert equal $result.dropins ($result.dropins | sort)
assert equal ($result.installed | length) 2
assert equal ($result.dropins | length) 2

# ---- RED4/GREEN4: idempotency — second run leaves same content, no error ----
let before = ls $unitDir | get name | each { path basename } | sort
install-units $store $runtime {id: "foo-deadbeef", host: "127.0.0.42", path: $project_path}
let after = ls $unitDir | get name | each { path basename } | sort
assert equal $before $after
# content still correct after second run
let webContent2 = open --raw ($unitDir | path join "pctl-foo-deadbeef-web.service")
assert equal $webContent $webContent2

# ---- RED5/GREEN5: uninstall leaves decoys alone ----
let decoy = $unitDir | path join "other-project-web.service"
"decoy\n" | save -f $decoy
assert ($decoy | path exists)

let removed = uninstall-units $runtime "foo-deadbeef"
# all removed paths sorted
assert equal $removed ($removed | sort)
# decoy survives
assert ($decoy | path exists)
# project files gone
assert (not (($unitDir | path join "pctl-foo-deadbeef.slice") | path exists))
assert (not (($unitDir | path join "pctl-foo-deadbeef-web.service") | path exists))
# drop-in dirs gone
assert (not (($unitDir | path join "pctl-foo-deadbeef-web.service.d") | path exists))
assert (not (($unitDir | path join "pctl-foo-deadbeef.slice.d") | path exists))

# ---- RED6/GREEN6: non-unit side-cars (probes.json) are not installed ----
# mkProject emits probes.json alongside the slice/service files. install-units
# must ignore anything that isn't a .slice or .service so the side-car doesn't
# land in user.control/ as a bogus unit.
let store2 = $tmpbase | path join "store2"
let runtime2 = $tmpbase | path join "runtime2"
setup-store $store2
'{"web": {"exec": ["/bin/true"], "periodSeconds": 1, "timeoutSeconds": 30}}'
  | save -f ($store2 | path join "probes.json")

let result2 = install-units $store2 $runtime2 {id: "bar-cafebabe", host: "127.0.0.43", path: "/home/somebody/projects/bar"}
let unitDir2 = $runtime2 | path join "systemd/user.control"
let installed2 = ls $unitDir2 | get name | each { path basename } | sort
assert (not ("probes.json" in $installed2)) $"probes.json leaked into user.control: ($installed2)"
assert (not (($unitDir2 | path join "probes.json.d") | path exists)) "bogus drop-in dir created for probes.json"
# The two real units are still there.
assert ("pctl-bar-cafebabe.slice" in $installed2)
assert ("pctl-bar-cafebabe-web.service" in $installed2)
# The returned record should also be filtered.
let returned_bases = $result2.installed | each { path basename }
assert (not ("probes.json" in $returned_bases))

# cleanup
rm -rf $tmpbase
