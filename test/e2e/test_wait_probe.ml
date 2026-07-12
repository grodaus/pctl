(* e2e parity for tests/e2e/wait_test.nu — probe-based readiness. A flag
 * file appears after 500ms; --wait must block until the probe sees it. *)

(* Absolute paths: the systemd --user session on the privileged CI
 * runner starts with a minimal PATH that does not include
 * /run/current-system/sw/bin, so bare names in ExecStart resolve to
 * nothing and silently fall through. *)
let bash = "/run/current-system/sw/bin/bash"
let touch = "/run/current-system/sw/bin/touch"

let () =
  Harness.skip_or_run ~name:"test_wait_probe" @@ fun () ->
  (* Flag path must live under /run/user/<uid> so the systemd --user
   * daemon can see it; $TMPDIR is dune's private sandbox on CI. Same
   * rationale as Harness.fresh_tmpdir. *)
  let tmp_base = Printf.sprintf "/run/user/%d" (Unix.getuid ()) in
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
      command =
        [
          bash;
          "-c";
          Printf.sprintf
            "%s 0.5; %s %s; exec %s -c \"while true; do %s 3600; done\""
            Harness.sleep_bin touch flag bash Harness.sleep_bin;
        ];
      service_config = [ ("Type", "simple") ];
      workspace = None;
      depends_on = [];
    }
  in
  Harness.with_scratch ~services:[ web ]
  @@ fun scratch ->
  let t0 = Unix.gettimeofday () in
  let rc, err = Harness.up_wait ~scratch ~timeout:10 () in
  (* On failure, enrich the pctl stderr transcript with the service
   * unit's own show/journal output: the probe times out when either
   * the service never reaches Active, its ExecStart fails under
   * systemd's exec sandboxing, or the flag file is being written to
   * a path the probe cannot see. systemctl show + journalctl
   * disambiguate all three. *)
  let id_s = Schema.Project_id.to_string (Harness.project_id scratch) in
  let err_enriched =
    if rc = 0 then err
    else
      let unit_name = Harness.service_name id_s "web" in
      Printf.sprintf "%s\n---- flag file ----\n%s exists=%b\n%s"
        err flag (Sys.file_exists flag)
        (Harness.unit_diagnostic unit_name)
  in
  Harness.check_rc_zero ~label:"up --wait" (rc, err_enriched);
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
