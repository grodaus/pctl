(* Bus_errors — the D-Bus error names pctl makes decisions on, and the
 * classifiers over them.
 *
 * Every name here is a wire constant and is matched by EQUALITY. The
 * value classified is [Schema.error]'s [error_name] field, which carries
 * the name sd-bus put in the reply; the [reply] field beside it is a
 * display string (name + message, or a decoded errno) and classifying on
 * that couples the decision to a formatting function — which is what
 * these predicates used to do.
 *
 * The two predicates take different arguments because their callers hold
 * different things. [is_no_such_unit] takes the whole error: its callers
 * ([Lifecycle], [Gc]) have caught a [Pctl_error]. [is_peer_gone] takes
 * the name alone: its caller ([Dbus.daemon_reload]'s retry) decides
 * before an error value exists, inside the scope that still owns the
 * sd_bus_error struct. *)

(* systemd's reply when a unit op names a unit it cannot load —
 * BUS_ERROR_NO_SUCH_UNIT, "Unit x.service not loaded." Callers tolerate
 * exactly this "there was nothing there" failure and propagate the rest.
 *
 * Which ops can answer it depends on whether the op LOADS the name first
 * (GENERIC_UNIT_LOAD, src/core/dbus-manager.c). StopUnit does, so a name
 * systemd can synthesise never reaches the error — an unloaded .service
 * answers this name, an unloaded .slice succeeds and returns a job path.
 * ResetFailedUnit does not load, so it answers this name for anything not
 * currently loaded, slice included. Both measured on systemd 260.1 with
 * `dbus-send --session --print-reply`.
 *
 * The slice half of that is what test/e2e/test_down_missing_units.ml
 * exists for: it holds the observable contract for the one caller that
 * stops a SLICE under this tolerance ([Lifecycle]'s down path), which on
 * this systemd never reaches it.
 *
 * "Already not failed" is not an error reply at all — unit_reset_failed
 * on a healthy unit just succeeds (bus_unit_method_reset_failed,
 * src/core/dbus-unit.c). *)
let no_such_unit = "org.freedesktop.systemd1.NoSuchUnit"

let error_name : Schema.error -> string option = function
  | Schema.Unit_op_failed { error_name; _ } -> error_name
  | _ -> None

let is_no_such_unit (e : Schema.error) : bool =
  error_name e = Some no_such_unit

(* Names that mean the destination is not on the bus right now, so the
 * same call on the same handle can simply be re-issued. See
 * [Bus_retry]'s header for the window this exists for and how long the
 * retry is allowed to last.
 *
 * org.freedesktop.DBus.Error.Disconnected is deliberately absent. It
 * names OUR connection, not the peer's — errno_to_bus_error_const
 * (bus-error.c) produces it only for ECONNRESET / ECONNABORTED /
 * ENETRESET, i.e. our own socket died. Asking again on a dead handle
 * cannot succeed, and would replace a truthful "Disconnected" with
 * whatever the second attempt reports instead. *)
(* Named on its own because it is the one actually observed on this host
 * (dbus-broker's driver_goodbye reply, see [Bus_retry]) and so the one a
 * test wants to reproduce. *)
let no_reply = "org.freedesktop.DBus.Error.NoReply"

let peer_gone_error_names =
  [
    no_reply;
    "org.freedesktop.DBus.Error.ServiceUnknown";
    "org.freedesktop.DBus.Error.NameHasNoOwner";
  ]

(* Transport failures almost never arrive unnamed: every [fail:] path in
 * sd_bus_call_methodv (bus-convenience.c) and sd_bus_call runs
 * sd_bus_error_set_errno, and both use bus_assert_return for their
 * argument checks, which populates too. That yields
 * "System.Error.<ERRNO>" for an errno with no const mapping (ENOTCONN is
 * one) and org.freedesktop.DBus.Error.Failed when the errno has no name
 * at all. Exact matching rejects every one of those, which is the answer
 * we want.
 *
 * Two checks in sd_bus_call are plain assert_return rather than
 * bus_assert_return, so they return the errno with the error struct
 * untouched and DO yield [None]: -ENOPKG when bus_resolve rejects the
 * bus, -ENOTCONN when neither a bus nor a message-attached bus was
 * given. pctl hands every call a live sd_bus* from sd_bus_open_user, so
 * neither can fire — [None] is unreachable because of that, not because
 * sd-bus names everything. The arm answers "do not retry" because an
 * unnamed failure is not evidence the peer will return. *)
let is_peer_gone : string option -> bool = function
  | None -> false
  | Some name -> List.mem name peer_gone_error_names
