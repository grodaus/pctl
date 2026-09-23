(* e2e harness — tmpdir + private systemd --user + spec.json fixture +
 * XDG isolation + cleanup.
 *
 * Every e2e test uses a unique tmpdir so derive-id produces a unique
 * project id and slice, and every test spawns a `systemd --user` of its
 * own (see docs/adr/0001) rather than sharing whoever ran it.
 * XDG_STATE_HOME, XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS are
 * pointed at the scratch, which is what routes the registry,
 * user.control and every bus call at that manager. A test holding two
 * scratches at once must [activate] the one it is talking to.
 *
 * [setup] hands back an [owned]; [sibling_scratch] hands back a bare
 * [scratch] pointing at somebody else's manager. Only the former can be
 * torn down.
 *
 * Gating: skip_reason () returns Some <why> when the host lacks
 * DBUS_SESSION_BUS_ADDRESS or a /run/user/<uid> dir — callers exit 0
 * with a SKIP: message in that case. *)

let read_file path = In_channel.with_open_bin path In_channel.input_all

let elapsed_s (c : Mtime_clock.counter) : float =
  Mtime.Span.to_float_ns (Mtime_clock.count c) /. 1e9

(* Poll [f] until it answers true or [timeout_s] elapses; the bool says
 * which. Monotonic for the reason lib/systemctl/bus_retry.ml gives.
 *
 * [interval_s] has no default: it is the cost of one attempt, and a
 * waitpid and a fork+exec of `systemctl --user is-active` do not share
 * one. *)
let poll_until ~timeout_s ~interval_s (f : unit -> bool) : bool =
  let elapsed = Mtime_clock.counter () in
  let rec loop () =
    if f () then true
    else if elapsed_s elapsed >= timeout_s then false
    else begin
      Unix.sleepf interval_s;
      loop ()
    end
  in
  loop ()

(* Run a shell command, return (stdout_bytes, exit_code). Caller
 * controls stderr (append "2>&1" to merge into the buffer,
 * "2>/dev/null" to drop). *)
let run_capture cmd =
  let ic = Unix.open_process_in cmd in
  let buf = Buffer.create 256 in
  (try
     while true do
       Buffer.add_string buf (input_line ic);
       Buffer.add_char buf '\n'
     done
   with End_of_file -> ());
  let status = Unix.close_process_in ic in
  let rc =
    match status with
    | Unix.WEXITED n -> n
    | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 128
  in
  (Buffer.contents buf, rc)

(* Leak reporting. The places that detect a leak — a manager that outlived
 * its scratch, a cgroup that will not go away — run from a Fun.protect
 * finaliser, where raising would replace the test's own failure with this
 * one. They record instead, and [skip_or_run] fails the run afterwards.
 * Green must not be reachable with a leak outstanding.
 *
 * NOT at_exit: do_at_exit runs before the runtime prints `Fatal error:
 * exception`, and an exit from there is never reached by the raise, so a
 * test that both failed and leaked would print this and nothing else —
 * the masking this indirection exists to avoid, one level up. Measured on
 * OCaml 5.4.1. *)
let leaks : string list ref = ref []

let report_leak fmt =
  Printf.ksprintf
    (fun msg ->
      leaks := msg :: !leaks;
      prerr_string msg)
    fmt

(* Only ever called where the body has already returned normally, so
 * there is no in-flight failure to bury.
 *
 * The reports are re-printed rather than pointed at: under
 * [Alcotest.run] a case's stderr goes to a file in _build, so what
 * [report_leak] wrote during the test is not on the terminal. *)
let exit_on_leaks () =
  match !leaks with
  | [] -> ()
  | ls ->
      Printf.eprintf "HARNESS: failing the run on %d leak(s):\n%s"
        (List.length ls)
        (String.concat "" (List.rev ls));
      flush stderr;
      flush stdout;
      exit 1

let skip_reason () : string option =
  match Sys.getenv_opt "DBUS_SESSION_BUS_ADDRESS" with
  | None -> Some "DBUS_SESSION_BUS_ADDRESS unset"
  | Some _ ->
      let uid = Unix.getuid () in
      let xdg_runtime = Printf.sprintf "/run/user/%d" uid in
      if not (Sys.file_exists xdg_runtime) then
        Some (Printf.sprintf "%s not present" xdg_runtime)
      else None

(* Make an absolute tmpdir. The caller is responsible for rm -rf.
 *
 * Base = /run/user/<uid>, which [skip_reason] guarantees exists. Nothing
 * requires it: a scratch's manager is the test's own child and sees
 * whatever the test sees, so $TMPDIR would serve. Moving the base there,
 * and out of the shared per-uid runtime tmpfs, is
 * pctl-e2e-scratch-base-tmpdir-gko. *)
let fresh_tmpdir prefix =
  let base = Printf.sprintf "/run/user/%d" (Unix.getuid ()) in
  let rec loop i =
    let candidate =
      Filename.concat base
        (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) i)
    in
    if Sys.file_exists candidate then loop (i + 1)
    else begin
      Unix.mkdir candidate 0o700;
      candidate
    end
  in
  loop 0

(* Two things a user manager's runtime dir needs that Sys.file_exists and
 * Sys.is_directory cannot give:
 *
 * - lstat, so symlinks are unlinked rather than resolved. systemd stores
 *   a unit's invocation id AS the target of
 *   $XDG_RUNTIME_DIR/systemd/units/invocation:<unit>, so every one of
 *   those links dangles by construction — Sys.file_exists is false for
 *   them, they were skipped, and their directory then failed to rmdir.
 *   A graceful exit removes the directory, which is why this only showed
 *   when the manager was killed. lstat also keeps a symlink to a
 *   directory from being descended into.
 * - rwx on a directory before it is read and emptied: the manager leaves
 *   $XDG_RUNTIME_DIR/systemd/inaccessible/ at mode r-x, holding 000-mode
 *   nodes that nothing can then remove.
 *
 * A failure to stat is reported, because it means the walk could not even
 * see what it was meant to delete. chmod, readdir, unlink and rmdir are
 * not: a directory that another process is unlinking underneath us
 * produces those routinely, and whether the tree actually went is a
 * question the one check at the end can answer for all of them. *)
