(* Bus_retry — when a failed bus call means "the peer went away" rather
 * than "the call was rejected", and how long to keep trying.
 *
 * The case this exists for, observed on this host (systemd 260,
 * dbus-broker 37):
 *
 *   systemctl Reload - failed:
 *     org.freedesktop.DBus.Error.NoReply: Remote peer disconnected
 *
 * Every NixOS / home-manager activation runs `switch-to-configuration`,
 * which issues `systemctl --user daemon-reexec`. The user manager then
 * drops its connection to the user bus, and dbus-broker answers every
 * call that was in flight to it with that synthetic error (see
 * driver_goodbye, dbus-broker src/bus/driver.c). The manager
 * re-registers about a second later; a call sent into that window is
 * queued for activation instead, and answered with NameHasNoOwner when
 * that fails (driver_name_activation_failed, same file). In both cases
 * pctl's own connection is healthy, so the same handle can just ask
 * again.
 *
 * ServiceUnknown, third in the list below, cannot fire on this host:
 * dbus-broker returns it for a destination that is not activatable,
 * and `busctl --user list --activatable` shows org.freedesktop.systemd1
 * is. Whether a name is activatable is host configuration this code
 * does not control, so the name stays — but the reachable answer here
 * is NameHasNoOwner.
 *
 * A genuine call timeout is NOT one of these and needs no special
 * handling: pctl calls sd_bus_call_method, and the synchronous
 * sd_bus_call it lands in returns -ETIMEDOUT, which
 * sd_bus_error_set_errno resolves through errno_to_bus_error_const to
 * org.freedesktop.DBus.Error.Timeout / "Timed out" (bus-error.c). The
 * NoReply / "Method call timed out" synthesis in sd-bus.c is inside
 * process_timeout(), i.e. the ASYNC callback path, which pctl does not
 * use. Checked against systemd 260.1.
 *
 * Why the budget is elapsed time and not an attempt count: a retryable
 * attempt has no fixed cost. dbus-broker synthesises the NoReply when
 * it processes the manager's disconnect, which can land at any point
 * in a call already in flight, so one attempt costs almost nothing and
 * the next can cost most of the sd-bus timeout. N attempts therefore
 * bounds nothing. What needs bounding is how long the manager is
 * allowed to be away — ~1 s here, see [peer_gone_budget] below — and
 * elapsed time bounds that whatever each attempt cost.
 *
 * The clock is monotonic so that a CLOCK_REALTIME step inside the
 * window cannot end the retry early or extend it indefinitely. *)

(* D-Bus error names that mean the destination is not on the bus right
 * now. Matched exactly: these are wire constants, and a prefix test
 * would couple the classifier to whatever formatting the caller
 * applies afterwards.
 *
 * org.freedesktop.DBus.Error.Disconnected is deliberately absent. It
 * names OUR connection, not the peer's — errno_to_bus_error_const
 * (bus-error.c) produces it only for ECONNRESET / ECONNABORTED /
 * ENETRESET, i.e. our own socket died. Asking again on a dead handle
 * cannot succeed, and would replace a truthful "Disconnected" with
 * whatever the second attempt reports instead. *)
let peer_gone_error_names =
  [
    "org.freedesktop.DBus.Error.NoReply";
    "org.freedesktop.DBus.Error.ServiceUnknown";
    "org.freedesktop.DBus.Error.NameHasNoOwner";
  ]

(* Transport failures almost never arrive unnamed: every [fail:] path
 * in sd_bus_call_methodv (bus-convenience.c) and sd_bus_call runs
 * sd_bus_error_set_errno, and both use bus_assert_return for their
 * argument checks, which populates too. That yields
 * "System.Error.<ERRNO>" for an errno with no const mapping (ENOTCONN
 * is one) and org.freedesktop.DBus.Error.Failed when the errno has no
 * name at all. Exact matching rejects every one of those, which is the
 * answer we want.
 *
 * Two checks in sd_bus_call are plain assert_return rather than
 * bus_assert_return, so they return the errno with the error struct
 * untouched and DO yield [None]: -ENOPKG when bus_resolve rejects the
 * bus, -ENOTCONN when neither a bus nor a message-attached bus was
 * given. pctl hands every call a live sd_bus* from sd_bus_open_user,
 * so neither can fire — [None] is unreachable because of that, not
 * because sd-bus names everything. The arm answers "do not retry"
 * because an unnamed failure is not evidence the peer will return. *)
let is_peer_gone = function
  | None -> false
  | Some name -> List.mem name peer_gone_error_names

let seconds_since (start : Mtime.t) (now : Mtime.t) : float =
  Mtime.Span.to_float_ns (Mtime.span start now) /. 1e9

(* Re-run [f] while it keeps failing with a retryable error and another
 * [delay] still fits inside [budget] seconds of the first attempt.
 * Both [now] and [sleep] are injected so the policy is testable
 * without a real clock. *)
let with_retry ~(now : unit -> Mtime.t) ~(sleep : float -> unit)
    ~(budget : float) ~(delay : float) ~(retry_on : 'e -> bool)
    (f : unit -> ('a, 'e) result) : ('a, 'e) result =
  let start = now () in
  let rec go () =
    match f () with
    | Ok _ as ok -> ok
    | Error e as err ->
        if retry_on e && seconds_since start (now ()) +. delay <= budget
        then (
          sleep delay;
          go ())
        else err
  in
  go ()

(* Policy values for a peer that is expected to come back. Measured on
 * this host: `Reexecuting.` to the manager answering calls again took
 * ~1 s (user journal, 2026-07-30 22:21:26 → 22:21:27). Five seconds
 * covers that with room for a loaded machine; a quarter-second poll
 * costs at most twenty wasted round trips over the window. *)
let peer_gone_budget = 5.0
let peer_gone_delay = 0.25
