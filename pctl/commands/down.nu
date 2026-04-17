use ../lib/identity.nu *
use ../lib/install.nu *
use ../lib/registry.nu *
use ../lib/sysctl.nu *

# pctl down — stop the project slice, uninstall units, drop registry entry.
export def main [
  --path: string   # override project path (default: cwd)
  --quiet
] {
  let runtime_dir = $env.XDG_RUNTIME_DIR? | default ""
  if ($runtime_dir | is-empty) {
    error make { msg: "pctl down: XDG_RUNTIME_DIR is not set" }
  }

  let project_path = if ($path | is-empty) { pwd | path expand } else { $path | path expand }
  let id = (derive-id $project_path).id

  # Registry must exist; report clearly if not.
  let reg_dir = registry-path $runtime_dir $id
  if not ($reg_dir | path exists) {
    error make { msg: $"pctl down: no registered project with id '($id)' at ($project_path)" }
  }

  # Stop the slice. Tolerate failure — it may already be down.
  try {
    run-systemctl stop $"pctl-($id).slice" --quiet=$quiet
  } catch { |e|
    if not $quiet {
      print $"(ansi yellow)warning(ansi reset): stop pctl-($id).slice failed: ($e.msg)"
    }
  }

  uninstall-units $runtime_dir $id

  run-systemctl daemon-reload --quiet=$quiet

  registry-remove $runtime_dir $id

  print $"project ($id) down"
}
