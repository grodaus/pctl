(* e2e smoke — real systemd --user over sd-bus.
 *
 * READ-ONLY against the scratch's own manager: [unit_state] of units every
 * nested manager boots with, asserting only that each read returns one of
 * the Schema.state variants without raising. *)

module S = Systemctl

let valid_states =
  [
    Schema.Active; Schema.Inactive; Schema.Failed;
    Schema.Activating; Schema.Deactivating; Schema.Reloading;
  ]

let test_unit_state_reads_a_valid_variant () =
  Harness.with_scratch ~services:[] @@ fun _ ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let t = S.Dbus.connect ~sw env in
  List.iter
    (fun unit_name ->
      let s = S.Dbus.unit_state t ~unit:unit_name in
      Alcotest.(check bool)
        (Printf.sprintf "unit_state %s returns a valid Schema.state" unit_name)
        true (List.mem s valid_states))
    [ "dbus.service"; "basic.target"; "default.target" ];
  S.Dbus.close t

let () =
  Harness.skip_or_run ~name:"dbus smoke" @@ fun () ->
  (* ~and_exit:false — see [Harness.skip_or_run]. *)
  Alcotest.run ~and_exit:false "pctl dbus smoke"
    [
      ( "dbus",
        [
          Alcotest.test_case "unit_state returns a valid Schema.state"
            `Quick test_unit_state_reads_a_valid_variant;
        ] );
    ]
