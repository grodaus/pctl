#!/usr/bin/env nu

use std assert

const module_path = (path self | path dirname | path join ".." ".." "pctl" "lib" "fmt.nu")

# Run a snippet in a subprocess so we can control whether its stdout is
# connected to a terminal. `| complete` always pipes (stdout is non-tty).
def run-piped [script: string]: nothing -> record {
  ^nu -c $script | complete
}

# --json forces JSON regardless of stdout state.
let r = run-piped $"use ($module_path) *; [{a: 1}] | format-out --json"
assert equal $r.exit_code 0
let parsed = $r.stdout | from json
assert equal $parsed [{a: 1}]

# --table forces table rendering (ASCII box drawing) even when piped.
let rt = run-piped $"use ($module_path) *; [{a: 1}] | format-out --table"
assert equal $rt.exit_code 0
assert ($rt.stdout | str contains "│")

# With neither flag and stdout piped, format-out emits JSON.
let ra = run-piped $"use ($module_path) *; [{a: 1}] | format-out"
assert equal $ra.exit_code 0
let parsed_auto = $ra.stdout | from json
assert equal $parsed_auto [{a: 1}]

# --json and --table together raise.
let rerr = run-piped $"use ($module_path) *; [{a: 1}] | format-out --json --table"
assert ($rerr.exit_code != 0)
