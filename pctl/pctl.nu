#!/usr/bin/env nu

use commands/init.nu
use commands/up.nu
use commands/down.nu
use commands/reload.nu
use commands/status.nu
use commands/restart.nu
use commands/logs.nu
use commands/list.nu
use commands/host.nu
use commands/gc.nu
use lib/fmt.nu format-out

# pctl — declarative Nix spec → systemd --user units.
def main [] {}

# Scaffold flake.nix + .gitignore in the current directory.
def "main init" [
  --force   # overwrite an existing flake.nix
] {
  init --force=$force
}

# Build the project, install units, and start the project slice.
def "main up" [
  --tree: string             # use a pre-built unit tree (skips `nix build`)
  --nix: string = ".#pctl"   # flake attribute to build
  --path: string             # override project path (default: cwd)
  --wait                     # block until every service is ready (probe or is-active)
  --timeout: int = 30        # overall readiness timeout in seconds
  --quiet                    # suppress systemctl banner
] {
  up --tree $tree --nix $nix --path $path --wait=$wait --timeout $timeout --quiet=$quiet
}

# Stop the project slice, uninstall its units, drop the registry entry.
def "main down" [
  --path: string   # override project path (default: cwd)
  --quiet
] {
  down --path $path --quiet=$quiet
}

# Rebuild, diff against the stored manifest, minimally restart changed units.
def "main reload" [
  --tree: string
  --nix: string = ".#pctl"
  --path: string
  --quiet
] {
  reload --tree $tree --nix $nix --path $path --quiet=$quiet
}

# Show systemctl status for the project slice (or a single service).
def "main status" [
  service?: string   # service name; omit for the whole slice
  --path: string
  --quiet
] {
  status $service --path $path --quiet=$quiet
}

# Restart the project slice (or a single service).
def "main restart" [
  service?: string
  --path: string
  --quiet
] {
  restart $service --path $path --quiet=$quiet
}

# Tail the journal for the project slice (or a single service).
def "main logs" [
  service?: string
  --path: string
  --follow (-f)           # tail -f behaviour
  --lines (-n): int = 100 # number of lines to show
  --quiet
] {
  logs $service --path $path --follow=$follow --lines $lines --quiet=$quiet
}

# List every registered project with its running state.
def "main ls" [
  --quiet
  --json    # force JSON output
  --table   # force table output
] {
  list --quiet=$quiet | format-out --json=$json --table=$table
}

# Alias for `ls` — list every registered project with its running state.
def "main list" [
  --quiet
  --json    # force JSON output
  --table   # force table output
] {
  list --quiet=$quiet | format-out --json=$json --table=$table
}

# Print the project's allocated 127.0.0.N on stdout.
def "main host" [
  --path: string   # override project path (default: cwd)
] {
  host --path $path
}

# Report (default) or delete (--yes) orphan state directories under
# $XDG_STATE_HOME/pctl-*. Never touches state dirs marked `unknown`
# (no persistent marker) or `live` (marker → path still exists).
def "main gc" [
  --yes     # delete orphan state directories
  --quiet
  --json    # force JSON output
  --table   # force table output
] {
  gc --yes=$yes --quiet=$quiet | format-out --json=$json --table=$table
}
