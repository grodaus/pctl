use units.nu *

export def install-units [
  store_tree: path
  runtime_dir: path
  project: record<id: string, host: string, path: string>
] {
  let target = unit-dir $runtime_dir
  mkdir $target

  # Only .slice/.service files are systemd units. Anything else in the store
  # tree (e.g. probes.json side-car from mkProject) must not land in
  # user.control/ or get a drop-in — systemd would try to load it and fail.
  let results = ls $store_tree
    | get name
    | where { |p|
      let b = $p | path basename
      ($b | str ends-with ".slice") or ($b | str ends-with ".service")
    }
    | each { |p|
      let base = $p | path basename
      let target_base = $base | str replace -a '@@PROJECT@@' $project.id
      let target_path = $target | path join $target_base
      open --raw $p
        | str replace -a '@@PROJECT@@' $project.id
        | str replace -a '@@PROJECT_PATH@@' $project.path
        | save -f $target_path

      let dropin_dir = $target_path + ".d"
      mkdir $dropin_dir
      let dropin_path = $dropin_dir | path join "pctl-runtime.conf"
      let body = if ($target_base | str ends-with ".slice") {
        $"[Slice]\nEnvironment=PCTL_ID=($project.id)\n"
      } else {
        $"[Service]\nEnvironment=PCTL_HOST=($project.host)\nEnvironment=PCTL_ID=($project.id)\n"
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
