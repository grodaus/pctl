-- The manifest records ownership only: which unit filenames a project may
-- delete. Hashes moved out because they outlived the tmpfs files they
-- described, so after a reboot every unit diffed as Unchanged and nothing
-- started (pctl-468). Rebuilt rather than ALTER TABLE DROP COLUMN so it
-- does not depend on the linked SQLite version.
CREATE TABLE manifest_new (
  project_id    TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  unit_filename TEXT NOT NULL,
  PRIMARY KEY (project_id, unit_filename)
);
INSERT INTO manifest_new (project_id, unit_filename)
  SELECT project_id, unit_filename FROM manifest;
DROP TABLE manifest;
ALTER TABLE manifest_new RENAME TO manifest;
