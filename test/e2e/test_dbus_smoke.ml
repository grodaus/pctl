(* e2e smoke — real systemd --user over sd-bus.
 *
 * Gated: runs only when DBUS_SESSION_BUS_ADDRESS is set AND the
 * per-uid runtime dir exists. On sandboxed or non-session hosts the
 * test prints a clear skip reason and exits 0 — the dev runner and CI
 * both treat that as "not applicable", not as a pass without
 * verification.
 *
 * READ-ONLY: the smoke test calls [unit_state] against a known unit
 * (we pick `dbus.service` because it is typically present on any
 * user session; we do NOT assert a specific value — only that the
 * call returns one of the six Schema.state variants without raising).
 *
 * Explicitly does NOT call start_unit/stop_unit/restart_unit against
 * any real unit: too risky. Reads only. *)

module S = Systemctl

let valid_states =
  [
    Schema.Active; Schema.Inactive; Schema.Failed;
    Schema.Activating; Schema.Deactivating; Schema.Reloading;
  ]

let test_unit_state_reads_a_valid_variant () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let t = S.Dbus.connect ~sw env in
  (* Pick a unit guaranteed to exist in a live user session. `dbus.service`
   * is one such; fall back to `basic.target` which is a systemd-native
   * target every session has. *)
  let candidates = [ "dbus.service"; "basic.target"; "default.target" ] in
  let any_read = ref false in
  List.iter
    (fun unit_name ->
      match
        try Some (S.Dbus.unit_state t ~unit:unit_name)
        with Schema.Pctl_error _ -> None
      with
      | None -> ()
      | Some s ->
          any_read := true;
          Alcotest.(check bool)
            (Printf.sprintf "unit_state %s returns a valid Schema.state"
               unit_name)
            true
            (List.mem s valid_states))
    candidates;
  Alcotest.(check bool)
    "at least one of the candidate units returned a state" true !any_read

let () =
  Harness.skip_or_run ~name:"dbus smoke" @@ fun () ->
  Alcotest.run "pctl dbus smoke"
    [
      ( "dbus",
        [
          Alcotest.test_case "unit_state returns a valid Schema.state"
            `Quick test_unit_state_reads_a_valid_variant;
        ] );
    ]
