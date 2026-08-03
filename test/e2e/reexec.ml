(* Reexec — the out-of-process `systemctl --user daemon-reexec` kicker the
 * reexec e2e tests share.
 *
 * Two tests drive the same window from opposite sides:
 * test_reload_survives_reexec asserts a Manager.Reload survives it,
 * test_unit_state_survives_reexec asserts a state read never launders a
 * peer-gone reply into a state. Both need a kicker, a completion marker,
 * a confirmed count, and a monotonic cap; keeping one copy is why this
 * module exists (pctl-4ih).
 *
 * The kicker runs OUT OF PROCESS on purpose. pctl's bus calls are
 * synchronous FFI that hold the Eio domain for their whole duration, so a
 * sibling fiber could only ever fire between calls — never inside one,
 * which is the case that matters.
 *
 * REEXECS THE DEVELOPER'S USER MANAGER. That is the same operation every
 * `nixos-rebuild switch` performs; running units are preserved across it.
 * Tests using this module must be last in the e2e progn (see
 * test/e2e/dune) and must let the manager settle before tearing down —
 * see [settle]. *)

let gap_s = 3

let marker_ok = "ok"

type t = {
  marker : string;
  marker_tmp : string;
  tally : string;
  log : string;
  (* Touched by the test to end the kicker's loop early — see
     [request_stop]. Absent from the shell's view means "keep going". *)
  stop : string;
  max_reexecs : int;
}

let paths t = [ t.marker; t.marker_tmp; t.tally; t.log; t.stop ]

(* Cap on the whole loop, not on one call: a wedged manager must not hang
 * the suite. DERIVED from [max_reexecs] rather than a shared constant —
 * one reexec costs a gap plus the reexec itself, so a caller that raises
 * its count would otherwise start tripping a fixed cap under load, turning
 * a run that merely ran out of windows into a hard failure. The slack is
 * generous because this is a ceiling for a wedged manager, not a target.
 * Monotonic for the reason [Bus_retry] gives — a CLOCK_REALTIME step
 * inside the window would move the deadline. *)
let hard_cap_s t = float_of_int (t.max_reexecs * (gap_s + 2)) +. 20.

let make ~label ~max_reexecs =
  let p suffix =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "pctl-e2e-%s-%d.%s" label (Unix.getpid ()) suffix)
  in
  {
    marker = p "done";
    marker_tmp = p "done.tmp";
    tally = p "tally";
    log = p "log";
    stop = p "stop";
    max_reexecs;
  }

let read_file path =
  if not (Sys.file_exists path) then ""
  else
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic))

let count_lines path =
  read_file path |> String.split_on_char '\n'
  |> List.filter (fun l -> String.trim l <> "")
  |> List.length

(* `set -e` is load-bearing. With plain `;`-chaining a daemon-reexec that
 * failed — no manager, denied, command not found — would still fall
 * through to the marker write, and every assertion the caller makes would
 * be satisfiable with zero reexecs performed. A reproducer that reports
 * green having done nothing is the one outcome these tests must not have.
 * Output goes to [log], not /dev/null, so a failure can say why.
 *
 * Each reexec appends to [tally] AFTER it returns 0, so the count is
 * observed rather than assumed.
 *
 * The stop check is `if`/`fi` rather than `[ -e … ] && break`: under
 * `set -e` the latter exits the subshell when the file is absent, which
 * is the common case and would end the kicker after one reexec.
 *
 * The marker is written to a sibling then renamed. The caller polls it
 * from another process while the shell writes it, and `echo ok > marker`
 * is create-then-write: a poll landing in between sees an empty file that
 * exists. rename(2) within a directory is atomic, so the marker only ever
 * appears complete. *)
let script t =
  let step =
    Printf.sprintf
      "if [ -e %s ]; then break; fi; sleep %d; systemctl --user \
       daemon-reexec; echo r >> %s"
      (Filename.quote t.stop) gap_s (Filename.quote t.tally)
  in
  Printf.sprintf
    "( set -e; for i in $(seq 1 %d); do %s; done; echo %s > %s; mv %s %s ) > \
     %s 2>&1 &"
    t.max_reexecs step marker_ok (Filename.quote t.marker_tmp)
    (Filename.quote t.marker_tmp) (Filename.quote t.marker)
    (Filename.quote t.log)