let rm_rf p =
  let rec go p =
    match Unix.lstat p with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
    | exception Unix.Unix_error (e, _, _) ->
        report_leak "HARNESS LEAK: cannot stat %s: %s\n" p
          (Unix.error_message e)
    | { Unix.st_kind = Unix.S_DIR; st_perm; _ } ->
        if st_perm land 0o700 <> 0o700 then
          (try Unix.chmod p 0o700 with Unix.Unix_error _ -> ());
        let entries = try Sys.readdir p with Sys_error _ -> [||] in
        Array.iter (fun n -> go (Filename.concat p n)) entries;
        (try Unix.rmdir p with Unix.Unix_error _ -> ())
    | _ -> ( try Unix.unlink p with Unix.Unix_error _ -> ())
  in
  go p;
  (* lstat, for the same reason the walk uses it: Sys.file_exists is false
   * for a dangling symlink, which is a thing that survived. *)
  if (try ignore (Unix.lstat p); true with Unix.Unix_error _ -> false) then
    report_leak "HARNESS LEAK: %s survived rm_rf:\n%s" p
      (fst
         (run_capture
            (Printf.sprintf "find %s -printf '%%M %%y %%p\\n' 2>&1"
               (Filename.quote p))))

(* Write a spec.json fixture containing sleep-infinity services and a
 * trivial slice. `services` maps service name -> service_config list.
 * No `@@PROJECT@@` placeholders — spec.json v2 is pure logical data. *)
let sleep_bin = "/run/current-system/sw/bin/sleep"

let default_command () = [ sleep_bin; "infinity" ]
let default_service_config () = [ ("Type", "simple") ]

type probe_fixture = {
  exec : string list;
  period_seconds : int;
  timeout_seconds : int;
}

type service_fixture = {
  name : string;
  command : string list;  (* argv → ExecStart, rendered OCaml-side *)
  service_config : (string * string) list;
  workspace : (bool * bool) option;
      (* (cwd, writable) — None = default false/false *)
  probe : probe_fixture option;
  depends_on : string list;
}

let service ?(workspace = None) ?(command = default_command ())
    ?(cfg = default_service_config ()) ?(probe = None) ?(depends_on = []) name =
  { name; command; service_config = cfg; workspace; probe; depends_on }

(* Build spec.json JSON from a set of services. Uses Spec's derived
 * yojson so this can't drift from the loader's expectations. *)
