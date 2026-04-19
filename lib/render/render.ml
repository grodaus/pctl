(* Pure rendering: spec → systemd ini-format unit bytes.
 *
 * Placeholder semantics ported from pctl/lib/install.nu:22-27 — plain
 * string replacement, no escaping. Applied to both unit filenames and
 * every value written into `[Service]`, `[Slice]`, `[Unit]`. *)

open Schema

(* ------------------------------------------------------------------ *)
(* Substitution                                                         *)
(* ------------------------------------------------------------------ *)

let replace_all ~needle ~replacement s =
  (* String.replace isn't in stdlib; hand-rolled search-and-splice.
   * Terminates because needle is non-empty. *)
  if needle = "" then s
  else
    let nlen = String.length needle in
    let slen = String.length s in
    let buf = Buffer.create slen in
    let i = ref 0 in
    while !i <= slen - nlen do
      if String.sub s !i nlen = needle then (
        Buffer.add_string buf replacement;
        i := !i + nlen)
      else (
        Buffer.add_char buf s.[!i];
        incr i)
    done;
    Buffer.add_substring buf s !i (slen - !i);
    Buffer.contents buf

let substitute s ~id ~project_path =
  s
  |> replace_all ~needle:"@@PROJECT@@" ~replacement:(Project_id.to_string id)
  |> replace_all ~needle:"@@PROJECT_PATH@@" ~replacement:project_path

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
 * whitespace-separated scalar: nix/lib/mkProject.nix (before the rewrite)
 * wrote `BindPaths=<path1> <path2>`. systemd accepts that form, but so it
 * does one-line-per-path form — the one-line form is clearer and stays
 * valid if any path contains a space (which none do in practice, but
 * costs us nothing). Split on whitespace, emit one line per entry. *)
let split_ws s =
  let n = String.length s in
  let buf = Buffer.create 16 in
  let parts = ref [] in
  let flush () =
    if Buffer.length buf > 0 then (
      parts := Buffer.contents buf :: !parts;
      Buffer.clear buf)
  in
  for i = 0 to n - 1 do
    match s.[i] with
    | ' ' | '\t' | '\n' | '\r' -> flush ()
    | c -> Buffer.add_char buf c
  done;
  flush ();
  List.rev !parts

let expand_key k v =
  (* Returns a list of (key, value) tuples. Most keys pass through
   * unchanged; BindPaths expands to multiple lines iff the value contains
   * whitespace. *)
  if k = "BindPaths" then
    match split_ws v with
    | [] -> []
    | [ single ] -> [ (k, single) ]
    | many -> List.map (fun p -> (k, p)) many
  else [ (k, v) ]

let expand_entries kvs =
  List.concat_map (fun (k, v) -> expand_key k v) kvs

let substitute_values kvs ~id ~project_path =
  List.map (fun (k, v) -> (k, substitute v ~id ~project_path)) kvs

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
  (* service_config without Description (we emit that in [Unit]). *)
  let sc_wo_desc = List.filter (fun (k, _) -> k <> "Description") sc in
  let service_kvs =
    sc_wo_desc |> expand_entries |> substitute_values ~id ~project_path
  in
  let buf = Buffer.create 512 in
  Buffer.add_string buf (emit_section ~header:"Unit" unit_kvs);
  Buffer.add_char buf '\n';
  Buffer.add_string buf (emit_section ~header:"Service" service_kvs);
  Buffer.contents buf

(* ------------------------------------------------------------------ *)
(* Slice render                                                         *)
(* ------------------------------------------------------------------ *)

let slice ~(slice : slice_spec) ~(id : project_id) ~project_path =
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
  let slice_kvs =
    sc_wo_desc |> expand_entries |> substitute_values ~id ~project_path
  in
  let buf = Buffer.create 256 in
  Buffer.add_string buf (emit_section ~header:"Unit" unit_kvs);
  Buffer.add_char buf '\n';
  Buffer.add_string buf (emit_section ~header:"Slice" slice_kvs);
  Buffer.contents buf
