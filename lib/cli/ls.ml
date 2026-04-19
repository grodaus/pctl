(* List — `pctl list` (alias `pctl ls`).
 *
 * Oracle: the prior Nushell `list` command, which emitted one row per
 * registered project with columns {id, path, host, started_at, running}.
 * We keep the Nushell column set (so any downstream parsing still works)
 * and add `class` as a derived column (Live/Orphan/Unknown) — strictly
 * more informative than the boolean `running`. Consumers reading only
 * the Nushell columns are unaffected.
 *
 * Class derivation (reconciled with Session.reset — see Gc.class_of_row):
 *   Unknown  — path no longer exists on disk
 *   Live     — session_id = current boot_id
 *   Orphan   — otherwise (path exists, session_id NULL)
 *
 * Output modes:
 *   --json  — emit a JSON array of records (one per row).
 *   --table — pretty text table (default if stdout is a TTY).
 *   Neither flag: falls back to table. Mirrors Nushell `format-out`.
 *   (The Nushell `format-out` also auto-detects JSON vs table based on
 *    TTY, but OCaml can't easily check if stdout is a pipe vs TTY
 *    without extra plumbing — table is a reasonable default.)
 *
 * Empty registry: prints "no projects registered" to stderr and exits 0
 * with an empty body on stdout (keeps stdout JSON-parseable as "[]"). *)


(* Wire-format row — one per registered project. Consumers (tuor,
 * humans, tests) read these by field name; order matches the Nushell
 * `list` command for byte-compat. *)
type row = {
  id : string;
  path : string;
  host : string option;
  started_at : string option;
  class_ : string; [@key "class"]
}
[@@deriving to_yojson]

let row_of (r : State.Projects.t) (cls : Schema.class_) : row =
  { id = r.id; path = r.path; host = r.host; started_at = r.started_at;
    class_ = Schema.class_to_string cls }

let render_json rows : string =
  `List (List.map (fun (r, c) -> row_to_yojson (row_of r c)) rows)
  |> Yojson.Safe.to_string

let render_table rows : string =
  if rows = [] then ""
  else
    let header = [ "id"; "path"; "host"; "started_at"; "class" ] in
    let text_row (r, c) =
      let row = row_of r c in
      [
        row.id;
        row.path;
        Option.value row.host ~default:"-";
        Option.value row.started_at ~default:"-";
        row.class_;
      ]
    in
    let body = List.map text_row rows in
    let widths =
      List.fold_left
        (fun acc row ->
          List.map2 (fun w cell -> max w (String.length cell)) acc row)
        (List.map String.length header)
        body
    in
    let emit_row row =
      List.map2 (fun w cell -> Printf.sprintf "%-*s" w cell) widths row
      |> String.concat "  "
    in
    List.map emit_row (header :: body)
    |> List.map (fun s -> s ^ "\n")
    |> String.concat ""

let run ~sw ~env ?(json = false) () : int =
  Pipeline.run (fun () ->
      Pipeline.with_connection ~env ~sw (fun conn ->
          let rows = Gc.report ~conn in
          if rows = [] then begin
            prerr_endline "no projects registered";
            if json then print_endline "[]"
          end
          else if json then print_endline (render_json rows)
          else print_string (render_table rows)))
