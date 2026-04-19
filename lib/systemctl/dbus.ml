(* Dbus — systemd D-Bus binding via ctypes-foreign.
 *
 * Targets libsystemd's sd_bus API. Lazy dlopen of libsystemd.so.0 in
 * [connect] means importing this module is cheap: unit tests that
 * only touch [In_mem] can link without libsystemd on the loader path.
 *
 * Concurrency model — chosen for simplicity in Phase 3:
 *   - Synchronous [sd_bus_call_method] calls block the Eio domain
 *     during the RPC. This is fine for a single-shot CLI: no other
 *     fiber needs progress while we're doing one RPC.
 *   - Subscription dispatch runs in a dedicated background fiber that
 *     alternates [sd_bus_process] (non-blocking drain) and
 *     [sd_bus_wait] with a 100 ms timeout. Eio preempts that fiber
 *     cooperatively. We do NOT integrate the bus fd into Eio's epoll
 *     loop in Phase 3 — documented as a Phase 5+ option in the plan's
 *     "Risks" section.
 *
 * Memory lifecycle — every allocating FFI call is wrapped in a
 *   [Fun.protect] so unref/free runs on both success and failure
 *   paths. The bus handle itself is tracked by [Gc.finalise] as a
 *   belt-and-braces; callers should prefer explicit [close].
 *
 * Plan binding: docs/src/plans/20260419-ocaml-rewrite.md
 *   § "Systemctl port" and "Phase 3 — Systemctl port + dbus adapter".
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

  let to_string s =
    let msg_ptr = C.getf s message_f in
    match msg_ptr with
    | None -> "(no message)"
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

module Ffi = struct
  type t = {
    sd_bus_default_user : sd_bus C.ptr -> int;
    sd_bus_open_user : sd_bus C.ptr -> int;
    sd_bus_unref : sd_bus -> sd_bus;
    sd_bus_message_unref : sd_bus_message -> sd_bus_message;
    sd_bus_error_free :
      Sd_bus_error.t Ctypes.structure C.ptr -> unit;
    sd_bus_get_fd : sd_bus -> int;
    sd_bus_process : sd_bus -> sd_bus_message C.ptr -> int;
    sd_bus_wait : sd_bus -> Unsigned.uint64 -> int;
    sd_bus_slot_unref : sd_bus_slot -> sd_bus_slot;
    sd_bus_add_match :
      sd_bus ->
      sd_bus_slot C.ptr ->
      string ->
      (sd_bus_message ->
      unit C.ptr ->
      Sd_bus_error.t Ctypes.structure C.ptr ->
      int) ->
      unit C.ptr ->
      int;
  }

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
      sd_bus_get_fd = foreign "sd_bus_get_fd" C.(sd_bus @-> returning int);
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
(* Variadic FFI: sd_bus_call_method + sd_bus_message_read.
 *
 * These take `(..., const char *types, ...)`. We don't need full
 * variadic support — every call we make has a known, fixed signature.
 * We declare one specialisation per signature.
 *)
(* ------------------------------------------------------------------ *)

(* sd_bus_call_method signature used everywhere we pass a (s s) string
 * pair (StartUnit/StopUnit/RestartUnit). Returns int; populates reply. *)
let sd_bus_call_method_ss =
  foreign "sd_bus_call_method"
    C.(
      sd_bus
      @-> string  (* destination *)
      @-> string  (* path *)
      @-> string  (* interface *)
      @-> string  (* member *)
      @-> ptr Sd_bus_error.struct_t
      @-> ptr sd_bus_message  (* reply *)
      @-> string  (* types = "ss" *)
      @-> string  (* first s *)
      @-> string  (* second s *)
      @-> returning int)

(* sd_bus_call_method variant for Reload() — no args; types = "". *)
let sd_bus_call_method_no_args =
  foreign "sd_bus_call_method"
    C.(
      sd_bus
      @-> string
      @-> string
      @-> string
      @-> string
      @-> ptr Sd_bus_error.struct_t
      @-> ptr sd_bus_message
      @-> string  (* "" *)
      @-> returning int)

(* sd_bus_call_method for GetUnit(s) -> o. One string arg. *)
let sd_bus_call_method_s =
  foreign "sd_bus_call_method"
    C.(
      sd_bus
      @-> string
      @-> string
      @-> string
      @-> string
      @-> ptr Sd_bus_error.struct_t
      @-> ptr sd_bus_message
      @-> string  (* types = "s" *)
      @-> string
      @-> returning int)

(* sd_bus_call_method for Properties.Get(s s) -> v. Two string args,
 * reply is a variant. *)
(* same as the _ss variant above *)

(* sd_bus_message_read: pull an object path (o) out of the reply from
 * GetUnit. *)
let sd_bus_message_read_o =
  foreign "sd_bus_message_read"
    C.(
      sd_bus_message
      @-> string  (* types = "o" *)
      @-> ptr (ptr_opt char)  (* char **value *)
      @-> returning int)

(* sd_bus_message_read for reading a variant string (v containing s).
 * libsystemd understands "v" specially: pass the inner type as an
 * extra argument. For a variant holding a single string, types="v"
 * expects: const char *contents, then the actual value. sd_bus's
 * `sd_bus_message_read` with "v" is tricky; we instead use
 * `sd_bus_message_read_basic` inside an `enter_container`. Simpler
 * route: read the reply as "v" using the helper variant below. *)

(* Read a simple string from a message (types = "s"). *)
let sd_bus_message_read_s =
  foreign "sd_bus_message_read"
    C.(
      sd_bus_message
      @-> string
      @-> ptr (ptr_opt char)
      @-> returning int)

(* Container navigation for unpacking the variant returned by
 * org.freedesktop.DBus.Properties.Get. *)
let sd_bus_message_enter_container =
  foreign "sd_bus_message_enter_container"
    C.(sd_bus_message @-> char @-> string @-> returning int)

let sd_bus_message_exit_container =
  foreign "sd_bus_message_exit_container"
    C.(sd_bus_message @-> returning int)

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

let check_rc ~op ~unit:u ~err rc =
  if rc < 0 then
    let msg = Sd_bus_error.to_string (C.( !@ ) err) in
    raise
      (Schema.Pctl_error
         (Schema.Unit_op_failed { op; unit_ = u; reply = msg }))

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
  env : Eio_unix.Stdenv.base;
  ffi : Ffi.t;
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

let close t =
  if not !(t.closed) then begin
    t.closed := true;
    t.dispatch_stopped := true;
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
              msg =
                Printf.sprintf "sd_bus_default_user/open_user returned %d"
                  rc;
            }));
  let bus = C.( !@ ) bus_pp in
  let t =
    {
      bus;
      sw;
      env;
      ffi;
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
    sd_bus_call_method_ss t.bus systemd1_dest systemd1_path manager_iface op
      err reply "ss" u "replace"
  in
  check_rc ~op ~unit:u ~err rc

let start_unit t ~unit:u = call_unit_op t ~op:"StartUnit" ~unit:u
let stop_unit t ~unit:u = call_unit_op t ~op:"StopUnit" ~unit:u
let restart_unit t ~unit:u = call_unit_op t ~op:"RestartUnit" ~unit:u

let daemon_reload t =
  with_error @@ fun err ->
  with_reply @@ fun reply ->
  let rc =
    sd_bus_call_method_no_args t.bus systemd1_dest systemd1_path
      manager_iface "Reload" err reply ""
  in
  check_rc ~op:"Reload" ~unit:"-" ~err rc

(* GetUnit(name) -> ObjectPath. *)
let get_unit_path t ~unit:u =
  with_error @@ fun err ->
  with_reply @@ fun reply ->
  let rc =
    sd_bus_call_method_s t.bus systemd1_dest systemd1_path manager_iface
      "GetUnit" err reply "s" u
  in
  check_rc ~op:"GetUnit" ~unit:u ~err rc;
  let reply_msg = C.( !@ ) reply in
  let out = C.allocate C.(ptr_opt char) None in
  let rc2 = sd_bus_message_read_o reply_msg "o" out in
  if rc2 < 0 then
    raise
      (Schema.Pctl_error
         (Schema.Unit_op_failed
            {
              op = "GetUnit/read";
              unit_ = u;
              reply = Printf.sprintf "sd_bus_message_read(o) rc=%d" rc2;
            }));
  cstring_of_ptr_opt (C.( !@ ) out)

(* Properties.Get(unit_iface, "ActiveState") on the unit path. Returns
 * the string from the variant. *)
let read_active_state t ~unit:u ~path =
  with_error @@ fun err ->
  with_reply @@ fun reply ->
  let rc =
    sd_bus_call_method_ss t.bus systemd1_dest path props_iface "Get" err
      reply "ss" unit_iface "ActiveState"
  in
  check_rc ~op:"Properties.Get" ~unit:u ~err rc;
  let reply_msg = C.( !@ ) reply in
  (* reply is a single variant `v` containing `s`. Enter the v
   * container, read the s, exit. *)
  let rc_enter = sd_bus_message_enter_container reply_msg 'v' "s" in
  if rc_enter < 0 then
    raise
      (Schema.Pctl_error
         (Schema.Unit_op_failed
            {
              op = "ActiveState/enter_container";
              unit_ = u;
              reply = Printf.sprintf "rc=%d" rc_enter;
            }));
  let out = C.allocate C.(ptr_opt char) None in
  let rc_read = sd_bus_message_read_s reply_msg "s" out in
  if rc_read < 0 then
    raise
      (Schema.Pctl_error
         (Schema.Unit_op_failed
            {
              op = "ActiveState/read";
              unit_ = u;
              reply = Printf.sprintf "rc=%d" rc_read;
            }));
  let s = cstring_of_ptr_opt (C.( !@ ) out) in
  let _ = sd_bus_message_exit_container reply_msg in
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
 * Limitations (OK for Phase 3 exit criteria — Phase 5 will tune):
 *   - No deduplication of "state didn't change" signals: if a
 *     subscriber is racy the callback may fire multiple times with
 *     the same state. Phase 5's probe.ml is responsible for filtering.
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
   * their current unit state, fire each callback. We ignore the
   * message body and sender error out-arg. *)
  let handler _msg _ud _err =
    let subs = !(t.subscribers) in
    List.iter
      (fun entry ->
        let s =
          (!safe_unit_state_forward) t ~unit:entry.unit_name
        in
        Eio.Fiber.fork ~sw:t.sw (fun () ->
            try entry.cb s with _ -> ()))
      subs;
    0
  in
  (* Keep the funptr alive for the lifetime of t. *)
  let handler_root = ref (Obj.repr handler) in
  t.callback_roots := handler_root :: !(t.callback_roots);
  let slot_pp = C.allocate sd_bus_slot C.null in
  let rc =
    t.ffi.sd_bus_add_match t.bus slot_pp match_rule handler C.null
  in
  if rc < 0 then
    raise
      (Schema.Pctl_error
         (Schema.Unit_op_failed
            {
              op = "sd_bus_add_match";
              unit_ = "-";
              reply = Printf.sprintf "rc=%d" rc;
            }));
  let slot = C.( !@ ) slot_pp in
  t.slots := slot :: !(t.slots);
  Eio.Fiber.fork ~sw:t.sw (fun () -> dispatch_loop t);
  t.match_rule_installed := true

let subscribe_unit_changes t ~unit:u cb =
  t.subscribers := { unit_name = u; cb } :: !(t.subscribers);
  if not !(t.match_rule_installed) then install_match_rule_and_fiber t
