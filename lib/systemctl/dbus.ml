(* Dbus — systemd D-Bus binding via ctypes-foreign.
 *
 * Targets libsystemd's sd_bus API. Lazy dlopen of libsystemd.so.0 in
 * [connect] means importing this module is cheap: unit tests that
 * only touch [In_mem] can link without libsystemd on the loader path.
 *
 * Concurrency model:
 *   - Synchronous [sd_bus_call_method] calls block the Eio domain
 *     during the RPC. Fine for a single-shot CLI: no other fiber
 *     needs progress while we're doing one RPC.
 *   - Subscription dispatch runs in a dedicated background fiber that
 *     alternates [sd_bus_process] (non-blocking drain) and
 *     [sd_bus_wait] with a 100 ms timeout. Eio preempts that fiber
 *     cooperatively. The bus fd is not integrated into Eio's epoll
 *     loop — that's a latency knob worth ~50 ms in the worst case,
 *     acceptable for pctl's use.
 *
 * Memory lifecycle — every allocating FFI call is wrapped in a
 *   [Fun.protect] so unref/free runs on both success and failure
 *   paths. The bus handle itself is tracked by [Gc.finalise] as a
 *   belt-and-braces; callers should prefer explicit [close].
 *)

module C = Ctypes
module F = Foreign

(* ------------------------------------------------------------------ *)
(* libsystemd dlopen — deferred to [connect] so importing this module
 * is cheap and test binaries don't need libsystemd.so on LD_LIBRARY_
 * PATH to link. *)
(* ------------------------------------------------------------------ *)

let libsystemd_lazy : Dl.library option Lazy.t =
  lazy
    (try Some (Dl.dlopen ~filename:"libsystemd.so.0" ~flags:[ Dl.RTLD_NOW ])
     with Dl.DL_error _ -> (
       try Some (Dl.dlopen ~filename:"libsystemd.so" ~flags:[ Dl.RTLD_NOW ])
       with Dl.DL_error _ -> None))

let libsystemd () =
  match Lazy.force libsystemd_lazy with
  | Some h -> h
  | None ->
      raise
        (Schema.Pctl_error
           (Schema.Bus_connect_failed
              {
                msg =
                  "libsystemd.so.0 not found via dlopen; check \
                   LD_LIBRARY_PATH or systemdLibs build input";
              }))

let foreign name typ =
  let lib = libsystemd () in
  F.foreign ~from:lib name typ

(* ------------------------------------------------------------------ *)
(* Opaque types from libsystemd — treated as `void *`. *)
(* ------------------------------------------------------------------ *)

type sd_bus = unit C.ptr
let sd_bus : sd_bus C.typ = C.(ptr void)
let sd_bus_null : sd_bus = C.null

type sd_bus_message = unit C.ptr
let sd_bus_message : sd_bus_message C.typ = C.(ptr void)

type sd_bus_slot = unit C.ptr
let sd_bus_slot : sd_bus_slot C.typ = C.(ptr void)

(* sd_bus_error is a struct with {name, message, _need_free}. We model
 * it as an opaque block of the right size — 24 bytes on x86_64. The
 * safer approach is to declare the layout explicitly and read `message`
 * back. We do that below. *)

module Sd_bus_error = struct
  type t

  let struct_t : t Ctypes.structure C.typ = C.structure "sd_bus_error"
  let name_f = C.field struct_t "name" C.(ptr_opt char)
  let message_f = C.field struct_t "message" C.(ptr_opt char)
  let need_free_f = C.field struct_t "_need_free" C.int
  let () = C.seal struct_t

  let make () : t Ctypes.structure =
    let s = C.make struct_t in
    C.setf s name_f None;
    C.setf s message_f None;
    C.setf s need_free_f 0;
    s

  let decode = function
    | None -> None
    | Some p ->
        let rec len i =
          if C.( !@ ) (C.( +@ ) p i) = '\x00' then i else len (i + 1)
        in
        let n = len 0 in
        let b = Bytes.create n in
        for i = 0 to n - 1 do
          Bytes.unsafe_set b i (C.( !@ ) (C.( +@ ) p i))
        done;
        Some (Bytes.unsafe_to_string b)

  (* (name, message) — either field may be NULL, hence the options. In
   * practice sd-bus names every failure it reports: an error reply
   * carries the peer's name (e.g. org.freedesktop.systemd1.NoSuchUnit),
   * and a locally-generated failure goes through
   * sd_bus_error_set_errno, which always sets one. See
   * [Bus_retry.is_peer_gone] for why the classifier nonetheless keeps
   * a [None] arm. *)
  let parts s = (decode (C.getf s name_f), decode (C.getf s message_f))
