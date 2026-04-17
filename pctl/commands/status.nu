use ../lib/identity.nu *
use ../lib/sysctl.nu *

# pctl status [service] — systemctl --user status <unit>.
# Without a service name, show the whole slice.
export def main [
  service?: string
  --path: string
  --quiet
] {
  let runtime_dir = $env.XDG_RUNTIME_DIR? | default ""
  if ($runtime_dir | is-empty) {
    error make { msg: "pctl status: XDG_RUNTIME_DIR is not set" }
  }
  let project_path = if ($path | is-empty) { pwd | path expand } else { $path | path expand }
  let id = (derive-id $project_path).id
  let unit = if ($service | is-empty) {
    $"pctl-($id).slice"
  } else {
    $"pctl-($id)-($service).service"
  }
  # systemctl status exits non-zero when unit is inactive — tolerate.
  try {
    run-systemctl status $unit --quiet=$quiet
  } catch { |e|
    if not $quiet {
      print $"(ansi yellow)note(ansi reset): systemctl status reported non-zero: ($e.msg)"
    }
  }
}
