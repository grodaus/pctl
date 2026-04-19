(* e2e parity for tests/e2e/up_no_block_test.nu and up_no_wait_test.nu.
 *
 * `up --no-block` must return promptly without waiting for a readiness
 * probe that would never pass. *)

let bash = "/run/current-system/sw/bin/bash"
let sleep_bin = "/run/current-system/sw/bin/sleep"

let () =
  match Harness.skip_reason () with
  | Some why ->
      Printf.printf "SKIP: test_up_no_block — %s\n" why;
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
      let rc = Harness.up_no_block ~scratch in
      let elapsed = Unix.gettimeofday () -. t0 in
      if rc <> 0 then Alcotest.failf "up --no-block exit=%d" rc;
      (* Plain `up --no-block` must return fast regardless of the probe —
       * no readiness wait is done. Generous 5s bound for systemctl
       * roundtrips. *)
      if elapsed > 5.0 then
        Alcotest.failf "up --no-block was slow (%.2fs > 5s)" elapsed;
      Printf.printf "test_up_no_block OK (%.2fs)\n" elapsed
