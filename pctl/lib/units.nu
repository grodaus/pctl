export const unit_subdir = ["systemd" "user.control"]

export def unit-dir [runtime_dir: string]: nothing -> string {
  $runtime_dir | path join ...$unit_subdir
}

export def slice-unit [id: string]: nothing -> string {
  $"pctl-($id).slice"
}

export def service-unit [id: string, service: string]: nothing -> string {
  $"pctl-($id)-($service).service"
}

export def unit-for [id: string, service?: string]: nothing -> string {
  if ($service | is-empty) { slice-unit $id } else { service-unit $id $service }
}

export def is-project-unit [id: string, basename: string]: nothing -> bool {
  ($basename | str starts-with $"pctl-($id).") or ($basename | str starts-with $"pctl-($id)-")
}

# Hash every top-level file in $unit_dir whose basename belongs to project $id.
# Returns { filename: sha256 }. Drop-in .d directories are skipped.
export def compute-manifest [unit_dir: string, id: string]: nothing -> record {
  ls $unit_dir
    | where type == file
    | get name
    | where { |p| is-project-unit $id ($p | path basename) }
    | reduce -f {} { |p, acc|
      $acc | insert ($p | path basename) (open --raw $p | hash sha256)
    }
}
