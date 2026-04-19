(* pctl internal schema.
 *
 * Every boundary (CLI args, Nix↔OCaml contract, SQLite rows, rendered unit
 * bytes) flows through one of the ADTs below. See
 * docs/src/plans/20260419-ocaml-rewrite.md § "Internal schema" for the
 * authoritative definition.
 *
 * StringMap: plain stdlib `Map.Make(String)`. No external dep; ordering by
 * string key is what we want for deterministic rendering. *)

module StringMap = Map.Make (String)

(* ------------------------------------------------------------------ *)
(* Core variants                                                       *)
(* ------------------------------------------------------------------ *)

type action = Added | Changed | Unchanged | Removed

type state =
  | Active
  | Inactive
  | Failed
  | Activating
  | Deactivating
  | Reloading

type kind = Simple | Oneshot | Forking | Notify | Dbus | Idle

type class_ = Live | Orphan | Unknown

let action_to_symbol = function
  | Added -> "+"
  | Changed -> "~"
  | Unchanged -> "="
  | Removed -> "-"

let action_to_string = function
  | Added -> "added"
  | Changed -> "changed"
  | Unchanged -> "unchanged"
  | Removed -> "removed"

let state_to_string = function
  | Active -> "active"
  | Inactive -> "inactive"
  | Failed -> "failed"
  | Activating -> "activating"
  | Deactivating -> "deactivating"
  | Reloading -> "reloading"

let state_of_string = function
  | "active" -> Some Active
  | "inactive" -> Some Inactive
  | "failed" -> Some Failed
  | "activating" -> Some Activating
  | "deactivating" -> Some Deactivating
  | "reloading" -> Some Reloading
  | _ -> None

let kind_to_string = function
  | Simple -> "simple"
  | Oneshot -> "oneshot"
  | Forking -> "forking"
  | Notify -> "notify"
  | Dbus -> "dbus"
  | Idle -> "idle"

let kind_of_string = function
  | "simple" -> Some Simple
  | "oneshot" -> Some Oneshot
  | "forking" -> Some Forking
  | "notify" -> Some Notify
  | "dbus" -> Some Dbus
  | "idle" -> Some Idle
  | _ -> None

let class_to_string = function
  | Live -> "live"
  | Orphan -> "orphan"
  | Unknown -> "unknown"

(* ------------------------------------------------------------------ *)
(* Opaque domain types (smart ctors)                                   *)
(* ------------------------------------------------------------------ *)

(* Errors need to be declared before the smart ctors can raise them, but the
 * error variant refers to no opaque types so ordering is fine. *)

type error =
  | Spec_not_found of { path : string }
  | Spec_parse of { path : string; msg : string }
  | Spec_unknown_version of int
  | Nix_build_failed of { expr : string; exit_code : int; stderr : string }
  | Install_failed of { path : string; reason : string }
  | Bus_connect_failed of { msg : string }
  | Unit_op_failed of { op : string; unit_ : string; reply : string }
  | Probe_exec_failed of { service : string; msg : string }
  | Probe_timeout of { service : string; timeout_ms : int }
  | Identity_invalid of { path : string; reason : string }
  | Registry_io of { id : string; reason : string }
  | Journalctl_failed of { unit_ : string; exit_code : int }

exception Pctl_error of error

(* ---- project_id ------------------------------------------------------- *)

module Project_id : sig
  type t = private string

  val of_string_exn : string -> t
  val of_string_opt : string -> t option
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end = struct
  type t = string

  let is_printable_ascii c =
    let code = Char.code c in
    code >= 0x21 && code <= 0x7e

  let validate s =
    if String.length s = 0 then Error "empty project id"
    else if String.contains s '/' then Error "project id contains '/'"
    else
      let rec loop i =
        if i = String.length s then Ok ()
        else if not (is_printable_ascii s.[i]) then
          Error
            (Printf.sprintf "non-printable-ASCII byte 0x%02x at index %d"
               (Char.code s.[i]) i)
        else loop (i + 1)
      in
      loop 0

  let of_string_exn s =
    match validate s with
    | Ok () -> s
    | Error reason -> raise (Pctl_error (Identity_invalid { path = s; reason }))

  let of_string_opt s =
    match validate s with Ok () -> Some s | Error _ -> None

  let to_string s = s
  let equal = String.equal
  let compare = String.compare
