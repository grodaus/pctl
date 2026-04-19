(* Restart — restart a single service (or the slice if svc = "").
 *
 * Oracle: pctl/commands/restart.nu. The filename for a service is
 * pctl-<id>-<svc>.service; if svc is empty (i.e. caller didn't pass one),
 * the restart targets pctl-<id>.slice — mirrors Nushell `unit-for`.
 *
 * Phase 4 brief signature takes `~svc:string` (required). We accept an
 * empty string as "restart the slice" so the cmdliner layer can emit a
 * clean `pctl restart` (no arg) that bounces the slice. Phase 5+ can
 * split if needed. *)

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
      let t = Systemctl.Dbus.connect ~sw env in
      Systemctl.Dbus.restart_unit t ~unit:unit_;
      Printf.printf "restarted %s\n" unit_)
