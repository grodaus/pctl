(* Gc_cmd — `pctl gc [--yes] [--json]`.
 *
 * Report (default) or purge (--yes) non-Live projects. Delegates to
 * [Pipeline.Prod.purge] for the --yes path so the Systemctl handle
 * lifecycle stays in one place.
 *
 * Oracle: the prior Nushell `gc` command. *)

let run ~sw ~env ?(yes = false) ?(json = false) () : int =
  Pipeline.run @@ fun () ->
  Pipeline.with_connection ~env ~sw @@ fun conn ->
  if yes then begin
    let removed = Pipeline.Prod.purge ~env ~conn in
    if json then Printf.printf "{\"removed\":%d}\n" removed
    else Printf.eprintf "pctl gc: removed %d\n" removed
  end
  else begin
    let report = Gc.report ~conn in
    if json then print_endline (Ls.render_json report)
    else print_string (Ls.render_table report);
    let summary_count cls =
      List.length (List.filter (fun (_, c) -> c = cls) report)
    in
    Printf.eprintf
      "pctl gc: live=%d orphan=%d unknown=%d — pass --yes to delete \
       non-live\n"
      (summary_count Schema.Live)
      (summary_count Schema.Orphan)
      (summary_count Schema.Unknown)
  end
