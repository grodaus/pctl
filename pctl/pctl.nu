#!/usr/bin/env nu
#
# pctl — declarative Nix spec → systemd user units.
#
# This is a thin dispatcher. Each verb lives in pctl/commands/<verb>.nu
# as `export def main [...]` and is forwarded here via nu subcommand pattern.

use commands/init.nu
use commands/up.nu
use commands/down.nu
use commands/reload.nu
use commands/status.nu
use commands/restart.nu
use commands/logs.nu
use commands/list.nu

def main [] {
  print "usage: pctl <verb> [args...]"
  print ""
  print "verbs:"
  print "  init          scaffold a flake.nix + .gitignore in cwd"
  print "  up            build, install, and start the project slice"
  print "  down          stop the project slice and remove its units"
  print "  status [svc]  show status of the slice or one service"
  print "  logs [svc]    tail journal for the slice or one service"
  print "  restart [svc] restart the slice or one service"
  print "  reload        rebuild, diff, minimally restart changed units"
  print "  ls            list all registered projects"
}

def "main init" [--force] {
  init --force=$force
}

def "main up" [
  --tree: string
  --nix: string = ".#pctl"
  --path: string
  --quiet
] {
  up --tree $tree --nix $nix --path $path --quiet=$quiet
}

def "main down" [
  --path: string
  --quiet
] {
  down --path $path --quiet=$quiet
}

def "main reload" [
  --tree: string
  --nix: string = ".#pctl"
  --path: string
  --quiet
] {
  reload --tree $tree --nix $nix --path $path --quiet=$quiet
}

def "main status" [service?: string, --path: string, --quiet] {
  status $service --path $path --quiet=$quiet
}

def "main restart" [service?: string, --path: string, --quiet] {
  restart $service --path $path --quiet=$quiet
}

def "main logs" [
  service?: string
  --path: string
  --follow (-f)
  --lines (-n): int = 100
  --quiet
] {
  logs $service --path $path --follow=$follow --lines $lines --quiet=$quiet
}

def "main ls" [--quiet] {
  list --quiet=$quiet
}
