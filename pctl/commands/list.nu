use ../lib/context.nu *
use ../lib/registry.nu *
use ../lib/sysctl.nu *
use ../lib/units.nu *

export def main [--quiet] {
  let runtime_dir = require-runtime-dir
  let rows = registry-list $runtime_dir
  if ($rows | is-empty) {
    print "no projects registered"
    return
  }
  $rows | each { |r|
    let active = try {
      run-systemctl is-active (slice-unit $r.id) --quiet
      true
    } catch { false }
    { id: $r.id, path: $r.path, host: $r.host, started_at: $r.started_at, running: $active }
  }
}
