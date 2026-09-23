(* Lifecycle — the single primitive that materialises a spec (or its
 * absence) onto disk and into systemd's view.
 *
 * [reload] is the only primitive: given a maybe-spec, it
 *   1. renders every unit and hashes it,
 *   2. reads and hashes what user.control holds for every unit the
 *      project owns (the manifest),
 *   3. diffs installed against rendered,
 *   4. writes/removes main units and their drop-ins via [Unit_store],
 *   5. applies the diff via [Systemctl], reloading systemd at most once.
 *
 * The left side of the diff comes from disk, never from SQLite: the
 * registry outlives a reboot, user.control does not (pctl-468).
 *
 * Ownership persists two-phase — [owned ∪ rendered] before the writes,
 * [rendered] after the removals, both before [apply_plan] — so the
 * manifest always names a superset of pctl's files on disk, even when
 * a write or a start raises.
 *
 * [up] is [reload ~spec:(Some s)]; [down] is [reload ~spec:None] plus
 * [clear_runtime_fields]. The split stays small on purpose — any new
 * materialisation shape should grow as another wrapper around [reload],
 * not as new surface on [reload] itself.
 *
 * Failure policy is hard-coded to match the oracle Nushell lifecycle:
 *   - stop_unit on a [Removed] row tolerates ONLY a no-such-unit reply
 *     (systemd may have already GCed the unit after its file was
 *     deleted); by that point the file IS gone, so any other failure
 *     leaves a live process with no unit left to manage it and must be
 *     reported;
 *   - the down path's slice stop_unit tolerates ONLY a no-such-unit
 *     reply; anything else propagates, because there the unit files are
 *     still on disk and deleting them after a failed cascade orphans the
 *     running processes;
 *   - start_unit / restart_unit / daemon_reload failures propagate. *)

type ctx = {
  id : Schema.project_id;
  host : Schema.host;
  project_path : Schema.project_path;
}

type report = {
  diff : Schema.plan_row list;
  units_on_disk : int;
}

let sha256_hex (bytes : string) : string =
  Digestif.SHA256.(digest_string bytes |> to_hex)

(* Hash both the main unit bytes AND its drop-in so a drop-in-only
   change (e.g. a host reallocation that only rewrites
   pctl-runtime.conf) surfaces as [Changed]. The NUL separator keeps the
   hash injective across {main="a", dropin="b"} vs {main="ab", dropin=""}. *)
let hash_entry ({ main; dropin } : Unit_store.entry) : string =
  let dropin_bytes = Option.value dropin ~default:"" in
  sha256_hex (main ^ "\x00" ^ dropin_bytes)

let service_dropin_body ~(id : Schema.project_id) ~(host : Schema.host) :
    string =
  Printf.sprintf
    "[Service]\nEnvironment=PCTL_HOST=%s\nEnvironment=PCTL_ID=%s\n"
    (Schema.Host.to_string host)
    (Schema.Project_id.to_string id)

(* Every unit [spec] renders to, sorted by unit filename. Slices carry no
   drop-in — Environment= is [Service]-only and systemd warns otherwise. *)
let render_all ~(ctx : ctx) ~(spec : Schema.spec) :
    (Schema.Unit_filename.t * Unit_store.entry) list =
  let slice =
    ( Schema.Unit_filename.slice ~id:ctx.id,
      { Unit_store.main = Render.slice ~slice:spec.slice ~id:ctx.id; dropin = None } )
  in
  let services =
    Schema.StringMap.bindings spec.services
    |> List.map (fun (_, (svc : Schema.service_spec)) ->
           ( Schema.Unit_filename.service ~id:ctx.id ~service:svc.name,
             {
               Unit_store.main =
                 Render.service ~service:svc ~id:ctx.id
                   ~project_path:ctx.project_path;
               dropin = Some (service_dropin_body ~id:ctx.id ~host:ctx.host);
             } ))
  in
  slice :: services
  |> List.sort (fun (a, _) (b, _) -> Schema.Unit_filename.compare a b)

