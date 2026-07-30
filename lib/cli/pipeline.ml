(* Pipeline — the common-case materializer.
 *
 * See pipeline.mli for the invariant contract. This file owns the
 * orchestration for up/reload/down/restart/results.
 *
 * Shape:
 *   - Top-level: port-agnostic helpers (resolve_path, caqti_stdenv,
 *     with_connection, run). Exposed so the simpler commands
 *     (host / logs / status / ls / gc_cmd / init) can share them.
 *   - Make(P): the port-dependent commands — up, reload, down,
 *     restart, results — plus internal helpers that hold a
 *     Systemctl.t (with_handle, apply_plan, opportunistic_sweep, purge).
 *   - Prod: Make applied to production adapters (Dbus, Nix_build.Real,
 *     Clock.Real). Consumed directly by bin/pctl.ml. *)

module type NIX = Nix_build.S

module type CLOCK = Clock.S

module type PORTS = sig
  module Systemctl : Systemctl.S
  module Nix : NIX
  module Clock : CLOCK
end

(* ---- Port-agnostic helpers -------------------------------------- *)

let resolve_path (path : string option) : Schema.project_path =
  match path with
  | Some p when p <> "" -> Schema.Project_path.of_raw p
  | _ -> Schema.Project_path.of_raw (Sys.getcwd ())

