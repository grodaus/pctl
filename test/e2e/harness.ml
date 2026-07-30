(* e2e harness — tmpdir + spec.json fixture + XDG isolation + cleanup.
 *
 * Every e2e test uses a unique tmpdir so derive-id produces a unique
 * project id and slice, avoiding collisions with other tests or the
 * developer's real projects on the same session. We also point
 * XDG_STATE_HOME at a per-test tmpdir so each test has its own state.db.
 *
 * Gating: skip_reason () returns Some <why> when the host lacks
 * DBUS_SESSION_BUS_ADDRESS or a /run/user/<uid> dir — callers exit 0
 * with a SKIP: message in that case. *)

let skip_reason () : string option =
  match Sys.getenv_opt "DBUS_SESSION_BUS_ADDRESS" with
  | None -> Some "DBUS_SESSION_BUS_ADDRESS unset"
  | Some _ ->
      let uid = Unix.getuid () in
      let xdg_runtime = Printf.sprintf "/run/user/%d" uid in
      if not (Sys.file_exists xdg_runtime) then
        Some (Printf.sprintf "%s not present" xdg_runtime)
      else None

(* Make an absolute tmpdir. The caller is responsible for rm -rf.
 *
 * Base = /run/user/<uid>, NOT $TMPDIR. On CI, `dune build @e2e` runs
 * inside a nix-shell build sandbox whose $TMPDIR is a private per-
 * build directory; the systemd --user daemon runs OUTSIDE that
 * sandbox and cannot see it — so workspace services with
 * BindPaths=<tmpdir>/project fail with 226/NAMESPACE. /run/user/<uid>
 * is the user-scoped runtime dir (owned by the session's systemd
 * --user, always visible to it), guaranteed present by
 * [skip_reason] above. *)
let fresh_tmpdir prefix =
  let base = Printf.sprintf "/run/user/%d" (Unix.getuid ()) in
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

(* Write a spec.json fixture containing sleep-infinity services and a
 * trivial slice. `services` maps service name -> service_config list.
 * No `@@PROJECT@@` placeholders — spec.json v2 is pure logical data. *)
let sleep_bin = "/run/current-system/sw/bin/sleep"

let default_command () = [ sleep_bin; "infinity" ]
let default_service_config () = [ ("Type", "simple") ]

type probe_fixture = {
  exec : string list;
  period_seconds : int;
  timeout_seconds : int;
}

type service_fixture = {
  name : string;
  command : string list;  (* argv → ExecStart, rendered OCaml-side *)
  service_config : (string * string) list;
  workspace : (bool * bool) option;
      (* (cwd, writable) — None = default false/false *)
  probe : probe_fixture option;
  depends_on : string list;
}

let service ?(workspace = None) ?(command = default_command ())
    ?(cfg = default_service_config ()) ?(probe = None) ?(depends_on = []) name =
  { name; command; service_config = cfg; workspace; probe; depends_on }

(* Build spec.json JSON from a set of services. Uses Spec's derived
 * yojson so this can't drift from the loader's expectations. *)
