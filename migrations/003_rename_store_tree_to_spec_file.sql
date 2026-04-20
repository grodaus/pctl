-- Rename the `store_tree` column to `spec_file` to match what it
-- actually stores: the path to a spec.json file. `mkProject` uses
-- `pkgs.writeText`, so the nix build outpath IS the spec.json file —
-- not a directory tree. The old name predated that realization.
ALTER TABLE projects RENAME COLUMN store_tree TO spec_file;
