(* Logs — `pctl logs [svc] [-n N] [-f] [--path DIR]`.
 *
 * Shells out to `journalctl --user -u <unit> -n <N> [-f]`. If [svc] is
 * empty we target the project slice; otherwise the service unit.
 * Oracle: the prior Nushell `logs` command. *)

let run ~sw ~env ~svc ?path ?(follow = false) ?(lines = 100) () : int =
  Pipeline.run @@ fun () ->
  let project_path = Pipeline.resolve_path path in
  let id = Identity.derive ~path:project_path in
  let id_s = Schema.Project_id.to_string id in
  let unit_ =
    if svc = "" then Printf.sprintf "pctl-%s.slice" id_s
    else Printf.sprintf "pctl-%s-%s.service" id_s svc
  in
  let base = [ "journalctl"; "--user"; "-u"; unit_; "-n"; string_of_int lines ] in
  let args = if follow then base @ [ "-f" ] else base in
  let process_mgr = Eio.Stdenv.process_mgr env in
  let proc =
    Eio.Process.spawn ~sw process_mgr
      ~stdout:(Eio.Stdenv.stdout env)
      ~stderr:(Eio.Stdenv.stderr env)
      args
  in
  match Eio.Process.await proc with
  | `Exited 0 -> ()
  | `Exited n ->
      raise
        (Schema.Pctl_error
           (Schema.Journalctl_failed { unit_; exit_code = n }))
  | `Signaled n ->
      raise
        (Schema.Pctl_error
           (Schema.Journalctl_failed { unit_; exit_code = 128 + n }))
