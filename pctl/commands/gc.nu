use ../lib/gc.nu *
use ../lib/known.nu known-path

# pctl gc — report (default) or delete (--yes) orphan state directories
# under `$XDG_STATE_HOME/pctl-<id>-<svc>`.
#
# A state dir is classified against the persistent known-markers `pctl up`
# writes (see lib/known.nu):
#   - live:    marker points at a project path that still exists on disk
#   - orphan:  marker points at a path that no longer exists — garbage
#   - unknown: no marker for this id — pre-existing leak or a state dir
#              that never came from pctl; we refuse to touch these
#
# `--yes` deletes orphans only, and skips even those if the matching
# `pctl-<id>.slice` is currently active on the user bus. When a row is
# deleted, both the state dir and the known-marker for that id go — the
# marker is dead the moment the project path it points at is dead.
export def main [
  --yes     # delete orphan state directories
  --quiet
] {
  let sh = state-home
  let rows = classify $sh
    | each { |r| $r | insert size (dir-size $r.path) }
    | each { |r|
      if (not $yes) or ($r.status != "orphan") {
        $r | insert deleted false | insert reason (if $yes { $"not orphan: ($r.status)" } else { "dry-run" })
      } else if (slice-active $r.id) {
        $r | insert deleted false | insert reason "slice active"
      } else {
        rm -rf $r.path
        let marker = known-path $sh $r.id
        if ($marker | path exists) { rm -f $marker }
        $r | insert deleted true | insert reason ""
      }
    }

  if not $quiet {
    let by = $rows | group-by status
    let summary = ["live" "orphan" "unknown"]
      | each { |k|
        let n = ($by | get -o $k | default [] | length)
        $"($k)=($n)"
      }
      | str join " "
    if $yes {
      let nd = $rows | where deleted == true | length
      print $"pctl gc: ($summary) — deleted ($nd)"
    } else {
      print $"pctl gc: ($summary) — pass --yes to delete orphans"
    }
  }

  $rows
}
