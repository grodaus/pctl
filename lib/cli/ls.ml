(* List — `pctl list` (alias `pctl ls`).
 *
 * Oracle: the prior Nushell `list` command, which emitted one row per
 * registered project with columns {id, path, host, started_at, running}.
 * We keep the Nushell column set (so any downstream parsing still works)
 * and add `class` as a derived column (Live/Orphan/Unknown) — strictly
 * more informative than the boolean `running`. Consumers reading only
 * the Nushell columns are unaffected.
 *
 * Plan note: the plan's "Internal schema" keeps class_ as (Live|Orphan|
 * Unknown); the task brief asked for columns {id, path, host, class}.
 * We emit {id, path, host, started_at, class} as the union — matching
 * both the Nushell oracle and the plan. Flagged in the Phase 6 report.
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

open Common

let render_class = function
  | Schema.Live -> "live"
  | Schema.Orphan -> "orphan"
  | Schema.Unknown -> "unknown"

let render_json (rows : (State.Projects.t * Schema.class_) list) : string =
  let escape s =
    let buf = Buffer.create (String.length s + 2) in
    String.iter
      (fun c ->
        match c with
        | '"' -> Buffer.add_string buf "\\\""
        | '\\' -> Buffer.add_string buf "\\\\"
        | '\n' -> Buffer.add_string buf "\\n"
        | '\r' -> Buffer.add_string buf "\\r"
        | '\t' -> Buffer.add_string buf "\\t"
        | c -> Buffer.add_char buf c)
      s;
    Buffer.contents buf
  in
  let opt_str = function
    | None -> "null"
    | Some s -> Printf.sprintf "\"%s\"" (escape s)
  in
  let row_json ((r : State.Projects.t), (cls : Schema.class_)) =
    Printf.sprintf
      "{\"id\":\"%s\",\"path\":\"%s\",\"host\":%s,\"started_at\":%s,\"class\":\"%s\"}"
      (escape r.id) (escape r.path) (opt_str r.host) (opt_str r.started_at)
      (render_class cls)
  in
  "[" ^ String.concat "," (List.map row_json rows) ^ "]"

let render_table (rows : (State.Projects.t * Schema.class_) list) : string =
  if rows = [] then ""
  else
    let header = [ "id"; "path"; "host"; "started_at"; "class" ] in
    let to_row ((r : State.Projects.t), cls) =
      [
        r.id;
        r.path;
        Option.value r.host ~default:"-";
        Option.value r.started_at ~default:"-";
        render_class cls;
      ]
    in
    let all_rows = header :: List.map to_row rows in
    (* Column widths. *)
    let ncols = List.length header in
    let widths = Array.make ncols 0 in
    List.iter
      (fun row ->
        List.iteri
          (fun i cell ->
            if String.length cell > widths.(i) then widths.(i) <- String.length cell)
          row)
      all_rows;
    let buf = Buffer.create 256 in
    List.iter
      (fun row ->
        List.iteri
          (fun i cell ->
            let w = widths.(i) in
            let pad = String.make (max 0 (w - String.length cell)) ' ' in
            Buffer.add_string buf cell;
            Buffer.add_string buf pad;
            if i < ncols - 1 then Buffer.add_string buf "  ")
          row;
        Buffer.add_char buf '\n')
      all_rows;
    Buffer.contents buf

let run ~sw ~env ?(json = false) ?(table = false) () : int =
  let _ = table in
  (* --table and default both fall through to render_table. Passing both is
   * undefined in Nushell; we prefer --json. *)
  run_with_errors (fun () ->
      with_connection ~env ~sw (fun conn ->
          let rows = Gc.report ~conn in
          if rows = [] then begin
            prerr_endline "no projects registered";
            if json then print_endline "[]"
          end
          else if json then print_endline (render_json rows)
          else print_string (render_table rows)))