let spec_json ~(services : service_fixture list) : string =
  let service_to_json (sf : service_fixture) : Spec.service_json =
    {
      kind = Schema.Simple;
      command = sf.command;
      service_config = sf.service_config;
      depends_on = sf.depends_on;
      workspace =
        (match sf.workspace with
         | None -> { cwd = false; writable = false }
         | Some (cwd, writable) -> { cwd; writable });
      probe =
        Option.map
          (fun (p : probe_fixture) : Spec.probe_json ->
            {
              exec = p.exec;
              period_seconds = p.period_seconds;
              timeout_seconds = p.timeout_seconds;
            })
          sf.probe;
    }
  in
  let services_obj =
    `Assoc
      (List.map
         (fun sf -> (sf.name, Spec.service_json_to_yojson (service_to_json sf)))
         services)
  in
  let slice : Spec.slice_json = { slice_config = [] } in
  `Assoc
    [
      ("services", services_obj);
      ("slice", Spec.slice_json_to_yojson slice);
      ("version", `Int 2);
    ]
  |> Yojson.Safe.to_string

type scratch = {
  tmp : string;
  project_dir : string;
  spec_path : string;
  xdg_state_home : string;
  xdg_state_home_prev : string option;
}

(* [setup_with] runs [build_services] AFTER the tmpdir + project_dir
 * exist, so tests that bake the real project_dir into their
 * ExecStart/env can do so. Plain [setup ~services] is the common case
 * where services are static. *)
let setup_with ~(build_services : scratch -> service_fixture list) : scratch =
  let tmp = fresh_tmpdir "pctl-e2e" in
  let project_dir = Filename.concat tmp "project" in
  Unix.mkdir project_dir 0o700;
  let spec_path = Filename.concat tmp "spec.json" in
  let xdg_state_home = Filename.concat tmp "state" in
  Unix.mkdir xdg_state_home 0o700;
  let prev = Sys.getenv_opt "XDG_STATE_HOME" in
  Unix.putenv "XDG_STATE_HOME" xdg_state_home;
  let scratch =
    { tmp; project_dir; spec_path; xdg_state_home; xdg_state_home_prev = prev }
  in
  let services = build_services scratch in
  let oc = open_out spec_path in
  output_string oc (spec_json ~services);
  close_out oc;
  scratch

let setup ~services : scratch = setup_with ~build_services:(fun _ -> services)

(* Project id for the scratch dir. *)
let project_id (s : scratch) : Schema.project_id =
  Identity.derive ~path:(Schema.Project_path.of_raw s.project_dir)

(* Unit filenames are concrete (pctl-<id>-<svc>.service); tests pass
 * them in directly. Path construction routes through [Unit_store.Fs]
 * so this harness never duplicates the user.control layout. Each
 * helper builds a fresh Fs handle — it reads XDG_RUNTIME_DIR on
 * creation, so tests that putenv before calling the helper see the
 * override. *)
let unit_path_on_disk ~unit_filename : string =
  Unit_store.Fs.unit_path (Unit_store.Fs.create ()) ~unit_filename

let dropin_path_on_disk ~unit_filename : string =
  Unit_store.Fs.dropin_file (Unit_store.Fs.create ()) ~unit_filename

let read_unit ~unit_filename : string option =
  let p = unit_path_on_disk ~unit_filename in
  if Sys.file_exists p then
    let ic = open_in p in
    Fun.protect
      ~finally:(fun () -> close_in ic)
      (fun () ->
        let n = in_channel_length ic in
        Some (really_input_string ic n))
  else None

let unit_exists ~unit_filename : bool =
  Sys.file_exists (unit_path_on_disk ~unit_filename)

let dropin_exists ~unit_filename : bool =
  Sys.file_exists (dropin_path_on_disk ~unit_filename)

let read_dropin ~unit_filename : string =
  let p = dropin_path_on_disk ~unit_filename in
  let ic = open_in p in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
      let n = in_channel_length ic in
      really_input_string ic n)

(* Best-effort teardown: calls Down.run, then rm -rf the tmpdir. Any
 * error from Down (already-down; manifest wiped) is swallowed — a
 * teardown must never block another test from running.
 *
 * Tombstone cleanup goes through Systemctl.Dbus: after Down.run has
 * removed the unit files, systemd may still hold a `failed` tombstone
 * on the test's service units or an idle parent slice. Clearing those
 * keeps leftovers from bleeding into the next test on the same session. *)
let teardown (s : scratch) =
  let id = try Some (project_id s) with _ -> None in
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          (try ignore (Cli.Pipeline.Prod.down ~sw ~env ~path:s.project_dir ~quiet:true ())
           with _ -> ());
          match id with
          | None -> ()
          | Some id ->
              let id_s = Schema.Project_id.to_string id in
              let slice = Printf.sprintf "pctl-%s.slice" id_s in
              let handle = Systemctl.Dbus.connect ~sw env in
              (try Systemctl.Dbus.reset_failed_unit handle ~unit:slice
               with _ -> ());
              (try Systemctl.Dbus.stop_unit handle ~unit:slice with _ -> ());
              Systemctl.Dbus.close handle));
  (* Restore XDG_STATE_HOME env if it was set before. *)
  (match s.xdg_state_home_prev with
   | Some v -> Unix.putenv "XDG_STATE_HOME" v
   | None -> Unix.putenv "XDG_STATE_HOME" "");
  rm_rf s.tmp

(* Run a shell command, return (stdout_bytes, exit_code). Caller
 * controls stderr (append "2>&1" to merge into the buffer,
 * "2>/dev/null" to drop). *)
let run_capture cmd =
  let ic = Unix.open_process_in cmd in
  let buf = Buffer.create 256 in
  (try
     while true do
       Buffer.add_string buf (input_line ic);
       Buffer.add_char buf '\n'
     done
   with End_of_file -> ());
  let status = Unix.close_process_in ic in
  let rc =
    match status with
    | Unix.WEXITED n -> n
    | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 128
  in
  (Buffer.contents buf, rc)

let systemctl_is_active unit_name =
  let out, _ =
    run_capture
      (Printf.sprintf "systemctl --user is-active %s 2>/dev/null"
         (Filename.quote unit_name))
  in
  String.trim out = "active"

let wait_active ?(timeout_s = 5.0) unit_name =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    if systemctl_is_active unit_name then true
    else if Unix.gettimeofday () > deadline then false
    else begin
      let _ = Unix.select [] [] [] 0.1 in
      loop ()
    end
  in
  loop ()

let is_active = systemctl_is_active

(* ActiveEnterTimestampMonotonic as a string; empty on error/no-such-unit. *)
let active_enter_ts unit_name =
  let out, _ =
    run_capture
      (Printf.sprintf
         "systemctl --user show %s -p ActiveEnterTimestampMonotonic --value \
          2>/dev/null"
         (Filename.quote unit_name))
  in
  String.trim out

(* Redirect a stdlib fd (stdout or stderr) into a temp file while [f]
 * runs; return [f]'s result plus the captured bytes. Used by all the
 * pctl-wrapper helpers so test failures can include pctl's own
 * printed context ("probe for service web timed out after 10000 ms",
 * "systemctl start failed: …") instead of just an exit code.
 *
 * fd_kind is [Unix.stdout] or [Unix.stderr]. The corresponding Stdlib
 * channel is flushed before and after to keep buffered output in the
 * capture. *)
let with_captured_fd ~(fd_kind : Unix.file_descr)
    ~(flush_channel : unit -> unit) (f : unit -> 'a) : 'a * string =
  let tmp = Filename.temp_file "pctl-e2e-capture" ".log" in
  let fd = Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let saved = Unix.dup fd_kind in
  flush_channel ();
  Unix.dup2 fd fd_kind;
  Unix.close fd;
  let restore () =
    flush_channel ();
    Unix.dup2 saved fd_kind;
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

let with_captured_stdout (f : unit -> 'a) : 'a * string =
  with_captured_fd ~fd_kind:Unix.stdout
    ~flush_channel:(fun () -> flush Stdlib.stdout) f

let with_captured_stderr (f : unit -> 'a) : 'a * string =
  with_captured_fd ~fd_kind:Unix.stderr
    ~flush_channel:(fun () -> flush Stdlib.stderr) f

(* pctl wrappers. Each returns (exit_code, pctl_stderr) — pctl.run
 * prints Pctl_error via prerr_endline, so capturing stderr lets
 * check_rc_zero surface the actual message, not just the rc bucket. *)

let run_up ?(wait = false) ?timeout ?(no_block = false) ~scratch ()
    : int * string =
  with_captured_stderr (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      Cli.Pipeline.Prod.up ~sw ~env ~tree:scratch.spec_path
        ~path:scratch.project_dir ~wait ~no_block ?timeout ())

let up ~scratch : int * string = run_up ~scratch ()
let up_wait ?(timeout = 30) ~scratch () = run_up ~wait:true ~timeout ~scratch ()
let up_no_block ~scratch = run_up ~no_block:true ~scratch ()

let results ?(timeout = 30) ?(json = false) ~scratch () : int * string =
  with_captured_stdout (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      Cli.Pipeline.Prod.results ~sw ~env ~path:scratch.project_dir ~timeout ~json ())

let host ~scratch : int * string =
  with_captured_stdout (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      Cli.Host.run ~sw ~env ~path:scratch.project_dir ())

let reload ~scratch : int * string =
  with_captured_stderr (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      Cli.Pipeline.Prod.reload ~sw ~env ~tree:scratch.spec_path
        ~path:scratch.project_dir ())

let down ~scratch : int * string =
  with_captured_stderr (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      Cli.Pipeline.Prod.down ~sw ~env ~path:scratch.project_dir ())

(* Helpers for logs / status / list / gc tests. *)

let logs ?(lines = 50) ~svc ~scratch () : int * string =
  with_captured_stdout (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      Cli.Logs.run ~sw ~env ~svc ~path:scratch.project_dir ~lines ())

let status ?(svc = "") ~scratch () : int =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Cli.Status.run ~sw ~env ~svc ~path:scratch.project_dir ()

let list ?(json = false) () : int * string =
  with_captured_stdout (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw -> Cli.Ls.run ~sw ~env ~json ())

let gc ?(yes = false) ?(json = false) () : int * string =
  with_captured_stdout (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw -> Cli.Gc_cmd.run ~sw ~env ~yes ~json ())

(* Test wrapper: setup -> body -> teardown (Fun.protect style). *)
let with_scratch ~services f =
  let s = setup ~services in
  Fun.protect
    ~finally:(fun () -> teardown s)
    (fun () -> f s)

(* Variant that lets the services be built from the scratch — used when
 * a service's ExecStart / BindPaths etc. must reference the concrete
 * project_dir (not knowable before setup). *)
let with_scratch_late build_services f =
  let s = setup_with ~build_services in
  Fun.protect
    ~finally:(fun () -> teardown s)
    (fun () -> f s)

(* ------------------------------------------------------------------ *)
(* Assertion helpers — collapse repetition in the 20 e2e test files.
 *
 * Each helper prints an "ASSERT" line on success so the human-readable
 * output still shows every checkpoint. Failure goes through
 * [Alcotest.failf] so test output matches prior behaviour. *)
(* ------------------------------------------------------------------ *)

let contains haystack needle =
  needle = ""
  ||
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

let skip_or_run ~name body =
  match skip_reason () with
  | Some why ->
      Printf.printf "SKIP: %s — %s\n" name why;
      exit 0
  | None -> body ()

let check_rc_zero ~label (rc, captured) =
  if rc <> 0 then
    Alcotest.failf "%s exit=%d\n---- pctl stderr ----\n%s" label rc
      (if captured = "" then "(empty)" else captured)

let assert_eq_int ~label expected got =
  Alcotest.(check int) label expected got

let assert_true ~label cond =
  Alcotest.(check bool) label true cond

let assert_false ~label cond =
  Alcotest.(check bool) label false cond

let assert_eq_string ~label expected got =
  Alcotest.(check string) label expected got

(* Diagnostic snapshot: the five fields that actually distinguish "not
 * active" causes (load-failed vs. crashed vs. still-activating vs.
 * sandbox-rejected), plus the last 30 journal lines. *)
let unit_diagnostic unit_name : string =
  let show, _ =
    run_capture
      (Printf.sprintf
         "systemctl --user show %s -p LoadState -p ActiveState -p SubState -p \
          Result -p ExecMainStatus -p ExecMainCode -p StatusErrno -p \
          InvocationID --no-pager 2>&1"
         (Filename.quote unit_name))
  in
  let jr, _ =
    run_capture
      (Printf.sprintf
         "journalctl --user --no-pager -n 30 --output=short-iso -u %s 2>&1"
         (Filename.quote unit_name))
  in
  Printf.sprintf "---- systemctl show %s ----\n%s---- journalctl -u %s (last 30) ----\n%s"
    unit_name show unit_name jr

let assert_unit_active unit_name =
  if not (wait_active unit_name) then
    Alcotest.failf
      "%s did not reach active within 5s\n%s" unit_name
      (unit_diagnostic unit_name)

let assert_unit_inactive unit_name =
  assert_false
    ~label:(Printf.sprintf "%s inactive" unit_name)
    (is_active unit_name)

let assert_unit_exists unit_filename =
  assert_true
    ~label:(Printf.sprintf "%s file exists" unit_filename)
    (unit_exists ~unit_filename)

let assert_unit_gone unit_filename =
  assert_false
    ~label:(Printf.sprintf "%s file gone" unit_filename)
    (unit_exists ~unit_filename)

let assert_dropin_gone unit_filename =
  assert_false
    ~label:(Printf.sprintf "%s dropin gone" unit_filename)
    (dropin_exists ~unit_filename)

let assert_contains ~label haystack needle =
  if not (contains haystack needle) then
    Alcotest.failf "%s: expected substring %S in %S" label needle haystack

let assert_not_contains ~label haystack needle =
  if contains haystack needle then
    Alcotest.failf "%s: unexpected substring %S in %S" label needle haystack

(* Name helpers — delegate to the canonical Schema derivations so tests
 * and production agree on the filename convention. *)
let slice_name id_s = Printf.sprintf "pctl-%s.slice" id_s
let service_name id_s svc = Printf.sprintf "pctl-%s-%s.service" id_s svc

let slice_filename_for ~(id : Schema.project_id) =
  Schema.Unit_filename.to_string (Schema.Unit_filename.slice ~id)

let service_filename_for ~(id : Schema.project_id) ~service_name =
  Schema.Unit_filename.to_string
    (Schema.Unit_filename.service ~id ~service:service_name)
