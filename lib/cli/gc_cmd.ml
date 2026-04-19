(* Gc_cmd — `pctl gc [--yes]`.
 *
 * Oracle: the prior Nushell `gc` command. Two modes:
 *   - Report (default): classify every project (Live/Orphan/Unknown)
 *     and print the report. No mutation.
 *   - Purge (--yes): remove every non-Live project row + unit files.
 *
 * Output modes mirror Nushell `format-out`:
 *   --json  — JSON array (one row per project or removed id).
 *   --table — text table (default when neither flag is passed).
 *
 * Delegates to [Common.purge] so the systemctl dispatch stays in one
 * place. *)

open Common

let run ~sw ~env ?(yes = false) ?(json = false) ?(table = false) () : int =
  let _ = table in
  run_with_errors (fun () ->
      with_connection ~env ~sw (fun conn ->
          if yes then begin
            let removed = purge ~env ~sw ~conn in
            if json then Printf.printf "{\"removed\":%d}\n" removed
            else Printf.eprintf "pctl gc: removed %d\n" removed
          end
          else begin
            let report = Gc.report ~conn in
            if json then print_endline (Ls.render_json report)
            else print_string (Ls.render_table report);
            let summary_count cls =
              List.length (List.filter (fun (_, c) -> c = cls) report)
            in
            Printf.eprintf
              "pctl gc: live=%d orphan=%d unknown=%d — pass --yes to delete \
               non-live\n"
              (summary_count Schema.Live)
              (summary_count Schema.Orphan)
              (summary_count Schema.Unknown)
          end))
