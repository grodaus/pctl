(* Bus_retry — how long to keep re-issuing a call whose peer went away.
 * WHICH failures mean that is [Bus_errors.is_peer_gone]'s job.
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
 * ServiceUnknown, one of [Bus_errors.peer_gone_error_names], cannot fire
 * on this host:
 * dbus-broker returns it for a destination that is not activatable,
 * and `busctl --user list --activatable` shows org.freedesktop.systemd1
 * is. Whether a name is activatable is host configuration this code
 * does not control, so the name stays — but the reachable answer here
 * is NameHasNoOwner.
 *
 * A genuine call timeout is NOT one of these and needs no special
 * handling: pctl calls sd_bus_call_method, and the synchronous
 * sd_bus_call it lands in returns -ETIMEDOUT, which arrives named
 * org.freedesktop.DBus.Error.Timeout / "Timed out" (errno_to_bus_error_const,
 * bus-error.c — see [Bus_errors] for that naming path). The NoReply /
 * "Method call timed out" synthesis in sd-bus.c is inside
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
