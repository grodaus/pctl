(* Fs — production Unit_store adapter.
 *
 * Owns $XDG_RUNTIME_DIR/systemd/user.control/, the tmpfs-backed directory
 * systemd --user loads unit definitions from. (Not ~/.config/systemd/user
 * — we want a path that survives `systemctl reset-failed` and disappears
 * across reboots.)
 *
 * [create] reads XDG_RUNTIME_DIR each call; tests that swap the env
 * between operations must [create] again so the new value is picked up. *)

type t = { root : string }

type entry = Unit_store_intf.entry = {
  main : string;
  dropin : string option;
}

let xdg_user_control () : string =
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

let create () : t = { root = xdg_user_control () }
let root t = t.root

let unit_path t ~unit_filename = Filename.concat t.root unit_filename
let dropin_dir t ~unit_filename = unit_path t ~unit_filename ^ ".d"

let dropin_file t ~unit_filename =
  Filename.concat (dropin_dir t ~unit_filename) "pctl-runtime.conf"

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

(* ENOENT is the one tolerated errno: removing what is already gone is the
 * idempotence [remove] promises. *)
let unix_or_uninstall_failed p f =
  let fail reason =
    raise (Schema.Pctl_error (Schema.Uninstall_failed { path = p; reason }))
  in
  try f () with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | Unix.Unix_error (e, fn, _) -> fail (fn ^ ": " ^ Unix.error_message e)
  | Sys_error msg -> fail msg

(* lstat, not Sys.file_exists / Sys.is_directory: both follow symlinks, so
 * a dangling link is skipped (and its directory then cannot be removed)
 * and a link to a directory is descended into rather than unlinked. *)
let rec rm_rf p =
  unix_or_uninstall_failed p (fun () ->
      match (Unix.lstat p).st_kind with
      | Unix.S_DIR ->
          Array.iter
            (fun name -> rm_rf (Filename.concat p name))
            (Sys.readdir p);
          Unix.rmdir p
      | _ -> Unix.unlink p)

let write t ~unit_ (entry : entry) : unit =
  mkdir_p t.root;
  let uf_s = Schema.Unit_filename.to_string unit_ in
  write_file ~path:(unit_path t ~unit_filename:uf_s) ~bytes:entry.main;
  match entry.dropin with
  | None -> rm_rf (dropin_dir t ~unit_filename:uf_s)
  | Some body ->
      write_file ~path:(dropin_file t ~unit_filename:uf_s) ~bytes:body

(* ENOENT is the one errno that means "absent"; any other failure raises,
 * since reading it as absent would restart the unit on every reload. *)
let read_file_opt path : string option =
  match Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None
  | exception Unix.Unix_error (e, fn, _) ->
      raise
        (Schema.Pctl_error
           (Schema.Install_failed
              { path; reason = fn ^ ": " ^ Unix.error_message e }))
  | fd -> (
      let ic = Unix.in_channel_of_descr fd in
      try
        Fun.protect
          ~finally:(fun () -> close_in ic)
          (fun () -> Some (really_input_string ic (in_channel_length ic)))
      with Sys_error msg ->
        raise (Schema.Pctl_error (Schema.Install_failed { path; reason = msg })))

let read t ~unit_ : entry option =
  let uf_s = Schema.Unit_filename.to_string unit_ in
  match read_file_opt (unit_path t ~unit_filename:uf_s) with
  | None -> None
  | Some main ->
      Some { main; dropin = read_file_opt (dropin_file t ~unit_filename:uf_s) }

let remove t ~unit_ : unit =
  let uf_s = Schema.Unit_filename.to_string unit_ in
  rm_rf (dropin_dir t ~unit_filename:uf_s);
  let main = unit_path t ~unit_filename:uf_s in
  unix_or_uninstall_failed main (fun () -> Unix.unlink main)

(* Only entries ending in [.slice] or [.service] are pctl-managed main
   unit files. In particular, the companion [<unit>.d/] drop-in
   directory must be excluded — it lives next to the main file and
   readdir surfaces it too. *)
let has_suffix s suf =
  let ns = String.length s and nf = String.length suf in
  ns >= nf && String.sub s (ns - nf) nf = suf

let is_main_unit s = has_suffix s ".slice" || has_suffix s ".service"

let list t : Schema.Unit_filename.t list =
  if not (Sys.file_exists t.root) then []
  else
    Sys.readdir t.root |> Array.to_list
    |> List.filter is_main_unit
    |> List.filter_map Schema.Unit_filename.of_string_opt
    |> List.sort Schema.Unit_filename.compare
