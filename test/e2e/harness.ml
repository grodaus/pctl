(* e2e harness — tmpdir + spec.json fixture + XDG isolation + cleanup.
 *
 * Every e2e test uses a unique tmpdir so derive-id produces a unique
 * project id and slice, avoiding collisions with other tests or the
 * developer's real projects on the same session. We also point
 * XDG_STATE_HOME at a per-test tmpdir so each test has its own state.db.
 *
 * Gating: skip_reason () returns Some <why> when the host lacks
 * DBUS_SESSION_BUS_ADDRESS or a /run/user/<uid> dir — callers exit 0
 * with a SKIP: message in that case. Matches the Phase-3 smoke test. *)

let skip_reason () : string option =
  match Sys.getenv_opt "DBUS_SESSION_BUS_ADDRESS" with
  | None -> Some "DBUS_SESSION_BUS_ADDRESS unset"
  | Some _ ->
      let uid = Unix.getuid () in
      let xdg_runtime = Printf.sprintf "/run/user/%d" uid in
      if not (Sys.file_exists xdg_runtime) then
        Some (Printf.sprintf "%s not present" xdg_runtime)
      else None

(* Make an absolute tmpdir. The caller is responsible for rm -rf. *)
let fresh_tmpdir prefix =
  let base = try Sys.getenv "TMPDIR" with Not_found -> "/tmp" in
  let rec loop i =
    let candidate =
      Filename.concat base
        (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) i)
    in
    if Sys.file_exists candidate then loop (i + 1)
    else begin
      Unix.mkdir candidate 0o700;
      candidate
    end
  in
  loop 0

let rec rm_rf p =
  if not (Sys.file_exists p) then ()
  else if Sys.is_directory p then begin
    let entries = try Sys.readdir p with Sys_error _ -> [||] in
    Array.iter (fun n -> rm_rf (Filename.concat p n)) entries;
    try Unix.rmdir p with Unix.Unix_error _ | Sys_error _ -> ()
  end
  else try Sys.remove p with Sys_error _ -> ()

(* Write a spec.json fixture containing a single sleep-infinity service,
 * a trivial slice, and optional `extra_services` keyed by name with
 * pre-built service_config records. `services` maps
 * service name -> list of (key, value) pairs for service_config. *)
let sleep_bin = "/run/current-system/sw/bin/sleep"

let default_service_config () =
  [
    ("Type", "simple");
    ("ExecStart", Printf.sprintf "%s infinity" sleep_bin);
    ("Slice", "pctl-@@PROJECT@@.slice");
  ]

type probe_fixture = {
  exec : string list;
  period_seconds : int;
  timeout_seconds : int;
}

type service_fixture = {
  name : string;
  service_config : (string * string) list;
  workspace : (bool * bool) option;
      (* (cwd, writable) — None = default false/false *)
  probe : probe_fixture option;
}

let service ?(workspace = None) ?(cfg = default_service_config ())
    ?(probe = None) name =
  { name; service_config = cfg; workspace; probe }

(* Build spec.json JSON from a set of services. `slice_config` is
 * optional and almost always empty for tests. *)
