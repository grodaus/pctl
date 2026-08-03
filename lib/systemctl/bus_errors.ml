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
 * Two different guards produce it, so the two ops pctl calls disagree
 * about which units can answer it:
 *
 *   - StopUnit always loads the name (method_stop_unit →
 *     method_start_unit_generic → manager_load_unit), and loading a
 *     missing file SUCCEEDS with load_state = not-found. The reply comes
 *     later, from the JOB_STOP-specific guard in
 *     unit_queue_job_check_and_mangle_type: load error AND currently
 *     inactive. A unit systemd synthesises is not a load error, so it
 *     takes the job instead.
 *   - ResetFailedUnit does not load at all (method_generic_unit_operation
 *     with flags = 0 → bus_get_unit_by_name), so any name not currently
 *     loaded answers the reply.
 *
 * Read in the v260.1 tree, which is what this host runs. Function names
 * rather than line numbers on purpose: the StopUnit guard moved out of
 * bus_unit_queue_job_one into unit.c between 257 and 260 without changing
 * its test.
 *
 * Which units those are per op is recorded against real systemd in
 * test/e2e/test_down_missing_units.ml. [Lifecycle]'s down path is the
 * caller that depends on it.
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