let spec_json ~(services : service_fixture list) : string =
  let service_to_json (sf : service_fixture) : Spec.service_json =
    {
      kind = Schema.Simple;
      command = sf.command;
      service_config = sf.service_config;
      depends_on = sf.depends_on;
      workspace =
        (match sf.workspace with
         | None -> { cwd = false; writable = false }
         | Some (cwd, writable) -> { cwd; writable });
      probe =
        Option.map
          (fun (p : probe_fixture) : Spec.probe_json ->
            {
              exec = p.exec;
              period_seconds = p.period_seconds;
              timeout_seconds = p.timeout_seconds;
            })
          sf.probe;
    }
  in
  let services_obj =
    `Assoc
      (List.map
         (fun sf -> (sf.name, Spec.service_json_to_yojson (service_to_json sf)))
         services)
  in
  let slice : Spec.slice_json = { slice_config = [] } in
  `Assoc
    [
      ("services", services_obj);
      ("slice", Spec.slice_json_to_yojson slice);
      ("version", `Int 2);
    ]
  |> Yojson.Safe.to_string

(* ------------------------------------------------------------------ *)
(* Nested systemd --user — one manager per scratch (docs/adr/0001).    *)
(* ------------------------------------------------------------------ *)

let systemd_bin = "/run/current-system/systemd/lib/systemd/systemd"
let sh_bin = "/run/current-system/sw/bin/sh"
let session_unit_dir = "/etc/systemd/user"
let cgroup_mount = "/sys/fs/cgroup"

(* The whole unit search path of a nested manager, besides the scratch's
 * own user.control. Curating it is what makes a reload cheap, and the
 * cost it removes is per unit FILE parsed, not per unit loaded — a nested
 * manager still synthesises .device/.mount/.slice/.scope from the dev
 * machine's /proc, /sys and mounts, so `list-units --all` reports a few
 * hundred either way.
 *
 * Every entry is load-bearing and every omission is silent:
 *   - without dbus.socket + dbus.service the manager starts and owns no
 *     message bus, so sd_bus_default_user — which is how pctl and every
 *     other sd-bus client reaches systemd — fails ENOENT. `systemctl
 *     --user` keeps working throughout, because it talks to
 *     $XDG_RUNTIME_DIR/systemd/private instead, so the harness's own
 *     is-active helpers cannot detect this;
 *   - without exit.target + systemd-exit.service SIGTERM starts a target
 *     whose Requires= does not exist, the job fails, and the manager
 *     stays up — startable but not stoppable. [reap_manager] escalates,
 *     but teardown does not run at all if the test is killed;
 *     pctl-nested-manager-harness-nak.2 is the backstop for that. *)
let curated_units =
  [
    "dbus.socket";
    "dbus.service";
    "basic.target";
    "default.target";
    "sockets.target";
    "paths.target";
    "timers.target";
    "shutdown.target";
    "exit.target";
    "systemd-exit.service";
  ]

(* Enablement symlinks, which curating the search path also drops. Having
 * dbus.socket on the path is not enough: dbus.service declares Requires=
 * and Sockets= on it, but nothing in the boot transaction pulls
 * dbus.service either, and dbus.socket has no [Install] section of its
 * own. What starts it is the generated
 * /etc/systemd/user/sockets.target.wants/dbus.socket. Omitting the link
 * fails exactly like omitting the unit. *)
let curated_wants = [ ("sockets.target.wants", "dbus.socket") ]

type manager = {
  pid : int;
  runtime_dir : string;  (* XDG_RUNTIME_DIR: user.control + bus live here *)
  bus_address : string;
  cgroup : string;  (* cgroupfs dir the manager was moved into *)
  log_path : string;  (* the manager's own stdout+stderr *)
  (* waitpid is destructive, and both [await_manager] and [reap_manager]
   * ask whether the manager is still there. Whoever reaps it first
   * records the status here, so the second caller can still say how it
   * exited instead of falling back to "reaped by someone else". *)
  mutable status : Unix.process_status option;
}

(* Absolute cgroupfs path of the cgroup systemd delegated to this user's
 * manager — everything up to and including user@<uid>.service.
 *
 * The nested manager has to sit DIRECTLY under it, in a directory whose
 * name ends in .slice, and that is not cosmetic. journald resolves
 * _SYSTEMD_USER_UNIT through the SESSION manager's view of the cgroup
 * tree: it strips the user-manager prefix, skips leading .slice
 * components, and attributes the message to the next one. Measured: a
 * manager left in the caller's inherited cgroup (an interactive
 * terminal's app-...-.scope) makes every nested service's stdout land
 * under that scope's name, so `journalctl --user -u
 * pctl-<id>-<svc>.service` reports "-- No entries --" with exit 0 and
 * `pctl logs` prints nothing. Re-run with the manager in a .slice
 * directly under user@<uid>.service and the same read returns the
 * service's output. *)
let user_manager_cgroup () : string =
  let uid = Unix.getuid () in
  let marker = Printf.sprintf "user@%d.service" uid in
  let own =
    let lines = String.split_on_char '\n' (read_file "/proc/self/cgroup") in
    match List.find_opt (fun l -> String.starts_with ~prefix:"0::" l) lines with
    | Some l -> String.sub l 3 (String.length l - 3)
    | None ->
        Alcotest.failf
          "no cgroup v2 line (0::) in /proc/self/cgroup:\n%s"
          (String.concat "\n" lines)
  in
  match Str.search_forward (Str.regexp_string marker) own 0 with
  (* [own] is absolute; drop its leading / so concat keeps the mount. *)
  | at ->
      Filename.concat cgroup_mount
        (String.sub own 1 (at + String.length marker - 1))
  | exception Not_found ->
      Alcotest.failf
        "this process is not under %s (cgroup %s), so there is no delegated \
         user-manager cgroup to nest a test manager in"
        marker own

(* Sub-cgroups first: a manager's init.scope survives its exit. The files
 * in a cgroup directory are controller attributes and are not removable.
 *
 * EBUSY is the one errno that must not be swallowed — it means processes
 * are still in the cgroup, which is exactly the leak [reap_manager] runs
 * this to confirm the absence of. ENOENT is fine (raced with another
 * remover); anything else is reported with what is still in there. *)
let rec rm_cgroup dir =
  if Sys.file_exists dir then begin
    let entries = try Sys.readdir dir with Sys_error _ -> [||] in
    Array.iter
      (fun n ->
        let p = Filename.concat dir n in
        if Sys.is_directory p then rm_cgroup p)
      entries;
    match Unix.rmdir dir with
    | () -> ()
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
    | exception Unix.Unix_error (e, _, _) ->
        report_leak
          "HARNESS LEAK: cannot remove cgroup %s: %s\n---- cgroup.procs \
           ----\n%s"
          dir (Unix.error_message e)
          (try read_file (Filename.concat dir "cgroup.procs")
           with Sys_error m -> m)
  end

(* Environment for the manager. Everything the scratch owns is set
 * explicitly; the activation variables a systemd-started test process
 * inherits are dropped, because a manager that finds NOTIFY_SOCKET or
 * LISTEN_FDS set treats them as its own. DBUS_SESSION_BUS_ADDRESS is
 * dropped rather than overridden: the manager must find its bus via
 * XDG_RUNTIME_DIR, and dbus.socket's ExecStartPost is what publishes
 * the address back into the manager's own environment. *)
let manager_env ~runtime_dir ~user_control ~config_home ~data_home ~state_home
    ~unit_dir =
  let overridden =
    [
      "XDG_RUNTIME_DIR";
      "XDG_CONFIG_HOME";
      "XDG_DATA_HOME";
      "XDG_STATE_HOME";
      "SYSTEMD_UNIT_PATH";
    ]
  in
  let dropped =
    [
      "DBUS_SESSION_BUS_ADDRESS";
      "NOTIFY_SOCKET";
      "LISTEN_FDS";
      "LISTEN_PID";
      "MANAGERPID";
      "INVOCATION_ID";
      "JOURNAL_STREAM";
    ]
  in
  let inherited =
    Unix.environment () |> Array.to_list
    |> List.filter (fun kv ->
           not
             (List.exists
                (fun k -> String.starts_with ~prefix:(k ^ "=") kv)
                (overridden @ dropped)))
  in
  Array.of_list
    (inherited
    @ [
        "XDG_RUNTIME_DIR=" ^ runtime_dir;
        "XDG_CONFIG_HOME=" ^ config_home;
        "XDG_DATA_HOME=" ^ data_home;
        "XDG_STATE_HOME=" ^ state_home;
        (* Two entries and no trailing colon. The trailing-colon form
         * APPENDS the default search path, which restores both the parse
         * cost and the coupling to whatever the dev machine has
         * installed, while every check here still passes. *)
        Printf.sprintf "SYSTEMD_UNIT_PATH=%s:%s" user_control unit_dir;
      ])

(* Symlink a unit from the session's unit dir into the scratch's, naming
 * what is missing rather than planting a dangling link — which produces
 * exactly the silent capability loss [curated_units] documents. *)
let link_unit ~into u =
  let target = Filename.concat session_unit_dir u in
  if not (Sys.file_exists target) then
    Alcotest.failf
      "%s is in the curated unit set but absent from %s, so a nested manager \
       cannot be given the capability it provides"
      u session_unit_dir;
  Unix.symlink target (Filename.concat into u)

(* Spawn the manager. It goes through sh only to place itself in [cgroup]
 * before exec'ing — the write has to happen in the child, and `exec`
 * keeps the pid we return.
 *
 * A raise partway through leaves no manager for teardown to hang off, so
 * the cgroup — the one thing here that lives outside [tmp] — is unwound
 * on the way out, and only once this run is the one that created it.
 * [tmp] itself belongs to the caller. *)
let spawn_manager ~tmp ~state_home : manager =
  let runtime_dir = Filename.concat tmp "run" in
  let config_home = Filename.concat tmp "config" in
  let data_home = Filename.concat tmp "data" in
  let unit_dir = Filename.concat tmp "units" in
  let cgroup =
    Filename.concat (user_manager_cgroup ()) (Filename.basename tmp ^ ".slice")
  in
  List.iter
    (fun d -> Unix.mkdir d 0o700)
    [ runtime_dir; config_home; data_home; unit_dir ];
  (* user.control's layout under the runtime dir belongs to
   * Unit_store.Fs, which derives it from XDG_RUNTIME_DIR. Point the
   * variable at the scratch first — [activate] sets it again once the
   * scratch exists — so this cannot drift from what pctl will write to. *)
  Unix.putenv "XDG_RUNTIME_DIR" runtime_dir;
  let user_control = Unit_store.Fs.root (Unit_store.Fs.create ()) in
  Unit_store.Fs.mkdir_p user_control;
  List.iter (link_unit ~into:unit_dir) curated_units;
  List.iter
    (fun (wants_dir, u) ->
      let d = Filename.concat unit_dir wants_dir in
      if not (Sys.file_exists d) then Unix.mkdir d 0o700;
      link_unit ~into:d u)
    curated_wants;
  Unix.mkdir cgroup 0o755;
  let build () =
    let log_path = Filename.concat tmp "manager.log" in
    let log_fd =
      Unix.openfile log_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
    in
    let pid =
      Fun.protect
        ~finally:(fun () -> Unix.close log_fd)
        (fun () ->
          Unix.create_process_env sh_bin
            [|
              "sh";
              "-c";
              Printf.sprintf "echo $$ > %s && exec %s --user"
                (Filename.quote (Filename.concat cgroup "cgroup.procs"))
                (Filename.quote systemd_bin);
            |]
            (manager_env ~runtime_dir ~user_control ~config_home ~data_home
               ~state_home ~unit_dir)
            Unix.stdin log_fd log_fd)
    in
    {
      pid;
      runtime_dir;
      bus_address = "unix:path=" ^ Filename.concat runtime_dir "bus";
      cgroup;
      log_path;
      status = None;
    }
  in
  try build ()
  with e ->
    rm_cgroup cgroup;
    raise e

let manager_ready_timeout_s = 15.0

(* How the manager exited, or None while it is still running. Every caller
 * goes through this rather than waitpid directly — see [manager.status]. *)
let manager_died (m : manager) : string option =
  let describe = function
    | Unix.WEXITED n -> Printf.sprintf "exited with status %d" n
    | Unix.WSIGNALED n -> Printf.sprintf "killed by signal %d" n
    | Unix.WSTOPPED n -> Printf.sprintf "stopped by signal %d" n
  in
  match m.status with
  | Some st -> Some (describe st)
  | None -> (
      match Unix.waitpid [ Unix.WNOHANG ] m.pid with
      | 0, _ -> None
      | _, st ->
          m.status <- Some st;
          Some (describe st)
      | exception Unix.Unix_error (Unix.ECHILD, _, _) ->
          Some "was reaped by someone other than the harness")

(* Both manager waits below poll a syscall — waitpid, or an sd_bus call
 * on a socket that is already open. *)
let manager_poll_s = 0.01

(* Reachability alone is a readiness test a curated set too small to boot
 * would pass; basic.target active is the cheapest read that also proves
 * default.target's transaction went through. Requires the process
 * environment to already point at [m] — see [activate].
 *
 * The connection is made once and then reused: a handle stays valid
 * across a systemd1 name that is not yet owned, which is the state most
 * of these polls are waiting out. *)
let await_manager (m : manager) =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let diagnostics () =
    Printf.sprintf "---- %s ----\n%s---- manager log ----\n%s" m.runtime_dir
      (fst
         (run_capture
            (Printf.sprintf "ls -lR %s 2>&1" (Filename.quote m.runtime_dir))))
      (try read_file m.log_path with Sys_error e -> e)
  in
  (* One budget across both phases below, not one each. *)
  let elapsed = Mtime_clock.counter () in
  let last = ref "no attempt made" in
  (* Each phase raises rather than returning false: a manager that died,
   * or one that ran out of budget, will not become ready, and carrying on
   * would only delay the same failure with a worse message.
   *
   * Pctl_error is the only failure retried: it is the one the bus path
   * raises. Anything else is a harness bug, and demoting that to a
   * timeout and a !last string is the same masking as before. *)
  let phase (f : unit -> bool) =
    let attempt () =
      (match manager_died m with
      | None -> ()
      | Some how ->
          Alcotest.failf
            "nested systemd --user (pid %d) %s before answering on %s\n%s" m.pid
            how m.bus_address (diagnostics ()));
      try f ()
      with Schema.Pctl_error e ->
        last := Schema.render_error e;
        false
    in
    if
      not
        (poll_until
           ~timeout_s:(manager_ready_timeout_s -. elapsed_s elapsed)
           ~interval_s:manager_poll_s attempt)
    then
      Alcotest.failf
        "nested systemd --user (pid %d) not ready on %s within %.0fs: %s\n%s"
        m.pid m.bus_address manager_ready_timeout_s !last (diagnostics ())
  in
  let handle = ref None in
  phase (fun () ->
      handle := Some (Systemctl.Dbus.connect ~sw env);
      true);
  let h = Option.get !handle in
  (* Not Fun.protect: a raise from [close] there would arrive as
   * Finally_raised in place of the phase's own failf. Closing is
   * best-effort; the switch and Gc.finalise both back it up. *)
  let close () = try Systemctl.Dbus.close h with _ -> () in
  (try
     phase (fun () ->
         match Systemctl.Dbus.unit_state h ~unit:"basic.target" with
         | Schema.Active -> true
         | st ->
             last :=
               Printf.sprintf "basic.target is %s, not active"
                 (Schema.state_to_string st);
             false)
   with e ->
     close ();
     raise e);
  close ()

let manager_exit_timeout_s = 10.0

(* SIGTERM makes systemd --user start exit.target. Then CONFIRM: a manager
 * that ignored the signal is still running every unit the test created,
 * and a fire-and-forget teardown would report success while leaking both.
 *
 * Ignoring SIGTERM is itself reported as a leak even when cgroup.kill
 * then succeeds: a manager that can be started but not asked to stop
 * passes every startup check the harness makes, and the only run that can
 * say so is this one.
 *
 * No errno from the signal is tolerated. It is only sent once
 * [manager_died] has confirmed an unreaped child, and a zombie still
 * accepts signals, so ESRCH means the harness lost track of the pid —
 * after which waitpid answers ECHILD, [gone_within] answers true, and a
 * live manager would be reported as reaped. EPERM means the pid belongs
 * to someone else. *)
let reap_manager (m : manager) =
  let gone_within timeout_s =
    poll_until ~timeout_s ~interval_s:manager_poll_s (fun () ->
        manager_died m <> None)
  in
  let attempt what f =
    match f () with
    | () -> ()
    | exception e ->
        report_leak
          "HARNESS LEAK: %s for nested systemd --user (pid %d): %s; it and its \
           units in %s may still be live\n"
          what m.pid (Printexc.to_string e) m.cgroup
  in
  (* The cgroup is removed whatever happens above it: an escape from here
   * would leak it unreported, and this runs from a finaliser where that
   * escape would also replace the test's own failure. *)
  Fun.protect ~finally:(fun () -> rm_cgroup m.cgroup) @@ fun () ->
  if manager_died m = None then
    attempt "SIGTERM failed" (fun () -> Unix.kill m.pid Sys.sigterm);
  if not (gone_within manager_exit_timeout_s) then begin
    report_leak
      "HARNESS LEAK: nested systemd --user (pid %d) ignored SIGTERM for %.0fs \
       — its shutdown path is broken; escalating to cgroup.kill\n---- manager \
       log ----\n%s"
      m.pid manager_exit_timeout_s
      (try read_file m.log_path with Sys_error e -> e);
    (* cgroup.kill, not SIGKILL on the pid: killing only the manager
     * leaves every service it started running and reparented, which is
     * the same leak in a shape no reaper recognises. The kernel makes
     * cgroup.kill writable in a cgroup this process created, and it
     * covers the whole subtree. *)
    let kill_path = Filename.concat m.cgroup "cgroup.kill" in
    attempt (Printf.sprintf "writing %s failed" kill_path) (fun () ->
        let fd = Unix.openfile kill_path [ Unix.O_WRONLY ] 0 in
        Fun.protect
          ~finally:(fun () -> Unix.close fd)
          (fun () -> ignore (Unix.write_substring fd "1" 0 1)));
    if not (gone_within 5.0) then
      report_leak
        "HARNESS LEAK: nested systemd --user (pid %d) survived cgroup.kill; \
         its units and cgroup %s are still live\n"
        m.pid m.cgroup
  end

type scratch = {
  tmp : string;
  project_dir : string;
  spec_path : string;
  xdg_state_home : string;
  manager : manager;
}

(* Point the process environment at [s]. Every consumer reads these at
 * use time — Unit_store.Fs on handle creation, sd_bus on connect, the
 * systemctl/journalctl subprocess helpers on spawn — so a test holding
 * two scratches at once must call this before each operation. See
 * test_worktree.ml.
 *
 * Nothing restores them afterwards. The next [activate] overwrites all
 * three, and the process exits without reading them again. *)
let activate (s : scratch) =
  Unix.putenv "XDG_STATE_HOME" s.xdg_state_home;
  Unix.putenv "XDG_RUNTIME_DIR" s.manager.runtime_dir;
  Unix.putenv "DBUS_SESSION_BUS_ADDRESS" s.manager.bus_address

(* The right to reap, held by whoever spawned the manager. [release] takes
 * one and nothing outside this signature can produce one, so handing it a
 * [sibling_scratch] — which shares another scratch's manager and would
 * reap it out from under a live owner — is not expressible.
 *
 * The type is abstract, and the constructor is unexported rather than
 * merely inconvenient, because the library has no .mli: a record, or an
 * exported `mint`, would leave the mistake spellable. *)
module Owned : sig
  type t

  (* [setup_with] runs [build_services] AFTER the tmpdir + project_dir
   * exist, so tests that bake the real project_dir into their
   * ExecStart/env can do so. Plain [setup ~services] is the common case
   * where services are static. *)
  val setup_with : build_services:(scratch -> service_fixture list) -> t
  val setup : services:service_fixture list -> t
  val scratch : t -> scratch
  val release : t -> unit
end = struct
  type t = scratch

  let scratch t = t

  (* Fun.protect, so the scratch is deleted even if reaping the manager
   * raises: this runs from a finaliser, and a raise here would both leak
   * the tmpdir and bury the failure the finaliser was unwinding. *)
  let release (s : t) =
    Fun.protect
      ~finally:(fun () -> rm_rf s.tmp)
      (fun () -> reap_manager s.manager)

  let setup_with ~(build_services : scratch -> service_fixture list) : t =
    let tmp = fresh_tmpdir "pctl-e2e" in
    let project_dir = Filename.concat tmp "project" in
    Unix.mkdir project_dir 0o700;
    let spec_path = Filename.concat tmp "spec.json" in
    let xdg_state_home = Filename.concat tmp "state" in
    Unix.mkdir xdg_state_home 0o700;
    (* Nothing to release yet if the spawn itself fails, so the tmpdir is
     * unwound here; [spawn_manager] unwinds its own cgroup. *)
    let manager =
      try spawn_manager ~tmp ~state_home:xdg_state_home
      with e ->
        rm_rf tmp;
        raise e
    in
    let s = { tmp; project_dir; spec_path; xdg_state_home; manager } in
    (* Everything past [spawn_manager] releases on failure itself: the
     * caller's Fun.protect only arms once setup has returned, so a manager
     * that never becomes ready would otherwise leak itself, its cgroup and
     * the tmpdir. *)
    (try
       activate s;
       await_manager manager;
       let services = build_services s in
       let oc = open_out spec_path in
       output_string oc (spec_json ~services);
       close_out oc
     with e ->
       release s;
       raise e);
    s

  let setup ~services = setup_with ~build_services:(fun _ -> services)
end

type owned = Owned.t

let scratch_of = Owned.scratch
let release = Owned.release
let setup_with = Owned.setup_with
let setup = Owned.setup

(* For the tests that need two rows in one projects table: a second
 * project on [of_]'s registry and manager, with a project_dir and
 * spec.json of its own and nothing else. See [with_sibling], which owns
 * the matching teardown. *)
let sibling_scratch ~(of_ : scratch) ~prefix ~services : scratch =
  let tmp = fresh_tmpdir prefix in
  let project_dir = Filename.concat tmp "project" in
  Unix.mkdir project_dir 0o700;
  let spec_path = Filename.concat tmp "spec.json" in
  let oc = open_out spec_path in
  output_string oc (spec_json ~services);
  close_out oc;
  {
    tmp;
    project_dir;
    spec_path;
    xdg_state_home = of_.xdg_state_home;
    manager = of_.manager;
  }

(* Project id for the scratch dir. *)
let project_id (s : scratch) : Schema.project_id =
  Identity.derive ~path:(Schema.Project_path.of_raw s.project_dir)

(* Unit filenames are concrete (pctl-<id>-<svc>.service); tests pass
 * them in directly. Path construction routes through [Unit_store.Fs]
 * so this harness never duplicates the user.control layout. Each
 * helper builds a fresh Fs handle — it reads XDG_RUNTIME_DIR on
 * creation, so tests that putenv before calling the helper see the
 * override. *)
let unit_path_on_disk ~unit_filename : string =
  Unit_store.Fs.unit_path (Unit_store.Fs.create ()) ~unit_filename

let dropin_path_on_disk ~unit_filename : string =
  Unit_store.Fs.dropin_file (Unit_store.Fs.create ()) ~unit_filename

let read_unit ~unit_filename : string option =
  let p = unit_path_on_disk ~unit_filename in
  if Sys.file_exists p then Some (read_file p) else None

let unit_exists ~unit_filename : bool =
  Sys.file_exists (unit_path_on_disk ~unit_filename)

let dropin_exists ~unit_filename : bool =
  Sys.file_exists (dropin_path_on_disk ~unit_filename)

let read_dropin ~unit_filename : string =
  read_file (dropin_path_on_disk ~unit_filename)

(* Best-effort teardown: calls Down.run, then [release]. Any error from
 * Down (already-down; manifest wiped) is swallowed — a teardown must
 * never block another test from running.
 *
 * The down + reset-failed + stop_unit sequence duplicates what the
 * manager's own death does to its units and their tombstones; retiring it
 * is pctl-nested-manager-harness-nak.3. All of it needs the manager's
 * bus, so it runs first — and inside a Fun.protect, because
 * Systemctl.Dbus.connect raises when the manager is already gone, which
 * is precisely the case where [release] must still run.
 *
 * [activate] first: both [Cli.Pipeline.Prod.down] and the bus connection
 * pick their manager out of the environment, so tearing down a scratch
 * that is not the current one would quietly drive somebody else's. *)
let teardown (o : owned) =
  let s = scratch_of o in
  activate s;
  let id = try Some (project_id s) with _ -> None in
  Fun.protect
    ~finally:(fun () -> release o)
    (fun () ->
      Eio_main.run (fun env ->
          Eio.Switch.run (fun sw ->
              (try
                 ignore
                   (Cli.Pipeline.Prod.down ~sw ~env ~path:s.project_dir
                      ~quiet:true ())
               with _ -> ());
              match id with
              | None -> ()
              | Some id -> (
                  let id_s = Schema.Project_id.to_string id in
                  let slice = Printf.sprintf "pctl-%s.slice" id_s in
                  match Systemctl.Dbus.connect ~sw env with
                  | exception Schema.Pctl_error _ -> ()
                  | handle ->
                      (try Systemctl.Dbus.reset_failed_unit handle ~unit:slice
                       with _ -> ());
                      (try Systemctl.Dbus.stop_unit handle ~unit:slice
                       with _ -> ());
                      Systemctl.Dbus.close handle))))

let systemctl_is_active unit_name =
  let out, _ =
    run_capture
      (Printf.sprintf "systemctl --user is-active %s 2>/dev/null"
         (Filename.quote unit_name))
  in
  String.trim out = "active"

(* Poll until [unit_name] reaches [wanted] activeness, bounded.
 *
 * Both directions have to be polled, because plain up / reload / down do
 * not wait for a systemd job: Manager.StartUnit and Manager.StopUnit each
 * queue a job and return the job path (see the note in lib/gc/gc.ml on
 * what a successful stop does and does not establish). Only `up --wait`
 * blocks, via [Probe]. Measured under pctl-e0d:
 * the slice's deactivation lands after `pctl down` returns, so a single
 * `is-active` read right afterwards is a coin flip. It used to look
 * deterministic only because down then paid a second Manager.Reload,
 * which outlasted the cascade. Filed as
 * pctl-down-returns-before-cascade-qi7. *)
let wait_activeness ?(timeout_s = 5.0) ~wanted unit_name =
  poll_until ~timeout_s ~interval_s:0.1 (fun () ->
      systemctl_is_active unit_name = wanted)

let wait_active ?timeout_s unit_name =
  wait_activeness ?timeout_s ~wanted:true unit_name

let wait_inactive ?timeout_s unit_name =
  wait_activeness ?timeout_s ~wanted:false unit_name

let is_active = systemctl_is_active

(* LoadState: "loaded" while systemd holds a fragment for the unit,
 * "not-found" once the file is gone.
 *
 * NOT evidence that a daemon-reload happened. Measured under pctl-e0d
 * against this session's systemd: a stopped unit whose file is deleted
 * reads "not-found" with zero intervening reloads, because systemd GCs
 * the stopped unit and `show` then re-loads it from disk. It also lies
 * about slices, which systemd synthesises fragment-less — see
 * test_down_missing_units.ml, which owns the evidence for that. *)
let load_state unit_name =
  let out, _ =
    run_capture
      (Printf.sprintf "systemctl --user show -p LoadState --value %s 2>/dev/null"
         (Filename.quote unit_name))
  in
  String.trim out

(* ActiveEnterTimestampMonotonic as a string; empty on error/no-such-unit. *)
let active_enter_ts unit_name =
  let out, _ =
    run_capture
      (Printf.sprintf
         "systemctl --user show %s -p ActiveEnterTimestampMonotonic --value \
          2>/dev/null"
         (Filename.quote unit_name))
  in
  String.trim out

(* Redirect a stdlib fd (stdout or stderr) into a temp file while [f]
 * runs; return [f]'s result plus the captured bytes. Used by all the
 * pctl-wrapper helpers so test failures can include pctl's own
 * printed context ("probe for service web timed out after 10000 ms",
 * "systemctl start failed: …") instead of just an exit code.
 *
 * fd_kind is [Unix.stdout] or [Unix.stderr]. The corresponding Stdlib
 * channel is flushed before and after to keep buffered output in the
 * capture. *)
let with_captured_fd ~(fd_kind : Unix.file_descr)
    ~(flush_channel : unit -> unit) (f : unit -> 'a) : 'a * string =
  let tmp = Filename.temp_file "pctl-e2e-capture" ".log" in
  let fd = Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let saved = Unix.dup fd_kind in
  flush_channel ();
  Unix.dup2 fd fd_kind;
  Unix.close fd;
  let restore () =
    flush_channel ();
    Unix.dup2 saved fd_kind;
    Unix.close saved
  in
  let result =
    try
      let r = f () in
      restore ();
      r
    with e ->
      restore ();
      raise e
  in
  let captured = read_file tmp in
  (try Sys.remove tmp with _ -> ());
  (result, captured)

let with_captured_stdout (f : unit -> 'a) : 'a * string =
  with_captured_fd ~fd_kind:Unix.stdout
    ~flush_channel:(fun () -> flush Stdlib.stdout) f

let with_captured_stderr (f : unit -> 'a) : 'a * string =
  with_captured_fd ~fd_kind:Unix.stderr
    ~flush_channel:(fun () -> flush Stdlib.stderr) f

(* pctl wrappers. Each returns (exit_code, pctl_stderr) — pctl.run
 * prints Pctl_error via prerr_endline, so capturing stderr lets
 * check_rc_zero surface the actual message, not just the rc bucket. *)

let run_up ?(wait = false) ?timeout ?(no_block = false) ~scratch ()
    : int * string =
  with_captured_stderr (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      Cli.Pipeline.Prod.up ~sw ~env ~tree:scratch.spec_path
        ~path:scratch.project_dir ~wait ~no_block ?timeout ())

let up ~scratch : int * string = run_up ~scratch ()
let up_wait ?(timeout = 30) ~scratch () = run_up ~wait:true ~timeout ~scratch ()
let up_no_block ~scratch = run_up ~no_block:true ~scratch ()

let results ?(timeout = 30) ?(json = false) ~scratch () : int * string =
  with_captured_stdout (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      Cli.Pipeline.Prod.results ~sw ~env ~path:scratch.project_dir ~timeout ~json ())

let host ~scratch : int * string =
  with_captured_stdout (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      Cli.Host.run ~sw ~env ~path:scratch.project_dir ())

let reload ~scratch : int * string =
  with_captured_stderr (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      Cli.Pipeline.Prod.reload ~sw ~env ~tree:scratch.spec_path
        ~path:scratch.project_dir ())

let down ~scratch : int * string =
  with_captured_stderr (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      Cli.Pipeline.Prod.down ~sw ~env ~path:scratch.project_dir ())

(* Helpers for logs / status / list / gc tests. *)

let logs ?(lines = 50) ~svc ~scratch () : int * string =
  with_captured_stdout (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      Cli.Logs.run ~sw ~env ~svc ~path:scratch.project_dir ~lines ())

let status ?(svc = "") ~scratch () : int =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Cli.Status.run ~sw ~env ~svc ~path:scratch.project_dir ()

let list ?(json = false) () : int * string =
  with_captured_stdout (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw -> Cli.Ls.run ~sw ~env ~json ())

let gc ?(yes = false) ?(json = false) () : int * string =
  with_captured_stdout (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw -> Cli.Gc_cmd.run ~sw ~env ~yes ~json ())

(* Test wrapper: setup -> body -> teardown (Fun.protect style). *)
let with_scratch ~services f =
  let o = setup ~services in
  Fun.protect
    ~finally:(fun () -> teardown o)
    (fun () -> f (scratch_of o))

(* Variant that lets the services be built from the scratch — used when
 * a service's ExecStart / BindPaths etc. must reference the concrete
 * project_dir (not knowable before setup). *)
let with_scratch_late build_services f =
  let o = setup_with ~build_services in
  Fun.protect
    ~finally:(fun () -> teardown o)
    (fun () -> f (scratch_of o))

(* [sibling_scratch] plus its teardown, which is not [teardown]: a sibling
 * owns no manager and no environment, only a project on [of_]'s. *)
let with_sibling ~of_ ~prefix ~services f =
  let s = sibling_scratch ~of_ ~prefix ~services in
  Fun.protect
    ~finally:(fun () ->
      (* [activate] for the same reason [teardown] does it: [down] picks
       * its manager and its registry out of the environment. *)
      activate s;
      (try ignore (down ~scratch:s) with _ -> ());
      rm_rf s.tmp)
    (fun () -> f s)

(* ------------------------------------------------------------------ *)
(* Assertion helpers — collapse repetition in the 20 e2e test files.
 *
 * Each helper prints an "ASSERT" line on success so the human-readable
 * output still shows every checkpoint. Failure goes through
 * [Alcotest.failf] so test output matches prior behaviour. *)
(* ------------------------------------------------------------------ *)

let contains haystack needle =
  needle = ""
  ||
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

(* A body that raises is left alone: the runtime prints it and exits
 * non-zero, and the leaks [report_leak] already wrote to stderr are part
 * of that report. Only a body that returned normally can be turned from
 * green to red here — which is why a body calling [Alcotest.run] must
 * pass [~and_exit:false], or control never comes back. A failing case
 * raises Test_error instead, and exits non-zero just the same. *)
let skip_or_run ~name body =
  match skip_reason () with
  | Some why ->
      Printf.printf "SKIP: %s — %s\n" name why;
      exit 0
  | None ->
      body ();
      exit_on_leaks ()

let check_rc_zero ~label (rc, captured) =
  if rc <> 0 then
    Alcotest.failf "%s exit=%d\n---- pctl stderr ----\n%s" label rc
      (if captured = "" then "(empty)" else captured)

let assert_eq_int ~label expected got =
  Alcotest.(check int) label expected got

let assert_true ~label cond =
  Alcotest.(check bool) label true cond

let assert_false ~label cond =
  Alcotest.(check bool) label false cond

let assert_eq_string ~label expected got =
  Alcotest.(check string) label expected got

(* Diagnostic snapshot: the five fields that actually distinguish "not
 * active" causes (load-failed vs. crashed vs. still-activating vs.
 * sandbox-rejected), plus the last 30 journal lines. *)
let unit_diagnostic unit_name : string =
  let show, _ =
    run_capture
      (Printf.sprintf
         "systemctl --user show %s -p LoadState -p ActiveState -p SubState -p \
          Result -p ExecMainStatus -p ExecMainCode -p StatusErrno -p \
          InvocationID --no-pager 2>&1"
         (Filename.quote unit_name))
  in
  let jr, _ =
    run_capture
      (Printf.sprintf
         "journalctl --user --no-pager -n 30 --output=short-iso -u %s 2>&1"
         (Filename.quote unit_name))
  in
  Printf.sprintf "---- systemctl show %s ----\n%s---- journalctl -u %s (last 30) ----\n%s"
    unit_name show unit_name jr

let assert_unit_active unit_name =
  if not (wait_active unit_name) then
    Alcotest.failf
      "%s did not reach active within 5s\n%s" unit_name
      (unit_diagnostic unit_name)

let assert_unit_inactive unit_name =
  if not (wait_inactive unit_name) then
    Alcotest.failf "%s did not leave active within 5s\n%s" unit_name
      (unit_diagnostic unit_name)

let assert_unit_exists unit_filename =
  assert_true
    ~label:(Printf.sprintf "%s file exists" unit_filename)
    (unit_exists ~unit_filename)

let assert_unit_gone unit_filename =
  assert_false
    ~label:(Printf.sprintf "%s file gone" unit_filename)
    (unit_exists ~unit_filename)

let assert_dropin_gone unit_filename =
  assert_false
    ~label:(Printf.sprintf "%s dropin gone" unit_filename)
    (dropin_exists ~unit_filename)

let assert_contains ~label haystack needle =
  if not (contains haystack needle) then
    Alcotest.failf "%s: expected substring %S in %S" label needle haystack

let assert_not_contains ~label haystack needle =
  if contains haystack needle then
    Alcotest.failf "%s: unexpected substring %S in %S" label needle haystack

(* Name helpers — delegate to the canonical Schema derivations so tests
 * and production agree on the filename convention. *)
let slice_name id_s = Printf.sprintf "pctl-%s.slice" id_s
let service_name id_s svc = Printf.sprintf "pctl-%s-%s.service" id_s svc

let slice_filename_for ~(id : Schema.project_id) =
  Schema.Unit_filename.to_string (Schema.Unit_filename.slice ~id)

let service_filename_for ~(id : Schema.project_id) ~service_name =
  Schema.Unit_filename.to_string
    (Schema.Unit_filename.service ~id ~service:service_name)