let spec_json ~(services : service_fixture list) : string =
  let escape s =
    (* Minimal JSON escape — only the characters we actually care about. *)
    let buf = Buffer.create (String.length s + 8) in
    String.iter
      (fun c ->
        match c with
        | '"' -> Buffer.add_string buf "\\\""
        | '\\' -> Buffer.add_string buf "\\\\"
        | '\n' -> Buffer.add_string buf "\\n"
        | '\r' -> Buffer.add_string buf "\\r"
        | '\t' -> Buffer.add_string buf "\\t"
        | c -> Buffer.add_char buf c)
      s;
    Buffer.contents buf
  in
  let kv_to_json (k, v) =
    Printf.sprintf "\"%s\":\"%s\"" (escape k) (escape v)
  in
  let service_json (sf : service_fixture) =
    let sc =
      String.concat "," (List.map kv_to_json sf.service_config)
    in
    let ws =
      match sf.workspace with
      | None -> "{\"cwd\":false,\"writable\":false}"
      | Some (cwd, w) ->
          Printf.sprintf "{\"cwd\":%b,\"writable\":%b}" cwd w
    in
    let probe_s =
      match sf.probe with
      | None -> "null"
      | Some p ->
          let items =
            String.concat ","
              (List.map (fun s -> Printf.sprintf "\"%s\"" (escape s)) p.exec)
          in
          Printf.sprintf
            "{\"exec\":[%s],\"period_seconds\":%d,\"timeout_seconds\":%d}"
            items p.period_seconds p.timeout_seconds
    in
    Printf.sprintf
      "\"%s\":{\"depends_on\":[],\"kind\":\"simple\",\"probe\":%s,\"service_config\":{%s},\"unit_filename\":\"pctl-@@PROJECT@@-%s.service\",\"workspace\":%s}"
      sf.name probe_s sc sf.name ws
  in
  let services_block =
    String.concat "," (List.map service_json services)
  in
  Printf.sprintf
    "{\"services\":{%s},\"slice\":{\"slice_config\":{},\"unit_filename\":\"pctl-@@PROJECT@@.slice\"},\"version\":1}"
    services_block

type scratch = {
  tmp : string;
  project_dir : string;
  spec_path : string;
  xdg_state_home : string;
  xdg_state_home_prev : string option;
}

let setup ~services : scratch =
  let tmp = fresh_tmpdir "pctl-e2e" in
  let project_dir = Filename.concat tmp "project" in
  Unix.mkdir project_dir 0o700;
  let spec_path = Filename.concat tmp "spec.json" in
  let oc = open_out spec_path in
  output_string oc (spec_json ~services);
  close_out oc;
  let xdg_state_home = Filename.concat tmp "state" in
  Unix.mkdir xdg_state_home 0o700;
  let prev = Sys.getenv_opt "XDG_STATE_HOME" in
  Unix.putenv "XDG_STATE_HOME" xdg_state_home;
  (* Also isolate PCTL_STATE_DB so Db.default_path sees us. *)
  Unix.putenv "PCTL_STATE_DB"
    (Filename.concat xdg_state_home "pctl-state.db");
  { tmp; project_dir; spec_path; xdg_state_home; xdg_state_home_prev = prev }

(* Project id for the scratch dir. *)
let project_id (s : scratch) : Schema.project_id =
  Identity.derive ~path:s.project_dir

(* Read a unit file from user.control. Returns None if missing. *)
let read_unit ~(id : Schema.project_id) ~unit_filename : string option =
  let p =
    Install.Paths.service_path ~id ~unit_filename
  in
  if Sys.file_exists p then
    let ic = open_in p in
    Fun.protect
      ~finally:(fun () -> close_in ic)
      (fun () ->
        let n = in_channel_length ic in
        Some (really_input_string ic n))
  else None

let unit_exists ~(id : Schema.project_id) ~unit_filename : bool =
  Sys.file_exists
    (Install.Paths.service_path ~id ~unit_filename)

let dropin_exists ~(id : Schema.project_id) ~unit_filename : bool =
  Sys.file_exists
    (Install.Paths.dropin_file ~id ~unit_filename)

let read_dropin ~(id : Schema.project_id) ~unit_filename : string =
  let p = Install.Paths.dropin_file ~id ~unit_filename in
  let ic = open_in p in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
      let n = in_channel_length ic in
      really_input_string ic n)

(* Best-effort teardown: calls Down.run, then rm -rf the tmpdir. Any
 * error from Down (already-down; manifest wiped) is swallowed — a
 * teardown must never block another test from running. *)
let teardown (s : scratch) =
  (try
     Eio_main.run @@ fun env ->
     Eio.Switch.run @@ fun sw ->
     let prev_stderr = Unix.dup Unix.stderr in
     let devnull = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
     Unix.dup2 devnull Unix.stderr;
     Unix.close devnull;
     (try ignore (Cli.Down.run ~sw ~env ~path:s.project_dir ())
      with _ -> ());
     Unix.dup2 prev_stderr Unix.stderr;
     Unix.close prev_stderr
   with _ -> ());
  (* Restore XDG_STATE_HOME env if it was set before. *)
  (match s.xdg_state_home_prev with
   | Some v -> Unix.putenv "XDG_STATE_HOME" v
   | None -> Unix.putenv "XDG_STATE_HOME" "");
  rm_rf s.tmp

