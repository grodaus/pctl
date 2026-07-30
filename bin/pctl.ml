(* pctl — declarative Nix spec -> systemd --user units.
 *
 * Cmdliner entry: dispatches to the per-command runners in `Cli`.
 * Each command opens its own Eio environment + Switch; Systemctl.Dbus
 * is the default handle. Errors flow through Cli.Pipeline.run. *)

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
      "Skip the readiness wait and return immediately after the systemd \
       start calls. Appends '(async)' to the status line. Cannot be \
       combined with --wait."
    in
    Arg.(value & flag & info [ "no-block" ] ~doc)
  in
  let wait =
    let doc =
      "Block until every service is ready (readinessProbe exits 0 or the \
       unit reaches active), bounded by --timeout. Cannot be combined \
       with --no-block."
    in
    Arg.(value & flag & info [ "wait" ] ~doc)
  in
  let timeout =
    let doc =
      "Overall --wait readiness timeout in seconds (shared across every \
       service)."
    in
    Arg.(value & opt int 300 & info [ "timeout" ] ~docv:"SECS" ~doc)
  in
  let run path tree nix no_block wait timeout =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    Cli.Pipeline.Prod.up ~sw ~env ?tree ~nix ?path ~no_block ~wait ~timeout ()
  in
  let info = Cmd.info "up" ~doc:"Build, install units, start the slice." in
  Cmd.v info Term.(const run $ path_arg $ tree_arg $ nix_arg $ no_block $ wait $ timeout)

(* ---- reload ---------------------------------------------------- *)

let reload_cmd =
  let run path tree nix =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    Cli.Pipeline.Prod.reload ~sw ~env ?tree ~nix ?path ()
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
    Eio.Switch.run @@ fun sw -> Cli.Pipeline.Prod.down ~sw ~env ?path ()
  in
  let info = Cmd.info "down" ~doc:"Stop the slice, uninstall units." in
  Cmd.v info Term.(const run $ path_arg)

(* ---- results --------------------------------------------------- *)

let results_cmd =
  let timeout =
    let doc = "Overall readiness timeout in seconds." in
    Arg.(value & opt int 600 & info [ "timeout" ] ~docv:"SECS" ~doc)
  in
  let json =
    let doc = "Emit JSON list of result records." in
    Arg.(value & flag & info [ "json" ] ~doc)
  in
  let run path timeout json =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    Cli.Pipeline.Prod.results ~sw ~env ?path ~timeout ~json ()
  in
  let info =
    Cmd.info "results"
      ~doc:"Block until every service is terminal, then report outcomes."
  in
  Cmd.v info Term.(const run $ path_arg $ timeout $ json)

(* ---- host ------------------------------------------------------ *)

let host_cmd =
  let run path =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw -> Cli.Host.run ~sw ~env ?path ()
  in
  let info =
    Cmd.info "host"
      ~doc:"Print the project's allocated 127.0.0.N on stdout."
  in
  Cmd.v info Term.(const run $ path_arg)

(* ---- restart --------------------------------------------------- *)

let restart_cmd =
  let svc_arg =
    let doc = "Service name to restart (empty = restart the whole slice)." in
    Arg.(value & pos 0 string "" & info [] ~docv:"SVC" ~doc)
  in
  let run svc path =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw -> Cli.Pipeline.Prod.restart ~sw ~env ~svc ?path ()
  in
  let info = Cmd.info "restart" ~doc:"Restart a service (or the slice)." in
  Cmd.v info Term.(const run $ svc_arg $ path_arg)

(* ---- logs ------------------------------------------------------ *)

let logs_cmd =
  let svc_arg =
    let doc = "Service name (empty = the whole slice)." in
    Arg.(value & pos 0 string "" & info [] ~docv:"SVC" ~doc)
  in
  let lines_arg =
    let doc = "Number of journal entries to show (default 100)." in
    Arg.(value & opt int 100 & info [ "n"; "lines" ] ~docv:"N" ~doc)
  in
  let follow_arg =
    let doc = "Tail the journal in follow mode (journalctl -f)." in
    Arg.(value & flag & info [ "f"; "follow" ] ~doc)
  in
  let run svc lines follow path =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    Cli.Logs.run ~sw ~env ~svc ?path ~follow ~lines ()
  in
  let info = Cmd.info "logs" ~doc:"Tail the journal for the project (or one service)." in
  Cmd.v info Term.(const run $ svc_arg $ lines_arg $ follow_arg $ path_arg)

(* ---- status ---------------------------------------------------- *)

let status_cmd =
  let svc_arg =
    let doc = "Service name (empty = the whole slice)." in
    Arg.(value & pos 0 string "" & info [] ~docv:"SVC" ~doc)
  in
  let run svc path =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    Cli.Status.run ~sw ~env ~svc ?path ()
  in
  let info = Cmd.info "status" ~doc:"Show systemctl status for the slice (or one service)." in
  Cmd.v info Term.(const run $ svc_arg $ path_arg)

(* ---- list / ls ------------------------------------------------- *)

let mk_list_cmd info =
  let json_arg = Arg.(value & flag & info [ "json" ] ~doc:"Emit JSON.") in
  let run json =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw -> Cli.Ls.run ~sw ~env ~json ()
  in
  Cmd.v info Term.(const run $ json_arg)

let list_cmd =
  mk_list_cmd
    (Cmd.info "list" ~doc:"List every registered project with its class.")

let ls_cmd = mk_list_cmd (Cmd.info "ls" ~doc:"Alias for `list`.")

(* ---- init ------------------------------------------------------ *)

let init_cmd =
  let force_arg =
    let doc = "Overwrite an existing flake.nix." in
    Arg.(value & flag & info [ "force" ] ~doc)
  in
  let run force = Cli.Init.run ~force () in
  let info =
    Cmd.info "init"
      ~doc:"Scaffold flake.nix + .gitignore in the current directory."
  in
  Cmd.v info Term.(const run $ force_arg)

(* ---- gc -------------------------------------------------------- *)

let gc_cmd =
  let yes_arg =
    let doc = "Delete every non-Live project (not just report)." in
    Arg.(value & flag & info [ "yes" ] ~doc)
  in
  let json_arg =
    Arg.(value & flag & info [ "json" ] ~doc:"Emit JSON.")
  in
  let run yes json =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    Cli.Gc_cmd.run ~sw ~env ~yes ~json ()
  in
  let info =
    Cmd.info "gc"
      ~doc:
        "Report (default) or delete (--yes) non-Live project registry \
         entries. Respects PCTL_NO_GC=1."
  in
  Cmd.v info Term.(const run $ yes_arg $ json_arg)

(* ---- default (no subcommand) ----------------------------------- *)

let default_cmd () =
  print_endline
    "pctl: a subcommand is required. Try: pctl up | reload | down | \
     restart | results | host | logs | status | list | init | gc";
  1

let root =
  let info = Cmd.info "pctl" ~version ~doc:"declarative Nix spec -> systemd --user units" in
  Cmd.group info ~default:Term.(const default_cmd $ const ())
    [
      up_cmd; reload_cmd; down_cmd; restart_cmd; results_cmd; host_cmd;
      logs_cmd; status_cmd; list_cmd; ls_cmd; init_cmd; gc_cmd;
    ]

let () = exit (Cmd.eval' root)