let clear t =
  List.iter (fun p -> if Sys.file_exists p then Sys.remove p) (paths t)

(* Ask the kicker to stop before its next reexec. Used by a test that has
 * already observed what it came for, so the developer's manager is not
 * reexec'd more times than the evidence needs. *)
let request_stop t =
  let oc = open_out t.stop in
  close_out oc

let start t =
  clear t;
  ignore (Sys.command (script t))

let finished t = Sys.file_exists t.marker

(* Reexecs that returned 0, read after [finished] is true so the kicker has
 * finished writing the tally. *)
let confirmed t = count_lines t.tally

(* Fails the calling test when the kicker did not run to completion, which
 * is what makes any "0 failures" claim mean something. *)
let check_completed t =
  if String.trim (read_file t.marker) <> marker_ok then
    Alcotest.failf
      "the reexec kicker did not complete — %d of at most %d reexecs \
       confirmed. Kicker output:\n%s"
      (confirmed t) t.max_reexecs
      (let l = read_file t.log in
       if String.trim l = "" then "(empty)" else l);
  if confirmed t < 1 then
    Alcotest.failf "the kicker completed without performing a single reexec"

(* Why [poll_until_finished] stopped. The caller needs this rather than
 * re-deriving it from the marker: a test that calls [request_stop] makes
 * the kicker exit its loop and write the marker, so after a cap-fired run
 * the marker is present too and [check_completed] can no longer tell the
 * two apart. *)
type ended = Kicker_done | Cap_fired

(* Poll [f] until the kicker finishes or the cap fires. [f] is called as
 * fast as the loop can go: the peer-gone window is on the order of one
 * in-flight call per reexec (measured: ~1 fault per reexec against
 * ~8000 reads/second), so ANY sleep in the caller's body collapses the
 * hit rate to zero and leaves the test green having observed nothing.
 * Do not add one. *)
let poll_until_finished t (f : unit -> unit) : int * ended =
  let elapsed = Mtime_clock.counter () in
  let capped () =
    Mtime.Span.to_float_ns (Mtime_clock.count elapsed) /. 1e9 >= hard_cap_s t
  in
  let iterations = ref 0 in
  while (not (finished t)) && not (capped ()) do
    incr iterations;
    f ()
  done;
  (!iterations, if finished t then Kicker_done else Cap_fired)

(* Fails the calling test if the loop ran out of wall clock. Separate from
 * [check_completed], which reports a kicker that died. *)
let check_not_capped t = function
  | Kicker_done -> ()
  | Cap_fired ->
      Alcotest.failf
        "the reexec loop hit its %.0fs cap with %d reexecs confirmed — the \
         manager is wedged or the kicker is stuck. Kicker output:\n%s"
        (hard_cap_s t) (confirmed t)
        (let l = read_file t.log in
         if String.trim l = "" then "(empty)" else l)

(* Wait for the manager to answer again, so teardown does not run inside
 * the settling window. Harness.teardown swallows every failure from its
 * `pctl down` + reset-failed + stop_unit sequence, and stop_unit is not
 * retried for peer-gone, so a NoReply there would leave the test's units
 * running with nothing printed (pctl-w53).
 *
 * MUST be called before the assertions, not from a [Fun.protect] finally
 * around them: this can itself fail, and a finally that raises while the
 * body is raising yields [Finally_raised], which buries the real failure.
 * Call [request_stop] first as well — while the kicker is still issuing
 * reexecs there is nothing to settle to, and the cap-fired path is exactly
 * where the kicker is still alive.
 *
 * [probe] must be a call the manager can genuinely fail: one that carries
 * a peer-gone retry budget ([Dbus.daemon_reload]) reports success while the
 * peer is still away, which is the opposite of what this asks. *)
let settle ~(probe : unit -> unit) =
  let deadline = Mtime_clock.counter () in
  let rec go last =
    let waited = Mtime.Span.to_float_ns (Mtime_clock.count deadline) /. 1e9 in
    if waited >= 15.0 then
      Alcotest.failf
        "the user manager did not answer again within %.0fs of the last \
         reexec; last failure: %s"
        waited
        (Option.value last ~default:"(none)")
    else
      match probe () with
      | () -> ()
      | exception Schema.Pctl_error e ->
          Unix.sleepf 0.2;
          go (Some (Schema.render_error e))
  in
  go None
