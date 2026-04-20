(* Cli.Project_paths.resolve — the hot-path bundle.
 *
 * Three cases:
 *   1. --tree override: out_path is NOT called; the bundle's
 *      spec_file is the override verbatim.
 *   2. --nix <attr> override: out_path is called with the given attr.
 *   3. default: out_path is called with the default ".#pctl" attr.
 *)

type recorder = {
  mutable calls : int;
  mutable last_attr : string option;
  mutable last_path : string option;
}

let fresh () = { calls = 0; last_attr = None; last_path = None }

let make_stub (r : recorder) ~return : (module Cli.Project_paths.NIX) =
  (module struct
    let out_path ~attr ~path ~env:_ ~sw:_ =
      r.calls <- r.calls + 1;
      r.last_attr <- Some attr;
      r.last_path <- Some path;
      return

    let read_spec_blob _ = None
  end)

let project_of_cwd () =
  Schema.Project_path.of_raw "/tmp/project_paths_test_proj"

let test_tree_override () =
  let r = fresh () in
  let stub = make_stub r ~return:"/nix/store/zzz-never-called-pctl-spec.json" in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let project = project_of_cwd () in
  let bundle =
    Cli.Project_paths.resolve ~env ~sw ~nix:stub
      ~tree:"/tmp/override-spec.json" project
  in
  Alcotest.(check int) "out_path not called" 0 r.calls;
  Alcotest.(check string)
    "spec_file = tree override" "/tmp/override-spec.json"
    (Fpath.to_string bundle.spec_file);
  Alcotest.(check string)
    "project passed through"
    (Schema.Project_path.to_string project)
    (Schema.Project_path.to_string bundle.project)

let test_nix_attr_override () =
  let r = fresh () in
  let stub = make_stub r ~return:"/nix/store/xyz-bar-pctl-spec.json" in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let project = project_of_cwd () in
  let bundle =
    Cli.Project_paths.resolve ~env ~sw ~nix:stub ~nix_attr:".#pctl-dev"
      project
  in
  Alcotest.(check int) "out_path called once" 1 r.calls;
  Alcotest.(check (option string))
    "attr forwarded" (Some ".#pctl-dev") r.last_attr;
  Alcotest.(check (option string))
    "path = project"
    (Some (Schema.Project_path.to_string project))
    r.last_path;
  Alcotest.(check string)
    "spec_file = stub return" "/nix/store/xyz-bar-pctl-spec.json"
    (Fpath.to_string bundle.spec_file)

let test_default_attr () =
  let r = fresh () in
  let stub = make_stub r ~return:"/nix/store/def-baz-pctl-spec.json" in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let project = project_of_cwd () in
  let bundle = Cli.Project_paths.resolve ~env ~sw ~nix:stub project in
  Alcotest.(check int) "out_path called once" 1 r.calls;
  Alcotest.(check (option string))
    "default attr = .#pctl" (Some ".#pctl") r.last_attr;
  Alcotest.(check string)
    "spec_file = stub return" "/nix/store/def-baz-pctl-spec.json"
    (Fpath.to_string bundle.spec_file)

let () =
  Alcotest.run "project_paths"
    [
      ( "resolve",
        [
          Alcotest.test_case "tree override skips nix build" `Quick
            test_tree_override;
          Alcotest.test_case "nix_attr override forwards attr" `Quick
            test_nix_attr_override;
          Alcotest.test_case "default attr is .#pctl" `Quick test_default_attr;
        ] );
    ]
