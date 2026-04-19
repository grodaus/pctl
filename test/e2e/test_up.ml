(* e2e parity: pctl up installs units and reaches active state. *)

let () =
  match Harness.skip_reason () with
  | Some why ->
      Printf.printf "SKIP: test_up — %s\n" why;
      exit 0
  | None ->
      Harness.with_scratch
        ~services:
          [
            Harness.service "web";
            Harness.service "api";
          ]
      @@ fun scratch ->
      let rc = Harness.up ~scratch in
      if rc <> 0 then Alcotest.failf "up exit=%d" rc;
      let id = Harness.project_id scratch in
      let id_s = Schema.Project_id.to_string id in
      let slice = Printf.sprintf "pctl-%s.slice" id_s in
      let web = Printf.sprintf "pctl-%s-web.service" id_s in
      let api = Printf.sprintf "pctl-%s-api.service" id_s in
      Alcotest.(check bool)
        "slice file on disk" true
        (Harness.unit_exists ~id ~unit_filename:"pctl-@@PROJECT@@.slice");
      Alcotest.(check bool)
        "web file on disk" true
        (Harness.unit_exists ~id
           ~unit_filename:"pctl-@@PROJECT@@-web.service");
      Alcotest.(check bool)
        "api file on disk" true
        (Harness.unit_exists ~id
           ~unit_filename:"pctl-@@PROJECT@@-api.service");
      (* Drop-ins *)
      let web_dropin =
        Harness.read_dropin ~id
          ~unit_filename:"pctl-@@PROJECT@@-web.service"
      in
      let contains haystack needle =
        let hl = String.length haystack and nl = String.length needle in
        let rec go i =
          if i + nl > hl then false
          else if String.sub haystack i nl = needle then true
          else go (i + 1)
        in
        if nl = 0 then true else go 0
      in
      Alcotest.(check bool)
        "web dropin has PCTL_ID" true
        (contains web_dropin (Printf.sprintf "PCTL_ID=%s" id_s));
      Alcotest.(check bool)
        "web dropin has PCTL_HOST=127.0.0." true
        (contains web_dropin "PCTL_HOST=127.0.0.");
      (* Systemd state. *)
      Alcotest.(check bool)
        (Printf.sprintf "slice %s active" slice)
        true
        (Harness.wait_active slice);
      Alcotest.(check bool)
        (Printf.sprintf "web %s active" web)
        true
        (Harness.wait_active web);
      Alcotest.(check bool)
        (Printf.sprintf "api %s active" api)
        true
        (Harness.wait_active api);
      print_endline "test_up OK"
