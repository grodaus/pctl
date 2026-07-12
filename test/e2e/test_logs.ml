(* e2e: pctl logs — journal output for an active service.
 *
 * Pattern: up a service that prints a known sentinel line, wait for
 * active, call logs, assert the sentinel is in journalctl output. *)

let () =
  Harness.skip_or_run ~name:"test_logs" @@ fun () ->
  let sentinel = "pctl-e2e-logs-sentinel" in
  let command =
    [
      "/run/current-system/sw/bin/sh";
      "-c";
      Printf.sprintf
        "echo %s; exec /run/current-system/sw/bin/sleep infinity" sentinel;
    ]
  in
  Harness.with_scratch
    ~services:[ Harness.service ~command ~cfg:[ ("Type", "simple") ] "logger" ]
  @@ fun scratch ->
  Harness.check_rc_zero ~label:"up" (Harness.up ~scratch);
  let id_s = Schema.Project_id.to_string (Harness.project_id scratch) in
  Harness.assert_unit_active (Harness.service_name id_s "logger");
  (* Give journald a moment to flush the message. *)
  let _ = Unix.select [] [] [] 0.5 in
  let rc, out = Harness.logs ~svc:"logger" ~lines:200 ~scratch () in
  Harness.check_rc_zero ~label:"logs" (rc, "");
  Harness.assert_contains ~label:"logs include sentinel" out sentinel;
  Printf.printf "test_logs OK — found sentinel in journal\n"
