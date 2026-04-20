(* Manifest — pure diff correctness and qcheck properties.
 *
 * The diff lives in Projects (it's a pure function over manifest data);
 * expose it locally with a short alias so the test bodies read cleanly. *)

open Schema

module Manifest = struct
  let diff = State.Projects.diff_manifest
  let summary = State.Projects.manifest_summary
end

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
  let rs = Manifest.diff ~before:m ~after:m in
  Alcotest.(check int) "one row" 1 (List.length rs);
  let r = List.hd rs in
  Alcotest.check action_testable "unchanged" Unchanged r.action;
  Alcotest.(check string) "unit" "a.service" (uf_s r.unit_)

let test_diff_added () =
  let rs = Manifest.diff ~before:[] ~after:(rows [ ("a", "h1") ]) in
  let r = List.hd rs in
  Alcotest.check action_testable "added" Added r.action;
  Alcotest.(check (option string)) "new_hash" (Some "h1") r.new_hash;
  Alcotest.(check (option string)) "no old" None r.old_hash

let test_diff_removed () =
  let rs = Manifest.diff ~before:(rows [ ("a", "h1") ]) ~after:[] in
  let r = List.hd rs in
  Alcotest.check action_testable "removed" Removed r.action;
  Alcotest.(check (option string)) "old_hash" (Some "h1") r.old_hash

let test_diff_changed () =
  let rs =
    Manifest.diff
      ~before:(rows [ ("a", "h1") ])
      ~after:(rows [ ("a", "h2") ])
  in
  let r = List.hd rs in
  Alcotest.check action_testable "changed" Changed r.action;
  Alcotest.(check (option string)) "old" (Some "h1") r.old_hash;
  Alcotest.(check (option string)) "new" (Some "h2") r.new_hash

let test_diff_sort () =
  let before = rows [ ("a", "1"); ("b", "2"); ("c", "3") ] in
  let after = rows [ ("b", "2"); ("c", "9"); ("d", "4") ] in
  let rs = Manifest.diff ~before ~after in
  let names = List.map (fun r -> uf_s r.unit_) rs in
  let actions = List.map (fun r -> pp_action r.action) rs in
  Alcotest.(check (list string)) "sorted" [ "a"; "b"; "c"; "d" ] names;
  Alcotest.(check (list string))
    "actions"
    [ "removed"; "unchanged"; "changed"; "added" ]
    actions

let test_diff_summary () =
  let before = rows [ ("a", "1"); ("b", "2"); ("c", "3") ] in
  let after = rows [ ("b", "2"); ("c", "9"); ("d", "4") ] in
  let rs = Manifest.diff ~before ~after in
  Alcotest.(check string) "summary" "+1 ~1 =1 -1" (Manifest.summary rs)

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
let to_manifest (m : (string * string) list) : manifest =
  List.map (fun (k, v) -> (uf k, v)) m

let canonicalize (m : manifest) : manifest =
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
      let fwd = Manifest.diff ~before:a ~after:b in
      let rev = Manifest.diff ~before:b ~after:a in
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
  QCheck.Test.make ~count:200 ~name:"empty before → every row Added"
    arb_manifest (fun after ->
      let after = canonicalize (to_manifest after) in
      let rs = Manifest.diff ~before:[] ~after in
      List.length rs = List.length after
      && List.for_all (fun r -> r.action = Added) rs)

let prop_diff_same =
  QCheck.Test.make ~count:200 ~name:"same → every row Unchanged" arb_manifest
    (fun m ->
      let m = canonicalize (to_manifest m) in
      let rs = Manifest.diff ~before:m ~after:m in
      List.length rs = List.length m
      && List.for_all (fun r -> r.action = Unchanged) rs)

let () =
  let open Alcotest in
  run "pctl manifest"
    [
      ( "manifest",
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
