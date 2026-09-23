(* Unit_store — parity tests between [Fs] and [In_mem].
 *
 * [Lifecycle] (phase 3) instantiates over [Unit_store.S], so the two
 * adapters must agree on every observable behaviour: [list] ordering,
 * [remove] idempotency, drop-in ↔ main coupling on [write]/[remove].
 * If they drift, integration tests that pass against [In_mem] could
 * still fail against [Fs] in production. *)

let id = Schema.Project_id.of_string_exn "proj_test"

let slice_unit : Schema.Unit_filename.t = Schema.Unit_filename.slice ~id

let svc_a : Schema.Unit_filename.t =
  Schema.Unit_filename.service ~id ~service:"a"

let svc_b : Schema.Unit_filename.t =
  Schema.Unit_filename.service ~id ~service:"b"

(* Swap XDG_RUNTIME_DIR at the start of each Fs scenario so Fs writes
 * under a fresh tmpdir. Fs.create reads the env fresh every call. *)
let with_tmp_runtime (f : unit -> unit) : unit =
  let runtime = Filename.temp_file "pctl-us-fs" "" in
  Sys.remove runtime;
  Unix.mkdir runtime 0o700;
  let old = Sys.getenv_opt "XDG_RUNTIME_DIR" in
  Unix.putenv "XDG_RUNTIME_DIR" runtime;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some v -> Unix.putenv "XDG_RUNTIME_DIR" v
      | None -> Unix.putenv "XDG_RUNTIME_DIR" "")
    f

let sample_entry ~svc : Unit_store.entry =
  { main = Printf.sprintf "[Service]\nExecStart=/bin/true %s\n" svc;
    dropin = Some (Printf.sprintf "[Service]\nEnvironment=X=%s\n" svc) }

let slice_entry : Unit_store.entry =
  { main = "[Slice]\nMemoryMax=512M\n"; dropin = None }

(* Run one scenario against both adapters; parity asserts on the
 * observable surface ([list], behaviour of second [remove]). *)
