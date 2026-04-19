(* Pure rendering: spec → systemd ini-format unit bytes.
 *
 * Bundle-3 simplification: the `@@PROJECT@@` / `@@PROJECT_PATH@@`
 * placeholder convention is gone. Values that need the project id or
 * path (StateDirectory-style id-prefixed names, BindPaths for writable
 * workspaces, WorkingDirectory for cwd workspaces) are computed here
 * from [workspace] on the [service_spec] directly. *)

open Schema

(* ------------------------------------------------------------------ *)
(* Ini helpers                                                          *)
(* ------------------------------------------------------------------ *)

let emit_section ~header kvs =
  let buf = Buffer.create 256 in
  Buffer.add_string buf (Printf.sprintf "[%s]\n" header);
  List.iter
    (fun (k, v) ->
      Buffer.add_string buf (Printf.sprintf "%s=%s\n" k v))
    kvs;
  Buffer.contents buf

(* BindPaths is the one systemd directive pctl currently emits as a
 * whitespace-separated scalar: nix/lib/mkProject.nix writes
 * `BindPaths=<path1> <path2>`. systemd accepts that form, but so does
 * the one-line-per-path form — the one-line form is clearer and stays
 * valid if any path contains a space (which none do in practice).
 * Input only ever contains space-separated paths; tabs/newlines would
 * be a spec bug upstream. *)
let split_ws s =
  String.split_on_char ' ' s |> List.filter (fun p -> p <> "")

(* Expand a single (k, v) in service_config into one or more output
 * lines. Most keys pass through unchanged; [BindPaths] carrying multiple
 * whitespace-separated paths expands to one line per path (systemd
 * accepts a single space-separated line, but per-line form is clearer
 * and stays correct if any path ever contains a space). *)
let expand_key k v =
  if k = "BindPaths" then
    match split_ws v with
    | [] -> []
    | [ single ] -> [ (k, single) ]
    | many -> List.map (fun p -> (k, p)) many
  else [ (k, v) ]

let expand_entries kvs = List.concat_map (fun (k, v) -> expand_key k v) kvs

(* ------------------------------------------------------------------ *)
(* Workspace-derived [Service] keys                                     *)
(* ------------------------------------------------------------------ *)

(* Given a [workspace] and the project path, produce the keys the
 * workspace flags imply. mkProject.nix used to emit these with
 * `@@PROJECT_PATH@@` placeholders; now we compute them at render time
 * from real values we already have in scope. *)
let workspace_keys ~(ws : workspace_spec) ~project_path : (string * string) list =
  let cwd_keys =
    if ws.cwd then [ ("WorkingDirectory", project_path) ] else []
  in
  let writable_keys =
    if ws.writable then
      [ ("ProtectHome", "tmpfs"); ("BindPaths", project_path) ]
    else []
  in
  cwd_keys @ writable_keys

(* systemd directives whose value is a name scoped into
 * /var/lib, /run, /tmp etc. — user writes a logical suffix
 * ("pg", "server"), we prefix with `pctl-<id>-` to namespace per
 * project. Keeps distinct projects' state dirs from colliding. *)
let id_prefixed_value_keys =
  [
    "StateDirectory";
    "RuntimeDirectory";
    "CacheDirectory";
    "LogsDirectory";
    "ConfigurationDirectory";
  ]

let apply_id_prefix ~(id : project_id) (k, v) =
  if List.mem k id_prefixed_value_keys && v <> "" then
    (k, Printf.sprintf "pctl-%s-%s" (Project_id.to_string id) v)
  else (k, v)

(* ------------------------------------------------------------------ *)
(* Service render                                                       *)
(* ------------------------------------------------------------------ *)

let description_for ~service_name ~id =
  Printf.sprintf "pctl service %s for %s" service_name
    (Project_id.to_string id)

let service ~(service : service_spec) ~(id : project_id) ~project_path =
  let sc = service.service_config in
  (* User-supplied Description wins over our generated default. *)
  let user_description = List.assoc_opt "Description" sc in
  let unit_kvs =
    [
      ( "Description",
        Option.value user_description
          ~default:(description_for ~service_name:service.name ~id) );
    ]
  in
  (* service_config without Description (we emit that in [Unit]), plus:
   *   - Slice=pctl-<id>.slice so the service is tied to its project slice;
   *   - workspace-derived keys (WorkingDirectory/BindPaths/ProtectHome).
   * User-supplied keys win iff they name the same key — we append
   * defaults AFTER the user's entries and drop any whose key the user
   * already set. *)
  let user_keys = List.map fst sc in
  let defaults =
    ("Slice", Schema.slice_filename ~id)
    :: workspace_keys ~ws:service.workspace ~project_path
  in
  let extra =
    List.filter (fun (k, _) -> not (List.mem k user_keys)) defaults
  in
  let sc_wo_desc = List.filter (fun (k, _) -> k <> "Description") sc in
  let service_kvs =
    (sc_wo_desc @ extra)
    |> List.map (apply_id_prefix ~id)
    |> expand_entries
  in
  let buf = Buffer.create 512 in
  Buffer.add_string buf (emit_section ~header:"Unit" unit_kvs);
  Buffer.add_char buf '\n';
  Buffer.add_string buf (emit_section ~header:"Service" service_kvs);
  Buffer.contents buf

(* ------------------------------------------------------------------ *)
(* Slice render                                                         *)
(* ------------------------------------------------------------------ *)

let slice ~(slice : slice_spec) ~(id : project_id) =
  let sc = slice.slice_config in
  let user_description = List.assoc_opt "Description" sc in
  let unit_kvs =
    [
      ( "Description",
        Option.value user_description
          ~default:
            (Printf.sprintf "pctl slice for %s" (Project_id.to_string id)) );
    ]
  in
  let sc_wo_desc = List.filter (fun (k, _) -> k <> "Description") sc in
  let buf = Buffer.create 256 in
  Buffer.add_string buf (emit_section ~header:"Unit" unit_kvs);
  Buffer.add_char buf '\n';
  Buffer.add_string buf (emit_section ~header:"Slice" (expand_entries sc_wo_desc));
  Buffer.contents buf
