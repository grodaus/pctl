(* Install — render the spec, delegate on-disk layout to Unit_store.Fs,
 * return the manifest (unit_filename ↔ sha256).
 *
 *   1. Unit filenames come from the project id + service name via
 *      Schema.Unit_filename.slice / Schema.Unit_filename.service.
 *   2. Each service carries its pctl-runtime.conf drop-in alongside the
 *      .service bytes; Unit_store.Fs decides on-disk layout.
 *   3. Slices get no drop-in — Environment= is [Service]-only and systemd
 *      warns otherwise. The project_id is already encoded in the slice
 *      filename.
 *   4. The manifest covers main unit bytes only; drop-in hashing is
 *      folded into the main hash in a later phase (RFC #4, phase 4).
 *
 * The filesystem port lives in [Unit_store]. This module does not call
 * Unix.mkdir / open_out_gen / rm_rf directly — those live in
 * Unit_store.Fs. [Paths] remains for the e2e harness, which inspects
 * on-disk state by absolute path. *)

(* ------------------------------------------------------------------ *)
(* Paths — preserved for the e2e harness's on-disk inspection.         *)
(* ------------------------------------------------------------------ *)

module Paths = struct
  let user_control () : string = Unit_store.Fs.xdg_user_control ()

  let unit_path ~unit_filename : string =
    Filename.concat (user_control ()) unit_filename

  let dropin_dir ~unit_filename : string =
    unit_path ~unit_filename ^ ".d"

  let dropin_file ~unit_filename : string =
    Filename.concat (dropin_dir ~unit_filename) "pctl-runtime.conf"
end

let sha256_hex (bytes : string) : string =
  Digestif.SHA256.(digest_string bytes |> to_hex)

(* Environment= is only valid under [Service]. Slices don't exec, so
   they get no drop-in: systemd warns "Unknown key 'Environment' in
   section [Slice], ignoring" if we try. The project_id is already
   encoded in the slice filename. *)
let service_dropin_body ~(id : Schema.project_id) ~(host : Schema.host) :
    string =
  Printf.sprintf "[Service]\nEnvironment=PCTL_HOST=%s\nEnvironment=PCTL_ID=%s\n"
    (Schema.Host.to_string host)
    (Schema.Project_id.to_string id)

module Install = struct
  let write_slice ~us ~(spec : Schema.spec) ~(id : Schema.project_id) :
      Schema.Unit_filename.t * string =
    let bytes = Render.slice ~slice:spec.slice ~id in
    let unit_filename = Schema.Unit_filename.slice ~id in
    Unit_store.Fs.write us ~unit_:unit_filename
      { main = bytes; dropin = None };
    (unit_filename, sha256_hex bytes)

  let write_service ~us ~(service : Schema.service_spec)
      ~(id : Schema.project_id) ~(host : Schema.host)
      ~(project_path : Schema.project_path) :
      Schema.Unit_filename.t * string =
    let bytes = Render.service ~service ~id ~project_path in
    let unit_filename =
      Schema.Unit_filename.service ~id ~service:service.name
    in
    let dropin = service_dropin_body ~id ~host in
    Unit_store.Fs.write us ~unit_:unit_filename
      { main = bytes; dropin = Some dropin };
    (unit_filename, sha256_hex bytes)

  let write_units ~(spec : Schema.spec) ~(id : Schema.project_id)
      ~(project_path : Schema.project_path) ~(host : Schema.host) :
      Schema.manifest =
    let us = Unit_store.Fs.create () in
    let slice_entry = write_slice ~us ~spec ~id in
    let service_entries =
      Schema.StringMap.bindings spec.services
      |> List.map (fun (_, svc) ->
             write_service ~us ~service:svc ~id ~host ~project_path)
    in
    slice_entry :: service_entries
    |> List.sort (fun (a, _) (b, _) -> Schema.Unit_filename.compare a b)

  let remove_units (unit_filenames : Schema.Unit_filename.t list) : unit =
    let us = Unit_store.Fs.create () in
    List.iter (fun uf -> Unit_store.Fs.remove us ~unit_:uf) unit_filenames
end
