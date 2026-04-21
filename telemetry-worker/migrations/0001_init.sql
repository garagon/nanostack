-- nanostack telemetry D1 schema v1
-- Fields match TELEMETRY_FIELDS_V1 from bin/lib/telemetry.sh.
-- No raw IPs, no hostnames, no paths, no content. CI enforces that the
-- client never sends anything outside this schema, and this DDL enforces
-- it at storage time via column whitelist + CHECK constraints.

CREATE TABLE IF NOT EXISTS events (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  received_at     TEXT    NOT NULL DEFAULT (datetime('now')),
  event_ts        TEXT    NOT NULL,
  skill           TEXT    NOT NULL,
  outcome         TEXT    NOT NULL CHECK (outcome IN ('success','error','abort','unknown')),
  duration_s      INTEGER,
  nanostack_version TEXT,
  os              TEXT    CHECK (os IS NULL OR os IN ('darwin','linux','unknown')),
  arch            TEXT    CHECK (arch IS NULL OR arch IN ('x86_64','arm64','unknown')),
  installation_id TEXT,
  session_id      TEXT,
  error_class     TEXT
);

CREATE INDEX IF NOT EXISTS idx_events_skill     ON events (skill);
CREATE INDEX IF NOT EXISTS idx_events_received  ON events (received_at);
CREATE INDEX IF NOT EXISTS idx_events_install   ON events (installation_id) WHERE installation_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_events_errors    ON events (error_class) WHERE outcome = 'error';
