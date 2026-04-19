(* Up — install units and start the project slice + services.
 *
 * Flow (per Phase 4 brief):
 *   1. Resolve project path.
 *   2. Open DB, run migration, session-reset.
 *   3. Load spec.json (via nix build, or --tree).
 *   4. Derive id. Reuse existing host or allocate a new one.
 *   5. Install units + drop-ins into XDG_RUNTIME_DIR/systemd/user.control/.
 *   6. Persist project row + manifest.
 *   7. Diff against previous manifest (empty if first run).
 *   8. Connect to Systemctl. Plan.apply — start Added/Changed, stop
 *      Removed, daemon_reload once.
 *   9. Print status line; --wait is a Phase 5 stub.
 *
 * Stdout contract:
 *   "project <id> up · <n> units · host=<h>" (mirrors Nushell).
 *
 * Oracle: pctl/commands/up.nu lines 26-112. *)

open Common

module Plan_dbus = Plan.Make (Systemctl.Dbus)
module Plan_in_mem = Plan.Make (Systemctl.In_mem)

(* Pluggable Systemctl for tests. Set via [set_systemctl_override]. When
 * None, Up.run uses Systemctl.Dbus. Phase 4 e2e tests that want an
 * in-memory systemctl (instead of real systemd) flip this before each
 * run. Production always runs with None. *)
type systemctl_choice =
  | Real_dbus
  | Fake_in_mem of Systemctl.In_mem.t

let systemctl_choice = ref Real_dbus

let set_in_mem_systemctl t = systemctl_choice := Fake_in_mem t
let reset_systemctl () = systemctl_choice := Real_dbus

let apply_plan ~env ~sw ~rows =
  match !systemctl_choice with
  | Real_dbus ->
      let t = Systemctl.Dbus.connect ~sw env in
      Plan_dbus.apply ~handle:t ~rows
  | Fake_in_mem t -> Plan_in_mem.apply ~handle:t ~rows

let run ~sw ~env ?tree ?nix ?path ?(no_block = false) ?(wait = false)
    ?timeout:_ () : int =
  ignore no_block;
  run_with_errors (fun () ->
      let project_path = resolve_path path in
      let spec_path_v =
        spec_path ?tree ?nix ~env ~sw ~project_path ()
      in
      let spec = Spec.load ~path:spec_path_v in
      let id = Identity.derive ~path:project_path in
      with_connection ~env ~sw (fun conn ->
          let existing = existing_host conn ~id in
          let host =
            match existing with
            | Some h -> h
            | None ->
                let taken = taken_hosts conn in
                Identity.Host_alloc.allocate ~id ~taken
          in
          let old_manifest =
            State.Manifest_db.load_manifest conn
              ~project_id:(Schema.Project_id.to_string id)
          in
          (* Install writes the new manifest's files on disk. *)
          let new_manifest =
            Install.Install.write_units ~spec ~id ~project_path ~host
          in
          (* Persist project row + manifest inside the same "transaction"
           * window; caqti-eio commits per-statement but the boot_id glues
           * it to this pctl run. *)
          let started_at =
            match existing_started_at conn ~id with
            | Some s when s <> "" -> s
            | _ -> iso8601_now ()
          in
          let boot_id = read_boot_id () in
          State.Projects.upsert conn
            {
              id = Schema.Project_id.to_string id;
              path = project_path;
              host = Some (Schema.Host.to_string host);
              started_at = Some started_at;
              store_tree = Some spec_path_v;
              session_id = (if boot_id = "" then None else Some boot_id);
            };
          State.Manifest_db.replace_project_manifest conn
            ~project_id:(Schema.Project_id.to_string id)
            ~rows:new_manifest;
          let rows = State.Manifest.diff ~before:old_manifest ~after:new_manifest in
          apply_plan ~env ~sw ~rows;
          let unit_count = List.length new_manifest in
          Printf.printf "project %s up · %d units · host=%s\n"
            (Schema.Project_id.to_string id)
            unit_count
            (Schema.Host.to_string host);
          if wait then
            (* Phase 5 will implement this; for Phase 4 --wait is a stub. *)
            prerr_endline
              "pctl: --wait is a Phase-5 stub; readiness wait not yet \
               implemented"))
