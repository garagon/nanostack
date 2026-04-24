-- 0002: add observational_fired column
-- Added for /think observational feedback firing-rate measurement.
-- Nullable because only /think ever sets it; other skills leave it null.
-- Integer 0/1 instead of boolean because D1/SQLite prefers the idiom and
-- CHECK constraints read cleanly.

ALTER TABLE events ADD COLUMN observational_fired INTEGER
  CHECK (observational_fired IS NULL OR observational_fired IN (0, 1));

CREATE INDEX IF NOT EXISTS idx_events_observational
  ON events (observational_fired)
  WHERE observational_fired IS NOT NULL;
