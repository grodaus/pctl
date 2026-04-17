export def registry-path [runtime_dir: string, id: string]: nothing -> string {
  $runtime_dir | path join "pctl" "projects" $id
}

export def registry-write [runtime_dir: string, id: string, record: record] {
  let dir = registry-path $runtime_dir $id
  mkdir $dir
  $record.path | save -f ($dir | path join "path")
  $record.host | save -f ($dir | path join "host")
  $record.manifest | to nuon | save -f ($dir | path join "manifest.nuon")
  $record.started_at | save -f ($dir | path join "started_at")
}

export def registry-read [runtime_dir: string, id: string]: nothing -> record {
  let dir = registry-path $runtime_dir $id
  {
    path: (open --raw ($dir | path join "path") | str trim)
    host: (open --raw ($dir | path join "host") | str trim)
    manifest: (open ($dir | path join "manifest.nuon"))
    started_at: (open --raw ($dir | path join "started_at") | str trim)
  }
}

export def registry-remove [runtime_dir: string, id: string] {
  rm -rf (registry-path $runtime_dir $id)
}

def projects-dir [runtime_dir: string]: nothing -> string {
  $runtime_dir | path join "pctl" "projects"
}

export def registry-list [runtime_dir: string]: nothing -> table {
  let base = projects-dir $runtime_dir
  if not ($base | path exists) {
    return []
  }
  ls $base
    | where type == dir
    | get name
    | sort
    | each { |d|
      let id = $d | path basename
      {
        id: $id
        path: (open --raw ($d | path join "path") | str trim)
        host: (open --raw ($d | path join "host") | str trim)
        started_at: (open --raw ($d | path join "started_at") | str trim)
      }
    }
}

export def taken-hosts [runtime_dir: string]: nothing -> list<string> {
  registry-list $runtime_dir | get host
}
