#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
temp_db="$(mktemp -t agentty-analytics-report.XXXXXX.sqlite3)"
trap 'rm -f "$temp_db"' EXIT

sqlite3 "$temp_db" <<'SQL'
CREATE TABLE analytics_blocked_user_candidates (
  user_key_hash TEXT NOT NULL,
  signature_key TEXT NOT NULL,
  issue_kind TEXT NOT NULL,
  issue_severity TEXT NOT NULL,
  summary TEXT NOT NULL,
  first_seen_at_epoch_seconds INTEGER NOT NULL,
  last_seen_at_epoch_seconds INTEGER NOT NULL,
  occurrence_count INTEGER NOT NULL
);

CREATE TABLE analytics_recent_issue_alerts (
  signature_key TEXT NOT NULL,
  user_key_hash TEXT NOT NULL,
  issue_kind TEXT NOT NULL,
  issue_severity TEXT NOT NULL,
  summary TEXT NOT NULL,
  first_seen_at_epoch_seconds INTEGER NOT NULL,
  last_seen_at_epoch_seconds INTEGER NOT NULL,
  first_alerted_at_epoch_seconds INTEGER,
  last_alerted_at_epoch_seconds INTEGER,
  alert_count INTEGER NOT NULL
);

CREATE TABLE analytics_alert_digest_queue (
  digest_date TEXT NOT NULL,
  issue_kind TEXT NOT NULL,
  issue_severity TEXT NOT NULL,
  affected_user_count INTEGER NOT NULL,
  total_occurrence_count INTEGER NOT NULL,
  first_seen_at_epoch_seconds INTEGER NOT NULL,
  last_seen_at_epoch_seconds INTEGER NOT NULL
);

INSERT INTO analytics_blocked_user_candidates VALUES
  ('user-hash-1', 'sig-1', 'automatic_reachability_failure_after_pairing', 'blocked', 'Automatic pairing completed, but every follow-up reachability probe failed.', 1715200000, 1715200300, 2);

INSERT INTO analytics_recent_issue_alerts VALUES
  ('sig-1', 'user-hash-1', 'automatic_reachability_failure_after_pairing', 'blocked', 'Automatic pairing completed, but every follow-up reachability probe failed.', 1715200000, 1715200300, 1715200310, 1715200310, 1);

INSERT INTO analytics_alert_digest_queue VALUES
  ('2026-04-10', 'automatic_reachability_failure_after_pairing', 'blocked', 1, 2, 1715200000, 1715200300);
SQL

output="$("$repo_root/services/backend/scripts/analytics-report" "$temp_db")"

printf '%s\n' "$output" | rg "Active External Blockers" >/dev/null
printf '%s\n' "$output" | rg "automatic_reachability_failure_after_pairing" >/dev/null
