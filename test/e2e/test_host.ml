(* e2e parity for tests/e2e/host_test.nu + host_not_registered_test.nu. *)

let () =
  Harness.skip_or_run ~name:"test_host" @@ fun () ->
  Harness.with_scratch ~services:[ Harness.service "web" ] @@ fun scratch ->
  (* Scenario 1: after `up`, `host` prints a valid 127.0.0.N. *)
  Harness.check_rc_zero ~label:"up" (Harness.up ~scratch);
  let rc, printed = Harness.host ~scratch in
  Harness.check_rc_zero ~label:"host" (rc, "");
  let trimmed = String.trim printed in
  let re = Str.regexp "^127\\.0\\.0\\.\\([0-9]+\\)$" in
  if not (Str.string_match re trimmed 0) then
    Alcotest.failf "host '%s' is not a 127.0.0.N" trimmed;
  Printf.printf "test_host OK — printed %s\n" trimmed;
  (* Scenario 2: host on a project never brought up exits non-zero with
   * "not registered" on stderr. *)
  Harness.with_sibling ~of_:scratch ~prefix:"pctl-e2e-host-b"
    ~services:[ Harness.service "web" ]
  @@ fun sibling ->
  let (rc, stdout), stderr_text =
    Harness.with_captured_stderr (fun () -> Harness.host ~scratch:sibling)
  in
  if rc = 0 then
    Alcotest.failf "host on unregistered project exit=0, stdout=%s" stdout;
  Harness.assert_contains ~label:"stderr mentions 'not registered'" stderr_text
    "not registered";
  Printf.printf
    "test_host OK (scenario 2, unregistered rc=%d, stderr mentions 'not \
     registered')\n"
    rc