module Make (M : Systemctl.S) (US : Unit_store.S) = struct
  (* Apply logic. Ordering is load-bearing:
       - [daemon_reload] runs once, before any start/stop fires, so
         systemd sees the new on-disk shape: [reload] has already
         written every unit and deleted the [Removed] ones by then.
         One is enough because nothing here writes to disk after it.
       - Slice rows run first so an [Added] slice is up before its
         services try to start under it; a [Removed] slice's cascade
         kill terminates every service in its cgroup.
       - A slice row never restarts: bouncing the slice cascade-kills
         every service in its cgroup, and those services are diffed
         independently, so they would be [Unchanged] and never brought
         back. Hence [Changed] on a slice is a no-op and [Added] on a
         slice is a plain start, where a service takes a restart for
         both.
       - [Removed] tolerates one stop reply and no more — see the arm. *)
  let is_slice_unit (r : Schema.plan_row) : bool =
    let s = Schema.Unit_filename.to_string r.unit_ in
    let n = String.length s in
    n >= 6 && String.sub s (n - 6) 6 = ".slice"

  let apply_row (handle : M.t) (r : Schema.plan_row) : unit =
    let unit_s = Schema.Unit_filename.to_string r.unit_ in
    match r.action with
    | Schema.Unchanged -> ()
    | Schema.Added ->
        (* Restart, not start, because [Added] does not imply the unit is
           new: it means no owned file is installed for it, which a unit
           whose file was deleted under a running process also reaches.
           StartUnit on an already-active unit is a no-op, so it would
           leave the process serving the OLD config while the diff
           printed [+]. RestartUnit on an inactive or unloaded unit simply
           starts it, so a genuinely new unit still costs the one call. *)
        if is_slice_unit r then M.start_unit handle ~unit:unit_s
        else M.restart_unit handle ~unit:unit_s
    | Schema.Changed ->
        if is_slice_unit r then ()
        else M.restart_unit handle ~unit:unit_s
    | Schema.Removed -> (
        (* The unit file is already deleted when this runs (see [reload]'s
           up path), so systemd may have GCed the unit and answer
           no-such-unit — nothing to stop, nothing running. Any other
           failure means the process is still alive with its unit file
           gone, which is exactly the state that must not pass silently. *)
        try M.stop_unit handle ~unit:unit_s
        with Schema.Pctl_error e when Systemctl.Bus_errors.is_no_such_unit e ->
          ())

  let apply_plan ~(handle : M.t) ~(rows : Schema.plan_row list) : unit =
    let rows = Plan.sort_rows rows in
    M.daemon_reload handle;
    let slices, services = List.partition is_slice_unit rows in
    List.iter (apply_row handle) slices;
    List.iter (apply_row handle) services

  (* Read owned names ONLY, never the union with rendered: a leaked,
     unowned file on disk would otherwise hash as Unchanged and never
     start. *)
  let installed_hashes ~(unit_store : US.t) owned : Schema.unit_hashes =
    List.filter_map
      (fun u -> Option.map (fun e -> (u, hash_entry e)) (US.read unit_store ~unit_:u))
      owned

  let reload ~(conn : State.Db.t) ~(handle : M.t) ~(unit_store : US.t)
      ~(ctx : ctx) ~(spec : Schema.spec option) () : report =
    let id_s = Schema.Project_id.to_string ctx.id in
    let persist units =
      State.Projects.replace_manifest conn ~project_id:id_s ~units
    in
    let owned = State.Projects.load_manifest conn ~project_id:id_s in
    let rendered =
      match spec with
      | None -> []
      | Some s -> render_all ~ctx ~spec:s
    in
    let rendered_names = List.map fst rendered in
    let installed = installed_hashes ~unit_store owned in
    let is_in l u = List.exists (fun (v, _) -> Schema.Unit_filename.equal u v) l in
    (* Owned and no longer rendered. Wider than the diff's Removed rows: an
       owned unit whose main file is already gone has no installed hash,
       yet its drop-in may survive and its process still runs. *)
    let stale = List.filter (fun u -> not (is_in rendered u)) owned in
    let diff =
      Plan.diff ~installed
        ~rendered:(List.map (fun (u, e) -> (u, hash_entry e)) rendered)
      @ List.filter_map
          (fun u ->
            if is_in installed u then None
            else
              Some
                { Schema.unit_ = u; action = Schema.Removed; old_hash = None; new_hash = None })
          stale
    in
    (match spec with
     | Some _ ->
         (* up / reload path: remove stale files before [apply_plan]'s
            single daemon_reload, so it sees them gone at the same time as
            it sees the units just written. *)
         persist (owned @ rendered_names);
         List.iter (fun (u, e) -> US.write unit_store ~unit_:u e) rendered;
         List.iter (fun u -> US.remove unit_store ~unit_:u) stale;
         persist rendered_names;
         apply_plan ~handle ~rows:diff
     | None ->
         (* down path: stop the slice first so the cgroup cascade kills
            every service in it BEFORE we unload the slice from systemd's
            view, then remove files, then daemon_reload. Skipping
            [apply_plan] here is deliberate; its slice-stop would
            happen after the daemon_reload, losing the cascade. *)
         let slice_unit =
           Schema.Unit_filename.to_string
             (Schema.Unit_filename.slice ~id:ctx.id)
         in
         (* Only a no-such-unit reply is tolerated — [pctl down] on a
            project whose slice never loaded has nothing to cascade.
            Every other stop failure means the cascade did NOT fire and
            the services are still running, so it must propagate before
            the removals and the reload below delete every unit file and
            unload the slice: that would leave those processes alive in a cgroup
            with no units left to manage them, invisible to [pctl status]
            and unreachable by [pctl down]. *)
         (try M.stop_unit handle ~unit:slice_unit
          with Schema.Pctl_error e when Systemctl.Bus_errors.is_no_such_unit e -> ());
         List.iter (fun u -> US.remove unit_store ~unit_:u) stale;
         persist [];
         (* The removals are the only thing this path changes on disk, so
            one reload after them is what systemd needs to forget the
            units. *)
         M.daemon_reload handle);
    { diff; units_on_disk = List.length rendered }

  let up ~conn ~handle ~unit_store ~ctx ~(spec : Schema.spec) () : report =
    reload ~conn ~handle ~unit_store ~ctx ~spec:(Some spec) ()

  let down ~conn ~handle ~unit_store ~ctx () : report =
    let r = reload ~conn ~handle ~unit_store ~ctx ~spec:None () in
    let id_s = Schema.Project_id.to_string ctx.id in
    State.Projects.clear_runtime_fields conn ~id:id_s;
    r
end
