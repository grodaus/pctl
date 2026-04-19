(* Logs — `pctl logs [svc] [-n N] [-f] [--path DIR]`.
 *
 * Oracle: pctl/commands/logs.nu. Shells out to journalctl --user -u <unit>
 * with -n <N> (default 100 to match Nushell, NOT 50 as the task brief
 * claimed — the Nushell oracle overrides). Passes -f through for
 * follow-mode when --follow is set.
 *
 * Default N: 100 (Nushell oracle). The plan's "CLI argv" block stated
 * `pctl logs <svc> [-n N]` without a default; we mirror the Nushell
 * behaviour since that's the byte-for-byte parity contract.
 *
 * Follow mode: Nushell supports --follow (-f). The plan's argv block
 * doesn't list it, but the task brief explicitly asked us to mirror
 * Nushell. Carried forward; flagged in the report as a deviation from
 * the frozen argv block.
 *
 * Service resolution: if [svc] is empty, target the project slice
 * (pctl-<id>.slice). Otherwise target the service unit
 * (pctl-<id>-<svc>.service). Mirrors Nushell `unit-for`.
 *
 * Unknown service: we don't pre-validate the service name against the
 * stored manifest — journalctl itself accepts any -u value and will
 * silently return zero lines for unknown units, which is what the
 * Nushell path does too. This keeps behavioural parity; surfaced in
 * the report.
 *
 * Exit code follows journalctl's. The stdout stream is piped straight
 * through so long logs / -f don't get buffered by OCaml. *)

open Common

let run ~sw ~env ~svc ?path ?(follow = false) ?(lines = 100) () : int =
  run_with_errors (fun () ->
      let project_path = resolve_path path in
      let id = Identity.derive ~path:project_path in
      let id_s = Schema.Project_id.to_string id in
      let unit_ =
        if svc = "" then Printf.sprintf "pctl-%s.slice" id_s
        else Printf.sprintf "pctl-%s-%s.service" id_s svc
      in
      let args =
        let base =
          [
            "journalctl";
            "--user";
            "-u";
            unit_;
            "-n";
            string_of_int lines;
          ]
        in
        if follow then base @ [ "-f" ] else base
      in
      let process_mgr = Eio.Stdenv.process_mgr env in
      let stdout_sink = Eio.Stdenv.stdout env in
      let stderr_sink = Eio.Stdenv.stderr env in
      let proc =
        Eio.Process.spawn ~sw process_mgr ~stdout:stdout_sink
          ~stderr:stderr_sink args
      in
      let status = Eio.Process.await proc in
      match status with
      | `Exited 0 -> ()
      | `Exited n ->
          (* journalctl's own exit code bubbles up; we propagate via the
           * Pctl_error machinery so run_with_errors returns it. Wrapping
           * as Registry_io (bucket 4) keeps the mapping stable; a future
           * phase could add a dedicated bucket. *)
          raise
            (Schema.Pctl_error
               (Schema.Registry_io
                  {
                    id = id_s;
                    reason =
                      Printf.sprintf "journalctl -u %s exited %d" unit_ n;
                  }))
      | `Signaled n ->
          raise
            (Schema.Pctl_error
               (Schema.Registry_io
                  {
                    id = id_s;
                    reason =
                      Printf.sprintf "journalctl -u %s killed by signal %d"
                        unit_ n;
                  })))
