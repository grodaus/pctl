use ../lib/context.nu *
use ../lib/registry.nu *
use ../lib/sysctl.nu *
use ../lib/units.nu *

# Returns one row per registered project; the CLI wrapper handles formatting.
export def main [--quiet] {
  let runtime_dir = require-runtime-dir
  let rows = registry-list $runtime_dir
  if ($rows | is-empty) {
    # stderr keeps stdout JSON-parseable.
    print -e "no projects registered"
    return []
  }
  let units = $rows | each { |r| slice-unit $r.id }
  let actives = systemctl-active ...$units
  $rows | enumerate | each { |it|
    let r = $it.item
    { id: $r.id, path: $r.path, host: $r.host, started_at: $r.started_at, running: ($actives | get $it.index) }
  }
}