let parity_scenario
    (op : write:(Schema.Unit_filename.t -> Unit_store.entry -> unit) ->
          remove:(Schema.Unit_filename.t -> unit) ->
          list:(unit -> Schema.Unit_filename.t list) ->
          'a)
    : 'a * 'a =
  let fs_result =
    let r = ref None in
    with_tmp_runtime (fun () ->
        let us = Unit_store.Fs.create () in
        r :=
          Some
            (op
               ~write:(fun u e -> Unit_store.Fs.write us ~unit_:u e)
               ~remove:(fun u -> Unit_store.Fs.remove us ~unit_:u)
               ~list:(fun () -> Unit_store.Fs.list us)));
    Option.get !r
  in
  let mem_result =
    let us = Unit_store.In_mem.create () in
    op
      ~write:(fun u e -> Unit_store.In_mem.write us ~unit_:u e)
      ~remove:(fun u -> Unit_store.In_mem.remove us ~unit_:u)
      ~list:(fun () -> Unit_store.In_mem.list us)
  in
  (fs_result, mem_result)

let uf_list = Alcotest.testable
    (fun ppf xs ->
      Format.fprintf ppf "[%s]"
        (String.concat "; "
           (List.map Schema.Unit_filename.to_string xs)))
    (fun a b ->
      List.length a = List.length b
      && List.for_all2 Schema.Unit_filename.equal a b)

let test_list_empty () =
  let fs, mem =
    parity_scenario (fun ~write:_ ~remove:_ ~list -> list ())
  in
  Alcotest.(check uf_list) "empty ⇒ []" [] fs;
  Alcotest.(check uf_list) "In_mem empty ⇒ []" [] mem

let test_list_sorted () =
  let fs, mem =
    parity_scenario (fun ~write ~remove:_ ~list ->
        write svc_b (sample_entry ~svc:"b");
        write slice_unit slice_entry;
        write svc_a (sample_entry ~svc:"a");
        list ())
  in
  Alcotest.(check uf_list)
    "Fs list sorted lex" [ svc_a; svc_b; slice_unit ] fs;
  Alcotest.(check uf_list)
    "In_mem list sorted lex" [ svc_a; svc_b; slice_unit ] mem

let test_remove_is_idempotent () =
  let fs, mem =
    parity_scenario (fun ~write ~remove ~list ->
        write svc_a (sample_entry ~svc:"a");
        remove svc_a;
        remove svc_a;
        list ())
  in
  Alcotest.(check uf_list) "Fs double-remove ⇒ []" [] fs;
  Alcotest.(check uf_list) "In_mem double-remove ⇒ []" [] mem

(* Fs-specific: dropin file lands under the *.d/ directory and [remove]
 * cleans it up. In_mem.inspect mirrors the entry in memory. *)
let test_fs_dropin_persisted_and_cleaned () =
  with_tmp_runtime (fun () ->
      let us = Unit_store.Fs.create () in
      Unit_store.Fs.write us ~unit_:svc_a (sample_entry ~svc:"a");
      let root = Unit_store.Fs.root us in
      let main_path = Filename.concat root (Schema.Unit_filename.to_string svc_a) in
      let dropin_path =
        Filename.concat (main_path ^ ".d") "pctl-runtime.conf"
      in
      Alcotest.(check bool) "main file exists" true (Sys.file_exists main_path);
      Alcotest.(check bool)
        "dropin file exists" true
        (Sys.file_exists dropin_path);
      Unit_store.Fs.remove us ~unit_:svc_a;
      Alcotest.(check bool)
        "main file removed" false
        (Sys.file_exists main_path);
      Alcotest.(check bool)
        "dropin file removed" false
        (Sys.file_exists dropin_path))

let dropin_dir_of us uf =
  Filename.concat (Unit_store.Fs.root us)
    (Schema.Unit_filename.to_string uf ^ ".d")

let test_fs_remove_dangling_symlink () =
  with_tmp_runtime (fun () ->
      let us = Unit_store.Fs.create () in
      Unit_store.Fs.write us ~unit_:svc_a (sample_entry ~svc:"a");
      let d = dropin_dir_of us svc_a in
      Unix.symlink "/nonexistent-pctl-target" (Filename.concat d "dangling");
      Unit_store.Fs.remove us ~unit_:svc_a;
      Alcotest.(check bool) "dropin dir removed" false (Sys.file_exists d))

let test_fs_remove_does_not_follow_dir_symlink () =
  with_tmp_runtime (fun () ->
      let us = Unit_store.Fs.create () in
      Unit_store.Fs.write us ~unit_:svc_a (sample_entry ~svc:"a");
      let outside = Filename.concat (Sys.getenv "XDG_RUNTIME_DIR") "outside" in
      Unix.mkdir outside 0o700;
      let kept = Filename.concat outside "kept" in
      Out_channel.with_open_bin kept (fun oc -> output_string oc "x");
      let d = dropin_dir_of us svc_a in
      Unix.symlink outside (Filename.concat d "link");
      Unit_store.Fs.remove us ~unit_:svc_a;
      Alcotest.(check bool) "dropin dir removed" false (Sys.file_exists d);
      Alcotest.(check bool) "link target untouched" true (Sys.file_exists kept))

(* root ignores directory permissions, so the injury below cannot fail. *)
let test_fs_remove_failure_is_loud () =
  if Unix.geteuid () = 0 then Alcotest.skip ();
  with_tmp_runtime (fun () ->
      let us = Unit_store.Fs.create () in
      Unit_store.Fs.write us ~unit_:svc_a (sample_entry ~svc:"a");
      let d = dropin_dir_of us svc_a in
      Unix.chmod d 0o500;
      let raised =
        Fun.protect
          ~finally:(fun () -> Unix.chmod d 0o700)
          (fun () ->
            try
              Unit_store.Fs.remove us ~unit_:svc_a;
              None
            with Schema.Pctl_error (Schema.Uninstall_failed { path; _ }) ->
              Some path)
      in
      Alcotest.(check (option string))
        "Uninstall_failed names the entry"
        (Some (Filename.concat d "pctl-runtime.conf"))
        raised)

let test_in_mem_inspect () =
  let us = Unit_store.In_mem.create () in
  let e : Unit_store.entry =
    { main = "main_bytes"; dropin = Some "dropin_bytes" }
  in
  Unit_store.In_mem.write us ~unit_:svc_a e;
  match Unit_store.In_mem.inspect us ~unit_:svc_a with
  | None -> Alcotest.fail "inspect returned None for a written unit"
  | Some got ->
      Alcotest.(check string) "main bytes round-tripped" "main_bytes" got.main;
      Alcotest.(check (option string))
        "dropin bytes round-tripped" (Some "dropin_bytes") got.dropin

let test_in_mem_fail_next_write () =
  let us = Unit_store.In_mem.create () in
  Unit_store.In_mem.fail_next_write us ~reason:"injected";
  let raised =
    try
      Unit_store.In_mem.write us ~unit_:svc_a (sample_entry ~svc:"a");
      false
    with Schema.Pctl_error (Schema.Install_failed { reason; _ })
      when reason = "injected" ->
      true
  in
  Alcotest.(check bool) "fail_next_write raised Install_failed" true raised;
  Alcotest.(check uf_list)
    "no partial write observable" []
    (Unit_store.In_mem.list us);
  (* Second write after failure must succeed (one-shot disarm). *)
  Unit_store.In_mem.write us ~unit_:svc_a (sample_entry ~svc:"a");
  Alcotest.(check uf_list)
    "second write lands" [ svc_a ]
    (Unit_store.In_mem.list us)

let () =
  Alcotest.run "unit_store"
    [
      ( "parity",
        [
          Alcotest.test_case "list empty" `Quick test_list_empty;
          Alcotest.test_case "list sorted" `Quick test_list_sorted;
          Alcotest.test_case "remove is idempotent" `Quick
            test_remove_is_idempotent;
        ] );
      ( "fs",
        [
          Alcotest.test_case "dropin lifecycle" `Quick
            test_fs_dropin_persisted_and_cleaned;
          Alcotest.test_case "remove unlinks a dangling symlink" `Quick
            test_fs_remove_dangling_symlink;
          Alcotest.test_case "remove does not follow a directory symlink"
            `Quick test_fs_remove_does_not_follow_dir_symlink;
          Alcotest.test_case "remove failure raises Uninstall_failed" `Quick
            test_fs_remove_failure_is_loud;
        ] );
      ( "in_mem",
        [
          Alcotest.test_case "inspect" `Quick test_in_mem_inspect;
          Alcotest.test_case "fail_next_write" `Quick
            test_in_mem_fail_next_write;
        ] );
    ]
