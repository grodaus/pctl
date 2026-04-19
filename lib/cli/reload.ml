(* Reload — same as Up but prints the plan (+/~/=/-) before apply.
 *
 * Oracle: the prior Nushell `reload` command. The key differences from Up:
 *   - Up runs `start` for every service after daemon-reload.
 *   - Reload is minimal: Added -> start, Changed -> restart,
 *     Removed -> stop, Unchanged -> skip; slice actions are a no-op
 *     (restarting a slice would bounce every service under it).
 *
 * These semantics live in [Plan.Make], so Reload just calls Plan.apply
 * with the diffed rows and prints the summary first. *)

open Common

let run ~sw ~env ?tree ?nix ?path () : int =
  run_with_errors (fun () ->
      let project_path = resolve_path path in
      let spec_path_v = spec_path ?tree ?nix ~env ~sw ~project_path () in
      let spec = Spec.load ~path:spec_path_v in
      let spec_blob =
        try Some (read_file spec_path_v) with Sys_error _ -> None
      in
      let id = Identity.derive ~path:project_path in
      with_connection ~env ~sw (fun conn ->
          opportunistic_sweep ~env ~sw ~conn;
          (* Reuse the existing host if registered; else allocate. *)
          let host =
            match existing_host conn ~id with
            | Some h -> h
            | None ->
                Identity.Host_alloc.allocate ~id ~taken:(taken_hosts conn)
          in
          let old_manifest =
            State.Projects.load_manifest conn
              ~project_id:(Schema.Project_id.to_string id)
          in
          (* Render + install — writes the new files, computes new manifest. *)
          let new_manifest =
            Install.Install.write_units ~spec ~id ~project_path ~host
          in
          let rows =
            State.Projects.diff_manifest ~before:old_manifest
              ~after:new_manifest
          in
          (* Print the plan BEFORE applying. *)
          print_string (Plan.render_summary rows);
          print_endline (State.Projects.manifest_summary rows);
          (* Remove files for units that are no longer in the new manifest. *)
          let removed_files =
            List.filter_map
              (fun (r : Schema.plan_row) ->
                if r.action = Schema.Removed then Some r.unit_ else None)
              rows
          in
          Install.Install.remove_units removed_files;
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
              spec_json = spec_blob;
            };
          State.Projects.replace_manifest conn
            ~project_id:(Schema.Project_id.to_string id)
            ~rows:new_manifest;
          apply_plan ~env ~sw ~rows))
