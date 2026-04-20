(* Install — render the spec into user.control, create drop-ins, compute
 * the manifest.
 *
 *   1. Unit filenames are derived from the project id + service name
 *      (Schema.Unit_filename.slice / Schema.Unit_filename.service).
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
  (* [user_control] is recomputed on each call. The prior top-level
   * [let user_control : string = ...] evaluated at module-load time,
   * which made tests that own their XDG_RUNTIME_DIR brittle: by the
   * time the test's [putenv] ran, [user_control] was frozen to
   * whatever value the dev's login session had exported. *)
  let user_control () : string =
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

  (* Absolute paths for a unit's main file, its drop-in dir, and its
   * drop-in config file. All take the concrete unit filename
   * (pctl-<id>.slice, pctl-<id>-<svc>.service) — no placeholder tokens. *)
  let unit_path ~unit_filename : string =
    Filename.concat (user_control ()) unit_filename

  let dropin_dir ~unit_filename : string =
    unit_path ~unit_filename ^ ".d"

  let dropin_file ~unit_filename : string =
    Filename.concat (dropin_dir ~unit_filename) "pctl-runtime.conf"
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
  let ensure_control_dir () = mkdir_p (Paths.user_control ())

  (* Write one slice, return (unit_filename, sha256). *)
  let write_slice ~(spec : Schema.spec) ~(id : Schema.project_id) :
      string * string =
    let bytes = Render.slice ~slice:spec.slice ~id in
    let unit_filename = Schema.Unit_filename.slice ~id in
    let unit_filename_s = Schema.Unit_filename.to_string unit_filename in
    write_file ~path:(Paths.unit_path ~unit_filename:unit_filename_s) ~bytes;
    (unit_filename_s, sha256_hex bytes)

  (* Write one service + its drop-in. *)
  let write_service ~(service : Schema.service_spec)
      ~(id : Schema.project_id) ~(host : Schema.host) ~project_path :
      string * string =
    let bytes = Render.service ~service ~id ~project_path in
    let unit_filename =
      Schema.Unit_filename.service ~id ~service:service.name
    in
    let unit_filename_s = Schema.Unit_filename.to_string unit_filename in
    write_file ~path:(Paths.unit_path ~unit_filename:unit_filename_s) ~bytes;
    write_file
      ~path:(Paths.dropin_file ~unit_filename:unit_filename_s)
      ~bytes:(service_dropin_body ~id ~host);
    (unit_filename_s, sha256_hex bytes)

  let write_units ~(spec : Schema.spec) ~(id : Schema.project_id)
      ~project_path ~(host : Schema.host) : Schema.manifest =
    ensure_control_dir ();
    let slice_entry = write_slice ~spec ~id in
    let service_entries =
      Schema.StringMap.bindings spec.services
      |> List.map (fun (_, svc) ->
             write_service ~service:svc ~id ~host ~project_path)
    in
    slice_entry :: service_entries
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)

  let remove_units (unit_filenames : string list) : unit =
    List.iter
      (fun unit_filename ->
        rm_rf (Paths.dropin_dir ~unit_filename);
        (try Sys.remove (Paths.unit_path ~unit_filename)
         with Sys_error _ -> ()))
      unit_filenames
end
