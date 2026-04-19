(* Host — `pctl host [--path DIR]`.
 *
 * Prints the project's allocated 127.0.0.N on stdout with a trailing
 * newline. If the project has no registry entry (never up'd or already
 * down'd), exits non-zero with a stderr message containing
 * "not registered" (matches host_not_registered_test).
 *
 * Oracle: the prior Nushell `host` command. *)

let run ~sw ~env ?path () : int =
  Pipeline.run @@ fun () ->
  let project_path = Pipeline.resolve_path path in
  let id = Identity.derive ~path:project_path in
  let id_s = Schema.Project_id.to_string id in
  Pipeline.with_connection ~env ~sw @@ fun conn ->
  match State.Projects.get_by_id conn ~id:id_s with
  | None | Some { host = None; _ } ->
      raise
        (Schema.Pctl_error
           (Schema.Registry_io
              {
                id = id_s;
                reason =
                  Printf.sprintf
                    "project %s is not registered — run `pctl up` first"
                    id_s;
              }))
  | Some { host = Some h; _ } -> print_endline h
