use ../lib/identity.nu *
use ../lib/sysctl.nu *

# pctl restart [service] — systemctl --user restart <unit>.
export def main [
  service?: string
  --path: string
  --quiet
] {
  let runtime_dir = $env.XDG_RUNTIME_DIR? | default ""
  if ($runtime_dir | is-empty) {
    error make { msg: "pctl restart: XDG_RUNTIME_DIR is not set" }
  }
  let project_path = if ($path | is-empty) { pwd | path expand } else { $path | path expand }
  let id = (derive-id $project_path).id
  let unit = if ($service | is-empty) {
    $"pctl-($id).slice"
  } else {
    $"pctl-($id)-($service).service"
  }
  run-systemctl restart $unit --quiet=$quiet
}
