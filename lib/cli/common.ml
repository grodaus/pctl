(* Common — shared CLI plumbing used by up/reload/down/restart.
 *
 * - [resolve_path]      : ?path:string -> absolute path (default: cwd)
 * - [spec_path]         : resolve the spec.json path by running nix build
 *                         or honouring --tree.
 * - [with_connection]   : open Db, run migrations, run session-reset, run
 *                         user function, close.
 *
 * `--tree` semantic difference from Nushell:
 *   Nushell: --tree is a directory of pre-rendered .slice/.service files.
 *   OCaml:   --tree is a path to a spec.json file (since Render runs from
 *            spec, not from byte-pre-rendered trees). Documented in
 *            bin/pctl.ml's cmdliner help text.
 *
 * `--nix ATTR` default: ".#pctl" (matches Nushell). *)

let resolve_path (path : string option) : string =
  match path with
  | Some p when p <> "" -> Identity.path_expand p
  | _ -> Sys.getcwd () |> Identity.path_expand

(* Resolve a spec.json path. If `tree` is set, treat it as the spec path
 * (it must be a file readable by [Spec.load]); otherwise run nix build
 * and use the resulting out-path. *)
let spec_path ?tree ?(nix = ".#pctl") ~env ~sw ~project_path () : string =
  match tree with
  | Some t when t <> "" -> Identity.path_expand t
  | _ ->
      Nix_build.print_out_paths ~attr:nix ~path:project_path ~env ~sw ()

(* Caqti_eio uses a narrow stdenv record (net/clock/mono_clock). Build
 * one from the Eio_main env — same coercion the integration tests use. *)
let caqti_stdenv env : Caqti_eio.stdenv =
  object
    method net = (env#net :> [ `Generic ] Eio.Net.ty Eio.Std.r)
    method clock = (env#clock :> float Eio.Time.clock_ty Eio.Std.r)
    method mono_clock = (env#mono_clock :> Eio.Time.Mono.ty Eio.Std.r)
  end

(* SQLite connection dance: open, migrate, session-reset, hand off. *)
let with_connection ~env ~sw (f : State.Db.t -> 'a) : 'a =
  let stdenv = caqti_stdenv env in
  let conn = State.Db.connect ~sw ~stdenv () in
  State.Db.migrate conn;
  State.Session.reset conn;
  f conn
(* Note: the connection closes when the switch releases. *)

(* Best-effort read of a project's existing host, so re-up can reuse it
 * (per up_idempotent_test behaviour). *)
let existing_host (conn : State.Db.t) ~id : Schema.host option =
  match State.Projects.get_by_id conn ~id:(Schema.Project_id.to_string id) with
  | None -> None
  | Some row -> (
      match row.host with
      | None -> None
      | Some s -> Schema.Host.of_string_opt s)

let existing_started_at (conn : State.Db.t) ~id : string option =
  match State.Projects.get_by_id conn ~id:(Schema.Project_id.to_string id) with
  | None -> None
  | Some row -> row.started_at

let taken_hosts (conn : State.Db.t) : Schema.host list =
  State.Projects.all conn
  |> List.filter_map (fun (r : State.Projects.t) ->
         match r.host with
         | Some h -> Schema.Host.of_string_opt h
         | None -> None)

let iso8601_now () : string =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d+00:00" (tm.tm_year + 1900)
    (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

let read_boot_id () : string =
  try
    let ic = open_in "/proc/sys/kernel/random/boot_id" in
    Fun.protect
      ~finally:(fun () -> close_in ic)
      (fun () -> String.trim (input_line ic))
  with _ -> ""

(* Thin error runner: wrap a thunk, convert Pctl_error -> (prints, exit code).
 * Uncaught exceptions get exit 1 + a generic message. *)
let run_with_errors (f : unit -> unit) : int =
  try
    f ();
    0
  with
  | Schema.Pctl_error e ->
      prerr_endline (Schema.render_error e);
      Schema.error_exit_code e
  | e ->
      Printf.eprintf "pctl: unexpected error: %s\n" (Printexc.to_string e);
      1

(* ------------------------------------------------------------------ *)
(* Systemctl dispatch — pluggable production/fake swap.
 *
 * Production uses [Real_dbus] (the real sd-bus binding). Tests CAN swap
 * in a [Fake_in_mem] handle via [set_in_mem_systemctl] to exercise
 * CLI commands without talking to real systemd.
 *
 * NOTE: the in-mem seam is defined but not currently wired from any
 * test — e2e tests run against real systemd, and unit tests hit the
 * [In_mem] module directly. The seam is retained because consolidating
 * choice-dispatch across commands needs a single source of truth
 * regardless, and keeping the option open costs only a few lines. *)
(* ------------------------------------------------------------------ *)

module Plan_dbus = Plan.Make (Systemctl.Dbus)
module Plan_in_mem = Plan.Make (Systemctl.In_mem)
module Probe_dbus = Probe.Make (Systemctl.Dbus)
module Probe_in_mem = Probe.Make (Systemctl.In_mem)
module Gc_dbus = Gc.Make (Systemctl.Dbus)
module Gc_in_mem = Gc.Make (Systemctl.In_mem)

type systemctl_choice =
  | Real_dbus
  | Fake_in_mem of Systemctl.In_mem.t

let systemctl_choice = ref Real_dbus
let set_in_mem_systemctl t = systemctl_choice := Fake_in_mem t
let reset_systemctl () = systemctl_choice := Real_dbus

let apply_plan ~env ~sw ~rows =
  match !systemctl_choice with
  | Real_dbus ->
      let t = Systemctl.Dbus.connect ~sw env in
      Plan_dbus.apply ~handle:t ~rows
  | Fake_in_mem t -> Plan_in_mem.apply ~handle:t ~rows

let opportunistic_sweep ~env ~sw ~conn =
  match !systemctl_choice with
  | Real_dbus ->
      let t = Systemctl.Dbus.connect ~sw env in
      Gc_dbus.opportunistic_sweep ~conn ~handle:t
  | Fake_in_mem t -> Gc_in_mem.opportunistic_sweep ~conn ~handle:t

let purge ~env ~sw ~conn : int =
  match !systemctl_choice with
  | Real_dbus ->
      let t = Systemctl.Dbus.connect ~sw env in
      Gc_dbus.purge ~conn ~handle:t
  | Fake_in_mem t -> Gc_in_mem.purge ~conn ~handle:t
