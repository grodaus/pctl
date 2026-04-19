(* pctl — declarative Nix spec -> systemd --user units.
 *
 * Phase 0 scaffold: only `--version` is wired. Per-command dispatch
 * (`up`, `reload`, `down`, `results`, `logs`, `host`, `restart`, `status`,
 * `list`, `gc`, `init`) lands in Phase 4+ per docs/src/plans/20260419-ocaml-rewrite.md. *)

(* Phase 3 link-stub: force-reference Systemctl so libsystemd ends up
 * in the binary's DT_NEEDED list. Phase 4 replaces this with the real
 * per-command dispatcher that calls Systemctl.Dbus.connect. *)
let _ : (module Systemctl.S) = (module Systemctl.In_mem)

let version = "0.0.1-ocaml-rewrite"

let default_cmd () =
  (* No subcommand given. Print a short banner and exit 0 — keeps
     `pctl` runnable as a sanity check in the nix build verification.
     Phase 4+ replaces this with a real dispatcher. *)
  print_endline "pctl: OCaml rewrite in progress. See docs/src/plans/20260419-ocaml-rewrite.md.";
  0

let cmd =
  let open Cmdliner in
  let info = Cmd.info "pctl" ~version ~doc:"declarative Nix spec -> systemd --user units" in
  Cmd.v info Term.(const default_cmd $ const ())

let () = exit (Cmdliner.Cmd.eval' cmd)
