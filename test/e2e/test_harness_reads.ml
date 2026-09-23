(* e2e: the harness's systemctl reads fail when they reach no manager,
 * rather than answering "inactive" or "". *)

let raises_unanswered label f =
  match f () with
  | _ ->
      Alcotest.failf "%s answered with no manager behind the environment"
        label
  | exception e ->
      Harness.assert_contains ~label (Printexc.to_string e) "did not answer"

let () =
  Harness.skip_or_run ~name:"test_harness_reads" @@ fun () ->
  Harness.with_scratch ~services:[] @@ fun s ->
  let unit_name = "pctl-harness-reads-absent.service" in
  Harness.assert_false ~label:"absent unit reads inactive"
    (Harness.is_active unit_name);
  Harness.assert_eq_string ~label:"absent unit LoadState" "not-found"
    (Harness.load_state unit_name);
  let empty = Harness.fresh_tmpdir "pctl-e2e-noman" in
  Fun.protect
    ~finally:(fun () ->
      Harness.rm_rf empty;
      Harness.activate s)
    (fun () ->
      print_endline "---- the three 'did not answer' reports below are expected ----";
      Unix.putenv "XDG_RUNTIME_DIR" empty;
      Unix.putenv "DBUS_SESSION_BUS_ADDRESS"
        ("unix:path=" ^ Filename.concat empty "bus");
      raises_unanswered "wait_inactive" (fun () ->
          Harness.wait_inactive unit_name);
      raises_unanswered "load_state" (fun () -> Harness.load_state unit_name);
      raises_unanswered "active_enter_ts" (fun () ->
          Harness.active_enter_ts unit_name));
  print_endline "test_harness_reads OK"
