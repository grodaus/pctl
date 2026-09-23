(* e2e parity for tests/e2e/results_test.nu.
 *
 * Three services in one project cover three terminal states:
 *   - ok:   oneshot + RemainAfterExit=yes, ExecStart=true   -> active
 *   - fail: oneshot + RemainAfterExit=yes, ExecStart=false  -> failed
 *   - slow: Type=simple, ExecStart sleeps then loops        -> active via unit-state
 *
 * `pctl results` must wait for every service to reach a terminal state
 * and print one row per service, even when one fails. Exit non-zero
 * because of the failing service, but all three must appear. *)

let bash = "/run/current-system/sw/bin/bash"
let true_bin = "/run/current-system/sw/bin/true"
let false_bin = "/run/current-system/sw/bin/false"

let oneshot name command =
  {
    Harness.name;
    probe = None;
    command;
    service_config = [ ("Type", "oneshot"); ("RemainAfterExit", "yes") ];
    workspace = None;
    depends_on = [];
  }

let simple name command =
  {
    Harness.name;
    probe = None;
    command;
    service_config = [ ("Type", "simple") ];
    workspace = None;
    depends_on = [];
  }

let () =
  Harness.skip_or_run ~name:"test_results" @@ fun () ->
  (* Mixed-outcome scenario. *)
  Harness.with_scratch
     ~services:
       [
         oneshot "ok" [ true_bin ];
         oneshot "fail" [ false_bin ];
         simple "slow"
           [
             bash;
             "-c";
             Printf.sprintf
               "%s 0.5; exec %s -c \"while true; do %s 3600; done\""
               Harness.sleep_bin bash Harness.sleep_bin;
           ];
       ]
   @@ fun scratch ->
   (* pctl up --no-block so `fail` doesn't short-circuit the apply pass
      inside Lifecycle.reload. *)
   let _ = Harness.up_no_block ~scratch in
   let t0 = Unix.gettimeofday () in
   let rc, out = Harness.results ~scratch ~timeout:10 () in
   let elapsed = Unix.gettimeofday () -. t0 in
   if rc = 0 then
     Alcotest.failf
       "expected results to exit non-zero for mixed outcome, got rc=%d stdout=%s"
       rc out;
   if elapsed > 8.0 then
     Alcotest.failf "results took too long (%.2fs > 8s)" elapsed;
   Harness.assert_contains ~label:"stdout has 'ok'" out "ok";
   Harness.assert_contains ~label:"stdout has 'fail'" out "fail";
   Harness.assert_contains ~label:"stdout has 'slow'" out "slow";
   Harness.assert_contains ~label:"stdout mentions 'failed'" out "failed";
   Printf.printf "test_results OK (plain text, %.2fs)\n" elapsed;
   (* --json variant: parse and verify shape. *)
   let rc_j, out_j = Harness.results ~scratch ~timeout:10 ~json:true () in
   if rc_j = 0 then
     Alcotest.failf "expected --json results to exit non-zero, got rc=%d" rc_j;
   let j =
     try Yojson.Safe.from_string (String.trim out_j)
     with _ -> Alcotest.failf "results --json not valid JSON: %s" out_j
   in
   let items =
     match j with
     | `List xs -> xs
     | _ -> Alcotest.failf "results --json is not a JSON array: %s" out_j
   in
   Harness.assert_eq_int ~label:"3 json rows" 3 (List.length items);
   List.iter
     (fun item ->
       match Schema.result_row_of_yojson item with
       | Ok _ -> ()
       | Error msg ->
           Alcotest.failf "result_row parse failed: %s in %s" msg
             (Yojson.Safe.to_string item))
     items;
   let names =
     List.map
       (fun item ->
         match item with
         | `Assoc fs -> (
             match List.assoc_opt "name" fs with
             | Some (`String s) -> s
             | _ -> "")
         | _ -> "")
       items
   in
   let sorted = List.sort String.compare names in
   if sorted <> [ "fail"; "ok"; "slow" ] then
     Alcotest.failf "unexpected names: [%s]" (String.concat "; " sorted);
   let fail_state =
     List.find_map
       (fun item ->
         match item with
         | `Assoc fs -> (
             match List.assoc_opt "name" fs with
             | Some (`String "fail") -> (
                 match List.assoc_opt "state" fs with
                 | Some (`String s) -> Some s
                 | _ -> None)
             | _ -> None)
         | _ -> None)
       items
   in
   (match fail_state with
    | Some "failed" -> ()
    | other ->
        Alcotest.failf "fail state should be 'failed', got %s"
          (Option.value ~default:"(missing)" other));
   Printf.printf "test_results OK (json, 3 rows)\n";
  (* Happy path: two services, both end in active, exit 0. A project of
   * its own, so the failed unit above is not in its results. *)
  Harness.with_sibling ~of_:scratch ~prefix:"pctl-e2e-results-b"
    ~services:
      [
        oneshot "ok" [ true_bin ];
        simple "slow"
          [
            bash;
            "-c";
            Printf.sprintf
              "%s 0.5; exec %s -c \"while true; do %s 3600; done\""
              Harness.sleep_bin bash Harness.sleep_bin;
          ];
      ]
  @@ fun scratch ->
  Harness.check_rc_zero ~label:"up" (Harness.up ~scratch);
  let rc, out = Harness.results ~scratch ~timeout:10 () in
  Harness.check_rc_zero ~label:"happy-path results" (rc, "");
  Harness.assert_contains ~label:"stdout has 'ok'" out "ok";
  Harness.assert_contains ~label:"stdout has 'slow'" out "slow";
  Harness.assert_not_contains ~label:"happy path has no 'failed'" out "failed";
  Printf.printf "test_results OK (happy path)\n"
