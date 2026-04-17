def sanitize-basename [raw: string]: nothing -> string {
  # Allow only [a-z0-9_]. Dashes in the basename would create extra slice
  # levels in `pctl-<id>.slice` (systemd splits slice names on '-'), so we
  # collapse every non-alnum character to '_' and keep ids dash-free.
  let lowered = $raw | str downcase
  let only_allowed = $lowered | str replace -ra '[^a-z0-9_]' '_'
  let collapsed = $only_allowed | str replace -ra '_+' '_'
  let trimmed = $collapsed | str replace -ra '^_+|_+$' ''
  if ($trimmed | is-empty) { "project" } else { $trimmed }
}

export def derive-id [path: string] {
  let abs = $path | path expand
  let raw_basename = $abs | path basename
  let basename = sanitize-basename $raw_basename
  let hash8 = $abs | hash sha256 | str substring 0..<8
  { id: $"($basename)_($hash8)", basename: $basename, hash8: $hash8 }
}

def host-for [n: int]: nothing -> string {
  $"127.0.0.($n)"
}

export def allocate-host [id: string, taken: list<string> = []] {
  let first_byte = $id | hash md5 | decode hex | first
  let initial = ($first_byte mod 253) + 2
  mut n = $initial
  mut tries = 0
  while $tries < 253 {
    let candidate = host-for $n
    if ($candidate not-in $taken) {
      return $candidate
    }
    $n = if $n < 254 { $n + 1 } else { 2 }
    $tries = $tries + 1
  }
  error make { msg: $"allocate-host: no free slot in 127.0.0.2..254 for id '($id)'" }
}
