#!/usr/bin/env nu
# End-to-end reality check against host systemd --user.
#
# NOT runnable in `nix flake check` sandbox (no systemd there).
# Invoke from the pctl repo root on a Linux host with systemd --user:
#
#   nu tests/e2e/reality.nu
#
# Requires nushell, curl, iproute2 (`ss`), git, darkhttpd (via nix).
# Exit status: 0 on success, non-zero on failure. Best-effort teardown of
# the scratch project runs even when an assertion fails.

use std assert

const const_repo_root = (path self "../..")
const const_pctl_script = (path self "../../pctl/pctl.nu")

# Allow nix-wrapped invocation to override the paths: when `nix run .#pctl-e2e`
# copies this script into /nix/store, `path self` no longer resolves to the
# repo. The wrapper sets PCTL_REPO / PCTL_SCRIPT.
let repo_root = ($env.PCTL_REPO? | default $const_repo_root)
let pctl_script = ($env.PCTL_SCRIPT? | default $const_pctl_script)

def banner [msg: string] {
  print $"\n=== ($msg)"
}

def pick-free-port [] {
  for p in 18080..19000 {
    let needle = $":($p) "
    let taken = (^ss -lnt | complete | get stdout | lines | any { |l| $l | str contains $needle })
    if not $taken { return $p }
  }
  error make { msg: "no free port in 18080..19000" }
}

def wait-active [unit: string, timeout_s: int = 5] {
  mut i = 0
  while $i < ($timeout_s * 10) {
    let r = (^systemctl --user is-active $unit | complete)
    if ($r.stdout | str trim) == "active" { return true }
    sleep 100ms
    $i = $i + 1
  }
  false
}

def run-pctl [cwd: string, ...args: string] {
  cd $cwd
  let out = (^nu $pctl_script ...$args | complete)
  cd -
  $out
}

def teardown [cwd: string] {
  try { run-pctl $cwd "down" | ignore } catch { |e| print $"teardown error: ($e.msg)" }
}

