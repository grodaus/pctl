(* e2e parity for tests/e2e/up_no_wait_test.nu: plain pctl up (no --wait)
 * must return immediately even when a readinessProbe would never pass.
 * --wait stays strictly opt-in. *)

let bash = "/run/current-system/sw/bin/bash"
let sleep_bin = "/run/current-system/sw/bin/sleep"

let () =
  match Harness.skip_reason () with
  | Some why ->
      Printf.printf "SKIP: test_up_no_wait — %s\n" why;
      exit 0
  | None ->
      let web =
        {
          Harness.name = "web";
          probe =
            Some
              {
                Harness.exec =
                  [ bash; "-c"; "test -f /definitely/does/not/exist" ];
                period_seconds = 1;
                timeout_seconds = 10;
              };
          service_config =
            [
              ("Type", "simple");
              ("ExecStart", Printf.sprintf "%s infinity" sleep_bin);
              ("Slice", "pctl-@@PROJECT@@.slice");
            ];
          workspace = None;
        }
      in
      Harness.with_scratch ~services:[ web ]
      @@ fun scratch ->
      let t0 = Unix.gettimeofday () in
      let rc = Harness.up ~scratch in
      let elapsed = Unix.gettimeofday () -. t0 in
      if rc <> 0 then Alcotest.failf "plain up exit=%d" rc;
      if elapsed > 3.0 then
        Alcotest.failf "plain up was slow, maybe waiting by accident (%.2fs \
                        > 3s)"
          elapsed;
      Printf.printf "test_up_no_wait OK (%.2fs)\n" elapsed
