(* e2e reality: Dbus.subscribe_unit_changes delivers callbacks for real
 * PropertiesChanged signals on a systemd --user unit.
 *
 * Regression against: sd-bus match rules alone are NOT enough — systemd
 * only emits per-unit PropertiesChanged to clients that have called
 * [org.freedesktop.systemd1.Manager.Subscribe]. Without that call,
 * [subscribe_unit_changes] is a silent no-op whenever no other client
 * has independently subscribed on the same session (e.g. under
 * linger-only sessions, or sandboxed/dedicated test runs).
 *
 * Shape:
 *   1. Bring up a scratch project with one sleep service.
 *   2. Open a fresh Dbus handle.
 *   3. Subscribe to the service unit.
 *   4. Trigger a transition via [restart_unit] on the SAME handle.
 *   5. Wait up to 5s for the callback to fire at least once.
 *
 * Fails the test (not a timeout crash) when the deadline elapses with
 * zero callbacks — which is exactly the bug's signature. *)

let bash = "/run/current-system/sw/bin/bash"

let () =
  Harness.skip_or_run ~name:"test_dbus_subscribe" @@ fun () ->
  let web =
    {
      Harness.name = "web";
      probe = None;
      service_config =
        [
          ("Type", "simple");
          ( "ExecStart",
            Printf.sprintf
              "%s -c 'exec %s -c \"while true; do sleep 3600; done\"'"
              bash bash );
        ];
      workspace = None;
    }
  in
  Harness.with_scratch ~services:[ web ]
  @@ fun scratch ->
  Harness.check_rc_zero ~label:"up --wait"
    (Harness.up_wait ~scratch ~timeout:10 ());
  let id_s = Schema.Project_id.to_string (Harness.project_id scratch) in
  let unit_name = Harness.service_name id_s "web" in
  Harness.assert_true
    ~label:(Printf.sprintf "%s active before subscribe" unit_name)
    (Harness.is_active unit_name);
  (* We can't assert the exact Deactivating -> Inactive -> Activating ->
   * Active sequence: the dbus handler re-reads unit_state synchronously
   * on each PropertiesChanged, and fast transitions flip past the
   * intermediate states before our read happens. What Subscribe() is
   * responsible for is *signal volume*: a working subscription fires
   * many callbacks over a restart (one per property change on the
   * Unit/Service objects). On a session where Manager.Subscribe was
   * never called (the privileged runner, lingered-only sessions),
   * systemd drops most per-unit PropertiesChanged signals entirely, so
   * we only see a handful — well below the count a real restart emits.
   *
   * We assert two things:
   *   1. At least 8 callbacks fired. Measured baseline on a working
   *      session is 15-20; the broken path on the privileged runner
   *      was 2. An 8-callback floor has headroom either side.
   *   2. The final observed state is Active — the restart actually
   *      completed, so the unit itself is fine; only signalling was
   *      dropped. *)
  let min_fired = 8 in
  let observed = ref [] in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let handle = Systemctl.Dbus.connect ~sw env in
  let terminal_p, terminal_u = Eio.Promise.create () in
  let resolved = ref false in
  let cb (s : Schema.state) =
    observed := s :: !observed;
    if (not !resolved) && s = Schema.Active then begin
      resolved := true;
      Eio.Promise.resolve terminal_u ()
    end
  in
  Systemctl.Dbus.subscribe_unit_changes handle ~unit:unit_name cb;
  Systemctl.Dbus.restart_unit handle ~unit:unit_name;
  let clock = (env#clock :> float Eio.Time.clock_ty Eio.Std.r) in
  Eio.Fiber.first
    (fun () -> Eio.Promise.await terminal_p)
    (fun () -> Eio.Time.sleep clock 5.0);
  Systemctl.Dbus.close handle;
  let seen = List.rev !observed in
  let fired = List.length seen in
  let last = match !observed with s :: _ -> Some s | [] -> None in
  let fmt_states states =
    String.concat "; " (List.map Schema.state_to_string states)
  in
  if fired < min_fired then
    Alcotest.failf
      "subscribe_unit_changes delivered only %d/%d callbacks over a \
       full restart of %s\n\
       observed: [%s]\n\
       (a session without Manager.Subscribe drops most per-unit \
       PropertiesChanged signals; see lib/systemctl/dbus.ml)"
      fired min_fired unit_name (fmt_states seen);
  (match last with
   | Some Schema.Active -> ()
   | Some s ->
       Alcotest.failf
         "subscribe_unit_changes: last observed state for %s was %s, \
          expected active (restart did not complete or final signal \
          was dropped)\nobserved: [%s]"
         unit_name (Schema.state_to_string s) (fmt_states seen)
   | None ->
       Alcotest.failf
         "subscribe_unit_changes: zero callbacks for %s within 5s"
         unit_name);
  Printf.printf "test_dbus_subscribe OK (fired=%d, seen=[%s])\n"
    fired (fmt_states seen)
