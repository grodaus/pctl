# Pure classification helpers for `pctl gc`.
#
# The public view is a table of rows { path, id, service, status, size }.
# - path: absolute path of the state directory
# - id: project id parsed from the directory name
# - service: service name parsed from the directory name
# - status: live | orphan | unknown (see classify)
# - size: byte size of the tree (see dir-size)
#
# A state directory `$XDG_STATE_HOME/pctl-<id>-<svc>` is ours iff <id> ends in
# `_<8 lowercase hex>` (identity.nu invariant) and the dash separator between
# id and service has no ambiguity — sanitize-basename collapses dashes to '_'
# inside ids, so `[^-]+_[0-9a-f]{8}` pins the split deterministically.

export def state-home []: nothing -> string {
  let explicit = $env.XDG_STATE_HOME? | default ""
  if ($explicit | is-empty) {
    ($env.HOME? | default "") | path join ".local" "state"
  } else {
    $explicit
  }
}

export def scan-state [state_home: string]: nothing -> table {
  if not ($state_home | path exists) { return [] }
  ls $state_home
    | where type == dir
    | get name
    | each { |d|
      let base = $d | path basename
      let m = $base | parse --regex '^pctl-(?P<id>[^-]+_[0-9a-f]{8})-(?P<svc>.+)$'
      if ($m | is-empty) { null } else {
        let row = $m | first
        { path: $d, id: $row.id, service: $row.svc }
      }
    }
    | compact
}

# Directory under state_home holding known/<id> → project path markers. Written
# by `pctl up`, persists across `down` and session reboots.
export def known-dir [state_home: string]: nothing -> string {
  $state_home | path join "pctl" "known"
}

# Classify every state dir found by scan-state against the known/ markers.
#
# status:
#   - live:    marker exists AND the recorded project path still exists
#   - orphan:  marker exists AND the recorded project path no longer exists
#   - unknown: no marker (pre-existing leak or state from a different tool);
#              `pctl gc` never deletes these — it only reports them.
export def classify [state_home: string]: nothing -> table {
  let kdir = known-dir $state_home
  scan-state $state_home | each { |r|
    let marker = $kdir | path join $r.id
    if not ($marker | path exists) {
      $r | insert status "unknown" | insert project_path null
    } else {
      let p = open --raw $marker | str trim
      let stat = if ($p | path exists) { "live" } else { "orphan" }
      $r | insert status $stat | insert project_path $p
    }
  }
}

# Byte size of a directory tree. Returns 0 for a missing path so callers can
# size-annotate a classified table without having to filter first.
export def dir-size [path: string]: nothing -> int {
  if not ($path | path exists) { return 0 }
  let r = ^du -sb $path | complete
  if $r.exit_code != 0 { return 0 }
  $r.stdout | str trim | split row -r '\s+' | first | into int
}

# True iff `pctl-<id>.slice` is currently `active` on the user bus. We check
# ActiveState, not LoadState — systemd synthesizes `LoadState=loaded` for any
# well-formed slice path on query, so LoadState is useless as a "does this
# slice really exist" signal. ActiveState=active is the only reliable "do
# not delete state for this id" guard for `pctl gc --yes`.
export def slice-active [id: string]: nothing -> bool {
  let bin = $env.PCTL_SYSTEMCTL? | default "systemctl"
  let slice = $"pctl-($id).slice"
  let r = ^$bin --user show $slice -p ActiveState --value | complete
  ($r.stdout | str trim) == "active"
}
