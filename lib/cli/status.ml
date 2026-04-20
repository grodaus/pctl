(* Status — `pctl status [svc] [--path DIR]`.
 *
 * Thin shell-out to `systemctl --user status <unit>`. Oracle: the
 * prior Nushell `status` command. stdout/stderr pipe through; we
 * tolerate systemctl's non-zero exit for inactive units (prints the
 * status report but returns 0 from pctl). *)

let run ~sw ~env ~svc ?path () : int =
  Pipeline.run @@ fun () ->
  let project_path = Pipeline.resolve_path path in
  let id = Identity.derive ~path:project_path in
  let unit_ =
    Schema.Unit_filename.to_string
      (if svc = "" then Schema.Unit_filename.slice ~id
       else Schema.Unit_filename.service ~id ~service:svc)
  in
  let args = [ "systemctl"; "--user"; "status"; unit_ ] in
  let process_mgr = Eio.Stdenv.process_mgr env in
  let proc =
    Eio.Process.spawn ~sw process_mgr
      ~stdout:(Eio.Stdenv.stdout env)
      ~stderr:(Eio.Stdenv.stderr env)
      args
  in
  let (_ : Eio.Process.exit_status) = Eio.Process.await proc in
  ()
