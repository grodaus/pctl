(* Up — install units and start the project slice + services.
 *
 * Flow:
 *   1. Resolve project path.
 *   2. Open DB, run migration, session-reset.
 *   3. Load spec.json (via nix build, or --tree).
 *   4. Derive id. Reuse existing host or allocate a new one.
 *   5. Install units + drop-ins into XDG_RUNTIME_DIR/systemd/user.control/.
 *   6. Persist project row + manifest.
 *   7. Diff against previous manifest (empty if first run).
 *   8. Connect to Systemctl. Plan.apply — start Added/Changed, stop
 *      Removed, daemon_reload once.
 *   9. Print status line; if --wait, block on Probe.wait_all.
 *
 * Stdout contract:
 *   "project <id> up · <n> units · host=<h>" (mirrors Nushell).
 *
 * Oracle: the prior Nushell `up` command. *)

open Common

(* Scope the Dbus connection to an INNER Switch so the dispatch fiber
 * (spawned by subscribe_unit_changes) gets cancelled and drained inside
 * an Eio-handled context, before control returns to the caller's outer
 * Switch. Otherwise a late PropertiesChanged signal can trigger
 * Eio.Fiber.fork on a closing switch and leak
 * Effect.Unhandled(Cancel.Get_context). *)
let run_wait_ready ~env ~sw:_ ~id ~host ~spec ~timeout_seconds : unit =
  match !systemctl_choice with
  | Real_dbus ->
      Eio.Switch.run @@ fun inner_sw ->
      let t = Systemctl.Dbus.connect ~sw:inner_sw env in
      let _rows =
        Probe_dbus.wait_all ~sw:inner_sw ~env ~handle:t ~id ~host ~spec
          ~timeout_seconds ~strategy:`Throw_first
      in
      (* Explicit close halts the background dispatch fiber before the
       * inner switch's release kicks in — belt-and-braces with the scope
       * isolation above. *)
      Systemctl.Dbus.close t
  | Fake_in_mem t ->
      Eio.Switch.run @@ fun inner_sw ->
      let _rows =
        Probe_in_mem.wait_all ~sw:inner_sw ~env ~handle:t ~id ~host ~spec
          ~timeout_seconds ~strategy:`Throw_first
      in
      ()

let run ~sw ~env ?tree ?nix ?path ?(no_block = false) ?(wait = false)
    ?(timeout = 300) () : int =
  if no_block && wait then begin
    prerr_endline "pctl up: --no-block and --wait are mutually exclusive";
    2
  end
  else
    run_with_errors (fun () ->
        let project_path = resolve_path path in
        let spec_path_v = spec_path ?tree ?nix ~env ~sw ~project_path () in
        let spec = Spec.load ~path:spec_path_v in
        let id = Identity.derive ~path:project_path in
        with_connection ~env ~sw (fun conn ->
            (* Opportunistic sweep — must run AFTER session_reset (inside
             * with_connection) and BEFORE any other DB work, so Unknown
             * rows get their units removed before we potentially allocate
             * a host that collides with them. *)
            opportunistic_sweep ~env ~sw ~conn;
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
            (* Install writes the new manifest's files on disk. *)
            let new_manifest =
              Install.Install.write_units ~spec ~id ~project_path ~host
            in
            (* Persist project row + manifest inside the same "transaction"
             * window; caqti-eio commits per-statement but the boot_id
             * glues it to this pctl run. *)
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
            State.Projects.replace_manifest conn
              ~project_id:(Schema.Project_id.to_string id)
              ~rows:new_manifest;
            let rows =
              State.Projects.diff_manifest ~before:old_manifest
                ~after:new_manifest
            in
            apply_plan ~env ~sw ~rows;
            let suffix = if no_block then " (async)" else "" in
            Printf.printf "project %s up · %d units · host=%s%s\n"
              (Schema.Project_id.to_string id)
              (List.length new_manifest)
              (Schema.Host.to_string host)
              suffix;
            if wait then
              run_wait_ready ~env ~sw ~id ~host ~spec ~timeout_seconds:timeout))
