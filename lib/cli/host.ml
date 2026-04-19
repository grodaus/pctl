(* Host — `pctl host [--path DIR]`.
 *
 * Prints the project's allocated 127.0.0.N on stdout with a trailing
 * newline. If the project has no registry entry (never up'd or already
 * down'd), exits non-zero with a message on stderr that includes the
 * substring "not registered" — matches host_not_registered_test.
 *
 * Oracle: the prior Nushell `host` command. *)

open Common

let run ~sw ~env ?path () : int =
  run_with_errors (fun () ->
      let project_path = resolve_path path in
      let id = Identity.derive ~path:project_path in
      let project_id_s = Schema.Project_id.to_string id in
      with_connection ~env ~sw (fun conn ->
          match State.Projects.get_by_id conn ~id:project_id_s with
          | None | Some { host = None; _ } ->
              raise
                (Schema.Pctl_error
                   (Schema.Registry_io
                      {
                        id = project_id_s;
                        reason =
                          Printf.sprintf
                            "project %s is not registered — run `pctl \
                             up` first"
                            project_id_s;
                      }))
          | Some { host = Some h; _ } -> print_endline h))
