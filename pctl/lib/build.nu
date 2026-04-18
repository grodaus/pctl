# Resolve a rendered unit store tree. --tree overrides (pre-built, skips nix build);
# otherwise build $nix via `nix build --no-link --print-out-paths`.
export def resolve-store-tree [
  nix: string
  tree?: string
  --quiet
]: nothing -> string {
  if not ($tree | is-empty) { return ($tree | path expand) }
  if not $quiet { print -e $"$ nix build ($nix) --no-link --print-out-paths" }
  # `| collect` captures stdout for the path; stderr streams live to the user.
  let out = try {
    ^nix build $nix --no-link --print-out-paths | collect
  } catch { |e|
    error make { msg: $"pctl: nix build failed with exit code ($e.exit_code)" }
  }
  $out | str trim | lines | last
}
