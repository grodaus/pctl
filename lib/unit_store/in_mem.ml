(* In_mem — hashtbl-backed Unit_store adapter for integration tests.
 *
 * Mirrors [Fs]'s observable semantics without touching the filesystem:
 *   - [write] overwrites any prior entry for the same unit.
 *   - [remove] tolerates missing units (matches Fs's [Sys.remove … with _]).
 *   - [list] returns keys sorted by [Unit_filename.compare], matching
 *     Fs.list after its [List.sort].
 *
 * Extras beyond the port:
 *   - [inspect] returns the most recently written entry (or None).
 *   - [fail_next_write] arms a one-shot [Install_failed] raise so tests
 *     can exercise the error path without a real fs injury. The failure
 *     fires before the hashtable is mutated, so no partial write is
 *     observable. *)

type entry = Unit_store_intf.entry = {
  main : string;
  dropin : string option;
}

type t = {
  table : (Schema.Unit_filename.t, entry) Hashtbl.t;
  mutable fail_next_write : string option;
      (* Some reason → next [write] raises Install_failed with that
         reason, then disarms. *)
}

let create () : t =
  { table = Hashtbl.create 8; fail_next_write = None }

let write t ~unit_ (entry : entry) : unit =
  (match t.fail_next_write with
   | None -> ()
   | Some reason ->
       t.fail_next_write <- None;
       raise
         (Schema.Pctl_error
            (Schema.Install_failed
               { path = Schema.Unit_filename.to_string unit_; reason })));
  Hashtbl.replace t.table unit_ entry

let remove t ~unit_ : unit = Hashtbl.remove t.table unit_

let list t : Schema.Unit_filename.t list =
  Hashtbl.fold (fun k _ acc -> k :: acc) t.table []
  |> List.sort Schema.Unit_filename.compare

let inspect t ~unit_ : entry option = Hashtbl.find_opt t.table unit_

let fail_next_write t ~reason : unit =
  t.fail_next_write <- Some reason
