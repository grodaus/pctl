# Persistent project markers consulted by `pctl gc`.
#
# A marker is a single file `$XDG_STATE_HOME/pctl/known/<id>` whose contents
# are the absolute project path that produced <id>. `pctl up` creates (or
# overwrites) the marker for the current project. `pctl down` leaves it
# alone on purpose: a `down` project's state still matters, and the marker
# is the only way `pctl gc` can tell "this project still has a home on
# disk, keep its state" from "the worktree is gone, this is garbage".

use gc.nu known-dir

export def known-path [state_home: string, id: string]: nothing -> string {
  (known-dir $state_home) | path join $id
}

export def known-write [state_home: string, id: string, project_path: string] {
  let dir = known-dir $state_home
  mkdir $dir
  $project_path | save -f ($dir | path join $id)
}

export def known-list [state_home: string]: nothing -> table {
  let dir = known-dir $state_home
  if not ($dir | path exists) { return [] }
  ls $dir
    | where type == file
    | get name
    | each { |f|
      { id: ($f | path basename), path: (open --raw $f | str trim) }
    }
}