end

(* ------------------------------------------------------------------ *)
(* FFI table — lazily built when [connect] is first called. We hold
 * references so dlsym only happens once per call name. *)
(* ------------------------------------------------------------------ *)

(* Signal handler callback type for sd_bus_add_match:
 *   int handler(sd_bus_message *m, void *userdata, sd_bus_error *ret_error)
 * Returning non-zero aborts; we always return 0. *)
let sd_bus_message_handler_t =
  C.(
    Foreign.funptr
      (sd_bus_message @-> ptr void @-> ptr Sd_bus_error.struct_t
     @-> returning int))

(* All symbols in one lazily-built record: a top-level [foreign] would dlopen
 * at module init, aborting binaries that never touch the bus. *)
module Ffi = struct
  type error_p = Sd_bus_error.t Ctypes.structure C.ptr

  (* dest -> path -> iface -> member -> err -> reply -> types -> … *)
  type 'a call_method =
    sd_bus ->
    string ->
    string ->
    string ->
    string ->
    error_p ->
    sd_bus_message C.ptr ->
    string ->
    'a

  type t = {
    sd_bus_default_user : sd_bus C.ptr -> int;
    sd_bus_open_user : sd_bus C.ptr -> int;
    sd_bus_unref : sd_bus -> sd_bus;
    sd_bus_message_unref : sd_bus_message -> sd_bus_message;
    sd_bus_error_free : error_p -> unit;
    sd_bus_process : sd_bus -> sd_bus_message C.ptr -> int;
    sd_bus_wait : sd_bus -> Unsigned.uint64 -> int;
    sd_bus_slot_unref : sd_bus_slot -> sd_bus_slot;
    sd_bus_add_match :
      sd_bus ->
      sd_bus_slot C.ptr ->
      string ->
      (sd_bus_message -> unit C.ptr -> error_p -> int) ->
      unit C.ptr ->
      int;
    sd_bus_message_read_basic : sd_bus_message -> char -> unit C.ptr -> int;
    (* types = "ss" — StartUnit/StopUnit/RestartUnit, Properties.Get. *)
    call_method_ss : (string -> string -> int) call_method;
    (* types = "s" — ResetFailedUnit, GetUnit. *)
    call_method_s : (string -> int) call_method;
    (* types = "" — Reload, Subscribe, Unsubscribe. *)
    call_method_no_args : int call_method;
    (* types = "s" | "o" — same C signature, only the type code differs. *)
    message_read_cstr :
      sd_bus_message -> string -> char C.ptr option C.ptr -> int;
    message_enter_container : sd_bus_message -> char -> string -> int;
    message_exit_container : sd_bus_message -> int;
  }

  let call_method_t ret =
    C.(
      sd_bus
      @-> string (* destination *)
      @-> string (* path *)
      @-> string (* interface *)
      @-> string (* member *)
      @-> ptr Sd_bus_error.struct_t
      @-> ptr sd_bus_message (* reply *)
      @-> string (* types *)
      @-> ret)

  let build () : t =
    {
      sd_bus_default_user =
        foreign "sd_bus_default_user" C.(ptr sd_bus @-> returning int);
      sd_bus_open_user =
        foreign "sd_bus_open_user" C.(ptr sd_bus @-> returning int);
      sd_bus_unref = foreign "sd_bus_unref" C.(sd_bus @-> returning sd_bus);
      sd_bus_message_unref =
        foreign "sd_bus_message_unref"
          C.(sd_bus_message @-> returning sd_bus_message);
      sd_bus_error_free =
        foreign "sd_bus_error_free"
          C.(ptr Sd_bus_error.struct_t @-> returning void);
      sd_bus_process =
        foreign "sd_bus_process"
          C.(sd_bus @-> ptr sd_bus_message @-> returning int);
      sd_bus_wait =
        foreign "sd_bus_wait" C.(sd_bus @-> uint64_t @-> returning int);
      sd_bus_slot_unref =
        foreign "sd_bus_slot_unref"
          C.(sd_bus_slot @-> returning sd_bus_slot);
      sd_bus_add_match =
        foreign "sd_bus_add_match"
          C.(
            sd_bus @-> ptr sd_bus_slot @-> string
            @-> sd_bus_message_handler_t @-> ptr void @-> returning int);
      sd_bus_message_read_basic =
        foreign "sd_bus_message_read_basic"
          C.(sd_bus_message @-> char @-> ptr void @-> returning int);
      call_method_ss =
        foreign "sd_bus_call_method"
          (call_method_t C.(string @-> string @-> returning int));
      call_method_s =
        foreign "sd_bus_call_method"
          (call_method_t C.(string @-> returning int));
      call_method_no_args =
        foreign "sd_bus_call_method" (call_method_t C.(returning int));
      message_read_cstr =
        foreign "sd_bus_message_read"
          C.(
            sd_bus_message
            @-> string (* types = "s" | "o" *)
            @-> ptr (ptr_opt char) (* char **value *)
            @-> returning int);
      message_enter_container =
        foreign "sd_bus_message_enter_container"
          C.(sd_bus_message @-> char @-> string @-> returning int);
      message_exit_container =
        foreign "sd_bus_message_exit_container"
          C.(sd_bus_message @-> returning int);
    }

  let cache : t option ref = ref None

  let get () =
    match !cache with
    | Some f -> f
    | None ->
        let f = build () in
        cache := Some f;
        f
