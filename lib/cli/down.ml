(* Down — stop units, remove files, null out runtime columns.
 *
 * Oracle: the prior Nushell `down` command. Sequence:
 *   1. Stop the project slice (systemd cascades to every service under it).
 *   2. Delete unit files and their drop-in dirs.
 *   3. daemon_reload — forget the deleted units.
 *   4. Clear manifest + runtime columns in the DB; keep the project row.
 *      (Nushell deleted the registry tree entirely. The OCaml rewrite
 *      keeps the row so `pctl gc` can decide when to remove it, based
 *      on class Live/Orphan/Unknown.) *)

open Common
module Gc_dbus = Gc.Make (Systemctl.Dbus)
module Gc_in_mem = Gc.Make (Systemctl.In_mem)

type systemctl_choice = Real_dbus | Fake_in_mem of Systemctl.In_mem.t

let systemctl_choice = ref Real_dbus
let set_in_mem_systemctl t = systemctl_choice := Fake_in_mem t
let reset_systemctl () = systemctl_choice := Real_dbus

let sweep ~env ~sw ~conn =
  match !systemctl_choice with
  | Real_dbus ->
      let t = Systemctl.Dbus.connect ~sw env in
      Gc_dbus.opportunistic_sweep ~conn ~handle:t
  | Fake_in_mem t -> Gc_in_mem.opportunistic_sweep ~conn ~handle:t

let run ~sw ~env ?path () : int =
  run_with_errors (fun () ->
      let project_path = resolve_path path in
      let id = Identity.derive ~path:project_path in
      with_connection ~env ~sw (fun conn ->
          sweep ~env ~sw ~conn;
          let project_id_s = Schema.Project_id.to_string id in
          let existing_manifest =
            State.Projects.load_manifest conn ~project_id:project_id_s
          in
          if existing_manifest = [] then
            raise
              (Schema.Pctl_error
                 (Schema.Registry_io
                    {
                      id = project_id_s;
                      reason =
                        Printf.sprintf
                          "pctl down: no registered project with id '%s' \
                           at %s"
                          project_id_s project_path;
                    }));
          let slice_unit = Printf.sprintf "pctl-%s.slice" project_id_s in
          (* Stop the slice (cascades to services on real systemd). For the
           * in-memory fake, also stop each tracked unit so tests see them
           * inactive. *)
          (match !systemctl_choice with
           | Real_dbus ->
               let t = Systemctl.Dbus.connect ~sw env in
               (try Systemctl.Dbus.stop_unit t ~unit:slice_unit
                with Schema.Pctl_error _ -> ());
               Systemctl.Dbus.daemon_reload t
           | Fake_in_mem t ->
               (try Systemctl.In_mem.stop_unit t ~unit:slice_unit
                with Schema.Pctl_error _ -> ());
               List.iter
                 (fun (uf, _) ->
                   try Systemctl.In_mem.stop_unit t ~unit:uf
                   with Schema.Pctl_error _ -> ())
                 existing_manifest;
               Systemctl.In_mem.daemon_reload t);
          (* Delete unit files + drop-in dirs. *)
          let unit_files = List.map fst existing_manifest in
          Install.Install.remove_units ~id unit_files;
          (* Final daemon_reload so systemd forgets the now-gone units. *)
          (match !systemctl_choice with
           | Real_dbus ->
               let t = Systemctl.Dbus.connect ~sw env in
               Systemctl.Dbus.daemon_reload t
           | Fake_in_mem t -> Systemctl.In_mem.daemon_reload t);
          State.Projects.replace_manifest conn
            ~project_id:project_id_s ~rows:[];
          State.Projects.clear_runtime_fields conn ~id:project_id_s;
          Printf.printf "project %s down\n" project_id_s))
