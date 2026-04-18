use ../lib/context.nu *
use ../lib/identity.nu *
use ../lib/registry.nu *

# pctl host — print the current project's allocated 127.0.0.N on stdout.
export def main [--path: string] {
  let runtime_dir = require-runtime-dir
  let project_path = resolve-project-path $path
  let id = (derive-id $project_path).id
  if not ((registry-path $runtime_dir $id) | path exists) {
    error make { msg: $"pctl: project ($id) is not registered — run `pctl up` first" }
  }
  print (registry-read $runtime_dir $id).host
}
