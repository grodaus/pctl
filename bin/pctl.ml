(* pctl — declarative Nix spec -> systemd --user units.
 *
 * Phase 4 cmdliner entry: dispatches to Cli.{Up,Reload,Down,Restart}.
 * Each command opens its own Eio environment + Switch; Systemctl.Dbus
 * is the default handle. Errors flow through Common.run_with_errors. *)

open Cmdliner

let version = "0.0.1-ocaml-rewrite"

(* ---- shared cmdliner args ------------------------------------- *)

let path_arg =
  let doc = "Override project path (default: current working directory)." in
  Arg.(value & opt (some string) None & info [ "path" ] ~docv:"DIR" ~doc)

let tree_arg =
  let doc =
    "Use a pre-built spec.json path (skips `nix build`). Note: in the \
     OCaml rewrite this is a spec.json file, not the unit tree the \
     Nushell --tree flag accepted."
  in
  Arg.(value & opt (some string) None & info [ "tree" ] ~docv:"PATH" ~doc)

let nix_arg =
  let doc = "Flake attribute to build to produce spec.json." in
  Arg.(value & opt string ".#pctl" & info [ "nix" ] ~docv:"ATTR" ~doc)

(* ---- up -------------------------------------------------------- *)

let up_cmd =
  let no_block =
    let doc =
      "Enqueue all service starts in one batch and return immediately. \
       Phase 4 ignores this flag beyond accepting it."
    in
    Arg.(value & flag & info [ "no-block" ] ~doc)
  in
  let wait =
    let doc =
      "Block until every service is ready. Phase 4 stub; readiness wait \
       lands in Phase 5."
    in
    Arg.(value & flag & info [ "wait" ] ~doc)
  in
  let timeout =
    let doc = "Overall readiness timeout in seconds." in
    Arg.(value & opt int 30 & info [ "timeout" ] ~docv:"SECS" ~doc)
  in
  let run path tree nix no_block wait timeout =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    Cli.Up.run ~sw ~env ?tree ~nix ?path ~no_block ~wait ~timeout ()
  in
  let info = Cmd.info "up" ~doc:"Build, install units, start the slice." in
  Cmd.v info Term.(const run $ path_arg $ tree_arg $ nix_arg $ no_block $ wait $ timeout)

(* ---- reload ---------------------------------------------------- *)

let reload_cmd =
  let run path tree nix =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    Cli.Reload.run ~sw ~env ?tree ~nix ?path ()
  in
  let info =
    Cmd.info "reload"
      ~doc:"Rebuild, diff against the stored manifest, minimally restart."
  in
  Cmd.v info Term.(const run $ path_arg $ tree_arg $ nix_arg)

(* ---- down ------------------------------------------------------ *)

let down_cmd =
  let run path =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw -> Cli.Down.run ~sw ~env ?path ()
  in
  let info = Cmd.info "down" ~doc:"Stop the slice, uninstall units." in
  Cmd.v info Term.(const run $ path_arg)

(* ---- restart --------------------------------------------------- *)

let restart_cmd =
  let svc_arg =
    let doc = "Service name to restart (empty = restart the whole slice)." in
    Arg.(value & pos 0 string "" & info [] ~docv:"SVC" ~doc)
  in
  let run svc path =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw -> Cli.Restart.run ~sw ~env ~svc ?path ()
  in
  let info = Cmd.info "restart" ~doc:"Restart a service (or the slice)." in
  Cmd.v info Term.(const run $ svc_arg $ path_arg)

(* ---- default (no subcommand) ----------------------------------- *)

let default_cmd () =
  print_endline "pctl: a subcommand is required. Try: pctl up | reload | down | restart";
  1

let root =
  let info = Cmd.info "pctl" ~version ~doc:"declarative Nix spec -> systemd --user units" in
  Cmd.group info ~default:Term.(const default_cmd $ const ())
    [ up_cmd; reload_cmd; down_cmd; restart_cmd ]

let () = exit (Cmd.eval' root)
