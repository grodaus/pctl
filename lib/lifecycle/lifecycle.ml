(* Lifecycle — the single primitive that materialises a spec (or its
 * absence) onto disk and into systemd's view.
 *
 * [reload] is the only primitive: given a maybe-spec, it
 *   1. hashes the rendered unit bytes,
 *   2. writes/removes main units and their drop-ins via [Unit_store],
 *   3. diffs the new manifest against the persisted one,
 *   4. applies the diff via [Systemctl] with the fixed daemon_reload
 *      bracketing,
 *   5. replaces the stored manifest.
 *
 * [up] is [reload ~spec:(Some s)]; [down] is [reload ~spec:None] plus
 * [clear_runtime_fields]. The split stays small on purpose — any new
 * materialisation shape should grow as another wrapper around [reload],
 * not as new surface on [reload] itself.
 *
 * Failure policy is hard-coded to match the oracle Nushell lifecycle:
 *   - stop_unit failures on [Removed] rows are tolerated (systemd may
 *     have already GCed the unit after its file was deleted);
 *   - start_unit / restart_unit / daemon_reload failures propagate.
 *
 * Drop-in hashing: phase 4 folds [dropin] into the main hash so a
 * host-change-only reload reports [Changed]. Today we hash the main
 * bytes alone, matching [Install]'s phase-0 behaviour. *)

type ctx = {
  id : Schema.project_id;
  host : Schema.host;
  project_path : Schema.project_path;
}

type report = {
  diff : Schema.plan_row list;
  manifest_before : Schema.manifest;
  manifest_after : Schema.manifest;
  units_on_disk : int;
}

(* Hashing + drop-in body rendering — moved here from [Install] so the
   render → hash → write pipeline lives in one place. [Install] keeps
   copies until phase 5 deletes the module. *)
let sha256_hex (bytes : string) : string =
  Digestif.SHA256.(digest_string bytes |> to_hex)

(* Hash both the main unit bytes AND its drop-in so a drop-in-only
   change (e.g. a host reallocation that only rewrites
   pctl-runtime.conf) surfaces as [Changed] in the next diff. Before
   this phase the manifest hashed [main] alone, so a host bounce
   silently missed the reload. The NUL separator keeps the hash
   injective across {main="a", dropin="b"} vs {main="ab", dropin=""}.

   Side effect: the first reload after a deploy sees every unit as
   Changed once, because existing manifests were computed under the
   old formula. One-time churn, acceptable per RFC #4. *)
let hash_entry ~(main : string) ~(dropin : string option) : string =
  let dropin_bytes = Option.value dropin ~default:"" in
  sha256_hex (main ^ "\x00" ^ dropin_bytes)

let service_dropin_body ~(id : Schema.project_id) ~(host : Schema.host) :
    string =
  Printf.sprintf
    "[Service]\nEnvironment=PCTL_HOST=%s\nEnvironment=PCTL_ID=%s\n"
    (Schema.Host.to_string host)
    (Schema.Project_id.to_string id)

(* Render every unit in [spec], write it through [US], and return the
   manifest sorted by unit filename (so diffs against persisted state
   are stable). Slices carry no drop-in — Environment= is [Service]-only
   and systemd warns otherwise. *)
module Write_all (US : Unit_store.S) = struct
  let run ~(us : US.t) ~(ctx : ctx) ~(spec : Schema.spec) : Schema.manifest =
    let slice_bytes = Render.slice ~slice:spec.slice ~id:ctx.id in
    let slice_unit = Schema.Unit_filename.slice ~id:ctx.id in
    US.write us ~unit_:slice_unit { main = slice_bytes; dropin = None };
    let service_rows =
      Schema.StringMap.bindings spec.services
      |> List.map (fun (_, (svc : Schema.service_spec)) ->
             let bytes =
               Render.service ~service:svc ~id:ctx.id
                 ~project_path:ctx.project_path
             in
             let unit_ =
               Schema.Unit_filename.service ~id:ctx.id ~service:svc.name
             in
             let dropin = service_dropin_body ~id:ctx.id ~host:ctx.host in
             US.write us ~unit_ { main = bytes; dropin = Some dropin };
             (unit_, hash_entry ~main:bytes ~dropin:(Some dropin)))
    in
    (slice_unit, hash_entry ~main:slice_bytes ~dropin:None) :: service_rows
    |> List.sort (fun (a, _) (b, _) -> Schema.Unit_filename.compare a b)
end

module Make (M : Systemctl.S) (US : Unit_store.S) = struct
  module WA = Write_all (US)

  type systemctl_handle = M.t
  type unit_store_handle = US.t

  (* Apply logic — absorbed from the old [Plan.Make] during phase 5.
     Ordering is load-bearing:
       - [daemon_reload] frames every pass so systemd sees the new
         on-disk shape before any start/stop fires.
       - Slice rows run first so an [Added] slice is up before its
         services try to start under it; a [Removed] slice's cascade
         kill terminates every service in its cgroup.
       - [Changed] on a slice row is a no-op: bouncing the slice
         would restart every service under it, which is never what
         [pctl reload] means.
       - [Removed] tolerates stop failure — systemd may have already
         GCed the unit after its file was deleted. Everything else
         propagates. *)
  let is_slice_unit (r : Schema.plan_row) : bool =
    let s = Schema.Unit_filename.to_string r.unit_ in
    let n = String.length s in
    n >= 6 && String.sub s (n - 6) 6 = ".slice"

  let sort_rows rows =
    List.sort
      (fun (a : Schema.plan_row) (b : Schema.plan_row) ->
        Schema.Unit_filename.compare a.unit_ b.unit_)
      rows

  let apply_row (handle : M.t) (r : Schema.plan_row) : unit =
    let unit_s = Schema.Unit_filename.to_string r.unit_ in
    match r.action with
    | Schema.Unchanged -> ()
    | Schema.Added -> M.start_unit handle ~unit:unit_s
    | Schema.Changed ->
        if is_slice_unit r then ()
        else M.restart_unit handle ~unit:unit_s
    | Schema.Removed -> (
        try M.stop_unit handle ~unit:unit_s
        with Schema.Pctl_error _ -> ())

  let apply_plan ~(handle : M.t) ~(rows : Schema.plan_row list) : unit =
    let rows = sort_rows rows in
    M.daemon_reload handle;
    let slices, services = List.partition is_slice_unit rows in
    List.iter (apply_row handle) slices;
    List.iter (apply_row handle) services;
    M.daemon_reload handle

  let reload ~(conn : State.Db.t) ~(handle : M.t) ~(unit_store : US.t)
      ~(ctx : ctx) ~(spec : Schema.spec option) () : report =
    let id_s = Schema.Project_id.to_string ctx.id in
    let manifest_before =
      State.Projects.load_manifest conn ~project_id:id_s
    in
    let manifest_after =
      match spec with
      | None -> []
      | Some s -> WA.run ~us:unit_store ~ctx ~spec:s
    in
    let diff =
      State.Projects.diff_manifest ~before:manifest_before
        ~after:manifest_after
    in
    (match spec with
     | Some _ ->
         (* up / reload path — preserves current pipeline.reload ordering:
            remove stale files first so systemd's next daemon_reload sees
            them gone, then apply (daemon_reload; start/restart Added/
            Changed; stop Removed (tolerated); daemon_reload). *)
         List.iter
           (fun (r : Schema.plan_row) ->
             if r.action = Schema.Removed then
               US.remove unit_store ~unit_:r.unit_)
           diff;
         apply_plan ~handle ~rows:diff
     | None ->
         (* tear-down path — preserves current pipeline.down ordering:
            stop the slice first so the cgroup cascade kills every
            service in it BEFORE we unload the slice from systemd's
            view, daemon_reload, remove files, daemon_reload. Skipping
            [apply_plan] here is deliberate; its slice-stop would
            happen after the daemon_reload, losing the cascade. *)
         let slice_unit =
           Schema.Unit_filename.to_string
             (Schema.Unit_filename.slice ~id:ctx.id)
         in
         (try M.stop_unit handle ~unit:slice_unit
          with Schema.Pctl_error _ -> ());
         M.daemon_reload handle;
         List.iter
           (fun (uf, _hash) -> US.remove unit_store ~unit_:uf)
           manifest_before;
         M.daemon_reload handle);
    State.Projects.replace_manifest conn ~project_id:id_s ~rows:manifest_after;
    {
      diff;
      manifest_before;
      manifest_after;
      units_on_disk = List.length manifest_after;
    }

  let up ~conn ~handle ~unit_store ~ctx ~(spec : Schema.spec) () : report =
    reload ~conn ~handle ~unit_store ~ctx ~spec:(Some spec) ()

  let down ~conn ~handle ~unit_store ~ctx () : report =
    let r = reload ~conn ~handle ~unit_store ~ctx ~spec:None () in
    let id_s = Schema.Project_id.to_string ctx.id in
    State.Projects.clear_runtime_fields conn ~id:id_s;
    r
end
