-- Worklist for the archived-uses sweep. The request path enqueues each
-- external `uses:` repo (bare `owner/repo`, lowercased) it sees; the daily
-- cron drains the table, checks each repo's archived status against the GitHub
-- API, and clears it. The primary key dedups repeated refs within a cycle.
CREATE TABLE IF NOT EXISTS pending (
  repo TEXT PRIMARY KEY
);
