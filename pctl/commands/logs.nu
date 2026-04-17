use ../lib/identity.nu *
use ../lib/sysctl.nu *

# pctl logs [service] — journalctl --user -u <unit>.
# Default --lines 100. Use --follow to tail.
export def main [
  service?: string
  --path: string
  --follow (-f)
  --lines (-n): int = 100
  --quiet
] {
  let runtime_dir = $env.XDG_RUNTIME_DIR? | default ""
  if ($runtime_dir | is-empty) {
    error make { msg: "pctl logs: XDG_RUNTIME_DIR is not set" }
  }
  let project_path = if ($path | is-empty) { pwd | path expand } else { $path | path expand }
  let id = (derive-id $project_path).id
  let unit = if ($service | is-empty) {
    $"pctl-($id).slice"
  } else {
    $"pctl-($id)-($service).service"
  }
  # Build argv: -u <unit> -n <lines> [-f]
  let base_args = ["-u" $unit "-n" ($lines | into string)]
  let args = if $follow { $base_args ++ ["-f"] } else { $base_args }
  run-journalctl ...$args --quiet=$quiet
}
