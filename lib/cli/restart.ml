(* Restart — restart a single service (or the slice if svc = "").
 *
 * Oracle: the prior Nushell `restart` command. The filename for a service is
 * pctl-<id>-<svc>.service; if svc is empty (caller didn't pass one), the
 * restart targets pctl-<id>.slice — mirrors Nushell `unit-for`. The
 * empty-string sentinel lets cmdliner emit a clean `pctl restart` (no
 * arg) that bounces the slice. *)

open Common

let run ~sw ~env ~svc ?path () : int =
  run_with_errors (fun () ->
      let project_path = resolve_path path in
      let id = Identity.derive ~path:project_path in
      let id_s = Schema.Project_id.to_string id in
      let unit_ =
        if svc = "" then Printf.sprintf "pctl-%s.slice" id_s
        else Printf.sprintf "pctl-%s-%s.service" id_s svc
      in
      (* Opportunistic sweep: scoped DB connection so restart doesn't keep
       * the SQLite file open longer than needed. *)
      with_connection ~env ~sw (fun conn ->
          opportunistic_sweep ~env ~sw ~conn;
          let t = Systemctl.Dbus.connect ~sw env in
          Systemctl.Dbus.restart_unit t ~unit:unit_);
      Printf.printf "restarted %s\n" unit_)
