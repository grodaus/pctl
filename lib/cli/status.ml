(* Status — `pctl status [svc] [--path DIR]`.
 *
 * Oracle: pctl/commands/status.nu — a thin shell-out to `systemctl --user
 * status <unit>`. The Nushell implementation deliberately tolerates
 * systemctl's non-zero exit for inactive units (prints a note on stderr
 * and returns success). We mirror that: stdout/stderr pipe through, exit
 * 0 even when systemctl reports inactive, because "pctl status foo" for
 * a stopped foo should still be observable rather than a hard failure.
 *
 * The task brief asked for `--json`/`--table` modes and "exit 0 iff at
 * least one unit Active" — the Nushell oracle supports neither of those.
 * We follow the Nushell oracle for byte-for-byte parity. Flagged in the
 * Phase 6 report.
 *
 * If [svc] is empty, target the slice (pctl-<id>.slice). Otherwise target
 * the service (pctl-<id>-<svc>.service). Mirrors Nushell `unit-for`. *)

open Common

let run ~sw ~env ~svc ?path () : int =
  run_with_errors (fun () ->
      let project_path = resolve_path path in
      let id = Identity.derive ~path:project_path in
      let id_s = Schema.Project_id.to_string id in
      let unit_ =
        if svc = "" then Printf.sprintf "pctl-%s.slice" id_s
        else Printf.sprintf "pctl-%s-%s.service" id_s svc
      in
      let args = [ "systemctl"; "--user"; "status"; unit_ ] in
      let process_mgr = Eio.Stdenv.process_mgr env in
      let stdout_sink = Eio.Stdenv.stdout env in
      let stderr_sink = Eio.Stdenv.stderr env in
      let proc =
        Eio.Process.spawn ~sw process_mgr ~stdout:stdout_sink
          ~stderr:stderr_sink args
      in
      let (_ : Eio.Process.exit_status) = Eio.Process.await proc in
      (* Systemctl status returns 3 for inactive; do NOT fail on non-zero. *)
      ())
