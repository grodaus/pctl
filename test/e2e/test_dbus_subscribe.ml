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
  let fired = ref 0 in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let handle = Systemctl.Dbus.connect ~sw env in
  let p, u = Eio.Promise.create () in
  let resolved = ref false in
  let cb (_s : Schema.state) =
    incr fired;
    if not !resolved then begin
      resolved := true;
      Eio.Promise.resolve u ()
    end
  in
  Systemctl.Dbus.subscribe_unit_changes handle ~unit:unit_name cb;
  (* Trigger transitions on the same bus connection we just subscribed on.
   * restart on an Active unit produces a Deactivating -> Inactive ->
   * Activating -> Active sequence; any one of them fires the callback. *)
  Systemctl.Dbus.restart_unit handle ~unit:unit_name;
  let clock = (env#clock :> float Eio.Time.clock_ty Eio.Std.r) in
  Eio.Fiber.first
    (fun () -> Eio.Promise.await p)
    (fun () -> Eio.Time.sleep clock 5.0);
  Systemctl.Dbus.close handle;
  if !fired = 0 then
    Alcotest.failf
      "subscribe_unit_changes: zero callbacks after restart_unit %s (5s \
       deadline elapsed)"
      unit_name;
  Printf.printf "test_dbus_subscribe OK (fired=%d)\n" !fired
