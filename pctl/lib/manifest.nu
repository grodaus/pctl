export def diff-manifest [old: record, new: record] {
  let old_keys = $old | columns
  let new_keys = $new | columns
  let all_keys = ($old_keys ++ $new_keys) | uniq | sort
  $all_keys | each { |unit|
    let oh = $old | get -o $unit
    let nh = $new | get -o $unit
    let action = if ($oh == null) {
      "added"
    } else if ($nh == null) {
      "removed"
    } else if ($oh == $nh) {
      "unchanged"
    } else {
      "changed"
    }
    { unit: $unit, action: $action, old_hash: (if $oh == null { "" } else { $oh }), new_hash: (if $nh == null { "" } else { $nh }) }
  }
}

export def summary [plan: table]: nothing -> string {
  let counts = $plan | group-by action
  let added = $counts | get -o added | default [] | length
  let changed = $counts | get -o changed | default [] | length
  let unchanged = $counts | get -o unchanged | default [] | length
  let removed = $counts | get -o removed | default [] | length
  $"+($added) ~($changed) =($unchanged) -($removed)"
}
