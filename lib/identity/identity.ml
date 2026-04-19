(* Project identity — ported from pctl/lib/identity.nu `derive-id`.
 *
 * The nushell implementation is the behavioural oracle: the OCaml port
 * must produce byte-identical ids for every path, so Phase 7 can swap
 * the binaries with zero rename of installed slices. See test/unit for
 * the fixture-parity anchors. *)

open Schema

(* ------------------------------------------------------------------ *)
(* Path expansion — faithful port of nushell's `path expand` for absolute
 * inputs. Normalizes ./ and ../ and collapses repeated slashes. Does NOT
 * resolve symlinks and does NOT require the path to exist. Relative input
 * is resolved against Sys.getcwd () — mirrors nushell behaviour. *)
(* ------------------------------------------------------------------ *)

let split_path s =
  let n = String.length s in
  let rec loop i acc_start acc =
    if i = n then
      let seg = String.sub s acc_start (n - acc_start) in
      List.rev (seg :: acc)
    else if s.[i] = '/' then
      let seg = String.sub s acc_start (i - acc_start) in
      loop (i + 1) (i + 1) (seg :: acc)
    else loop (i + 1) acc_start acc
  in
  loop 0 0 []

let normalize_absolute path =
  let segs = split_path path in
  let rec fold acc = function
    | [] -> List.rev acc
    | "" :: tl -> fold acc tl
    | "." :: tl -> fold acc tl
    | ".." :: tl -> (
        match acc with _ :: rest -> fold rest tl | [] -> fold [] tl)
    | seg :: tl -> fold (seg :: acc) tl
  in
  let parts = fold [] segs in
  "/" ^ String.concat "/" parts

let path_expand raw =
  let abs =
    if String.length raw > 0 && raw.[0] = '/' then raw
    else Filename.concat (Sys.getcwd ()) raw
  in
  normalize_absolute abs

let basename_of_path p =
  let p =
    if String.length p > 1 && p.[String.length p - 1] = '/' then
      String.sub p 0 (String.length p - 1)
    else p
  in
  match String.rindex_opt p '/' with
  | Some i -> String.sub p (i + 1) (String.length p - i - 1)
  | None -> p

(* ------------------------------------------------------------------ *)
(* sanitize-basename — 1:1 port of pctl/lib/identity.nu:1-10.           *)
(* ------------------------------------------------------------------ *)

let sanitize_basename raw =
  let lowered =
    String.map
      (fun c ->
        if c >= 'A' && c <= 'Z' then Char.chr (Char.code c + 32) else c)
      raw
  in
  let underscored =
    String.map
      (fun c ->
        if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_' then c
        else '_')
      lowered
  in
  let buf = Buffer.create (String.length underscored) in
  let prev_underscore = ref false in
  String.iter
    (fun c ->
      if c = '_' then (
        if not !prev_underscore then Buffer.add_char buf '_';
        prev_underscore := true)
      else (
        Buffer.add_char buf c;
        prev_underscore := false))
    underscored;
  let collapsed = Buffer.contents buf in
  let n = String.length collapsed in
  let lo = ref 0 in
  while !lo < n && collapsed.[!lo] = '_' do
    incr lo
  done;
  let hi = ref (n - 1) in
  while !hi >= !lo && collapsed.[!hi] = '_' do
    decr hi
  done;
  let trimmed =
    if !lo > !hi then "" else String.sub collapsed !lo (!hi - !lo + 1)
  in
  if trimmed = "" then "project" else trimmed

(* ------------------------------------------------------------------ *)
(* hash8 — first 8 hex chars of SHA-256 over the absolute path.         *)
(* digestif chosen for Phase 1 (ocamlPackages.digestif 1.3.0).          *)
(* ------------------------------------------------------------------ *)

let sha256_hex s = Digestif.SHA256.(digest_string s |> to_hex)
let hash8 abs_path = String.sub (sha256_hex abs_path) 0 8

(* Public API *)

let derive ~path =
  let abs = path_expand path in
  let raw_base = basename_of_path abs in
  let base = sanitize_basename raw_base in
  let h8 = hash8 abs in
  Project_id.of_string_exn (base ^ "_" ^ h8)

(* Re-export the sibling module so `Identity.Host_alloc.allocate` is
 * reachable from dependents without needing `(wrapped false)`. *)
module Host_alloc = Host_alloc
