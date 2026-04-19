-- Stores the full spec.json blob used by `pctl up` so `pctl results`
-- can re-derive the service/probe shape without re-reading store_tree
-- (which may have been garbage-collected in the nix store). Before
-- this column existed, Results synthesised a minimal spec from the
-- manifest — that path is gone in v2.
ALTER TABLE projects ADD COLUMN spec_json TEXT;
