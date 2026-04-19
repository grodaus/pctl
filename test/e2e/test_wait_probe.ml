(* e2e parity for tests/e2e/wait_test.nu — probe-based readiness. A flag
 * file appears after 500ms; --wait must block until the probe sees it. *)

let bash = "/run/current-system/sw/bin/bash"

let () =
  Harness.skip_or_run ~name:"test_wait_probe" @@ fun () ->
  let tmp_base = try Sys.getenv "TMPDIR" with Not_found -> "/tmp" in
  let flag =
    Filename.concat tmp_base
      (Printf.sprintf "pctl-wait-probe-%d-%f.flag" (Unix.getpid ())
         (Unix.gettimeofday ()))
  in
  (try Sys.remove flag with _ -> ());
  let web =
    {
      Harness.name = "web";
      probe =
        Some
          {
            Harness.exec = [ bash; "-c"; Printf.sprintf "test -f %s" flag ];
            period_seconds = 1;
            timeout_seconds = 10;
          };
      service_config =
        [
          ("Type", "simple");
          ( "ExecStart",
            Printf.sprintf
              "%s -c 'sleep 0.5; touch %s; exec %s -c \"while true; \
               do sleep 3600; done\"'"
              bash flag bash );
          ("Slice", "pctl-@@PROJECT@@.slice");
        ];
      workspace = None;
    }
  in
  Harness.with_scratch ~services:[ web ]
  @@ fun scratch ->
  let t0 = Unix.gettimeofday () in
  Harness.check_rc_zero ~label:"up --wait"
    (Harness.up_wait ~scratch ~timeout:10 ());
  let elapsed = Unix.gettimeofday () -. t0 in
  if not (Sys.file_exists flag) then
    Alcotest.fail "flag file missing — service never became ready";
  (* Must block at least ~400ms (flag appears at 500ms). *)
  if elapsed < 0.4 then
    Alcotest.failf "up --wait returned too fast (%.2fs < 0.4s)" elapsed;
  if elapsed > 5.0 then
    Alcotest.failf "up --wait took too long (%.2fs > 5s)" elapsed;
  (try Sys.remove flag with _ -> ());
  Printf.printf "test_wait_probe OK (waited %.2fs)\n" elapsed
