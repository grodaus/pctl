# No `| complete` — stdout/stderr stream through so `journalctl -f` works and
# the caller sees output live. Banner on stderr keeps stdout JSON-parseable.
def run-streamed [bin: string, args: list<string>, quiet: bool] {
  let full_args = ["--user"] ++ $args
  if not $quiet {
    print -e $"$ ($bin) ($full_args | str join ' ')"
  }
  try {
    ^$bin ...$full_args
  } catch { |e|
    error make {
      msg: $"($bin) failed with exit code ($e.exit_code)"
      label: { text: "command exited non-zero", span: (metadata $bin).span }
    }
  }
}

export def run-systemctl [...args: string, --quiet] {
  let bin = $env.PCTL_SYSTEMCTL? | default "systemctl"
  run-streamed $bin $args $quiet
}

# Start N units in a single `systemctl --user start --no-block` call. The job
# is enqueued and the command returns immediately — individual unit failures
# do NOT propagate as a non-zero exit, so callers must observe outcomes via
# `wait-ready` / `wait-all` / `pctl results`.
export def start-async [units: list<string>, --quiet] {
  if ($units | is-empty) { return }
  let bin = $env.PCTL_SYSTEMCTL? | default "systemctl"
  run-streamed $bin (["start" "--no-block"] ++ $units) $quiet
}

export def run-journalctl [...args: string, --quiet] {
  let bin = $env.PCTL_JOURNALCTL? | default "journalctl"
  run-streamed $bin $args $quiet
}

# Batched `is-active` probe — one bool per unit, in input order. Single
# subprocess for N units instead of N (matters for `pctl ls`). `do -i`
# suppresses pipefail so we can read stdout even when systemctl exits
# non-zero (which it does whenever any listed unit is inactive). Output is
# always padded to `units | length`; missing lines count as not-active.
export def systemctl-active [...units: string]: nothing -> list<bool> {
  if ($units | is-empty) { return [] }
  let bin = $env.PCTL_SYSTEMCTL? | default "systemctl"
  let result = do -i { ^$bin --user is-active ...$units | complete }
  let states = $result.stdout | str trim | lines
  $units | enumerate | each { |it| ($states | get -o $it.index) == "active" }
}
