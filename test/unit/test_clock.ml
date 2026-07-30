(* [read_boot_id_exn] must never hand back "" — Session.reset and gc both
 * treat it as a real boot id and delete rows (pctl-2jn). *)

let with_boot_file contents f =
  let path = Filename.temp_file "pctl-bootid-" "" in
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  Fun.protect ~finally:(fun () -> try Sys.remove path with _ -> ()) (fun () -> f path)

let raises_sys_error f =
  try
    ignore (f ());
    false
  with Sys_error _ -> true

let test_reads_trimmed () =
  with_boot_file "b6b1e0f2-0000-4000-8000-000000000000\n" @@ fun path ->
  Alcotest.(check string)
    "trailing newline trimmed" "b6b1e0f2-0000-4000-8000-000000000000"
    (Clock.read_boot_id_exn ~path ())

let test_blank_file_raises () =
  with_boot_file "  \n\t\n" @@ fun path ->
  Alcotest.(check bool)
    "whitespace-only boot id raises rather than returning \"\"" true
    (raises_sys_error (fun () -> Clock.read_boot_id_exn ~path ()))

let test_empty_file_raises () =
  with_boot_file "" @@ fun path ->
  Alcotest.(check bool)
    "zero-byte boot id raises" true
    (raises_sys_error (fun () -> Clock.read_boot_id_exn ~path ()))

let test_missing_file_raises () =
  let path = Filename.temp_file "pctl-bootid-" "" in
  Sys.remove path;
  Alcotest.(check bool)
    "unreadable boot id raises" true
    (raises_sys_error (fun () -> Clock.read_boot_id_exn ~path ()))

(* The degrading reader is the one path allowed to return "". *)
let test_real_degrades_to_empty () =
  Alcotest.(check bool)
    "Real.read_boot_id never raises" true
    (try
       ignore (Clock.Real.read_boot_id ());
       true
     with _ -> false)

let () =
  Alcotest.run "pctl clock"
    [
      ( "read_boot_id_exn",
        [
          Alcotest.test_case "trims the read" `Quick test_reads_trimmed;
          Alcotest.test_case "blank file raises" `Quick test_blank_file_raises;
          Alcotest.test_case "empty file raises" `Quick test_empty_file_raises;
          Alcotest.test_case "missing file raises" `Quick
            test_missing_file_raises;
        ] );
      ( "Real",
        [
          Alcotest.test_case "degrades instead of raising" `Quick
            test_real_degrades_to_empty;
        ] );
    ]
