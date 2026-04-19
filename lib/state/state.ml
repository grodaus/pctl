(* State — umbrella for the SQLite-backed state submodules.
 *
 * Callers write `State.Projects.upsert`, `State.Session.reset`, etc.
 * The pure [Manifest] diff (phase 1) stays; the SQLite
 * [Manifest_db] persists the current manifest per project. *)

module Db = Db
module Migrate = Migrate
module Meta = Meta
module Projects = Projects
module Manifest = Manifest
module Manifest_db = Manifest_db
module Session = Session
