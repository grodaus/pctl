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

(* [quiet] silences the stdout status line AND the stderr error trace
 * from [run_with_errors]. Used by the e2e harness teardown, which calls
 * [down] best-effort after every test — the stderr chatter from "already
 * down" projects made the dev-loop output unreadable. *)
let run ~sw ~env ?path ?(quiet = false) () : int =
  let work () =
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
        Install.Install.remove_units (List.map fst existing_manifest);
        (* Final daemon_reload so systemd forgets the now-gone units. *)
        daemon_reload ~env ~sw;
        State.Projects.replace_manifest conn ~project_id:project_id_s
          ~rows:[];
        State.Projects.clear_runtime_fields conn ~id:project_id_s;
        if not quiet then Printf.printf "project %s down\n" project_id_s)
  in
  if quiet then
    try
      work ();
      0
    with _ -> 0
  else run_with_errors work
