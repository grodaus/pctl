# Render structured input. Auto-detects: JSON when stdout is piped, table on a tty.
# --json/--table override the auto-detect.
export def format-out [--json, --table]: any -> any {
  let input = $in
  if $json and $table {
    error make { msg: "format-out: --json and --table are mutually exclusive" }
  }
  if $json or (not $table and not (is-terminal --stdout)) {
    $input | to json --indent 2
  } else {
    $input
  }
}
