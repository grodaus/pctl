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

  open --raw $src_flake | save -f $target_flake
  if ($src_gitignore | path exists) {
    if ($target_gitignore | path exists) {
      let existing_lines = open --raw $target_gitignore | lines
      let template_lines = open --raw $src_gitignore | lines
      let needed = $template_lines | where { |l| $l not-in $existing_lines }
      if ($needed | is-not-empty) {
        let existing = open --raw $target_gitignore
        $"($existing)\n(($needed | str join "\n"))\n" | save -f $target_gitignore
      }
    } else {
      open --raw $src_gitignore | save -f $target_gitignore
    }
  }

  print $"pctl init: wrote ($target_flake)"
  print $"pctl init: updated ($target_gitignore)"
}
