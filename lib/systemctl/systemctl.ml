(* Systemctl — umbrella module.
 *
 * Exposes the SYSTEMCTL signature and both implementations (In_mem
 * fake + Dbus binding). Callers pick which to use at [connect] time;
 * the CLI wires up [Dbus] in production, tests wire [In_mem].
 *
 * The [Dbus] module is included here but its FFI table is loaded
 * lazily — see lib/systemctl/dbus.ml. Importing [Systemctl] does NOT
 * dlopen libsystemd, so unit tests (which never open a real bus) can
 * link against this library without libsystemd.so on the loader
 * path. *)
module type S = Systemctl_intf.SYSTEMCTL

module In_mem = In_mem
module Dbus = Dbus

(* Retry policy for bus calls whose peer went away mid-call. Exposed
 * because it is pure and unit-tested on its own; [Dbus] is its only
 * production caller. *)
module Bus_retry = Bus_retry
