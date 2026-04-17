# pctl init — scaffold a flake.nix + .gitignore in the current directory.
#
# Templates live at <pctl-install>/templates/init/{flake.nix,.gitignore}.
# This file is at pctl/commands/init.nu; templates are at ../../templates/init
# relative to this file.

const script_dir = path self | path dirname
const templates_dir = path self | path dirname | path join ".." ".." "templates" "init"

export def main [--force] {
  let cwd = pwd | path expand
  let target_flake = $cwd | path join "flake.nix"
  let target_gitignore = $cwd | path join ".gitignore"

  if (($target_flake | path exists) and (not $force)) {
    error make { msg: $"pctl init: flake.nix already exists at ($target_flake) — pass --force to overwrite" }
  }

  let src_flake = $templates_dir | path join "flake.nix"
  let src_gitignore = $templates_dir | path join ".gitignore"

  if not ($src_flake | path exists) {
    error make { msg: $"pctl init: template flake.nix missing at ($src_flake)" }
  }

  open --raw $src_flake | save -f $target_flake
  if ($src_gitignore | path exists) {
    if ($target_gitignore | path exists) {
      # append missing lines rather than clobber
      let existing = open --raw $target_gitignore
      let template = open --raw $src_gitignore
      let needed = $template | lines | where { |l| not ($existing | str contains $l) }
      if ($needed | is-not-empty) {
        $"($existing)\n(($needed | str join "\n"))\n" | save -f $target_gitignore
      }
    } else {
      open --raw $src_gitignore | save -f $target_gitignore
    }
  }

  print $"pctl init: wrote ($target_flake)"
  print $"pctl init: updated ($target_gitignore)"
}
