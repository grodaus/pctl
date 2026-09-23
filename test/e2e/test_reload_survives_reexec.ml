(* e2e — a Manager.Reload in flight survives `systemctl --user
 * daemon-reexec`.
 *
 * This is the reproducer for pctl-jbd. [Bus_retry]'s header has the
 * causal story; what matters here is that before that retry existed,
 * a concurrent reexec surfaced as pctl exit 5 and failed whichever
 * e2e test happened to be running.
 *
 * Verified RED by flipping Bus_retry.peer_gone_budget to 0.0 (the
 * pre-fix behaviour) on this host (systemd 260, dbus-broker 37): one
 * reload failed per reexec, each `NoReply: Remote peer disconnected`.
 * The reload count is whatever fits in the time the kicker takes and
 * so varies with load (11-14 observed); the failure count does not.
 *
 * Scope: this asserts the OUTCOME (a concurrent reexec does not fail a
 * reload), not the mechanism. The retry policy itself — which names
 * count as peer-gone, and why the budget is elapsed time — is unit
 * tested in test/unit/test_bus_retry.ml.
 *
 * The kicker, the marker protocol and the monotonic cap live in
 * [Reexec], shared with test_unit_state_survives_reexec. This test never
 * calls [Reexec.request_stop]: every window it gets is another chance to
 * catch a reload failing, and there is no point at which it has seen
 * enough.
 *
 * REEXECS THE DEVELOPER'S USER MANAGER. That is the same operation
 * every `nixos-rebuild switch` performs: running units are preserved
 * across it. *)

module S = Systemctl

let reexec_count = 2

(* Counts are printed after [Alcotest.run] returns — alcotest captures
 * a test case's stdout into _build, so anything printed inside the
 * body never reaches the terminal. That needs [~and_exit:false] below;
 * the default [run] exits the process itself and the print is dead
 * code. *)
let reloads = ref 0

(* Set from the kicker's tally file, not from [reexec_count] — the
 * summary calls these "confirmed", so they have to be counted. *)
let reexecs_confirmed = ref 0

let test_reload_survives_reexec () =
  let k = Reexec.make ~label:"reload-reexec" ~max_reexecs:reexec_count in
  Fun.protect ~finally:(fun () -> Reexec.clear k) @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let t = S.Dbus.connect ~sw env in
  let failures = ref [] in
  Reexec.start k;
  let iterations, ended =
    Reexec.poll_until_finished k (fun () ->
        try S.Dbus.daemon_reload t
        with Schema.Pctl_error e ->
          failures := Schema.render_error e :: !failures)
  in
  reloads := iterations;
  (* Settle before asserting, same ordering rule as
     test_unit_state_survives_reexec — see [Reexec.settle].
     [Dbus.daemon_reload] is the wrong probe here even though it is this
     test's subject: its peer-gone retry means it succeeds while the manager
     is still away, so it cannot tell that the session is back. init.scope
     is the user manager's own scope, always loaded, and the read is
     unretried. *)
  Reexec.request_stop k;
  Reexec.settle ~probe:(fun () -> ignore (S.Dbus.unit_state t ~unit:"init.scope"));
  Reexec.check_not_capped k ended;
  Reexec.check_completed k;
  let confirmed = Reexec.confirmed k in
  (* Belt and braces: [check_completed] says the shell reached the end,
     the tally says how many reexecs actually returned 0. *)
  Alcotest.(check int) "reexecs confirmed" reexec_count confirmed;
  reexecs_confirmed := confirmed;
  if !failures <> [] then
    Alcotest.failf "%d of %d reloads failed across %d reexecs:\n%s"
      (List.length !failures) !reloads confirmed
      (String.concat "\n" (List.rev !failures))

let () =
  Harness.skip_or_run ~name:"reload survives reexec" @@ fun () ->
  (* ~and_exit:false so the summary below runs — see also
   * [Harness.skip_or_run]. *)
  Alcotest.run ~and_exit:false "pctl reload survives reexec"
    [
      ( "daemon_reload",
        [
          Alcotest.test_case "concurrent daemon-reexec does not fail a reload"
            `Slow test_reload_survives_reexec;
        ] );
    ];
  Printf.printf
    "\ntest_reload_survives_reexec OK — %d reloads across %d confirmed \
     reexecs, 0 failures\n\
     %!"
    !reloads !reexecs_confirmed
