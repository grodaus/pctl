use units.nu *

export def install-units [
  store_tree: path
  runtime_dir: path
  project_id: string
  host: string
] {
  let target = unit-dir $runtime_dir
  mkdir $target

  let results = ls $store_tree
    | get name
    | each { |p|
      let base = $p | path basename
      let target_base = $base | str replace -a '@@PROJECT@@' $project_id
      let target_path = $target | path join $target_base
      open --raw $p | str replace -a '@@PROJECT@@' $project_id | save -f $target_path

      let dropin_dir = $target_path + ".d"
      mkdir $dropin_dir
      let dropin_path = $dropin_dir | path join "pctl-runtime.conf"
      let body = if ($target_base | str ends-with ".slice") {
        $"[Slice]\nEnvironment=PCTL_ID=($project_id)\n"
      } else {
        $"[Service]\nEnvironment=PCTL_HOST=($host)\nEnvironment=PCTL_ID=($project_id)\n"
      }
      $body | save -f $dropin_path

      { installed: $target_path, dropin: $dropin_path }
    }

  {
    installed: ($results | get installed | sort)
    dropins: ($results | get dropin | sort)
  }
}

export def uninstall-units [runtime_dir: path, project_id: string] {
  let matching = ls (unit-dir $runtime_dir)
    | get name
    | where { |p| is-project-unit $project_id ($p | path basename) }

  for p in $matching { rm -rf $p }
  $matching | sort
}
