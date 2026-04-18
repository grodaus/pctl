#!/usr/bin/env nu
# workspace.writable gives a service write access to the project dir:
# ProtectHome=tmpfs + BindPaths=<project_path> means the rest of /home is
# invisible but the project dir is bind-mounted in, writable. A oneshot that
# touches ./hello proves the bind-mount is real.

use std assert
use harness.nu *
use ../../pctl/lib/identity.nu derive-id

const touch_bin = "/run/current-system/sw/bin/touch"

# Oneshot that writes a file into @@PROJECT_PATH@@. install-units substitutes
# @@PROJECT_PATH@@ with the real scratch project dir at install time.
let body = $"[Unit]
Description=workspace writer @@PROJECT@@

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=($touch_bin) @@PROJECT_PATH@@/hello
Slice=pctl-@@PROJECT@@.slice
WorkingDirectory=@@PROJECT_PATH@@
ProtectHome=tmpfs
BindPaths=@@PROJECT_PATH@@
NoNewPrivileges=yes
ProtectSystem=strict
"

let scratch = setup {writer: $body}

try {
  let up = run-pctl $scratch.project_dir "up" "--tree" $scratch.tree_dir "--quiet"
  assert ($up.exit_code == 0) $"up failed: stdout=($up.stdout) stderr=($up.stderr)"

  let id = (derive-id $scratch.project_dir).id
  let writer = $"pctl-($id)-writer.service"

  # Oneshot + RemainAfterExit=yes lands in active once ExecStart succeeds.
  assert (wait-active $writer 5) $"writer ($writer) did not become active"

  # Installed unit must have the project path baked in — no placeholder left.
  let installed = open --raw (unit-path $writer)
  assert (not ($installed | str contains "@@PROJECT_PATH@@"))
  assert ($installed | str contains $"WorkingDirectory=($scratch.project_dir)")
  assert ($installed | str contains $"BindPaths=($scratch.project_dir)")

  # The actual write went through — file exists on the host filesystem.
  let hello = $scratch.project_dir | path join "hello"
  assert ($hello | path exists) $"writer did not create ($hello) — bind-mount failed?"

  print $"workspace_test OK — ($id)"
} catch { |e|
  teardown $scratch
  error make { msg: $"workspace_test failed: ($e.msg)" }
}

teardown $scratch
