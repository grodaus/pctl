(* e2e — [Dbus.unit_state] never reports a running unit as Inactive, and a
 * peer-gone reply to its GetUnit reaches the caller.
 *
 * This is the guard the pctl-a7p / pctl-q2j batch shipped without. Those
 * tickets narrowed dbus.ml's tolerance from "any Pctl_error" to "only a
 * no-such-unit reply". The classifier (test/unit/test_bus_errors.ml) and
 * the fake (test/unit/test_systemctl_sig.ml) are covered; the adapter that
 * talks to systemd was not, at any layer. pctl-g9l demonstrated it:
 * reverting get_unit_path_opt to `with Schema.Pctl_error _ -> None` left
 * `dune test` AND the whole e2e suite green.
 *
 * Only real systemd can drive it. In_mem answers from a Hashtbl and never
 * issues the GetUnit whose reply is the thing being classified.
 *
 * The window is pctl-jbd's, scoped by pctl-xxf: every `systemctl --user
 * daemon-reexec` drops the manager's bus connection, and dbus-broker
 * answers calls in flight to it with org.freedesktop.DBus.Error.NoReply.
 * GetUnit is not retried, so a read landing in that window fails.
 *
 * TWO things are asserted, and the distinction is the whole point:
 *
 *   1. No read answers Inactive. The service is confirmed Active before
 *      the kicker runs and running units survive a reexec, so Active (or
 *      a raise) is the only truthful answer for the whole loop. Inactive
 *      is what the pre-narrowing code fabricated from a NoReply.
 *   2. At least one propagated failure came from GetUnit — the call whose
 *      reply [get_unit_path_opt] classifies. [unit_state] issues GetUnit
 *      and THEN Properties.Get(ActiveState); a fault on the second
 *      propagates whether or not the narrowing is correct, so counting
 *      propagations without splitting them by op would let a run report
 *      success having never exercised the branch. Measured: the first
 *      propagation of a run was Properties.Get in 2 of 3 runs.
 *
 * Assertion 2 cannot be made unconditional: which call a fault lands on is
 * timing, roughly even between the two. The kicker therefore keeps
 * reexecing until a GetUnit fault is seen (up to [max_reexecs]) and stops
 * as soon as one is, so the common case costs fewer reexecs than a fixed
 * count. If the cap is reached with none, the test prints the
 * [unexercised_prefix] line and exits 0 rather than failing on a coin
 * toss: scripts/e2e-repeat.sh counts those lines and fails a batch in
 * which no run exercised the branch.
 *
 * Measured on this host (systemd 260.1, dbus-broker 37):
 *   - 11 runs as written: all 11 green, all 11 exercised the GetUnit
 *     branch. Windows needed: 1,1,1,1,2,2,2,3,3,6,8 — median 2, and one
 *     run got there only on the 8th, i.e. the cap is not generous.
 *   - With the catch-all restored: 3/3 RED at this cap, 5/5 RED at a
 *     fixed 4 windows, reported as "observed N wrong state(s)".
 * Roughly half of all faults land on Properties.Get and are useless here,
 * which is why the run that needed 8 windows had 7 of them.
 *
 * A deterministic driver was looked for and does not exist: GetUnit
 * answers NoSuchUnit for every malformed name (checked on 260.1: embedded
 * space, missing suffix, slash, bare '@'), so the one reply an argument
 * can produce is the tolerated one.
 *
 * Scope: the OUTCOME (a bus fault is never laundered into a state), not
 * which names are tolerated — that is test_bus_errors.ml's job.
 *
 * Reexecs its own scratch's manager, up to [max_reexecs] times, so
 * nothing outside the scratch is disturbed — unlike
 * test_reload_survives_reexec; [Reexec]'s header has both. *)

module S = Systemctl

let bash = "/run/current-system/sw/bin/bash"

(* Windows to spend looking for a GetUnit fault. [request_stop] ends the
 * kicker on the first one, so in the measured runs this costs 1-3 windows
 * and only a tail run spends more; the number therefore trades nothing
 * against the typical case and only shrinks the UNEXERCISED tail. Set
 * above the worst observed run (8) for that reason. [Reexec.hard_cap_s]
 * derives from it, so raising it does not start tripping a fixed cap. *)
let max_reexecs = 16

(* Grepped by scripts/e2e-repeat.sh. Changing it changes that script. *)
let unexercised_prefix = "UNEXERCISED: "

(* [op] as the Dbus adapter labels its two calls — lib/systemctl/dbus.ml
 * raises Unit_op_failed with these. "GetUnit" is the classified one. *)
let getunit_op = "GetUnit"

let () =
  Harness.skip_or_run ~name:"test_unit_state_survives_reexec" @@ fun () ->
  let web =
    {
      Harness.name = "web";
      probe = None;
      command =
        [
          bash;
          "-c";
          Printf.sprintf "exec %s -c \"while true; do %s 3600; done\"" bash
            Harness.sleep_bin;
        ];
      service_config = [ ("Type", "simple") ];
      workspace = None;
      depends_on = [];
    }
  in
  Harness.with_scratch ~services:[ web ] @@ fun scratch ->
  Harness.check_rc_zero ~label:"up --wait"
    (Harness.up_wait ~scratch ~timeout:10 ());
  let id_s = Schema.Project_id.to_string (Harness.project_id scratch) in
  let unit_name = Harness.service_name id_s "web" in
  (* Asserted through systemctl, independently of the code under test: the
     invariant below is only meaningful if the unit really is up. *)
  Harness.assert_true
    ~label:(Printf.sprintf "%s active before the reexecs" unit_name)
    (Harness.is_active unit_name);
  let k = Reexec.make ~label:"unit-state-reexec" ~max_reexecs in
  Fun.protect ~finally:(fun () -> Reexec.clear k) @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let t = S.Dbus.connect ~sw env in
  (* Sanity check on the same handle the loop uses, before any reexec. *)
  (match S.Dbus.unit_state t ~unit:unit_name with
   | Schema.Active -> ()
   | other ->
       Alcotest.failf "unit_state said %s before any reexec, expected active"
         (Schema.state_to_string other));
  let wrong = ref [] in
  let propagated_by_op : (string, int) Hashtbl.t = Hashtbl.create 4 in
  let bump op =
    Hashtbl.replace propagated_by_op op
      (1 + Option.value (Hashtbl.find_opt propagated_by_op op) ~default:0)
  in
  let getunit_faults () =
    Option.value (Hashtbl.find_opt propagated_by_op getunit_op) ~default:0
  in
  let first_of_op = Hashtbl.create 4 in
  Reexec.start k;
  (* No sleep in this body — see [Reexec.poll_until_finished]. *)
  let reads, ended =
    Reexec.poll_until_finished k @@ fun () ->
    match S.Dbus.unit_state t ~unit:unit_name with
    | Schema.Active | Schema.Reloading -> ()
    | (Schema.Activating | Schema.Deactivating | Schema.Failed | Schema.Inactive)
      as observed ->
        (* Inactive is the laundered bus fault; the others would mean the
           unit really moved, which a reexec must not cause either. *)
        wrong := Schema.state_to_string observed :: !wrong
    | exception Schema.Pctl_error (Schema.Unit_op_failed { op; _ } as e) ->
        bump op;
        if not (Hashtbl.mem first_of_op op) then
          Hashtbl.add first_of_op op (Schema.render_error e);
        (* Got what we came for: let the kicker stop rather than spend
           wall clock on reexecs that add nothing. *)
        if op = getunit_op then Reexec.request_stop k
    | exception Schema.Pctl_error e ->
        Alcotest.failf "unexpected error shape from unit_state: %s"
          (Schema.render_error e)
  in
  (* Order is load-bearing, and [Reexec.settle]'s header says why: stop the
     kicker, wait for the manager, and only THEN raise anything. Every
     assertion below aborts the test straight into Harness.teardown, so a
     check that fires first reaps a manager still inside the window. The
     cap-fired path is both the likeliest to be unsettled and the one that
     reports a failure. *)
  Reexec.request_stop k;
  Reexec.settle ~probe:(fun () -> ignore (S.Dbus.unit_state t ~unit:unit_name));
  Reexec.check_not_capped k ended;
  Reexec.check_completed k;
  let confirmed = Reexec.confirmed k in
  let by_op =
    Hashtbl.fold (fun op n acc -> (op, n) :: acc) propagated_by_op []
    |> List.sort compare
    |> List.map (fun (op, n) -> Printf.sprintf "%s×%d" op n)
    |> String.concat ", "
  in
  let by_op = if by_op = "" then "none" else by_op in
  if !wrong <> [] then
    Alcotest.failf
      "observed %d wrong state(s) for a running unit across %d reads and %d \
       reexecs: %s — a bus fault was answered with a state instead of \
       propagating (pctl-a7p). Propagations: %s"
      (List.length !wrong) reads confirmed
      (String.concat ", " (List.rev !wrong))
      by_op;
  Hashtbl.iter
    (fun _ line -> Printf.eprintf "  (propagated, as designed: %s)\n%!" line)
    first_of_op;
  if getunit_faults () = 0 then
    (* Exits 0: see the header. The batch script is what gates on this. *)
    Printf.printf
      "%stest_unit_state_survives_reexec — %d reads across %d reexecs, no \
       fault landed on the classified %s read (propagations: %s). The \
       invariant held; the narrowing was not exercised.\n\
       %!"
      unexercised_prefix reads confirmed getunit_op by_op
  else
    Printf.printf
      "test_unit_state_survives_reexec OK — %d reads across %d reexecs, %d \
       propagated from %s, 0 wrong states (propagations: %s)\n\
       %!"
      reads confirmed (getunit_faults ()) getunit_op by_op
