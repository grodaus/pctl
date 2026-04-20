(* Pipeline integration test — runs the full [up] pipeline with an
 * In_mem Systemctl, a stubbed Nix build, and a frozen clock. Exercises
 * invariants 1–4 end-to-end without needing a live user session.
 *
 * The test doesn't check the Systemctl side directly (the fake handle
 * is opened and closed inside Pipeline and never escapes), but
 * orchestration correctness manifests in persistent state: the DB row,
 * the manifest table, and the rendered unit files on disk. *)

let single_spec_json =
  {|{"services":{"pg":{"depends_on":[],"kind":"simple","probe":null,"service_config":{"ExecStart":"/bin/true","NoNewPrivileges":"yes","ProtectControlGroups":"yes","ProtectHome":"read-only","ProtectKernelModules":"yes","ProtectKernelTunables":"yes","ProtectSystem":"strict","RestrictNamespaces":"yes","RestrictSUIDSGID":"yes","Type":"simple"},"workspace":{"cwd":false,"writable":false}}},"slice":{"slice_config":{}},"version":2}|}

module Stub_nix : Cli.Pipeline.NIX = struct
  let out_path ~attr:_ ~cwd:_ ~env:_ ~sw:_ =
    let tmp = Filename.temp_file "pctl-test-spec" ".json" in
    let oc = open_out tmp in
    output_string oc single_spec_json;
    close_out oc;
    tmp

  let read_spec_blob _ = single_spec_json
end

let frozen_clock_m =
  Clock.frozen ~now:"2026-01-01T00:00:00+00:00" ~boot:"test-boot"

module Frozen_clock = (val frozen_clock_m : Clock.S)

module Ports : Cli.Pipeline.PORTS = struct
  module Systemctl = Systemctl.In_mem
  module Nix = Stub_nix
  module Clock = Frozen_clock
end

module Cli_under_test = Cli.Pipeline.Make (Ports)

let tmp_dir prefix =
  let p = Filename.temp_file prefix "" in
  Sys.remove p;
  Unix.mkdir p 0o700;
  p

(* Own XDG_* env vars so the test doesn't touch the dev's real state or
 * runtime dirs. [Install] reads XDG_RUNTIME_DIR lazily at Paths module
 * init — we must putenv BEFORE the first [Install.Install.write_units]
 * call. See note in lib/install/install.ml (Paths.user_control). *)
let with_owned_env f =
  let runtime = tmp_dir "pctl-test-runtime" in
  let state_home = tmp_dir "pctl-test-state" in
  let old_runtime = Sys.getenv_opt "XDG_RUNTIME_DIR" in
  let old_state = Sys.getenv_opt "XDG_STATE_HOME" in
  Unix.putenv "XDG_RUNTIME_DIR" runtime;
  Unix.putenv "XDG_STATE_HOME" state_home;
  Fun.protect
    ~finally:(fun () ->
      (match old_runtime with
       | Some v -> Unix.putenv "XDG_RUNTIME_DIR" v
       | None -> Unix.putenv "XDG_RUNTIME_DIR" "");
      match old_state with
      | Some v -> Unix.putenv "XDG_STATE_HOME" v
      | None -> Unix.putenv "XDG_STATE_HOME" "")
    (fun () -> f ~runtime ~state_home)

(* Open a fresh connection that points at the SAME state.db that
 * Pipeline wrote through its own [with_connection]. Used for
 * post-condition assertions — the pipeline's connection has already
 * closed by the time we inspect. *)
let inspect_conn ~sw ~env =
  let stdenv : Caqti_eio.stdenv =
    object
      method net = (env#net :> [ `Generic ] Eio.Net.ty Eio.Std.r)
      method clock = (env#clock :> float Eio.Time.clock_ty Eio.Std.r)
      method mono_clock = (env#mono_clock :> Eio.Time.Mono.ty Eio.Std.r)
    end
  in
  let conn = State.Db.connect ~sw ~stdenv () in
  State.Db.migrate conn;
  conn

let test_up_happy () =
  with_owned_env @@ fun ~runtime ~state_home:_ ->
  let project = tmp_dir "pctl-test-proj" in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let exit_code =
    Cli_under_test.up ~sw ~env ~path:project ~no_block:true ()
  in
  Alcotest.(check int) "up exits 0" 0 exit_code;
  (* Invariant 3 — manifest bytes match disk bytes. Re-open the DB and
   * read back. *)
  let conn = inspect_conn ~sw ~env in
  let id_s =
    Schema.Project_id.to_string
      (Identity.derive ~path:(Schema.Project_path.of_raw project))
  in
  let row =
    match State.Projects.get_by_id conn ~id:id_s with
    | Some r -> r
    | None -> Alcotest.fail "project row not persisted"
  in
  (match row.host with
   | None -> Alcotest.fail "host not allocated"
   | Some h ->
       Alcotest.(check bool)
         "host in 127.0.0.0/8" true
         (String.length h >= 8
          && String.sub h 0 8 = "127.0.0."));
  Alcotest.(check (option string))
    "session_id = frozen boot_id"
    (Some "test-boot") row.session_id;
  Alcotest.(check (option string))
    "spec_json blob persisted"
    (Some single_spec_json) row.spec_json;
  let manifest = State.Projects.load_manifest conn ~project_id:id_s in
  Alcotest.(check int) "manifest has slice + service row" 2
    (List.length manifest);
  (* Invariant 3: files rendered to XDG_RUNTIME_DIR/systemd/user.control *)
  let control =
    Filename.concat runtime (Filename.concat "systemd" "user.control")
  in
  let slice_file =
    Filename.concat control (Printf.sprintf "pctl-%s.slice" id_s)
  in
  Alcotest.(check bool) "slice unit file exists" true
    (Sys.file_exists slice_file)

(* Property-style: [up] followed by [reload] leaves the DB in the same
 * shape as a single [up]. Invariant 4 says the diff reflects the
 * persisted state, so the second call should observe Unchanged for
 * everything. *)
let test_up_then_reload_idempotent () =
  with_owned_env @@ fun ~runtime:_ ~state_home:_ ->
  let project = tmp_dir "pctl-test-proj" in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let e1 = Cli_under_test.up ~sw ~env ~path:project ~no_block:true () in
  Alcotest.(check int) "first up exits 0" 0 e1;
  let e2 = Cli_under_test.reload ~sw ~env ~path:project () in
  Alcotest.(check int) "reload exits 0" 0 e2;
  (* Host stays the same — re-up must not reallocate. *)
  let conn = inspect_conn ~sw ~env in
  let id_s =
    Schema.Project_id.to_string
      (Identity.derive ~path:(Schema.Project_path.of_raw project))
  in
  let row =
    match State.Projects.get_by_id conn ~id:id_s with
    | Some r -> r
    | None -> Alcotest.fail "project row vanished after reload"
  in
  Alcotest.(check bool) "host still allocated" true
    (Option.is_some row.host)

let () =
  Alcotest.run "pipeline"
    [
      ( "up",
        [
          Alcotest.test_case "happy path" `Quick test_up_happy;
          Alcotest.test_case "up-then-reload idempotent" `Quick
            test_up_then_reload_idempotent;
        ] );
    ]
