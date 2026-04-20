(* See [project_paths.mli] for the contract. *)

type t = {
  project : Schema.project_path;
  spec_file : Fpath.t;
}

module type NIX = Nix_build.S

(* `nix build --print-out-paths` emits a trailing newline on stdout. *)
let rtrim_ws s =
  let len = String.length s in
  let rec last i =
    if i < 0 then -1
    else match s.[i] with ' ' | '\t' | '\n' | '\r' -> last (i - 1) | _ -> i
  in
  let i = last (len - 1) in
  if i = len - 1 then s else String.sub s 0 (i + 1)

let parse_spec_file raw =
  let trimmed = rtrim_ws raw in
  if String.length trimmed = 0 then Error "empty spec file path"
  else
    match Fpath.v trimmed with
    | exception Invalid_argument msg -> Error msg
    | p ->
        if Fpath.is_abs p then Ok p
        else
          Error
            (Printf.sprintf "spec file path '%s' is not absolute" trimmed)

let resolve ~env ~sw ~nix:(module N : NIX) ?tree ?nix_attr project =
  let raw =
    match tree with
    | Some t when t <> "" -> t
    | _ ->
        let attr =
          match nix_attr with Some n when n <> "" -> n | _ -> ".#pctl"
        in
        N.out_path ~attr ~cwd:project ~env ~sw
  in
  match parse_spec_file raw with
  | Ok spec_file -> { project; spec_file }
  | Error reason ->
      raise (Schema.Pctl_error (Schema.Identity_invalid { path = raw; reason }))
