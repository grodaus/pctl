use ../lib/context.nu *
use ../lib/identity.nu *
use ../lib/sysctl.nu *
use ../lib/units.nu *

# pctl status [service] — systemctl --user status <unit>. Defaults to the slice.
export def main [
  service?: string
  --path: string
  --quiet
] {
  let runtime_dir = require-runtime-dir
  let project_path = resolve-project-path $path
  let id = (derive-id $project_path).id
  let unit = unit-for $id $service
  # systemctl status exits non-zero when the unit is inactive — tolerate.
  try {
    run-systemctl status $unit --quiet=$quiet
  } catch { |e|
    if not $quiet {
      print $"(ansi yellow)note(ansi reset): systemctl status reported non-zero: ($e.msg)"
    }
  }
}
