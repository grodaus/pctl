(* Spec — spec.json loader.
 *
 * Reads a spec.json file emitted by `nix/lib/mkProject.nix` and returns
 * a typed [Schema.spec]. Rejects:
 *   - missing file                             → Spec_not_found
 *   - invalid JSON                             → Spec_parse
 *   - missing or wrong-type fields             → Spec_parse
 *   - version != 1                             → Spec_unknown_version
 *   - unknown service kind                     → Spec_parse
 *   - non-string service_config values         → Spec_parse
 *
 * We parse by hand rather than via [ppx_deriving_yojson] because:
 *   - service_config values must be rejected if non-string with a
 *     precise error naming the offending key — the ppx can only do
 *     generic "expected string" messages;
 *   - optional fields that default to sentinels (empty list / false /
 *     None) map more naturally to hand-written record construction;
 *   - the `services` field is a JSON object, mapped to
 *     [Schema.service_spec StringMap.t] — not a list — which the ppx
 *     can't express without extra plumbing.
 *
 * See docs/src/plans/20260419-ocaml-rewrite.md → "spec.json schema v1". *)

open Schema

let spec_parse ~path msg =
  raise (Pctl_error (Spec_parse { path; msg }))

(* ---- Small helpers ---------------------------------------------- *)

let assoc_opt k = function
  | `Assoc fs -> List.assoc_opt k fs
  | _ -> None

let require_field ~path ~what ~field j =
  match assoc_opt field j with
  | Some v -> v
  | None ->
      spec_parse ~path
        (Printf.sprintf "%s: missing required field '%s'" what field)

let require_string ~path ~what ~field j =
  match require_field ~path ~what ~field j with
  | `String s -> s
  | v ->
      spec_parse ~path
        (Printf.sprintf "%s: field '%s' must be a string, got %s" what field
           (Yojson.Safe.to_string v))

let as_string_list ~path ~what ~field = function
  | `List items ->
      List.map
        (function
          | `String s -> s
          | v ->
              spec_parse ~path
                (Printf.sprintf
                   "%s: field '%s' must be a list of strings, got %s"
                   what field (Yojson.Safe.to_string v)))
        items
  | v ->
      spec_parse ~path
        (Printf.sprintf "%s: field '%s' must be a list, got %s" what field
           (Yojson.Safe.to_string v))

