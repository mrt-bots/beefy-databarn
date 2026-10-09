{{
  config(
    materialized='table',
    engine='MergeTree',
    order_by=['seq'],
  )
}}

-- Copy of beefy-history current/issues.parquet. Parse errors, duplicates, invalid addresses, etc.

SELECT
  CAST(src.seq AS Int64) AS seq,
  CAST(src.type AS String) AS issue_type,
  CAST(src.repo AS String) AS repo,
  CAST(src.`commitSha` AS String) AS commit_sha,
  CAST(src.`committedAt` AS Int64) AS committed_at,
  toDateTime64(src.`committedAt`, 0, 'UTC') AS committed_at_ts,
  CAST(src.path AS Nullable(String)) AS path,
  CAST(src.kind AS Nullable(String)) AS kind,
  CAST(src.chain AS Nullable(String)) AS chain,
  CAST(src.id AS Nullable(String)) AS beefy_id,
  CAST(src.message AS String) AS message,
  CAST(src.details AS Nullable(String)) AS details
FROM {{ beefy_history_s3_issues() }} AS src
