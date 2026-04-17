export def install-units [
  storeTree: path
  runtimeDir: path
  projectId: string
  host: string
] {
  let unitDir = $runtimeDir | path join "systemd/user.control"
  mkdir $unitDir

  let results = ls $storeTree
    | get name
    | each { |p|
      let base = $p | path basename
      let target_base = $base | str replace -a '@@PROJECT@@' $projectId
      let target = $unitDir | path join $target_base
      open --raw $p | str replace -a '@@PROJECT@@' $projectId | save -f $target

      let dropinDir = $target + ".d"
      mkdir $dropinDir
      let dropinPath = $dropinDir | path join "pctl-runtime.conf"
      let body = if ($target_base | str ends-with ".slice") {
        $"[Slice]\nEnvironment=PCTL_ID=($projectId)\n"
      } else {
        $"[Service]\nEnvironment=PCTL_HOST=($host)\nEnvironment=PCTL_ID=($projectId)\n"
      }
      $body | save -f $dropinPath

      { installed: $target, dropin: $dropinPath }
    }

  let installed = $results | get installed | sort
  let dropins = $results | get dropin | sort
  { installed: $installed, dropins: $dropins }
}

export def uninstall-units [runtimeDir: path, projectId: string] {
  let unitDir = $runtimeDir | path join "systemd/user.control"
  if not ($unitDir | path exists) {
    return []
  }
  let dotPrefix = $"pctl-($projectId)."
  let dashPrefix = $"pctl-($projectId)-"

  let matching = ls $unitDir
    | get name
    | where { |p|
      let base = $p | path basename
      ($base | str starts-with $dotPrefix) or ($base | str starts-with $dashPrefix)
    }

  $matching | each { |p| rm -rf $p } | ignore
  $matching | sort
}