(* Wait for a unit to reach "active" via systemctl --user is-active. *)
let wait_active ?(timeout_s = 5.0) unit_name =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    let ic = Unix.open_process_in (Printf.sprintf "systemctl --user is-active %s 2>/dev/null" (Filename.quote unit_name)) in
    let s =
      try String.trim (input_line ic) with End_of_file -> ""
    in
    let _ = Unix.close_process_in ic in
    if s = "active" then true
    else if Unix.gettimeofday () > deadline then false
    else begin
      let _ = Unix.select [] [] [] 0.1 in
      loop ()
    end
  in
  loop ()

let is_active unit_name =
  let ic = Unix.open_process_in (Printf.sprintf "systemctl --user is-active %s 2>/dev/null" (Filename.quote unit_name)) in
  let s = try String.trim (input_line ic) with End_of_file -> "" in
  let _ = Unix.close_process_in ic in
  s = "active"

(* Get unit's ActiveEnterTimestampMonotonic (as a string). Empty on
 * error/no-such-unit. *)
let active_enter_ts unit_name =
  let ic =
    Unix.open_process_in
      (Printf.sprintf
         "systemctl --user show %s -p ActiveEnterTimestampMonotonic --value 2>/dev/null"
         (Filename.quote unit_name))
  in
  let s = try String.trim (input_line ic) with End_of_file -> "" in
  let _ = Unix.close_process_in ic in
  s

(* Run `Cli.Up.run` against a scratch setup. Returns the exit code. *)
let up ~scratch =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Cli.Up.run ~sw ~env ~tree:scratch.spec_path ~path:scratch.project_dir ()

let up_wait ?(timeout = 30) ~scratch () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Cli.Up.run ~sw ~env ~tree:scratch.spec_path ~path:scratch.project_dir
    ~wait:true ~timeout ()

let up_no_block ~scratch =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Cli.Up.run ~sw ~env ~tree:scratch.spec_path ~path:scratch.project_dir
    ~no_block:true ()

(* Results/host — capture stdout so tests can inspect JSON / the printed
 * host line. Both reuse the project path baked into [scratch]. *)

let with_captured_stdout (f : unit -> 'a) : 'a * string =
  let tmp = Filename.temp_file "pctl-e2e-stdout" ".log" in
  let fd = Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let saved = Unix.dup Unix.stdout in
  flush Stdlib.stdout;
  Unix.dup2 fd Unix.stdout;
  Unix.close fd;
  let restore () =
    flush Stdlib.stdout;
    Unix.dup2 saved Unix.stdout;
    Unix.close saved
  in
  let result =
    try
      let r = f () in
      restore ();
      r
    with e ->
      restore ();
      raise e
  in
  let ic = open_in tmp in
  let n = in_channel_length ic in
  let captured = really_input_string ic n in
  close_in ic;
  (try Sys.remove tmp with _ -> ());
  (result, captured)

let results ?(timeout = 30) ?(json = false) ~scratch () : int * string =
  with_captured_stdout (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      Cli.Results.run ~sw ~env ~path:scratch.project_dir ~timeout ~json ())

let host ~scratch : int * string =
  with_captured_stdout (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      Cli.Host.run ~sw ~env ~path:scratch.project_dir ())

let reload ~scratch =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Cli.Reload.run ~sw ~env ~tree:scratch.spec_path ~path:scratch.project_dir ()

let down ~scratch =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Cli.Down.run ~sw ~env ~path:scratch.project_dir ()

(* Test wrapper: setup -> body -> teardown (Fun.protect style). *)
let with_scratch ~services f =
  let s = setup ~services in
  Fun.protect
    ~finally:(fun () -> teardown s)
    (fun () -> f s)
