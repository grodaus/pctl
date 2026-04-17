use ../lib/context.nu *
use ../lib/identity.nu *
use ../lib/install.nu *
use ../lib/registry.nu *
use ../lib/sysctl.nu *
use ../lib/units.nu *

# pctl down — stop the project slice, uninstall units, drop registry entry.
export def main [
  --path: string
  --quiet
] {
  let runtime_dir = require-runtime-dir
  let project_path = resolve-project-path $path
  let id = (derive-id $project_path).id

  let reg_dir = registry-path $runtime_dir $id
  if not ($reg_dir | path exists) {
    error make { msg: $"pctl down: no registered project with id '($id)' at ($project_path)" }
  }

  try {
    run-systemctl stop (slice-unit $id) --quiet=$quiet
  } catch { |e|
    if not $quiet {
      print $"(ansi yellow)warning(ansi reset): stop (slice-unit $id) failed: ($e.msg)"
    }
  }

  uninstall-units $runtime_dir $id
  run-systemctl daemon-reload --quiet=$quiet
  registry-remove $runtime_dir $id

  print $"project ($id) down"
}
