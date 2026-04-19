(* Gc_cmd — `pctl gc [--yes]`.
 *
 * Oracle: pctl/commands/gc.nu. Two modes:
 *   - Report (default): classify every project (Live/Orphan/Unknown)
 *     and print the report. No mutation.
 *   - Purge (--yes): remove every non-Live project row + unit files.
 *
 * Output modes mirror Nushell `format-out`:
 *   --json  — JSON array (one row per project or removed id).
 *   --table — text table (default when neither flag is passed).
 *
 * Wraps the [Gc.Make] functor around [Systemctl.Dbus] in production.
 * Tests substitute an in-memory fake via [set_in_mem_systemctl]. *)

open Common
module Gc_dbus = Gc.Make (Systemctl.Dbus)
module Gc_in_mem = Gc.Make (Systemctl.In_mem)

type systemctl_choice =
  | Real_dbus
  | Fake_in_mem of Systemctl.In_mem.t

let systemctl_choice = ref Real_dbus
let set_in_mem_systemctl t = systemctl_choice := Fake_in_mem t
let reset_systemctl () = systemctl_choice := Real_dbus

let purge ~env ~sw ~conn : int =
  match !systemctl_choice with
  | Real_dbus ->
      let t = Systemctl.Dbus.connect ~sw env in
      Gc_dbus.purge ~conn ~handle:t
  | Fake_in_mem t -> Gc_in_mem.purge ~conn ~handle:t

let run ~sw ~env ?(yes = false) ?(json = false) ?(table = false) () : int =
  let _ = table in
  run_with_errors (fun () ->
      with_connection ~env ~sw (fun conn ->
          if yes then begin
            let removed = purge ~env ~sw ~conn in
            if json then
              Printf.printf "{\"removed\":%d}\n" removed
            else
              Printf.eprintf "pctl gc: removed %d\n" removed
          end
          else begin
            let report = Gc.report ~conn in
            if json then print_endline (Ls.render_json report)
            else print_string (Ls.render_table report);
            let summary_count cls =
              List.length
                (List.filter (fun (_, c) -> c = cls) report)
            in
            let live = summary_count Schema.Live in
            let orphan = summary_count Schema.Orphan in
            let unknown = summary_count Schema.Unknown in
            Printf.eprintf
              "pctl gc: live=%d orphan=%d unknown=%d — pass --yes to delete \
               non-live\n"
              live orphan unknown
          end))
