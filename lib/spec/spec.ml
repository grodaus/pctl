(* Spec — spec.json loader.
 *
 * Reads a spec.json file emitted by `nix/lib/mkProject.nix` and returns
 * a typed [Schema.spec]. Rejects:
 *   - missing file                             → Spec_not_found
 *   - invalid JSON / schema mismatch           → Spec_parse
 *   - version != 1                             → Spec_unknown_version
 *   - unknown service kind                     → Spec_parse (via kind_of_yojson)
 *   - non-string service_config values         → Spec_parse (via string_map_of_yojson)
 *
 * Uses [ppx_deriving_yojson] for the bulk of the structural parse; a
 * single wrapper catches [Type_error] / [Json_error] and raises
 * [Pctl_error (Spec_parse _)] with the ppx's own error message. A tiny
 * validator runs after parse for cross-field checks (version == 1).
 *
 * See docs/src/plans/20260419-ocaml-rewrite.md → "spec.json schema v1". *)

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

(* ---- Wire-format records (mirror spec.json v1) --------------------- *)

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

type service_json = {
  kind : kind;
      [@to_yojson kind_to_yojson] [@of_yojson kind_of_yojson]
  unit_filename : string;
  service_config : (string * string) list;
      [@of_yojson string_map_of_yojson]
      [@to_yojson string_map_to_yojson]
  depends_on : string list; [@default []]
  workspace : workspace_json option; [@default None]
  probe : probe_json option; [@default None]
}
[@@deriving yojson { strict = false }]

type slice_json = {
  unit_filename : string;
  slice_config : (string * string) list;
      [@default []]
      [@of_yojson string_map_of_yojson]
      [@to_yojson string_map_to_yojson]
}
[@@deriving yojson { strict = false }]

type spec_json = {
  version : int;
  slice : slice_json;
  services : (string * service_json) list;
}
[@@deriving of_yojson { strict = false }]

(* Sort-agnostic decoder for a JSON object keyed by service name. The
 * ppx handles `(string * t) list` by expecting a JSON list of pairs; we
 * want an object. Hand-wrap at this one spot. *)
let services_of_yojson j : ((string * service_json) list, string) result =
  match j with
  | `Assoc fs ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | (name, svc_j) :: tl -> (
            match service_json_of_yojson svc_j with
            | Ok svc -> loop ((name, svc) :: acc) tl
            | Error e -> Error (Printf.sprintf "services.%s: %s" name e))
      in
      loop [] fs
  | _ -> Error "services must be a JSON object"

let spec_json_of_yojson j : (spec_json, string) result =
  let ( let* ) = Result.bind in
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
            | None -> Error (Printf.sprintf "'version' must be an int, got %s" s))
        | Ok _ -> Error "'version' must be an int"
        | Error e -> Error e
      in
      let* slice_j = get "slice" in
      let* slice = slice_json_of_yojson slice_j in
      let* services_j = get "services" in
      let* services = services_of_yojson services_j in
      Ok { version; slice; services }
  | _ -> Error "spec must be a JSON object"

(* ---- Lift wire records into Schema values -------------------------- *)

let workspace_of_json : workspace_json option -> workspace_spec = function
  | None -> { cwd = false; writable = false }
  | Some { cwd; writable } -> { cwd; writable }

let probe_of_json : probe_json option -> probe option = function
  | None -> None
  | Some { exec; period_seconds; timeout_seconds } ->
      Some { exec; period_seconds; timeout_seconds }

let service_of_json ~name (s : service_json) : service_spec =
  {
    name;
    kind = s.kind;
    depends_on = s.depends_on;
    workspace = workspace_of_json s.workspace;
    probe = probe_of_json s.probe;
    unit_filename = s.unit_filename;
    service_config = s.service_config;
  }

let slice_of_json (s : slice_json) : slice_spec =
  { unit_filename = s.unit_filename; slice_config = s.slice_config }

let spec_of_json (sj : spec_json) : spec =
  if sj.version <> 1 then
    raise (Pctl_error (Spec_unknown_version sj.version));
  let services =
    List.fold_left
      (fun acc (name, svc) ->
        StringMap.add name (service_of_json ~name svc) acc)
      StringMap.empty sj.services
  in
  { version = sj.version; slice = slice_of_json sj.slice; services }

(* ---- Entry points --------------------------------------------------- *)

let parse ~path (j : Yojson.Safe.t) : spec =
  match spec_json_of_yojson j with
  | Ok sj -> spec_of_json sj
  | Error msg -> raise (Pctl_error (Spec_parse { path; msg }))

let load ~path : spec =
  if not (Sys.file_exists path) then
    raise (Pctl_error (Spec_not_found { path }));
  let json =
    try Yojson.Safe.from_file path
    with
    | Yojson.Json_error msg -> raise (Pctl_error (Spec_parse { path; msg }))
    | Sys_error msg -> raise (Pctl_error (Spec_parse { path; msg }))
  in
  parse ~path json
