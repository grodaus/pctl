(* Spec — spec.json loader.
 *
 * Reads a spec.json file emitted by `nix/lib/mkProject.nix` and returns
 * a typed [Schema.spec]. Rejects:
 *   - missing file                             → Spec_not_found
 *   - invalid JSON / schema mismatch           → Spec_parse
 *   - version != 2                             → Spec_unknown_version
 *   - unknown service kind                     → Spec_parse (via kind_of_yojson)
 *   - non-string service_config values         → Spec_parse (via string_map_of_yojson)
 *
 * Uses [ppx_deriving_yojson] for the bulk of the structural parse; a
 * thin wrapper catches invalid JSON and re-raises [Pctl_error
 * (Spec_parse _)].
 *
 * See docs/src/plans/20260419-ocaml-rewrite.md → "spec.json schema v2". *)

open Schema

(* ---- Kind / workspace / probe JSON mappings ------------------------ *)

let kind_to_yojson k : Yojson.Safe.t = `String (kind_to_string k)

let kind_of_yojson = function
  | `String s -> (
      match kind_of_string s with
      | Some k -> Ok k
      | None ->
          Error
            (Printf.sprintf
               "unknown service kind '%s' \
                (accepted: simple/oneshot/forking/notify/dbus/idle)"
               s))
  | _ -> Error "service kind must be a string"

(* service_config / slice_config: Nix coerces every value to a string via
 * `lib.mapAttrs (_: toString)`. Reject anything that isn't a JSON string
 * with a precise error naming the offending key. *)
let string_map_of_yojson = function
  | `Assoc fs ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | (k, `String v) :: tl -> loop ((k, v) :: acc) tl
        | (k, _) :: _ ->
            Error
              (Printf.sprintf
                 "service_config['%s'] must be a string (every value is \
                  coerced to string by mkProject)"
                 k)
      in
      loop [] fs
  | _ -> Error "service_config must be a JSON object"

let string_map_to_yojson (pairs : (string * string) list) : Yojson.Safe.t =
  `Assoc (List.map (fun (k, v) -> (k, `String v)) pairs)

(* ---- Wire records — one per level ----------------------------------- *)

type probe_json = {
  exec : string list;
  period_seconds : int; [@default 1]
  timeout_seconds : int; [@default 30]
}
[@@deriving yojson { strict = false }]

type workspace_json = {
  cwd : bool; [@default false]
  writable : bool; [@default false]
}
[@@deriving yojson { strict = false }]

(* Service entry as it appears inside `services.<name>`. The service's
 * name is the outer JSON key and is set by the decoder; on the wire we
 * don't re-emit it inside the value. *)
type service_json = {
  kind : kind;
      [@to_yojson kind_to_yojson] [@of_yojson kind_of_yojson]
  service_config : (string * string) list;
      [@of_yojson string_map_of_yojson]
      [@to_yojson string_map_to_yojson]
  depends_on : string list; [@default []]
  workspace : workspace_json;
      [@default { cwd = false; writable = false }]
  probe : probe_json option; [@default None]
}
[@@deriving yojson { strict = false }]

type slice_json = {
  slice_config : (string * string) list;
      [@default []]
      [@of_yojson string_map_of_yojson]
      [@to_yojson string_map_to_yojson]
}
[@@deriving yojson { strict = false }]

let probe_of_json (p : probe_json) : probe =
  { exec = p.exec; period_seconds = p.period_seconds;
    timeout_seconds = p.timeout_seconds }

let workspace_of_json (w : workspace_json) : workspace_spec =
  { cwd = w.cwd; writable = w.writable }

(* ---- Entry points --------------------------------------------------- *)

let decode_services (j : Yojson.Safe.t) :
    (service_spec StringMap.t, string) result =
  match j with
  | `Assoc fs ->
      let rec loop acc = function
        | [] -> Ok acc
        | (name, svc_j) :: tl -> (
            match service_json_of_yojson svc_j with
            | Ok s ->
                let spec : service_spec =
                  {
                    name;
                    kind = s.kind;
                    depends_on = s.depends_on;
                    workspace = workspace_of_json s.workspace;
                    probe = Option.map probe_of_json s.probe;
                    service_config = s.service_config;
                  }
                in
                loop (StringMap.add name spec acc) tl
            | Error e -> Error (Printf.sprintf "services.%s: %s" name e))
      in
      loop StringMap.empty fs
  | _ -> Error "services must be a JSON object"

let parse ~path (j : Yojson.Safe.t) : spec =
  let ( let* ) = Result.bind in
  let result =
    match j with
    | `Assoc fs ->
        let get k =
          match List.assoc_opt k fs with
          | Some v -> Ok v
          | None -> Error (Printf.sprintf "missing required field '%s'" k)
        in
        let* version =
          match get "version" with
          | Ok (`Int n) -> Ok n
          | Ok (`Intlit s) -> (
              match int_of_string_opt s with
              | Some n -> Ok n
              | None ->
                  Error (Printf.sprintf "'version' must be an int, got %s" s))
          | Ok _ -> Error "'version' must be an int"
          | Error e -> Error e
        in
        let* slice_j = get "slice" in
        let* slice = slice_json_of_yojson slice_j in
        let* services_j = get "services" in
        let* services = decode_services services_j in
        Ok (version, slice, services)
    | _ -> Error "spec must be a JSON object"
  in
  match result with
  | Error msg -> raise (Pctl_error (Spec_parse { path; msg }))
  | Ok (version, slice, services) ->
      if version <> 2 then raise (Pctl_error (Spec_unknown_version version));
      { version; slice = { slice_config = slice.slice_config }; services }

let load (p : Fpath.t) : spec =
  let path = Fpath.to_string p in
  if not (Sys.file_exists path) then
    raise (Pctl_error (Spec_not_found { path }));
  let json =
    try Yojson.Safe.from_file path
    with
    | Yojson.Json_error msg -> raise (Pctl_error (Spec_parse { path; msg }))
    | Sys_error msg -> raise (Pctl_error (Spec_parse { path; msg }))
  in
  parse ~path json