end

type project_id = Project_id.t

(* ---- host (127.0.0.N) ------------------------------------------------- *)

module Host : sig
  type t = private string

  val of_string_exn : string -> t
  val of_string_opt : string -> t option
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end = struct
  type t = string

  (* Nushell's allocate-host walks 2..254 inclusive (first_byte mod 253 + 2
   * → 2..254). 127.0.0.0 is reserved, 127.0.0.1 is the system loopback,
   * 127.0.0.255 is the loopback broadcast. Smart ctor matches that range. *)
  let parse s =
    let prefix = "127.0.0." in
    let plen = String.length prefix in
    if String.length s <= plen then Error "host missing 127.0.0. prefix"
    else if not (String.sub s 0 plen = prefix) then
      Error "host missing 127.0.0. prefix"
    else
      let tail = String.sub s plen (String.length s - plen) in
      match int_of_string_opt tail with
      | None -> Error (Printf.sprintf "host last octet '%s' is not an int" tail)
      | Some n when n < 2 || n > 254 ->
          Error (Printf.sprintf "host last octet %d outside 2..254" n)
      | Some _ -> Ok s

  let of_string_exn s =
    match parse s with
    | Ok s -> s
    | Error reason ->
        raise (Pctl_error (Identity_invalid { path = s; reason }))

  let of_string_opt s = match parse s with Ok s -> Some s | Error _ -> None
  let to_string s = s
  let equal = String.equal
  let compare = String.compare
end

type host = Host.t

(* ------------------------------------------------------------------ *)
(* Records                                                             *)
(* ------------------------------------------------------------------ *)

(* manifest — keyed by raw unit_filename string (may still contain
 * @@PROJECT@@ placeholders; substitution happens at install time). *)
type manifest = (string * string) list

type plan_row = {
  unit_ : string;
  action : action;
  old_hash : string option;
  new_hash : string option;
}

type probe = {
  exec : string list;
  period_seconds : int;
  timeout_seconds : int;
}

type workspace_spec = { cwd : bool; writable : bool }

type service_spec = {
  name : string;
  kind : kind;
  depends_on : string list;
  workspace : workspace_spec;
  probe : probe option;
  unit_filename : string;
  service_config : (string * string) list;
}

type slice_spec = {
  unit_filename : string;
  slice_config : (string * string) list;
}

type spec = {
  version : int;
  slice : slice_spec;
  services : service_spec StringMap.t;
}

(* result_row wire format — parsed by tuor's
 * scripts/collect-pctl-artifacts.nu, which only accesses fields by name
 * (never compares state/kind to specific strings). We emit snake_case
 * bare strings for both polymorphic-variant fields via explicit
 * [@to_yojson]/[@of_yojson] attributes; plain [@@deriving yojson] on a
 * polymorphic variant emits a JSON list (e.g. ["Probe_failed"]), which
 * is not what we want on the wire. *)