def main [] {
  if ($env.XDG_RUNTIME_DIR? | is-empty) {
    error make { msg: "XDG_RUNTIME_DIR must be set" }
  }

  let repo = $repo_root
  let port = pick-free-port
  print $"using port ($port)"

  let tmp = (mktemp -d -t pctl-e2e-XXXXXX)
  let www = ($tmp | path join "www")
  mkdir $www
  "<h1>pctl e2e ok</h1>" | save ($www | path join "index.html")

  # The `--addr` is rendered as the systemd environment placeholder
  # `${PCTL_HOST}`; systemd expands it at service start using the
  # Environment=PCTL_HOST=... drop-in that pctl writes at install time.
  # Nix itself sees the literal string because `''${PCTL_HOST}''` in a Nix
  # indented string evaluates to a literal `${PCTL_HOST}`.
  let flake_content = (
    "{\n"
    + "  description = \"pctl e2e\";\n"
    + "  inputs = {\n"
    + "    nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";\n"
    + $"    pctl.url = \"git+file://($repo)\";\n"
    + "    pctl.inputs.nixpkgs.follows = \"nixpkgs\";\n"
    + "  };\n"
    + "  outputs = { self, nixpkgs, pctl }:\n"
    + "    let\n"
    + "      system = \"x86_64-linux\";\n"
    + "      pkgs = nixpkgs.legacyPackages.${system};\n"
    + "    in\n"
    + "    {\n"
    + "      packages.${system}.pctl = pctl.lib.${system}.mkProject {\n"
    + "        services = {\n"
    + "          web = {\n"
    + "            command = [\n"
    + "              \"${pkgs.darkhttpd}/bin/darkhttpd\"\n"
    + $"              \"($www)\"\n"
    + $"              \"--port\" \"($port)\"\n"
    + "              \"--addr\" \"\\${PCTL_HOST}\"\n"
    + "            ];\n"
    + "          };\n"
    + "        };\n"
    + "      };\n"
    + "    };\n"
    + "}\n"
  )
  $flake_content | save ($tmp | path join "flake.nix")
  cd $tmp
  ^git init -q
  ^git add -A

  banner "Step 1: pctl up"
  let up = run-pctl $tmp "up"
  print $up.stdout
  assert ($up.exit_code == 0) $"up failed: ($up.stderr)"

  # Extract project id and assigned host from up stdout.
  # Format: "project <id> up · N units · host=<ip>"
  let id_line = ($up.stdout | lines | where { |l| $l | str starts-with "project " } | first)
  let id = ($id_line | parse "project {id} up{rest}" | first | get id)
  let host = ($id_line | parse --regex 'host=(?P<h>[0-9.]+)' | first | get h)
  print $"project id: ($id)"
  print $"assigned host: ($host)"

  banner "Step 2: assert web service became active"
  let web_unit = $"pctl-($id)-web.service"
  let active = wait-active $web_unit 10
  if not $active {
    ^systemctl --user status $web_unit --no-pager -n 20 | print
    teardown $tmp
    error make { msg: $"service ($web_unit) did not reach active state" }
  }
  print $"($web_unit) is active"

  banner "Step 3: cgroup path sanity"
  let cgroup = (^systemctl --user show $web_unit -p ControlGroup --value | complete | get stdout | str trim)
  print $"ControlGroup = ($cgroup)"
  # Expect pctl.slice > pctl-<id>.slice > <web>.service (3 segments from user@.service)
  # Fail if the <id> part is itself split into multiple slice levels.
  let segs = ($cgroup | parse --regex 'pctl-[^/]*\.slice' | length)
  if $segs > 2 {
    teardown $tmp
    error make { msg: $"cgroup shows nested project slices: ($cgroup)" }
  }

  banner "Step 4: HTTP reality check against assigned PCTL_HOST"
  # Bug-2 regression: the service must bind to the pctl-assigned host IP,
  # not the literal 127.0.0.1 the user might have typed. Curl the assigned
  # host to prove `${PCTL_HOST}` was expanded by systemd and darkhttpd bound
  # there. A control curl against 127.0.0.1 should *fail* to bind.
  let resp = (^curl -s -w "%{http_code}" $"http://($host):($port)/index.html" | complete)
  let body = ($resp.stdout | str substring 0..-4)
  let code = ($resp.stdout | str substring (-3)..)
  print $"code=($code)"
  print $"body=($body)"
  if $code != "200" {
    teardown $tmp
    error make { msg: $"expected HTTP 200, got ($code). body=($body)" }
  }
  if not ($body | str contains "pctl e2e ok") {
    teardown $tmp
    error make { msg: $"body missing expected content: ($body)" }
  }

  # Negative control: the literal 127.0.0.1 must NOT accept the connection
  # on this port. If it does, darkhttpd bound to 0.0.0.0 or to 127.0.0.1
  # (ignoring ${PCTL_HOST}) and the port-collision story is broken.
  if $host != "127.0.0.1" {
    let neg = (^curl -sS --max-time 2 --connect-timeout 1 -o /dev/null -w "%{http_code}" $"http://127.0.0.1:($port)/" | complete)
    let neg_code = ($neg.stdout | str trim)
    if $neg_code == "200" {
      teardown $tmp
      error make { msg: $"service accepted connection on 127.0.0.1:($port); PCTL_HOST allocation is not effective" }
    }
    print $"negative control: 127.0.0.1:($port) refused \(as expected\)"
  }

  banner "Step 5: pctl down"
  let down = run-pctl $tmp "down"
  print $down.stdout
  assert ($down.exit_code == 0) $"down failed: ($down.stderr)"

  banner "Step 6: registry + user.control cleaned"
  let reg_path = ($env.XDG_RUNTIME_DIR | path join "pctl" "projects" $id)
  if ($reg_path | path exists) {
    error make { msg: $"registry entry not removed: ($reg_path)" }
  }
  let remaining = (
    ls $"($env.XDG_RUNTIME_DIR)/systemd/user.control/"
    | get name
    | where { |n| ($n | path basename | str starts-with $"pctl-($id)") }
    | length
  )
  if $remaining > 0 {
    error make { msg: $"lingering unit files for ($id) in user.control" }
  }

  banner "Step 7: no lingering darkhttpd"
  let procs = (^pgrep -fc $"darkhttpd.*--port ($port)" | complete | get stdout | str trim | into int)
  if $procs > 0 {
    error make { msg: $"($procs) darkhttpd processes still bound to port ($port)" }
  }

  banner "ALL GREEN"
  cd /
  rm -rf $tmp
}
