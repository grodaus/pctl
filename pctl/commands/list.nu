use ../lib/registry.nu *
use ../lib/sysctl.nu *

# pctl ls — enumerate all registered projects with their running state.
export def main [--quiet] {
  let runtime_dir = $env.XDG_RUNTIME_DIR? | default ""
  if ($runtime_dir | is-empty) {
    error make { msg: "pctl ls: XDG_RUNTIME_DIR is not set" }
  }
  let rows = registry-list $runtime_dir
  if ($rows | is-empty) {
    print "no projects registered"
    return
  }
  $rows | each { |r|
    let active = try {
      run-systemctl is-active $"pctl-($r.id).slice" --quiet
      true
    } catch { false }
    {
      id: $r.id
      path: $r.path
      host: $r.host
      started_at: $r.started_at
      running: $active
    }
  }
}