let as_bool_or ~path ~what ~field default = function
  | None -> default
  | Some (`Bool b) -> b
  | Some v ->
      spec_parse ~path
        (Printf.sprintf "%s: field '%s' must be a boolean, got %s" what field
           (Yojson.Safe.to_string v))

let as_int_or ~path ~what ~field default = function
  | None -> default
  | Some (`Int n) -> n
  | Some (`Intlit s) -> (
      try int_of_string s
      with _ ->
        spec_parse ~path
          (Printf.sprintf "%s: field '%s' must be an int, got %s" what field s))
  | Some v ->
      spec_parse ~path
        (Printf.sprintf "%s: field '%s' must be an int, got %s" what field
           (Yojson.Safe.to_string v))

(* service_config: Nix coerces every value to a string via
 * `lib.mapAttrs (_: toString)`. Reject anything that isn't a
 * JSON string with a precise error naming the offending key. *)
let parse_service_config ~path ~what j : (string * string) list =
  match j with
  | `Assoc fs ->
      List.map
        (fun (k, v) ->
          match v with
          | `String s -> (k, s)
          | _ ->
              spec_parse ~path
                (Printf.sprintf
                   "%s: service_config['%s'] must be a string, got %s"
                   what k (Yojson.Safe.to_string v)))
        fs
  | v ->
      spec_parse ~path
        (Printf.sprintf "%s: service_config must be a JSON object, got %s"
           what (Yojson.Safe.to_string v))

(* ---- Field parsers ---------------------------------------------- *)

let parse_kind ~path ~what = function
  | `String s -> (
      match kind_of_string s with
      | Some k -> k
      | None ->
          spec_parse ~path
            (Printf.sprintf
               "%s: unknown service kind '%s' \
                (accepted: simple/oneshot/forking/notify/dbus/idle)"
               what s))
  | v ->
      spec_parse ~path
        (Printf.sprintf "%s: field 'kind' must be a string, got %s" what
           (Yojson.Safe.to_string v))

let parse_workspace ~path ~what j : workspace_spec =
  match j with
  | `Null -> { cwd = false; writable = false }
  | `Assoc _ ->
      let cwd =
        as_bool_or ~path ~what ~field:"workspace.cwd" false (assoc_opt "cwd" j)
      in
      let writable =
        as_bool_or ~path ~what ~field:"workspace.writable" false
          (assoc_opt "writable" j)
      in
      { cwd; writable }
  | v ->
      spec_parse ~path
        (Printf.sprintf "%s: workspace must be a JSON object, got %s" what
           (Yojson.Safe.to_string v))

let parse_probe ~path ~what j : probe option =
  match j with
  | `Null -> None
  | `Assoc _ ->
      let exec_j =
        require_field ~path ~what:(what ^ ".probe") ~field:"exec" j
      in
      let exec =
        as_string_list ~path ~what:(what ^ ".probe") ~field:"exec" exec_j
      in
      let period_seconds =
        as_int_or ~path ~what:(what ^ ".probe") ~field:"period_seconds" 1
          (assoc_opt "period_seconds" j)
      in
      let timeout_seconds =
        as_int_or ~path ~what:(what ^ ".probe") ~field:"timeout_seconds" 30
          (assoc_opt "timeout_seconds" j)
      in
      Some { exec; period_seconds; timeout_seconds }
  | v ->
      spec_parse ~path
        (Printf.sprintf "%s.probe: must be a JSON object or null, got %s"
           what (Yojson.Safe.to_string v))

let parse_service ~path ~name j : service_spec =
  let what = Printf.sprintf "services.%s" name in
  let kind_j = require_field ~path ~what ~field:"kind" j in
  let kind = parse_kind ~path ~what kind_j in
  let unit_filename = require_string ~path ~what ~field:"unit_filename" j in
  let service_config_j =
    require_field ~path ~what ~field:"service_config" j
  in
  let service_config = parse_service_config ~path ~what service_config_j in
  let depends_on =
    match assoc_opt "depends_on" j with
    | None -> []
    | Some v -> as_string_list ~path ~what ~field:"depends_on" v
  in
  let workspace =
    match assoc_opt "workspace" j with
    | None -> { cwd = false; writable = false }
    | Some v -> parse_workspace ~path ~what v
  in
  let probe =
    match assoc_opt "probe" j with
    | None -> None
    | Some v -> parse_probe ~path ~what v
  in
  { name; kind; depends_on; workspace; probe; unit_filename; service_config }

let parse_slice ~path j : slice_spec =
  let what = "slice" in
  let unit_filename = require_string ~path ~what ~field:"unit_filename" j in
  let slice_config =
    match assoc_opt "slice_config" j with
    | None -> []
    | Some sc ->
        (* slice_config has the same string-only value constraint as
         * service_config. *)
        parse_service_config ~path ~what:"slice" sc
  in
  { unit_filename; slice_config }

let parse_services ~path j : service_spec StringMap.t =
  match j with
  | `Assoc fields ->
      List.fold_left
        (fun acc (name, svc_j) ->
          StringMap.add name (parse_service ~path ~name svc_j) acc)
        StringMap.empty fields
  | v ->
      spec_parse ~path
        (Printf.sprintf "services: must be a JSON object, got %s"
           (Yojson.Safe.to_string v))

(* ---- Top-level ---------------------------------------------- *)

let parse ~path (j : Yojson.Safe.t) : spec =
  let version =
    match assoc_opt "version" j with
    | None -> spec_parse ~path "missing required field 'version'"
    | Some (`Int n) -> n
    | Some (`Intlit s) -> (
        try int_of_string s
        with _ ->
          spec_parse ~path (Printf.sprintf "'version' must be an int, got %s" s))
    | Some v ->
        spec_parse ~path
          (Printf.sprintf "'version' must be an int, got %s"
             (Yojson.Safe.to_string v))
  in
  if version <> 1 then raise (Pctl_error (Spec_unknown_version version));
  let slice_j = require_field ~path ~what:"spec" ~field:"slice" j in
  let slice = parse_slice ~path slice_j in
  let services_j = require_field ~path ~what:"spec" ~field:"services" j in
  let services = parse_services ~path services_j in
  { version; slice; services }

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
