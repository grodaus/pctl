(* e2e parity: pctl up installs units and reaches active state. *)

let () =
  Harness.skip_or_run ~name:"test_up" @@ fun () ->
  Harness.with_scratch
    ~services:[ Harness.service "web"; Harness.service "api" ]
  @@ fun scratch ->
  Harness.check_rc_zero ~label:"up" (Harness.up ~scratch);
  let id = Harness.project_id scratch in
  let id_s = Schema.Project_id.to_string id in
  Harness.assert_unit_exists (Harness.slice_filename_for ~id);
  Harness.assert_unit_exists (Harness.service_filename_for ~id ~service_name:"web");
  Harness.assert_unit_exists (Harness.service_filename_for ~id ~service_name:"api");
  (* Drop-ins: web's drop-in exposes PCTL_ID/PCTL_HOST. *)
  let web_dropin =
    Harness.read_dropin
      ~unit_filename:(Harness.service_filename_for ~id ~service_name:"web")
  in
  Harness.assert_contains ~label:"web dropin has PCTL_ID" web_dropin
    (Printf.sprintf "PCTL_ID=%s" id_s);
  Harness.assert_contains ~label:"web dropin has PCTL_HOST=127.0.0." web_dropin
    "PCTL_HOST=127.0.0.";
  (* Systemd state. *)
  Harness.assert_unit_active (Harness.slice_name id_s);
  Harness.assert_unit_active (Harness.service_name id_s "web");
  Harness.assert_unit_active (Harness.service_name id_s "api");
  print_endline "test_up OK"
