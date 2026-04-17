use ../lib/context.nu *
use ../lib/identity.nu *
use ../lib/sysctl.nu *
use ../lib/units.nu *

# pctl logs [service] — journalctl --user -u <unit>. Default --lines 100, --follow to tail.
export def main [
  service?: string
  --path: string
  --follow (-f)
  --lines (-n): int = 100
  --quiet
] {
  let runtime_dir = require-runtime-dir
  let project_path = resolve-project-path $path
  let id = (derive-id $project_path).id
  let unit = unit-for $id $service
  let args = ["-u" $unit "-n" ($lines | into string)] ++ (if $follow { ["-f"] } else { [] })
  run-journalctl ...$args --quiet=$quiet
}
