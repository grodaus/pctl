(* Install — render the spec into user.control, create drop-ins, compute
 * the manifest.
 *
 *   1. Unit filename has @@PROJECT@@ substituted to the project id.
 *   2. .slice/.service files land directly in user.control/.
 *   3. Each service gets a drop-in at "<unit>.d/pctl-runtime.conf"
 *      carrying PCTL_HOST + PCTL_ID. Slices get no drop-in (Environment=
 *      is [Service]-only; systemd warns otherwise).
 *   4. The manifest covers main unit files only, not drop-ins.
 *
 * The content written to the main unit file is produced by Render. *)

(* ------------------------------------------------------------------ *)
(* Paths — where pctl writes on disk.                                  *)
(*                                                                     *)
(* `user.control` lives under $XDG_RUNTIME_DIR/systemd/user.control    *)
(* (NOT ~/.config/systemd/user.control, which persists across reboots  *)
(* — we want a tmpfs-backed path that systemd reset-failed can clean). *)
(* XDG_RUNTIME_DIR must be set; we raise the same "not set" error as   *)
(* the Nushell `require-runtime-dir` helper.                           *)
(* ------------------------------------------------------------------ *)

module Paths = struct
  let user_control : string =
    match Sys.getenv_opt "XDG_RUNTIME_DIR" with
    | None | Some "" ->
        raise
          (Schema.Pctl_error
             (Schema.Install_failed
                {
                  path = "XDG_RUNTIME_DIR";
                  reason =
                    "XDG_RUNTIME_DIR is not set (requires Linux + systemd \
                     --user)";
                }))
    | Some rt -> Filename.concat rt (Filename.concat "systemd" "user.control")

  (* Substitute @@PROJECT@@ in unit basenames. Filenames never contain
   * @@PROJECT_PATH@@ (it would be nonsense in a filename); that rule
   * is Render's concern. *)
  let substitute_id ~(id : Schema.project_id) (basename : string) : string =
    Render.replace_all ~needle:"@@PROJECT@@"
      ~replacement:(Schema.Project_id.to_string id)
      basename

  let slice_path ~(id : Schema.project_id) ~(unit_filename : string) : string =
    Filename.concat user_control (substitute_id ~id unit_filename)

  let service_path ~(id : Schema.project_id) ~(unit_filename : string) : string
      =
    Filename.concat user_control (substitute_id ~id unit_filename)

  let dropin_dir ~(id : Schema.project_id) ~(unit_filename : string) : string =
    (substitute_id ~id unit_filename |> Filename.concat user_control) ^ ".d"

  let dropin_file ~(id : Schema.project_id) ~(unit_filename : string) : string
      =
    Filename.concat (dropin_dir ~id ~unit_filename) "pctl-runtime.conf"
end

(* ------------------------------------------------------------------ *)
(* Small fs helpers.                                                   *)
(* ------------------------------------------------------------------ *)

let sha256_hex (bytes : string) : string =
  Digestif.SHA256.(digest_string bytes |> to_hex)

let rec mkdir_p path =
  if path = "" || path = "/" || path = "." then ()
  else if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o700
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let write_file ~path ~bytes =
  let parent = Filename.dirname path in
  mkdir_p parent;
  try
    let oc = open_out_gen [ Open_wronly; Open_creat; Open_trunc ] 0o644 path in
    Fun.protect
      ~finally:(fun () -> close_out oc)
      (fun () -> output_string oc bytes)
  with Sys_error msg ->
    raise (Schema.Pctl_error (Schema.Install_failed { path; reason = msg }))

(* rm -rf on a directory tree. Tolerates non-existence (returns silently). *)
let rec rm_rf p =
  if not (Sys.file_exists p) then ()
  else if Sys.is_directory p then begin
    let entries = try Sys.readdir p with Sys_error _ -> [||] in
    Array.iter (fun name -> rm_rf (Filename.concat p name)) entries;
    try Unix.rmdir p
    with Unix.Unix_error _ | Sys_error _ -> ()
  end
  else try Sys.remove p with Sys_error _ -> ()

(* ------------------------------------------------------------------ *)
(* Drop-in rendering.                                                  *)
(* ------------------------------------------------------------------ *)

(* Environment= is only valid under [Service]. Slices don't exec, so
   they get no drop-in: systemd warns "Unknown key 'Environment' in
   section [Slice], ignoring" if we try. The project_id is already
   encoded in the slice filename. *)
let service_dropin_body ~(id : Schema.project_id) ~(host : Schema.host) :
    string =
  Printf.sprintf "[Service]\nEnvironment=PCTL_HOST=%s\nEnvironment=PCTL_ID=%s\n"
    (Schema.Host.to_string host)
    (Schema.Project_id.to_string id)

(* ------------------------------------------------------------------ *)
(* Main API.                                                           *)
(* ------------------------------------------------------------------ *)

module Install = struct
  (* Ensure user.control/ exists. *)
  let ensure_control_dir () = mkdir_p Paths.user_control

  (* Write one slice + its drop-in, return (unit_filename, sha256). *)
  let write_slice ~(spec : Schema.spec) ~(id : Schema.project_id)
      ~project_path : string * string =
    let bytes = Render.slice ~slice:spec.slice ~id ~project_path in
    let unit_filename =
      Paths.substitute_id ~id spec.slice.unit_filename
    in
    let path =
      Paths.slice_path ~id ~unit_filename:spec.slice.unit_filename
    in
    write_file ~path ~bytes;
    (unit_filename, sha256_hex bytes)

  (* Write one service + its drop-in. *)
  let write_service ~(service : Schema.service_spec)
      ~(id : Schema.project_id) ~(host : Schema.host) ~project_path :
      string * string =
    let bytes = Render.service ~service ~id ~project_path in
    let unit_filename = Paths.substitute_id ~id service.unit_filename in
    let path = Paths.service_path ~id ~unit_filename:service.unit_filename in
    write_file ~path ~bytes;
    let dropin =
      Paths.dropin_file ~id ~unit_filename:service.unit_filename
    in
    write_file ~path:dropin ~bytes:(service_dropin_body ~id ~host);
    (unit_filename, sha256_hex bytes)

  let write_units ~(spec : Schema.spec) ~(id : Schema.project_id)
      ~project_path ~(host : Schema.host) : Schema.manifest =
    ensure_control_dir ();
    let slice_entry = write_slice ~spec ~id ~project_path in
    let service_entries =
      Schema.StringMap.bindings spec.services
      |> List.map (fun (_, svc) ->
             write_service ~service:svc ~id ~host ~project_path)
    in
    slice_entry :: service_entries
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)

  let remove_units ~(id : Schema.project_id) (unit_filenames : string list) :
      unit =
    List.iter
      (fun uf ->
        (* uf in the manifest already has @@PROJECT@@ substituted to the id.
         * But to be defensive, substitute again — if it's already substituted,
         * it's a no-op. *)
        let basename = Paths.substitute_id ~id uf in
        let path = Filename.concat Paths.user_control basename in
        let d = path ^ ".d" in
        rm_rf d;
        (try Sys.remove path with Sys_error _ -> ()))
      unit_filenames
end
