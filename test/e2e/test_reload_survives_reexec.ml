(* e2e — a Manager.Reload in flight survives `systemctl --user
 * daemon-reexec`.
 *
 * This is the reproducer for pctl-jbd. [Bus_retry]'s header has the
 * causal story; what matters here is that before that retry existed,
 * a concurrent reexec surfaced as pctl exit 5 and failed whichever
 * e2e test happened to be running.
 *
 * Verified RED by flipping Bus_retry.peer_gone_budget to 0.0 (the
 * pre-fix behaviour) on this host (systemd 260, dbus-broker 37): one
 * reload failed per reexec, each `NoReply: Remote peer disconnected`.
 * The reload count is whatever fits in the ~6 s the kicker takes and
 * so varies with load (11-14 observed); the failure count does not.
 *
 * Scope: this asserts the OUTCOME (a concurrent reexec does not fail a
 * reload), not the mechanism. The retry policy itself — which names
 * count as peer-gone, and why the budget is elapsed time — is unit
 * tested in test/unit/test_bus_retry.ml.
 *
 * The kicker runs OUT OF PROCESS on purpose. [Dbus.daemon_reload] is a
 * synchronous FFI call that holds the Eio domain for its whole
 * duration, so a sibling fiber could only ever fire between reloads —
 * never inside one, which is the case that matters. Reloads are issued
 * back-to-back with no gap so the reexec has nowhere else to land.
 *
 * REEXECS THE DEVELOPER'S USER MANAGER. That is the same operation
 * every `nixos-rebuild switch` performs: running units are preserved
 * across it. *)

module S = Systemctl

(* Two reexecs, ~3 s apart, then the marker. The reload loop watches for
 * the marker rather than counting iterations, so a slow host lengthens
 * the loop instead of ending it early. *)
let reexec_count = 2
let reexec_gap_s = 3
let hard_cap_s = 60.0
let marker_ok = "ok"

(* `set -e` is load-bearing. With plain `;`-chaining a daemon-reexec
 * that failed — no manager, denied, command not found — would still
 * fall through to the marker write, and every assertion below would be
 * satisfiable with zero reexecs performed. A reproducer that reports
 * green having done nothing is the one outcome this test must not
 * have. Output goes to [log], not /dev/null, so a failure can say
 * why.
 *
 * Each reexec appends a line to [tally] AFTER it returns 0, so the
 * count the summary prints is observed rather than assumed.
 *
 * The marker is written to a sibling then renamed. The reload loop
 * polls it from another process while the shell writes it, and
 * `echo ok > marker` is create-then-write: a poll landing in between
 * sees an empty file that exists. rename(2) within a directory is
 * atomic, so the marker only ever appears complete. *)
let kicker_script ~marker ~marker_tmp ~tally ~log =
  let steps =
    List.init reexec_count (fun _ ->
        Printf.sprintf "sleep %d; systemctl --user daemon-reexec; echo r >> %s"
          reexec_gap_s (Filename.quote tally))
  in
  Printf.sprintf "( set -e; %s; echo %s > %s; mv %s %s ) > %s 2>&1 &"
    (String.concat "; " steps) marker_ok (Filename.quote marker_tmp)
    (Filename.quote marker_tmp) (Filename.quote marker) (Filename.quote log)

let read_file p =
  if not (Sys.file_exists p) then ""
  else
    let ic = open_in_bin p in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic))

let count_lines p =
  read_file p |> String.split_on_char '\n'
  |> List.filter (fun l -> String.trim l <> "")
  |> List.length

let scratch_path suffix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "pctl-e2e-reexec-%d.%s" (Unix.getpid ()) suffix)

(* Counts are printed after [Alcotest.run] returns — alcotest captures
 * a test case's stdout into _build, so anything printed inside the
 * body never reaches the terminal. That needs [~and_exit:false] below;
 * the default [run] exits the process itself and the print is dead
 * code. *)
let reloads = ref 0

(* Set from the kicker's tally file, not from [reexec_count] — the
 * summary calls these "confirmed", so they have to be counted. *)
let reexecs_confirmed = ref 0

let test_reload_survives_reexec () =
  let marker = scratch_path "done"
  and marker_tmp = scratch_path "done.tmp"
  and tally = scratch_path "tally"
  and log = scratch_path "log" in
  let scratch = [ marker; marker_tmp; tally; log ] in
  let clear () =
    List.iter (fun p -> if Sys.file_exists p then Sys.remove p) scratch
  in
  clear ();
  Fun.protect ~finally:clear @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let t = S.Dbus.connect ~sw env in
  ignore (Sys.command (kicker_script ~marker ~marker_tmp ~tally ~log));
  (* Monotonic for the reason [Bus_retry] gives: a CLOCK_REALTIME step
   * inside the window would move the cap. *)
  let elapsed = Mtime_clock.counter () in
  let capped () =
    Mtime.Span.to_float_ns (Mtime_clock.count elapsed) /. 1e9 >= hard_cap_s
  in
  let failures = ref [] in
  while (not (Sys.file_exists marker)) && not (capped ()) do
    incr reloads;
    try S.Dbus.daemon_reload t
    with Schema.Pctl_error e -> failures := Schema.render_error e :: !failures
  done;
  (* Vacuity guard: the marker is only renamed into place if every
   * reexec exited 0, so its presence is what makes "0 failures" mean
   * anything. The tally is read after the marker appears, i.e. after
   * the kicker has finished writing it. *)
  let confirmed = count_lines tally in
  if String.trim (read_file marker) <> marker_ok then
    Alcotest.failf
      "the reexec kicker did not complete — %d of %d reexecs confirmed. \
       Kicker output:\n\
       %s"
      confirmed reexec_count
      (let l = read_file log in
       if String.trim l = "" then "(empty)" else l);
  (* Belt and braces: the marker says the shell reached the end, the
   * tally says how many reexecs actually returned 0. *)
  Alcotest.(check int) "reexecs confirmed" reexec_count confirmed;
  reexecs_confirmed := confirmed;
  if !failures <> [] then
    Alcotest.failf "%d of %d reloads failed across %d reexecs:\n%s"
      (List.length !failures) !reloads confirmed
      (String.concat "\n" (List.rev !failures))

let () =
  Harness.skip_or_run ~name:"reload survives reexec" @@ fun () ->
  (* ~and_exit:false so the summary below runs. A failing case raises
   * Test_error instead, which exits non-zero and stops the e2e progn
   * just the same. *)
  Alcotest.run ~and_exit:false "pctl reload survives reexec"
    [
      ( "daemon_reload",
        [
          Alcotest.test_case "concurrent daemon-reexec does not fail a reload"
            `Slow test_reload_survives_reexec;
        ] );
    ];
  Printf.printf
    "\ntest_reload_survives_reexec OK — %d reloads across %d confirmed \
     reexecs, 0 failures\n\
     %!"
    !reloads !reexecs_confirmed
