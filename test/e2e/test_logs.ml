(* e2e: pctl logs — journal output for an active service.
 *
 * Pattern: up a service that prints a known sentinel line, wait for
 * active, call logs, assert the sentinel is in journalctl output. *)

let contains h n =
  let hl = String.length h and nl = String.length n in
  let rec go i =
    if i + nl > hl then false
    else if String.sub h i nl = n then true
    else go (i + 1)
  in
  nl = 0 || go 0

let () =
  match Harness.skip_reason () with
  | Some why ->
      Printf.printf "SKIP: test_logs — %s\n" why;
      exit 0
  | None ->
      let sentinel = "pctl-e2e-logs-sentinel" in
      let cfg =
        [
          ("Type", "simple");
          ( "ExecStart",
            Printf.sprintf
              "/run/current-system/sw/bin/sh -c 'echo %s; exec /run/current-system/sw/bin/sleep infinity'"
              sentinel );
          ("Slice", "pctl-@@PROJECT@@.slice");
        ]
      in
      Harness.with_scratch
        ~services:[ Harness.service ~cfg "logger" ]
      @@ fun scratch ->
      let rc = Harness.up ~scratch in
      if rc <> 0 then Alcotest.failf "up exit=%d" rc;
      let id = Harness.project_id scratch in
      let id_s = Schema.Project_id.to_string id in
      let unit_name = Printf.sprintf "pctl-%s-logger.service" id_s in
      if not (Harness.wait_active unit_name) then
        Alcotest.failf "service %s did not reach active" unit_name;
      (* Give journald a moment to flush the message. *)
      let _ = Unix.select [] [] [] 0.5 in
      let rc, out = Harness.logs ~svc:"logger" ~lines:200 ~scratch () in
      if rc <> 0 then
        Alcotest.failf "logs exit=%d, stdout=%s" rc out;
      if not (contains out sentinel) then
        Alcotest.failf
          "logs did not include sentinel '%s'.\n---stdout---\n%s" sentinel
          out;
      Printf.printf "test_logs OK — found sentinel in journal\n"
