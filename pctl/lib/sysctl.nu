def run-wrapped [bin: string, args: list<string>, quiet: bool] {
  let full_args = ["--user"] ++ $args
  if not $quiet {
    print $"$ ($bin) ($full_args | str join ' ')"
  }
  let result = ^$bin ...$full_args | complete
  if $result.exit_code != 0 {
    error make {
      msg: $"($bin) failed with exit code ($result.exit_code)"
      label: { text: "command exited non-zero", span: (metadata $bin).span }
    }
  }
  $result
}

export def run-systemctl [...args: string, --quiet] {
  let bin = $env.PCTL_SYSTEMCTL? | default "systemctl"
  run-wrapped $bin $args $quiet
}

export def run-journalctl [...args: string, --quiet] {
  let bin = $env.PCTL_JOURNALCTL? | default "journalctl"
  run-wrapped $bin $args $quiet
}
