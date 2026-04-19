(* e2e parity for tests/e2e/wait_timeout_test.nu. A probe that never
 * passes; --wait must fail within ~timeout, not wait forever. *)

let bash = "/run/current-system/sw/bin/bash"
let sleep_bin = "/run/current-system/sw/bin/sleep"

let () =
  Harness.skip_or_run ~name:"test_wait_timeout" @@ fun () ->
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
        ];
      workspace = None;
    }
  in
  Harness.with_scratch ~services:[ web ]
  @@ fun scratch ->
  let t0 = Unix.gettimeofday () in
  (* Capture stderr so we can check that the error names 'web'. *)
  let tmp = Filename.temp_file "pctl-e2e-stderr" ".log" in
  let fd = Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let saved = Unix.dup Unix.stderr in
  Unix.dup2 fd Unix.stderr;
  Unix.close fd;
  let rc = Harness.up_wait ~scratch ~timeout:2 () in
  flush Stdlib.stderr;
  Unix.dup2 saved Unix.stderr;
  Unix.close saved;
  let elapsed = Unix.gettimeofday () -. t0 in
  let stderr_text =
    let ic = open_in tmp in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    (try Sys.remove tmp with _ -> ());
    s
  in
  if rc = 0 then Alcotest.fail "expected up --wait to fail";
  if elapsed > 6.0 then
    Alcotest.failf "up --wait took too long to time out (%.2fs > 6s)" elapsed;
  Harness.assert_contains ~label:"error names service 'web'" stderr_text "web";
  Printf.printf "test_wait_timeout OK (timed out in %.2fs, exit=%d)\n"
    elapsed rc
