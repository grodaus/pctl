export def require-runtime-dir []: nothing -> string {
  let rt = $env.XDG_RUNTIME_DIR? | default ""
  if ($rt | is-empty) {
    error make { msg: "pctl: XDG_RUNTIME_DIR is not set (requires Linux + systemd --user)" }
  }
  $rt
}

export def resolve-project-path [path?: string]: nothing -> string {
  if ($path | is-empty) { pwd | path expand } else { $path | path expand }
}
