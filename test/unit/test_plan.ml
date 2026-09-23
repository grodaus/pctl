(* Plan — pure diff correctness and qcheck properties. *)

open Schema

module UfMap = Map.Make (Schema.Unit_filename)

(* Bridge test fixtures (plain strings) to the typed manifest keys. *)
let uf = Schema.Unit_filename.of_string_exn
let uf_s = Schema.Unit_filename.to_string
let row (k, v) : Schema.Unit_filename.t * string = (uf k, v)
let rows xs = List.map row xs

let pp_action = function
  | Added -> "added"
  | Changed -> "changed"
  | Unchanged -> "unchanged"
  | Removed -> "removed"

let action_testable =
  Alcotest.testable (fun fmt a -> Format.pp_print_string fmt (pp_action a)) ( = )

let test_diff_unchanged () =
  let m = rows [ ("a.service", "h1") ] in
  let rs = Plan.diff ~installed:m ~rendered:m in
  Alcotest.(check int) "one row" 1 (List.length rs);
  let r = List.hd rs in
  Alcotest.check action_testable "unchanged" Unchanged r.action;
  Alcotest.(check string) "unit" "a.service" (uf_s r.unit_)

let test_diff_added () =
  let rs = Plan.diff ~installed:[] ~rendered:(rows [ ("a", "h1") ]) in
  let r = List.hd rs in
  Alcotest.check action_testable "added" Added r.action;
  Alcotest.(check (option string)) "new_hash" (Some "h1") r.new_hash;
  Alcotest.(check (option string)) "no old" None r.old_hash

let test_diff_removed () =
  let rs = Plan.diff ~installed:(rows [ ("a", "h1") ]) ~rendered:[] in
  let r = List.hd rs in
  Alcotest.check action_testable "removed" Removed r.action;
  Alcotest.(check (option string)) "old_hash" (Some "h1") r.old_hash

let test_diff_changed () =
  let rs =
    Plan.diff
      ~installed:(rows [ ("a", "h1") ])
      ~rendered:(rows [ ("a", "h2") ])
  in
  let r = List.hd rs in
  Alcotest.check action_testable "changed" Changed r.action;
  Alcotest.(check (option string)) "old" (Some "h1") r.old_hash;
  Alcotest.(check (option string)) "new" (Some "h2") r.new_hash

let test_diff_sort () =
  let installed = rows [ ("a", "1"); ("b", "2"); ("c", "3") ] in
  let rendered = rows [ ("b", "2"); ("c", "9"); ("d", "4") ] in
  let rs = Plan.diff ~installed ~rendered in
  let names = List.map (fun r -> uf_s r.unit_) rs in
  let actions = List.map (fun r -> pp_action r.action) rs in
  Alcotest.(check (list string)) "sorted" [ "a"; "b"; "c"; "d" ] names;
  Alcotest.(check (list string))
    "actions"
    [ "removed"; "unchanged"; "changed"; "added" ]
    actions

let test_diff_summary () =
  let installed = rows [ ("a", "1"); ("b", "2"); ("c", "3") ] in
  let rendered = rows [ ("b", "2"); ("c", "9"); ("d", "4") ] in
  let rs = Plan.diff ~installed ~rendered in
  Alcotest.(check string) "summary" "+1 ~1 =1 -1" (Plan.counts rs)

(* QCheck properties. *)

let arb_manifest =
  let open QCheck in
  let kv =
    pair
      (Gen.string_size ~gen:(Gen.char_range 'a' 'z') (Gen.int_range 1 6)
      |> QCheck.make ~print:(fun s -> s))
      (string_size (Gen.int_range 1 6))
  in
  list_size (Gen.int_range 0 10) kv

(* qcheck generates plain-string keys; lift them into the typed manifest.
 * The generator restricts keys to lowercase alpha of length 1..6, so
 * [of_string_exn] never rejects. *)
let to_manifest (m : (string * string) list) : unit_hashes =
  List.map (fun (k, v) -> (uf k, v)) m

let canonicalize (m : unit_hashes) : unit_hashes =
  let map =
    List.fold_left
      (fun acc (k, v) -> UfMap.add k v acc)
      UfMap.empty m
  in
  UfMap.bindings map

let prop_diff_symmetry =
  QCheck.Test.make ~count:200 ~name:"diff symmetry"
    (QCheck.pair arb_manifest arb_manifest) (fun (a, b) ->
      let a = canonicalize (to_manifest a)
      and b = canonicalize (to_manifest b) in
      let fwd = Plan.diff ~installed:a ~rendered:b in
      let rev = Plan.diff ~installed:b ~rendered:a in
      let count_fwd act =
        List.length (List.filter (fun r -> r.action = act) fwd)
      in
      let count_rev act =
        List.length (List.filter (fun r -> r.action = act) rev)
      in
      count_fwd Added = count_rev Removed
      && count_fwd Removed = count_rev Added
      && count_fwd Unchanged = count_rev Unchanged
      && count_fwd Changed = count_rev Changed)

let prop_diff_empty_before =
  QCheck.Test.make ~count:200 ~name:"nothing installed → every row Added"
    arb_manifest (fun rendered ->
      let rendered = canonicalize (to_manifest rendered) in
      let rs = Plan.diff ~installed:[] ~rendered in
      List.length rs = List.length rendered
      && List.for_all (fun r -> r.action = Added) rs)

let prop_diff_same =
  QCheck.Test.make ~count:200 ~name:"same → every row Unchanged" arb_manifest
    (fun m ->
      let m = canonicalize (to_manifest m) in
      let rs = Plan.diff ~installed:m ~rendered:m in
      List.length rs = List.length m
      && List.for_all (fun r -> r.action = Unchanged) rs)

let () =
  let open Alcotest in
  run "pctl plan"
    [
      ( "diff",
        [
          test_case "unchanged" `Quick test_diff_unchanged;
          test_case "added" `Quick test_diff_added;
          test_case "removed" `Quick test_diff_removed;
          test_case "changed" `Quick test_diff_changed;
          test_case "sorted with mixed actions" `Quick test_diff_sort;
          test_case "summary format" `Quick test_diff_summary;
        ]
        @ List.map QCheck_alcotest.to_alcotest
            [ prop_diff_symmetry; prop_diff_empty_before; prop_diff_same ] );
    ]
