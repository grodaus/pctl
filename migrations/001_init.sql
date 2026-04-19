CREATE TABLE projects (
  id           TEXT PRIMARY KEY,
  path         TEXT NOT NULL,
  host         TEXT,
  started_at   TEXT,
  store_tree   TEXT,
  session_id   TEXT
);

CREATE INDEX idx_projects_session ON projects(session_id);

CREATE TABLE manifest (
  project_id    TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  unit_filename TEXT NOT NULL,
  sha256        TEXT NOT NULL,
  PRIMARY KEY (project_id, unit_filename)
);

CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT INTO meta (key, value) VALUES ('schema_version', '1'), ('last_boot_id', '');