end

(* ------------------------------------------------------------------ *)
(* Helpers                                                             *)
(* ------------------------------------------------------------------ *)

(* Decode a libsystemd-allocated C string (not owned by us: libsystemd
 * keeps the pointer alive as long as the parent message is refd). *)
let cstring_of_ptr_opt = function
  | None -> ""
  | Some p ->
      let rec len i =
        if C.( !@ ) (C.( +@ ) p i) = '\x00' then i else len (i + 1)
      in
      let n = len 0 in
      let b = Bytes.create n in
      for i = 0 to n - 1 do
        Bytes.unsafe_set b i (C.( !@ ) (C.( +@ ) p i))
      done;
      Bytes.unsafe_to_string b

(* Decode a negative sd-bus return code into a human-readable message.
 * sd-bus follows the libc convention of returning -errno on failure, but
 * surfaces it as a raw integer — callers get "-123" without context. We
 * resolve strerror(errno), name the errno where the platform exposes
 * strerrorname_np, and attach a hint for the common "no user bus
 * reachable" failure modes so CI logs are self-diagnosing. *)
let strerror_ffi =
  F.foreign "strerror" C.(int @-> returning (ptr_opt char))

(* strerrorname_np is a GNU extension (glibc ≥ 2.32). musl and older
 * glibc don't ship it — bind lazily and tolerate its absence. *)
let strerrorname_np : int -> string option =
  let f_opt =
    try
      Some
        (F.foreign "strerrorname_np"
           C.(int @-> returning (ptr_opt char)))
    with _ -> None
  in
  fun errno ->
    match f_opt with
    | None -> None
    | Some f -> (
        match f errno with
        | None -> None
        | Some _ as p -> Some (cstring_of_ptr_opt p))

(* Errno integers the hint branch cares about, sourced from <errno.h>
 * via the pctl_errno C stub — keeps us off hardcoded Linux ABI values.
 * Exposed as OCaml primitives (not dlsym'd symbols) so they link
 * without needing -rdynamic on the final executable. *)
external pctl_errno_enoent : unit -> int = "pctl_errno_ENOENT" [@@noalloc]

external pctl_errno_econnrefused : unit -> int = "pctl_errno_ECONNREFUSED"
  [@@noalloc]

external pctl_errno_enomedium : unit -> int = "pctl_errno_ENOMEDIUM"
  [@@noalloc]

let errno_ENOENT = pctl_errno_enoent ()
let errno_ECONNREFUSED = pctl_errno_econnrefused ()
let errno_ENOMEDIUM = pctl_errno_enomedium ()

let user_bus_hint errno =
  if errno = errno_ENOENT || errno = errno_ECONNREFUSED
     || errno = errno_ENOMEDIUM
  then
    Some
      "no user bus reachable — check that `systemd --user` is running \
       and $XDG_RUNTIME_DIR points at /run/user/$(id -u). On CI \
       runners, enable lingering with `loginctl enable-linger $USER` \
       or wrap the command in `dbus-run-session --`."
  else None

let format_sd_bus_err op rc =
  let errno = if rc < 0 then -rc else rc in
  let desc = cstring_of_ptr_opt (strerror_ffi errno) in
  let named =
    match strerrorname_np errno with
    | Some name -> Printf.sprintf "%s: %s" name desc
    | None -> desc
  in
  let base = Printf.sprintf "%s returned -%d (%s)" op errno named in
  match user_bus_hint errno with
  | Some hint -> base ^ " — " ^ hint
  | None -> base

(* Format whatever sd-bus gave us on a failed call. If the sd_bus_error
 * struct was populated we prefer its name + message (grep-friendly
 * D-Bus error names like org.freedesktop.systemd1.NoSuchUnit come
 * through here).
 *
 * Transport failures do NOT leave the struct empty: every [fail:] path
 * in sd_bus_call_methodv / sd_bus_call runs sd_bus_error_set_errno, so
 * even a closed bus arrives named ("System.Error.ENOTCONN"). The
 * [None, None] arm is therefore near-unreachable and the errno decode
 * is a backstop, not the usual transport case — see [Bus_retry], which
 * classifies on that same name. *)
let format_bus_reply ~op ~err rc =
  match Sd_bus_error.parts (C.( !@ ) err) with
  | Some name, Some message -> Printf.sprintf "%s: %s" name message
  | None, Some message -> message
  | Some name, None -> name ^ " (no message)"
  | None, None -> format_sd_bus_err op rc

let check_rc ~op ~unit:u ~err rc =
  if rc < 0 then
    raise
      (Schema.Pctl_error
         (Schema.Unit_op_failed
            { op; unit_ = u; reply = format_bus_reply ~op ~err rc }))

(* Raise Unit_op_failed if [rc < 0]. Used for non-sd_bus_error-populating
 * calls (e.g. message_read, enter_container). *)
let fail_on_neg_rc ~op ~unit:u rc =
  if rc < 0 then
    raise
      (Schema.Pctl_error
         (Schema.Unit_op_failed
            { op; unit_ = u; reply = format_sd_bus_err op rc }))

let with_error f =
  let err = Sd_bus_error.make () in
  let err_p = C.addr err in
  Fun.protect
    ~finally:(fun () -> (Ffi.get ()).sd_bus_error_free err_p)
    (fun () -> f err_p)

let with_reply f =
  let reply = C.allocate sd_bus_message sd_bus_null in
  Fun.protect
    ~finally:(fun () ->
      let r = C.( !@ ) reply in
      if not (C.is_null r) then
        ignore ((Ffi.get ()).sd_bus_message_unref r))
    (fun () -> f reply)

(* Allocate a string out-pointer, run [f], decode the C string into an
 * OCaml string. Used by sd_bus_message_read callers. *)
let read_cstring_out f =
  let out = C.allocate C.(ptr_opt char) None in
  f out;
  cstring_of_ptr_opt (C.( !@ ) out)

(* ------------------------------------------------------------------ *)
(* Handle type + [connect].                                            *)
(* ------------------------------------------------------------------ *)

type subscriber_entry = {
  unit_name : string;
  cb : Schema.state -> unit;
}

type t = {
  bus : sd_bus;
  sw : Eio.Switch.t;
  ffi : Ffi.t;
  (* Monotonic clock, kept for [Bus_retry]'s elapsed-time budget. Same
   * source as [Probe]'s deadlines — see lib/probe/probe.ml. *)
  mono : Eio.Time.Mono.ty Eio.Std.r;
  (* Slots from sd_bus_add_match; unref on close. *)
  slots : sd_bus_slot list ref;
  (* Subscribers keyed by unit-name prefix; handler fires all matching
   * entries whenever any PropertiesChanged arrives on the manager's
   * unit interface. Simpler than per-unit match rules (which need
   * sd_bus_path_encode of the unit name). *)
  subscribers : subscriber_entry list ref;
  (* Roots for Foreign.funptr-wrapped callbacks — the C side keeps a
   * raw fn-ptr into us; GC must not collect until after
   * sd_bus_slot_unref. *)
  callback_roots : Obj.t ref list ref;
  dispatch_stopped : bool ref;
  closed : bool ref;
  match_rule_installed : bool ref;
}

(* Forward ref; same pattern as [safe_unit_state_forward] below. *)
let manager_unsubscribe_forward : (t -> unit) ref = ref (fun _ -> ())

let close t =
  if not !(t.closed) then begin
    t.closed := true;
    t.dispatch_stopped := true;
    (* Unsubscribe only if we Subscribed, and before unref-ing the bus. *)
    if !(t.match_rule_installed) && not (C.is_null t.bus) then
      (try !manager_unsubscribe_forward t with _ -> ());
    List.iter
      (fun s -> ignore (t.ffi.sd_bus_slot_unref s))
      !(t.slots);
    t.slots := [];
    t.callback_roots := [];
    if not (C.is_null t.bus) then ignore (t.ffi.sd_bus_unref t.bus)
  end

(* Re-resolve a unit's state, tolerating errors (returns Inactive on
 * failure — same policy as [unit_state]). Declared as a forward ref
 * because the subscribe helper needs it before [unit_state]'s final
 * definition is in scope. We close over [t] and invoke it from the
 * signal handler. *)
let safe_unit_state_forward :
    (t -> unit:string -> Schema.state) ref =
  ref (fun _ ~unit:_ -> Schema.Inactive)

(* Background fiber: cooperatively process sd_bus events while the
 * handle is open. We use sd_bus_wait with a short timeout so the
 * fiber yields to Eio regularly and close() can stop it promptly. *)
let dispatch_loop t =
  let timeout_us = Unsigned.UInt64.of_int 100_000 (* 100 ms *) in
  let msg_p = C.allocate sd_bus_message sd_bus_null in
  let continue = ref true in
  while !continue do
    if !(t.dispatch_stopped) || !(t.closed) then continue := false
    else (
      (* Non-blocking drain. sd_bus_process returns > 0 if a message was
       * processed, 0 if none, < 0 on error. We loop until it returns 0. *)
      let rec drain () =
        let rc = t.ffi.sd_bus_process t.bus msg_p in
        if rc > 0 then (
          let m = C.( !@ ) msg_p in
          if not (C.is_null m) then
            ignore (t.ffi.sd_bus_message_unref m);
          drain ())
        else ()
      in
      drain ();
      if not (!(t.dispatch_stopped) || !(t.closed)) then (
        (* sd_bus_wait blocks up to timeout_us. To let Eio preempt, we
         * yield before calling. We don't integrate the bus fd into Eio's
         * epoll in this phase (documented above). *)
        Eio.Fiber.yield ();
        let _rc = t.ffi.sd_bus_wait t.bus timeout_us in
        ()))
  done

let connect ~sw env =
  let ffi = Ffi.get () in
  let bus_pp = C.allocate sd_bus sd_bus_null in
  let rc = ffi.sd_bus_default_user bus_pp in
  let rc =
    if rc < 0 then ffi.sd_bus_open_user bus_pp else rc
  in
  if rc < 0 then
    raise
      (Schema.Pctl_error
         (Schema.Bus_connect_failed
            {
              msg = format_sd_bus_err "sd_bus_default_user/open_user" rc;
            }));
  let bus = C.( !@ ) bus_pp in
  let t =
    {
      bus;
      sw;
      ffi;
      mono = (env#mono_clock :> Eio.Time.Mono.ty Eio.Std.r);
      slots = ref [];
      subscribers = ref [];
      callback_roots = ref [];
      dispatch_stopped = ref false;
      closed = ref false;
      match_rule_installed = ref false;
    }
  in
  (* Belt-and-braces finaliser. Finaliser body must not allocate OCaml
   * nor raise past the runtime boundary — sd_bus_unref is pure C and
   * ignore-return is safe. *)
  Gc.finalise
    (fun t ->
      if not !(t.closed) then ignore (t.ffi.sd_bus_unref t.bus))
    t;
  t

(* ------------------------------------------------------------------ *)
(* Method calls                                                        *)
(* ------------------------------------------------------------------ *)

let systemd1_dest = "org.freedesktop.systemd1"
let systemd1_path = "/org/freedesktop/systemd1"
let manager_iface = "org.freedesktop.systemd1.Manager"
let unit_iface = "org.freedesktop.systemd1.Unit"
let props_iface = "org.freedesktop.DBus.Properties"

let call_unit_op t ~op ~unit:u =
  with_error @@ fun err ->
  with_reply @@ fun reply ->
  let rc =
    t.ffi.call_method_ss t.bus systemd1_dest systemd1_path manager_iface op
      err reply "ss" u "replace"
  in
  check_rc ~op ~unit:u ~err rc

let start_unit t ~unit:u = call_unit_op t ~op:"StartUnit" ~unit:u
let stop_unit t ~unit:u = call_unit_op t ~op:"StopUnit" ~unit:u
let restart_unit t ~unit:u = call_unit_op t ~op:"RestartUnit" ~unit:u

(* Manager.Reload is idempotent, so a call whose peer vanished can
 * simply be re-issued. That is worth doing here because the peer
 * vanishing is routine on this platform: every NixOS / home-manager
 * activation reexecs the user manager, and pctl reloads twice per [up]
 * (the pair bracketing [Lifecycle.apply_plan]) plus two more for each
 * project the gc sweep removes. See [Bus_retry] for the failure
 * signature and for why the retry is bounded by elapsed time rather
 * than by attempt count. *)
let daemon_reload t =
  let now () = Eio.Time.Mono.now t.mono in
  let started = now () in
  let attempts = ref 0 in
  let attempt () =
    incr attempts;
    with_error @@ fun err ->
    with_reply @@ fun reply ->
    let rc =
      t.ffi.call_method_no_args t.bus systemd1_dest systemd1_path
        manager_iface "Reload" err reply ""
    in
    if rc >= 0 then Ok ()
    else
      (* Decode inside the [with_error] scope — its finaliser frees the
       * struct both fields point into. The retry classifies on the
       * name; [reply] is only ever rendered. *)
      let name, _ = Sd_bus_error.parts (C.( !@ ) err) in
      Error (name, format_bus_reply ~op:"Reload" ~err rc)
  in
  match
    Bus_retry.with_retry ~now ~sleep:(Eio.Time.Mono.sleep t.mono)
      ~budget:Bus_retry.peer_gone_budget ~delay:Bus_retry.peer_gone_delay
      ~retry_on:(fun (name, _) -> Bus_retry.is_peer_gone name)
      attempt
  with
  | Ok () -> ()
  | Error (_, reply) ->
      (* Say so when the budget was spent, so an immediate rejection and
       * a five-second exhausted retry are distinguishable. Callers that
       * discard the error still get the seconds in the message —
       * [Gc.opportunistic_sweep] swallows this one entirely. *)
      let reply =
        if !attempts > 1 then
          Printf.sprintf "%s (gave up after %d attempts over %.1fs)" reply
            !attempts
            (Bus_retry.seconds_since started (now ()))
        else reply
      in
      raise
        (Schema.Pctl_error
           (Schema.Unit_op_failed { op = "Reload"; unit_ = "-"; reply }))

(* See [install_match_rule_and_fiber] for why this is required. *)
let manager_subscribe t =
  with_error @@ fun err ->
  with_reply @@ fun reply ->
  let rc =
    t.ffi.call_method_no_args t.bus systemd1_dest systemd1_path
      manager_iface "Subscribe" err reply ""
  in
  check_rc ~op:"Subscribe" ~unit:"-" ~err rc

(* Best-effort: systemd may have dropped the connection during shutdown. *)
let manager_unsubscribe_best_effort t =
  with_error @@ fun err ->
  with_reply @@ fun reply ->
  let _rc =
    t.ffi.call_method_no_args t.bus systemd1_dest systemd1_path
      manager_iface "Unsubscribe" err reply ""
  in
  ()

let () = manager_unsubscribe_forward := manager_unsubscribe_best_effort

(* ResetFailedUnit(s) — clears the `failed` tombstone. Swallows
 * not-loaded/not-failed errors: callers use this best-effort, same as
 * `systemctl --user reset-failed` with a glob that matches nothing. *)
let reset_failed_unit t ~unit:u =
  with_error @@ fun err ->
  with_reply @@ fun reply ->
  let _rc =
    t.ffi.call_method_s t.bus systemd1_dest systemd1_path manager_iface
      "ResetFailedUnit" err reply "s" u
  in
  ()

(* GetUnit(name) -> ObjectPath. *)
let get_unit_path t ~unit:u =
  with_error @@ fun err ->
  with_reply @@ fun reply ->
  let rc =
    t.ffi.call_method_s t.bus systemd1_dest systemd1_path manager_iface
      "GetUnit" err reply "s" u
  in
  check_rc ~op:"GetUnit" ~unit:u ~err rc;
  let reply_msg = C.( !@ ) reply in
  read_cstring_out (fun out ->
      fail_on_neg_rc ~op:"GetUnit/read" ~unit:u
        (t.ffi.message_read_cstr reply_msg "o" out))

(* Properties.Get(unit_iface, "ActiveState") on the unit path. Returns
 * the string from the variant. *)
let read_active_state t ~unit:u ~path =
  with_error @@ fun err ->
  with_reply @@ fun reply ->
  let rc =
    t.ffi.call_method_ss t.bus systemd1_dest path props_iface "Get" err
      reply "ss" unit_iface "ActiveState"
  in
  check_rc ~op:"Properties.Get" ~unit:u ~err rc;
  let reply_msg = C.( !@ ) reply in
  (* reply is a single variant `v` containing `s`. Enter the v container,
   * read the s, exit. *)
  fail_on_neg_rc ~op:"ActiveState/enter_container" ~unit:u
    (t.ffi.message_enter_container reply_msg 'v' "s");
  let s =
    read_cstring_out (fun out ->
        fail_on_neg_rc ~op:"ActiveState/read" ~unit:u
          (t.ffi.message_read_cstr reply_msg "s" out))
  in
  let _ = t.ffi.message_exit_container reply_msg in
  s

let state_of_active_string ~unit:u = function
  | "active" -> Schema.Active
  | "inactive" -> Schema.Inactive
  | "failed" -> Schema.Failed
  | "activating" -> Schema.Activating
  | "deactivating" -> Schema.Deactivating
  | "reloading" -> Schema.Reloading
  | other ->
      raise
        (Schema.Pctl_error
           (Schema.Unit_op_failed
              {
                op = "ActiveState/parse";
                unit_ = u;
                reply = Printf.sprintf "unknown ActiveState '%s'" other;
              }))

let unit_state t ~unit:u =
  (* GetUnit may fail with NoSuchUnit for a unit that has never been
   * loaded. systemd's own `systemctl is-active` reports "inactive" in
   * that case, so mirror that. We treat any exception on get_unit_path
   * as "inactive". *)
  match
    try Some (get_unit_path t ~unit:u) with Schema.Pctl_error _ -> None
  with
  | None -> Schema.Inactive
  | Some path ->
      let s = read_active_state t ~unit:u ~path in
      state_of_active_string ~unit:u s

(* Properties.Get(unit_iface, "Job") on the unit path. The property type
 * is (u,o) — a struct of (jobId, objectPath). systemd sets the path to
 * "/" when no job is pending; otherwise it points at the queued
 * transaction's object path. We only care about the path.
 *
 * Wire encoding: the reply is v<struct<u,o>>. Enter the v, enter the
 * struct, skip the u (JobId), read the o, exit both. *)
let read_job_path t ~unit:u ~path =
  with_error @@ fun err ->
  with_reply @@ fun reply ->
  let rc =
    t.ffi.call_method_ss t.bus systemd1_dest path props_iface "Get" err
      reply "ss" unit_iface "Job"
  in
  check_rc ~op:"Properties.Get(Job)" ~unit:u ~err rc;
  let reply_msg = C.( !@ ) reply in
  fail_on_neg_rc ~op:"Job/enter_variant" ~unit:u
    (t.ffi.message_enter_container reply_msg 'v' "(uo)");
  fail_on_neg_rc ~op:"Job/enter_struct" ~unit:u
    (t.ffi.message_enter_container reply_msg 'r' "uo");
  (* Skip the u (jobId) via read_basic — the u32 payload never makes it
   * back to the caller; we only care about the object path. *)
  let u32 = C.allocate C.uint32_t Unsigned.UInt32.zero in
  fail_on_neg_rc ~op:"Job/read_u" ~unit:u
    (t.ffi.sd_bus_message_read_basic reply_msg 'u' (C.to_voidp u32));
  let path_s =
    read_cstring_out (fun out ->
        fail_on_neg_rc ~op:"Job/read_o" ~unit:u
          (t.ffi.message_read_cstr reply_msg "o" out))
  in
  let _ = t.ffi.message_exit_container reply_msg in
  let _ = t.ffi.message_exit_container reply_msg in
  path_s

let unit_job_pending t ~unit:u =
  (* Same NoSuchUnit tolerance as [unit_state]: an unloaded unit has no
   * pending job. Any Pctl_error during the property read falls back to
   * "no pending job" — we'd rather fail-fast on state than hang on a
   * transient read error. *)
  match
    try Some (get_unit_path t ~unit:u) with Schema.Pctl_error _ -> None
  with
  | None -> false
  | Some path ->
      (try
         let job_path = read_job_path t ~unit:u ~path in
         job_path <> "/"
       with Schema.Pctl_error _ -> false)

(* Wire the forward reference so the signal handler can re-read state
 * without a dependency cycle. *)
let () =
  safe_unit_state_forward :=
    fun t ~unit:u ->
      try unit_state t ~unit:u with Schema.Pctl_error _ -> Schema.Inactive

(* ------------------------------------------------------------------ *)
(* subscribe_unit_changes — minimal-but-complete implementation.
 *
 * Strategy (chosen per "Risks" fallback in the task brief):
 *
 *   - One coarse sd_bus_add_match rule: signals of type
 *     `PropertiesChanged` on `org.freedesktop.DBus.Properties`, sender
 *     `org.freedesktop.systemd1`. We do NOT filter by object-path
 *     (which would require sd_bus_path_encode on the unit name).
 *   - Paired with a [Manager.Subscribe] call — without it, systemd
 *     only emits per-unit PropertiesChanged to clients that have
 *     explicitly opted in. A match rule alone will silently match
 *     zero signals on a session with no other subscribed client
 *     (lingered services, minimal CI runners).
 *   - The C trampoline handler runs under the background dispatch
 *     fiber. It iterates all registered subscribers, re-resolves the
 *     unit's current state (GetUnit → ActiveState), and fires each
 *     matching callback. The handler does NOT decode the signal body
 *     — it treats every PropertiesChanged as a hint to re-read state.
 *   - Subscribers are stored in a list on [t]. Duplicate subscribes on
 *     the same unit simply append — matching In_mem semantics.
 *   - The match rule + handler funptr are installed lazily: the first
 *     [subscribe_unit_changes] call registers the rule and spawns the
 *     dispatch fiber. Subsequent calls only append to the subscriber
 *     list.
 *
 * Known limitations:
 *   - No deduplication of "state didn't change" signals: if a
 *     subscriber is racy the callback may fire multiple times with
 *     the same state. probe.ml filters on the consumer side.
 *   - No per-unit subscriber removal.
 *
 * Memory lifecycle:
 *   - The funptr wrapper retained via t.callback_roots prevents the GC
 *     from moving/freeing the C closure before sd_bus_slot_unref.
 *   - On [close], we unref every slot then the bus.
 *)

let match_rule =
  "type='signal',sender='org.freedesktop.systemd1',interface='org.\
   freedesktop.DBus.Properties',member='PropertiesChanged'"

let install_match_rule_and_fiber t =
  (* Handler called by libsystemd from the dispatch fiber when any
   * matching signal arrives. Look up every subscriber, re-resolve
   * their current unit state, fire each callback synchronously.
   *
   * We do NOT [Fiber.fork] here: the handler runs during the dispatch
   * loop's [sd_bus_process] call, and [Fiber.fork] performs an Eio
   * effect that requires a live cancellation context. On the last
   * signal before switch teardown that context may already be
   * releasing, raising Effect.Unhandled. The probe.ml callback does
   * only `ref := true; Promise.resolve` — cheap; safe to run inline. *)
  let handler _msg _ud _err =
    let subs = !(t.subscribers) in
    List.iter
      (fun entry ->
        let s =
          (!safe_unit_state_forward) t ~unit:entry.unit_name
        in
        try entry.cb s with _ -> ())
      subs;
    0
  in
  (* Keep the funptr alive for the lifetime of t. *)
  let handler_root = ref (Obj.repr handler) in
  t.callback_roots := handler_root :: !(t.callback_roots);
  let slot_pp = C.allocate sd_bus_slot C.null in
  fail_on_neg_rc ~op:"sd_bus_add_match" ~unit:"-"
    (t.ffi.sd_bus_add_match t.bus slot_pp match_rule handler C.null);
  let slot = C.( !@ ) slot_pp in
  t.slots := slot :: !(t.slots);
  (* AFTER add_match (no dropped early signals) but BEFORE fiber fork. *)
  manager_subscribe t;
  Eio.Fiber.fork ~sw:t.sw (fun () -> dispatch_loop t);
  t.match_rule_installed := true

let subscribe_unit_changes t ~unit:u cb =
  t.subscribers := { unit_name = u; cb } :: !(t.subscribers);
  if not !(t.match_rule_installed) then install_match_rule_and_fiber t
