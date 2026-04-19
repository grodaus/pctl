(* Paths — where pctl writes on disk.
 *
 * Oracle: the prior Nushell unit-paths layer. `user.control` is under
 * $XDG_RUNTIME_DIR/systemd/user.control (NOT ~/.config/systemd/user.control
 * despite what the Phase 4 task brief said — the Nushell implementation
 * uses XDG_RUNTIME_DIR and the e2e tests assert that). XDG_RUNTIME_DIR
 * must be set; we raise the same "not set" error as the prior Nushell
 * `require-runtime-dir` helper.
 *
 * Unit filename substitution:
 *   The Nushell install module did `str replace -a '@@PROJECT@@' $project.id`
 *   against the *basename* only. We mirror that: we never substitute
 *   @@PROJECT_PATH@@ in filenames (slice/service filenames never embed
 *   a filesystem path), only @@PROJECT@@ -> project_id. *)

let user_control : string =
  match Sys.getenv_opt "XDG_RUNTIME_DIR" with
  | None | Some "" ->
      raise
        (Schema.Pctl_error
           (Schema.Install_failed
              {
                path = "XDG_RUNTIME_DIR";
                reason =
                  "XDG_RUNTIME_DIR is not set (requires Linux + systemd \
                   --user)";
              }))
  | Some rt -> Filename.concat rt (Filename.concat "systemd" "user.control")

let substitute_id ~(id : Schema.project_id) (basename : string) : string =
  (* Matches Render.substitute's rule for @@PROJECT@@ only; filenames never
   * contain @@PROJECT_PATH@@ (it would be a nonsense directive in a unit
   * filename). *)
  Render.replace_all ~needle:"@@PROJECT@@"
    ~replacement:(Schema.Project_id.to_string id)
    basename

let slice_path ~(id : Schema.project_id) ~(unit_filename : string) : string =
  Filename.concat user_control (substitute_id ~id unit_filename)

let service_path ~(id : Schema.project_id) ~(unit_filename : string) : string =
  Filename.concat user_control (substitute_id ~id unit_filename)

let dropin_dir ~(id : Schema.project_id) ~(unit_filename : string) : string =
  (substitute_id ~id unit_filename |> Filename.concat user_control) ^ ".d"

let dropin_file ~(id : Schema.project_id) ~(unit_filename : string) : string =
  Filename.concat (dropin_dir ~id ~unit_filename) "pctl-runtime.conf"
