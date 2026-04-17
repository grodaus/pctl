# Resolve a rendered unit store tree. --tree overrides (pre-built, skips nix build);
# otherwise build $nix via `nix build --no-link --print-out-paths`.
export def resolve-store-tree [
  nix: string
  tree?: string
  --quiet
]: nothing -> string {
  if not ($tree | is-empty) { return ($tree | path expand) }
  if not $quiet { print $"$ nix build ($nix) --no-link --print-out-paths" }
  let built = ^nix build $nix --no-link --print-out-paths | complete
  if $built.exit_code != 0 {
    error make { msg: $"pctl: nix build failed: ($built.stderr)" }
  }
  $built.stdout | str trim | lines | last
}
