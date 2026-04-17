use ../lib/context.nu *
use ../lib/identity.nu *
use ../lib/sysctl.nu *
use ../lib/units.nu *

export def main [
  service?: string
  --path: string
  --quiet
] {
  let runtime_dir = require-runtime-dir
  let project_path = resolve-project-path $path
  let id = (derive-id $project_path).id
  run-systemctl restart (unit-for $id $service) --quiet=$quiet
}