let caqti_stdenv (env : Eio_unix.Stdenv.base) : Caqti_eio.stdenv =
  object
    method net = (env#net :> [ `Generic ] Eio.Net.ty Eio.Std.r)
    method clock = (env#clock :> float Eio.Time.clock_ty Eio.Std.r)
    method mono_clock = (env#mono_clock :> Eio.Time.Mono.ty Eio.Std.r)
  end

let with_connection ~env ~sw (f : State.Db.t -> 'a) : 'a =
  let stdenv = caqti_stdenv env in
  let conn = State.Db.connect ~sw ~stdenv () in
  State.Db.migrate conn;
  State.Session.reset conn;
  f conn

let run (f : unit -> unit) : int =
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

(* ---- Shared result-formatting helpers (results command) --------- *)

let worst_row (rows : Schema.result_row list) : Schema.result_row option =
  let rank : Schema.result_state -> int = function
    | `Active -> 0
    | `Timed_out -> 1
    | `Probe_failed -> 2
    | `Inactive -> 3
    | `Failed -> 4
  in
  List.fold_left
    (fun acc r ->
      match acc with
      | None when r.Schema.state = `Active -> None
      | None -> Some r
      | Some cur ->
          if rank r.Schema.state > rank cur.Schema.state then Some r
          else acc)
    None rows

let format_human (rows : Schema.result_row list) : string =
  let buf = Buffer.create 128 in
  List.iter
    (fun (r : Schema.result_row) ->
      let state = Schema.result_state_to_string r.Schema.state in
      let pad s w =
        let n = String.length s in
        if n >= w then s else s ^ String.make (w - n) ' '
      in
      Buffer.add_string buf
        (Printf.sprintf "%s  %s  %s\n" (pad state 12)
           (pad (Printf.sprintf "%Lins" r.Schema.elapsed) 10)
           r.Schema.name))
    rows;
  Buffer.contents buf

let format_json (rows : Schema.result_row list) : string =
  let j : Yojson.Safe.t =
    `List (List.map Schema.result_row_to_yojson rows)
  in
  Yojson.Safe.to_string j

(* ---- Registry reads used by with_project + host ----------------- *)

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

(* ---- Port-dependent commands ------------------------------------ *)

module Make (P : PORTS) = struct
  module Probe_P = Probe.Make (P.Systemctl)
  module Gc_P = Gc.Make (P.Systemctl)
  module Lifecycle_P = Lifecycle.Make (P.Systemctl) (Unit_store.Fs)

  (* Invariant 5: every Systemctl operation runs under a fresh handle
   * scoped to an inner Switch so the dispatch fiber (Dbus) has a
   * chance to drain before the outer switch releases. [close] is
   * called via Fun.protect so it runs on both success and failure. *)
  let with_handle ~env (f : P.Systemctl.t -> 'a) : 'a =
    Eio.Switch.run @@ fun inner_sw ->
    let h = P.Systemctl.connect ~sw:inner_sw env in
    Fun.protect
      ~finally:(fun () -> P.Systemctl.close h)
      (fun () -> f h)

  let opportunistic_sweep ~env ~conn =
    with_handle ~env (fun h ->
        Gc_P.opportunistic_sweep ~conn ~handle:h)

  let purge ~env ~conn : int =
    with_handle ~env (fun h -> Gc_P.purge ~conn ~handle:h)

  (* --- Internal: spec + identity + host + metadata upsert -------- *)

  (* Yields the resolved [ctx], the DB connection, the parsed spec, and
     a fresh [Unit_store.Fs.t] handle; Lifecycle then owns the
     render/write/diff/apply/persist sequence. *)
  let with_project ~sw ~env ?tree ?nix ?path
      (k :
        Lifecycle.ctx ->
        State.Db.t ->
        Schema.spec ->
        Unit_store.Fs.t ->
        'a) : 'a =
    let project = resolve_path path in
    let paths =
      Project_paths.resolve ~env ~sw
        ~nix:(module P.Nix : Project_paths.NIX)
        ?tree ?nix_attr:nix project
    in
    let spec = Spec.load paths.spec_file in
    let spec_blob = P.Nix.read_spec_blob paths.spec_file in
    let id = Identity.derive ~path:project in
    with_connection ~env ~sw @@ fun conn ->
    opportunistic_sweep ~env ~conn;
    let host =
      match existing_host conn ~id with
      | Some h -> h
      | None ->
          Identity.Host_alloc.allocate ~id ~taken:(taken_hosts conn)
    in
    let id_s = Schema.Project_id.to_string id in
    let project_path_s = Schema.Project_path.to_string project in
    let started_at =
      match existing_started_at conn ~id with
      | Some s when s <> "" -> s
      | _ -> P.Clock.now_iso8601 ()
    in
    let boot_id = P.Clock.read_boot_id () in
    State.Projects.upsert conn
      {
        id = id_s;
        path = project_path_s;
        host = Some (Schema.Host.to_string host);
        started_at = Some started_at;
        spec_file = Some (Fpath.to_string paths.spec_file);
        session_id = (if boot_id = "" then None else Some boot_id);
        spec_json = Some spec_blob;
      };
    let ctx : Lifecycle.ctx = { id; host; project_path = project } in
    let us = Unit_store.Fs.create () in
    k ctx conn spec us

  let with_registered ~sw ~env ?(sweep = false) ?path
      (k : State.Db.t -> Schema.project_id -> 'a) : 'a =
    let project = resolve_path path in
    let id = Identity.derive ~path:project in
    with_connection ~env ~sw @@ fun conn ->
    if sweep then opportunistic_sweep ~env ~conn;
    k conn id

  (* --- Commands -------------------------------------------------- *)

  let up ~sw ~env ?tree ?nix ?path ?(no_block = false) ?(wait = false)
      ?(timeout = 300) () : int =
    if no_block && wait then begin
      prerr_endline "pctl up: --no-block and --wait are mutually exclusive";
      2
    end
    else
      run @@ fun () ->
      with_project ~sw ~env ?tree ?nix ?path @@ fun ctx conn spec us ->
      let r =
        with_handle ~env (fun h ->
            Lifecycle_P.up ~conn ~handle:h ~unit_store:us ~ctx ~spec ())
      in
      let suffix = if no_block then " (async)" else "" in
      Printf.printf "project %s up · %d units · host=%s%s\n"
        (Schema.Project_id.to_string ctx.id)
        r.units_on_disk
        (Schema.Host.to_string ctx.host)
        suffix;
      if wait then
        with_handle ~env @@ fun h ->
        let _rows =
          Probe_P.wait_all ~sw ~env ~handle:h ~id:ctx.id ~host:ctx.host
            ~spec ~timeout_seconds:timeout ~strategy:`Throw_first
        in
        ()

  let reload ~sw ~env ?tree ?nix ?path () : int =
    run @@ fun () ->
    with_project ~sw ~env ?tree ?nix ?path @@ fun ctx conn spec us ->
    let r =
      with_handle ~env (fun h ->
          Lifecycle_P.reload ~conn ~handle:h ~unit_store:us ~ctx
            ~spec:(Some spec) ())
    in
    print_string (Plan.render_summary r.diff);
    print_endline (State.Projects.manifest_summary r.diff)

  let down ~sw ~env ?path ?(quiet = false) () : int =
    let work () =
      with_registered ~sw ~env ~sweep:true ?path @@ fun conn id ->
      let id_s = Schema.Project_id.to_string id in
      let existing = State.Projects.load_manifest conn ~project_id:id_s in
      if existing = [] then begin
        let project_path = Schema.Project_path.to_string (resolve_path path) in
        raise
          (Schema.Pctl_error
             (Schema.Registry_io
                {
                  id = id_s;
                  reason =
                    Printf.sprintf
                      "pctl down: no registered project with id '%s' at %s"
                      id_s project_path;
                }))
      end;
      (* A registered project with a non-empty manifest always has a
         host set (upsert writes both together). Fall through to
         Registry_io if the DB is inconsistent rather than fabricate
         a dummy value. *)
      let host =
        match existing_host conn ~id with
        | Some h -> h
        | None ->
            raise
              (Schema.Pctl_error
                 (Schema.Registry_io
                    {
                      id = id_s;
                      reason =
                        "project has a manifest row but no host — registry \
                         is inconsistent";
                    }))
      in
      let project = resolve_path path in
      let ctx : Lifecycle.ctx = { id; host; project_path = project } in
      let us = Unit_store.Fs.create () in
      let _r =
        with_handle ~env (fun h ->
            Lifecycle_P.down ~conn ~handle:h ~unit_store:us ~ctx ())
      in
      if not quiet then Printf.printf "project %s down\n" id_s
    in
    if quiet then
      try
        work ();
        0
      with _ -> 0
    else run work

  let restart ~sw ~env ~svc ?path () : int =
    run @@ fun () ->
    with_registered ~sw ~env ~sweep:true ?path @@ fun _conn id ->
    let unit_ =
      Schema.Unit_filename.to_string
        (if svc = "" then Schema.Unit_filename.slice ~id
         else Schema.Unit_filename.service ~id ~service:svc)
    in
    with_handle ~env (fun h -> P.Systemctl.restart_unit h ~unit:unit_);
    Printf.printf "restarted %s\n" unit_

  let spec_for_results (conn : State.Db.t) ~project_id_s : Schema.spec =
    match State.Projects.get_by_id conn ~id:project_id_s with
    | None | Some { spec_json = None | Some ""; _ } ->
        raise
          (Schema.Pctl_error
             (Schema.Registry_io
                {
                  id = project_id_s;
                  reason = "project is not registered — run `pctl up` first";
                }))
    | Some { spec_json = Some blob; _ } ->
        Spec.parse
          ~path:(project_id_s ^ ":spec_json")
          (Yojson.Safe.from_string blob)

  let results ~sw ~env ?path ?(timeout = 600) ?(json = false) () : int =
    run @@ fun () ->
    with_registered ~sw ~env ?path @@ fun conn id ->
    let id_s = Schema.Project_id.to_string id in
    let host =
      match State.Projects.get_by_id conn ~id:id_s with
      | Some { host = Some h; _ } -> (
          match Schema.Host.of_string_opt h with
          | Some h -> h
          | None ->
              raise
                (Schema.Pctl_error
                   (Schema.Registry_io
                      {
                        id = id_s;
                        reason =
                          Printf.sprintf
                            "project host '%s' is not a valid 127.0.0.N"
                            h;
                      })))
      | _ ->
          raise
            (Schema.Pctl_error
               (Schema.Registry_io
                  {
                    id = id_s;
                    reason =
                      "project is not registered — run `pctl up` first";
                  }))
    in
    let spec = spec_for_results conn ~project_id_s:id_s in
    let rows =
      with_handle ~env (fun h ->
          Probe_P.wait_all ~sw ~env ~handle:h ~id ~host ~spec
            ~timeout_seconds:timeout ~strategy:`Collect_all)
    in
    let out = if json then format_json rows ^ "\n" else format_human rows in
    print_string out;
    match
      Option.bind (worst_row rows)
        (Probe.error_of_row ~overall_timeout_seconds:timeout)
    with
    | None -> ()
    | Some e -> raise (Schema.Pctl_error e)
end

(* ---- Production wiring -------------------------------------------- *)

module Prod = Make (struct
  module Systemctl = Systemctl.Dbus
  module Nix = Nix_build.Real
  module Clock = Clock.Real
end)
