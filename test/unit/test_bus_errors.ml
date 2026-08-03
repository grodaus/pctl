(* Bus_errors — the two classifiers that decide whether a failed bus call
 * is tolerated, retried, or propagated.
 *
 * Both match D-Bus error NAMES by equality. The property under test is
 * that no display string can move a verdict: the same failure rendered
 * differently, and a message that merely quotes a name, must classify the
 * same way as before. That is what the earlier prefix-on-[reply] test
 * could not state.
 *
 * THE RULE FOR THIS FILE: every wire name is written out as a literal
 * here, never taken from [Bus_errors]. This is the recording of the
 * vocabulary — feeding a constant into the predicate that compares against
 * it asserts only that equality works, and leaves a typo'd constant green.
 * Everywhere else in the repo references [Bus_errors]; the values
 * themselves are pinned here and nowhere else. *)

open Systemctl

let err ?error_name ?(reply = "") () =
  Schema.Unit_op_failed { op = "StopUnit"; unit_ = "x.service"; error_name; reply }

(* The tolerated reply, as the real adapter builds it: name from the
 * sd_bus_error struct, [reply] the rendered "name: message". Recorded
 * against systemd 260.1 — `dbus-send --session --print-reply
 * … Manager.StopUnit string:pctl-nosuch-xyz.service` answers
 * "org.freedesktop.systemd1.NoSuchUnit: Unit pctl-nosuch-xyz.service not
 * loaded." *)
let test_is_no_such_unit () =
  let check expect e =
    Alcotest.(check bool)
      (Schema.render_error e)
      expect
      (Bus_errors.is_no_such_unit e)
  in
  (* Literal, per the rule in this file's header. *)
  let no_such_unit = "org.freedesktop.systemd1.NoSuchUnit" in
  Alcotest.(check string)
    "Bus_errors.no_such_unit is the name systemd answers with"
    no_such_unit Bus_errors.no_such_unit;
  check true
    (err ~error_name:no_such_unit
       ~reply:(no_such_unit ^ ": Unit x.service not loaded.")
       ());
  (* Rendering is irrelevant to the verdict — same name, no message. *)
  check true
    (err ~error_name:no_such_unit ~reply:(no_such_unit ^ " (no message)") ());
  (* Equality, not prefix: nothing longer than the name is tolerated. *)
  check false (err ~error_name:"org.freedesktop.systemd1.NoSuchUnitXxx" ());
  check false (err ~error_name:"org.freedesktop.systemd1.JobTypeNotApplicable" ());
  check false (err ~error_name:"org.freedesktop.DBus.Error.NoReply" ());
  (* A message quoting the name cannot promote a different failure. *)
  check false
    (err ~error_name:"org.freedesktop.DBus.Error.Failed"
       ~reply:"org.freedesktop.systemd1.NoSuchUnit: Unit x.service not loaded."
       ());
  (* No name: a decode failure or the near-unreachable empty-struct
     reply. Not evidence the unit was absent, so not tolerated. *)
  check false
    (err ~reply:"StopUnit returned -104 (ECONNRESET: Connection reset by peer)"
       ());
  (* Only a unit op can carry a reply name; every other arm is a
     different failure and must never be tolerated as one. *)
  Alcotest.(check bool)
    "Bus_connect_failed is not no-such-unit" false
    (Bus_errors.is_no_such_unit
       (Schema.Bus_connect_failed
          { msg = "org.freedesktop.systemd1.NoSuchUnit: Unit x not loaded." }))

let test_is_peer_gone () =
  let check expect name =
    Alcotest.(check bool)
      (Printf.sprintf "is_peer_gone %s"
         (match name with None -> "<none>" | Some s -> s))
      expect (Bus_errors.is_peer_gone name)
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

(* The two classifiers must not both claim the same failure: [Lifecycle]
 * and [Gc] tolerate is_no_such_unit while [Dbus.daemon_reload] retries
 * is_peer_gone, and a name in both sets would be silently dropped by
 * whichever ran first. *)
let test_vocabularies_are_disjoint () =
  Alcotest.(check bool)
    "no_such_unit is not a peer-gone name" false
    (Bus_errors.is_peer_gone (Some Bus_errors.no_such_unit));
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (name ^ " is not no-such-unit")
        false
        (Bus_errors.is_no_such_unit (err ~error_name:name ())))
    Bus_errors.peer_gone_error_names

let () =
  Alcotest.run "bus_errors"
    [
      ( "classification",
        [
          Alcotest.test_case "is_no_such_unit matches the name exactly" `Quick
            test_is_no_such_unit;
          Alcotest.test_case "is_peer_gone matches the name exactly" `Quick
            test_is_peer_gone;
          Alcotest.test_case "the two vocabularies are disjoint" `Quick
            test_vocabularies_are_disjoint;
        ] );
    ]