type result_state =
  [ `Active | `Failed | `Inactive | `Probe_failed | `Timed_out ]

type result_kind = [ `Probe | `Unit_state ]

let result_state_to_string = function
  | `Active -> "active"
  | `Failed -> "failed"
  | `Inactive -> "inactive"
  | `Probe_failed -> "probe_failed"
  | `Timed_out -> "timed_out"

let result_state_of_string = function
  | "active" -> Some `Active
  | "failed" -> Some `Failed
  | "inactive" -> Some `Inactive
  | "probe_failed" -> Some `Probe_failed
  | "timed_out" -> Some `Timed_out
  | _ -> None

let result_kind_to_string = function
  | `Probe -> "probe"
  | `Unit_state -> "unit_state"

let result_kind_of_string = function
  | "probe" -> Some `Probe
  | "unit_state" -> Some `Unit_state
  | _ -> None

let result_state_to_yojson s : Yojson.Safe.t =
  `String (result_state_to_string s)

let result_state_of_yojson = function
  | `String s -> (
      match result_state_of_string s with
      | Some v -> Ok v
      | None -> Error (Printf.sprintf "result_row.state: unknown '%s'" s))
  | _ -> Error "result_row.state: not a string"

let result_kind_to_yojson k : Yojson.Safe.t =
  `String (result_kind_to_string k)

let result_kind_of_yojson = function
  | `String s -> (
      match result_kind_of_string s with
      | Some v -> Ok v
      | None -> Error (Printf.sprintf "result_row.kind: unknown '%s'" s))
  | _ -> Error "result_row.kind: not a string"

type result_row = {
  name : string;
  state : result_state;
      [@to_yojson result_state_to_yojson] [@of_yojson result_state_of_yojson]
  elapsed : int64; (* nanoseconds *)
  kind : result_kind;
      [@to_yojson result_kind_to_yojson] [@of_yojson result_kind_of_yojson]
}
[@@deriving yojson]

(* ------------------------------------------------------------------ *)
(* Errors                                                              *)
(* ------------------------------------------------------------------ *)

let render_error = function
  | Spec_not_found { path } -> Printf.sprintf "spec not found: %s" path
  | Spec_parse { path; msg } ->
      Printf.sprintf "spec parse error (%s): %s" path msg
  | Spec_unknown_version v ->
      Printf.sprintf "spec version %d is not supported by this pctl" v
  | Nix_build_failed { expr; exit_code; stderr } ->
      Printf.sprintf "nix build '%s' failed with exit %d:\n%s" expr exit_code
        stderr
  | Install_failed { path; reason } ->
      Printf.sprintf "install failed for %s: %s" path reason
  | Bus_connect_failed { msg } ->
      Printf.sprintf "sd-bus connect failed: %s" msg
  | Unit_op_failed { op; unit_; reply } ->
      Printf.sprintf "systemctl %s %s failed: %s" op unit_ reply
  | Probe_exec_failed { service; msg } ->
      Printf.sprintf "probe for service %s failed to exec: %s" service msg
  | Probe_timeout { service; timeout_ms } ->
      Printf.sprintf "probe for service %s timed out after %d ms" service
        timeout_ms
  | Identity_invalid { path; reason } ->
      Printf.sprintf "invalid identity for '%s': %s" path reason
  | Registry_io { id; reason } ->
      Printf.sprintf "registry I/O failure for project %s: %s" id reason
  | Journalctl_failed { unit_; exit_code } ->
      Printf.sprintf "journalctl -u %s exited %d" unit_ exit_code

(* Exit-code mapping (stable across pctl releases, comment must stay in
 * sync with man page / release notes once those exist):
 *
 *   2 — spec problems     (spec not found, parse, unknown version, invalid id)
 *   3 — nix build failure
 *   4 — install / registry I/O
 *   5 — dbus connect / unit op
 *   6 — probe failures (exec or timeout)
 *
 * Identity_invalid is input validation, not I/O — it belongs in the spec
 * bucket (2), not I/O (4). *)
let error_exit_code = function
  | Spec_not_found _ | Spec_parse _ | Spec_unknown_version _
  | Identity_invalid _ ->
      2
  | Nix_build_failed _ -> 3
  | Install_failed _ | Registry_io _ -> 4
  | Bus_connect_failed _ | Unit_op_failed _ -> 5
  | Probe_exec_failed _ | Probe_timeout _ -> 6
  (* Journalctl's own exit code bubbles up — we don't override it with
   * a bucket. Use 0 here so [error_exit_code] is total; [Logs.run]
   * short-circuits and calls [exit] with the journalctl exit code
   * directly instead of going through [run_with_errors]. *)
  | Journalctl_failed { exit_code; _ } -> exit_code
