(* Nix_build — shell out to `nix build --no-link --print-out-paths`.
 *
 * Oracle: pctl/lib/build.nu `resolve-store-tree`. Behavioural difference:
 *   - Nushell streams stderr live to the user.
 *   - OCaml captures stderr into a buffer so we can include it in
 *     Nix_build_failed on non-zero exit.
 *
 * When `path` is provided, the process is spawned with cwd = path so
 * `nix build .#foo` resolves the flake at the project dir, matching
 * Nushell semantics (the Nushell script is invoked via `cd $cwd`).
 *
 * Return value: trimmed stdout, which for `--print-out-paths` is a single
 * line — an absolute /nix/store path. If the attribute builds multiple
 * derivations, we take the last line (matching Nushell `lines | last`). *)

let buf_sink_to_string (buf : Buffer.t) : string = Buffer.contents buf

let last_line (s : string) : string =
  let s = String.trim s in
  match String.rindex_opt s '\n' with
  | Some i -> String.sub s (i + 1) (String.length s - i - 1)
  | None -> s

let print_out_paths ~attr ?path ~env ~sw () : string =
  let cwd_arg : Eio.Fs.dir_ty Eio.Path.t option =
    match path with
    | Some p when p <> "" ->
        let fs = (Eio.Stdenv.fs env :> Eio.Fs.dir_ty Eio.Path.t) in
        Some Eio.Path.(fs / p)
    | _ -> None
  in
  let process_mgr = Eio.Stdenv.process_mgr env in
  let stdout_buf = Buffer.create 256 in
  let stderr_buf = Buffer.create 1024 in
  let stdout_sink = Eio.Flow.buffer_sink stdout_buf in
  let stderr_sink = Eio.Flow.buffer_sink stderr_buf in
  let args = [ "nix"; "build"; "--no-link"; "--print-out-paths"; attr ] in
  let proc =
    match cwd_arg with
    | Some cwd ->
        Eio.Process.spawn ~sw process_mgr ~cwd ~stdout:stdout_sink
          ~stderr:stderr_sink args
    | None ->
        Eio.Process.spawn ~sw process_mgr ~stdout:stdout_sink
          ~stderr:stderr_sink args
  in
  match Eio.Process.await proc with
  | `Exited 0 -> last_line (buf_sink_to_string stdout_buf)
  | `Exited n ->
      raise
        (Schema.Pctl_error
           (Schema.Nix_build_failed
              {
                expr = attr;
                exit_code = n;
                stderr = buf_sink_to_string stderr_buf;
              }))
  | `Signaled s ->
      raise
        (Schema.Pctl_error
           (Schema.Nix_build_failed
              {
                expr = attr;
                exit_code = 128 + s;
                stderr = buf_sink_to_string stderr_buf;
              }))

(* Nix port — Pipeline.Make depends on this signature.
 * [Real] uses [print_out_paths] + a best-effort slurp of the spec.json
 * bytes (for persistence into the projects registry). Tests substitute
 * a stub that returns canned bytes without shelling out to nix. *)

module type S = sig
  val out_path :
    attr:string ->
    path:string ->
    env:Eio_unix.Stdenv.base ->
    sw:Eio.Switch.t ->
    string

  val read_spec_blob : string -> string option
end

module Real : S = struct
  let out_path ~attr ~path ~env ~sw =
    print_out_paths ~attr ~path ~env ~sw ()

  let read_spec_blob path =
    try
      let ic = open_in path in
      Fun.protect
        ~finally:(fun () -> close_in ic)
        (fun () ->
          let n = in_channel_length ic in
          Some (really_input_string ic n))
    with Sys_error _ -> None
end
