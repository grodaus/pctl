(* Bus_retry — the retry policy that keeps a Manager.Reload alive across
 * a `systemctl --user daemon-reexec`.
 *
 * The policy has two halves and both are tested here:
 *   - [is_peer_gone], which classifies a D-Bus error NAME (never a
 *     display string);
 *   - [with_retry], whose budget is wall-clock rather than an attempt
 *     count, because a retryable attempt has no fixed cost — see
 *     [Bus_retry]'s header. *)

open Systemctl

(* Deterministic monotonic clock. [sleep] is the only thing the policy
 * can use to advance it; [advance] lets an attempt charge itself the
 * time it "took", which is how the slow-failure case is expressed. *)
let mk_clock () =
  let ns = ref 0L in
  let slept = ref [] in
  let advance d = ns := Int64.add !ns (Int64.of_float (d *. 1e9)) in
  let now () = Mtime.of_uint64_ns !ns in
  let sleep d =
    slept := d :: !slept;
    advance d
  in
  (now, sleep, (fun () -> List.rev !slept), advance)

let no_reply = "org.freedesktop.DBus.Error.NoReply"
let budget = 1.0
let delay = 0.25

let run ~now ~sleep ~retry_on f =
  Bus_retry.with_retry ~now ~sleep ~budget ~delay ~retry_on f

let retry_on_name = Bus_retry.is_peer_gone

let float_list = Alcotest.(list (float 0.0001))
let result_s = Alcotest.(result string (option string))

let test_success_does_not_sleep () =
  let now, sleep, slept, _ = mk_clock () in
  let calls = ref 0 in
  let r =
    run ~now ~sleep ~retry_on:retry_on_name (fun () ->
        incr calls;
        Ok "reloaded")
  in
  Alcotest.check result_s "returns the value" (Ok "reloaded") r;
  Alcotest.(check int) "called once" 1 !calls;
  Alcotest.check float_list "never slept" [] (slept ())

let test_retries_peer_gone_until_success () =
  let now, sleep, slept, _ = mk_clock () in
  let calls = ref 0 in
  let r =
    run ~now ~sleep ~retry_on:retry_on_name (fun () ->
        incr calls;
        if !calls < 3 then Error (Some no_reply) else Ok "reloaded")
  in
  Alcotest.check result_s "recovers" (Ok "reloaded") r;
  Alcotest.(check int) "three attempts" 3 !calls;
  Alcotest.check float_list "one delay per retry" [ delay; delay ]
    (slept ())

let test_does_not_retry_other_errors () =
  let now, sleep, slept, _ = mk_clock () in
  let calls = ref 0 in
  let no_such_unit = Some "org.freedesktop.systemd1.NoSuchUnit" in
  let r =
    run ~now ~sleep ~retry_on:retry_on_name (fun () ->
        incr calls;
        Error no_such_unit)
  in
  Alcotest.check result_s "propagates" (Error no_such_unit) r;
  Alcotest.(check int) "no retry" 1 !calls;
  Alcotest.check float_list "never slept" [] (slept ())

let test_gives_up_when_budget_exhausted () =
  let now, sleep, slept, _ = mk_clock () in
  let calls = ref 0 in
  let r =
    run ~now ~sleep ~retry_on:retry_on_name (fun () ->
        incr calls;
        Error (Some no_reply))
  in
  Alcotest.check result_s "last error wins" (Error (Some no_reply)) r;
  (* budget 1.0 / delay 0.25 → sleeps at t=0, .25, .5, .75; the sleep
   * that would land on t=1.25 does not fit, so attempt 5 is the last. *)
  Alcotest.(check int) "five attempts" 5 !calls;
  Alcotest.check float_list "four delays"
    [ delay; delay; delay; delay ]
    (slept ())

(* What "elapsed time, not attempt count" buys: an attempt that itself
 * consumes the whole window is not retried. An attempt count would
 * have kept going, however long the attempt had taken. *)
let test_slow_failure_is_not_retried () =
  let now, sleep, slept, advance = mk_clock () in
  let calls = ref 0 in
  let r =
    run ~now ~sleep ~retry_on:retry_on_name (fun () ->
        incr calls;
        advance 25.0;
        Error (Some no_reply))
  in
  Alcotest.check result_s "propagates" (Error (Some no_reply)) r;
  Alcotest.(check int) "no retry" 1 !calls;
  Alcotest.check float_list "never slept" [] (slept ())

(* Names are matched exactly, not by prefix: the classifier must not be
 * coupled to how the reply is later rendered for humans. *)
let test_is_peer_gone_classification () =
  let check expect name =
    Alcotest.(check bool)
      (Printf.sprintf "is_peer_gone %s"
         (match name with None -> "<none>" | Some s -> s))
      expect (Bus_retry.is_peer_gone name)
  in
  check true (Some "org.freedesktop.DBus.Error.NoReply");
  check true (Some "org.freedesktop.DBus.Error.ServiceUnknown");
  check true (Some "org.freedesktop.DBus.Error.NameHasNoOwner");
  check false (Some "org.freedesktop.systemd1.NoSuchUnit");
  check false (Some "org.freedesktop.DBus.Error.AccessDenied");
  check false (Some "org.freedesktop.DBus.Error.NoReplyXxx");
  (* Names our own dead socket, not an absent peer — see
   * [peer_gone_error_names]. *)
  check false (Some "org.freedesktop.DBus.Error.Disconnected");
  (* The shape a transport failure actually takes: sd_bus_error_set_errno
   * names it rather than leaving the struct empty. *)
  check false (Some "System.Error.ENOTCONN");
  check false (Some "org.freedesktop.DBus.Error.Failed");
  (* Effectively unreachable through sd_bus_call_method; covered so the
   * total match stays honest. *)
  check false None

let () =
  Alcotest.run "bus_retry"
    [
      ( "with_retry",
        [
          Alcotest.test_case "success does not sleep" `Quick
            test_success_does_not_sleep;
          Alcotest.test_case "retries peer-gone until success" `Quick
            test_retries_peer_gone_until_success;
          Alcotest.test_case "other errors propagate immediately" `Quick
            test_does_not_retry_other_errors;
          Alcotest.test_case "gives up when the budget is exhausted"
            `Quick test_gives_up_when_budget_exhausted;
          Alcotest.test_case "a slow failure is not retried" `Quick
            test_slow_failure_is_not_retried;
        ] );
      ( "is_peer_gone",
        [
          Alcotest.test_case "classifies by exact error name" `Quick
            test_is_peer_gone_classification;
        ] );
    ]
