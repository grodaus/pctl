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

(* Stop the project slice (systemd cascades to every service under it),
 * then daemon-reload. *)
let stop_and_reload ~env ~sw ~slice_unit =
  let t = Systemctl.Dbus.connect ~sw env in
  (try Systemctl.Dbus.stop_unit t ~unit:slice_unit
   with Schema.Pctl_error _ -> ());
  Systemctl.Dbus.daemon_reload t

let daemon_reload ~env ~sw =
  let t = Systemctl.Dbus.connect ~sw env in
  Systemctl.Dbus.daemon_reload t

let run ~sw ~env ?path () : int =
  run_with_errors (fun () ->
      let project_path = resolve_path path in
      let id = Identity.derive ~path:project_path in
      with_connection ~env ~sw (fun conn ->
          opportunistic_sweep ~env ~sw ~conn;
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
          stop_and_reload ~env ~sw ~slice_unit;
          (* Delete unit files + drop-in dirs. *)
          Install.Install.remove_units ~id (List.map fst existing_manifest);
          (* Final daemon_reload so systemd forgets the now-gone units. *)
          daemon_reload ~env ~sw;
          State.Projects.replace_manifest conn ~project_id:project_id_s
            ~rows:[];
          State.Projects.clear_runtime_fields conn ~id:project_id_s;
          Printf.printf "project %s down\n" project_id_s))
