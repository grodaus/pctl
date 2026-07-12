(* e2e parity: pctl up --wait blocks until every service (no probe) is
 * active. Oracle: tests/e2e/wait_test.nu (probe variant) and wait_pctl_host_test.
 * This variant covers the no-probe unit-state path. *)

let bash = "/run/current-system/sw/bin/bash"

let () =
  Harness.skip_or_run ~name:"test_wait_active" @@ fun () ->
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
  Harness.with_scratch ~services:[ web ]
  @@ fun scratch ->
  let t0 = Unix.gettimeofday () in
  Harness.check_rc_zero ~label:"up --wait"
    (Harness.up_wait ~scratch ~timeout:10 ());
  let elapsed = Unix.gettimeofday () -. t0 in
  if elapsed > 8.0 then
    Alcotest.failf "up --wait took too long (%.2fs > 8s)" elapsed;
  let id_s = Schema.Project_id.to_string (Harness.project_id scratch) in
  Harness.assert_true
    ~label:(Printf.sprintf "%s active" (Harness.service_name id_s "web"))
    (Harness.is_active (Harness.service_name id_s "web"));
  print_endline "test_wait_active OK"
