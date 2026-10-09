{{
  config(
    materialized='table',
    engine='MergeTree',
    order_by=['object_id', 'seq'],
  )
}}

-- Copy of beefy-history current/events.parquet (RustFS). Nested config is JSON text in `data`.
-- Event `change_type` is added|changed|removed|readded. Config type is data.type (flattened below).
-- Identity is kind:chain:address (object_id), not beefy_key. Boosts are ingested when present.

SELECT
  CAST(src.seq AS Int64) AS seq,
  CAST(src.`objectId` AS String) AS object_id,
  CAST(src.kind AS String) AS kind,
  CAST(src.chain AS String) AS chain,
  CAST(src.id AS String) AS beefy_id,
  {{ evm_address('src.address') }} AS address,
  CAST(src.type AS String) AS change_type,
  CAST(src.source AS String) AS source,
  CAST(src.`commitRepo` AS String) AS commit_repo,
  CAST(src.`commitSha` AS String) AS commit_sha,
  CAST(src.`committedAt` AS Int64) AS committed_at,
  toDateTime64(src.`committedAt`, 0, 'UTC') AS committed_at_ts,
  CAST(src.`authoredAt` AS Int64) AS authored_at,
  toDateTime64(src.`authoredAt`, 0, 'UTC') AS authored_at_ts,
  CAST(src.`commitSubject` AS String) AS commit_subject,
  CAST(src.path AS Nullable(String)) AS path,
  CAST(src.data AS Nullable(String)) AS data,
  CAST(src.`dataHash` AS Nullable(String)) AS data_hash,
  CAST(src.reason AS Nullable(String)) AS reason,
  ifNull(src.`changedKeys`, emptyArrayString()) AS changed_keys,
  {{ beefy_history_json_text('src.data', 'status') }} AS status,
  {{ beefy_history_json_text('src.data', 'type') }} AS config_type,
  {{ beefy_history_json_bool('src.data', 'isGovVault') }} AS is_gov_vault,
  {{ beefy_history_json_text('src.data', 'platformId') }} AS platform_id,
  {{ beefy_history_json_text('src.data', 'tokenProviderId') }} AS token_provider_id,
  {{ beefy_history_json_text('src.data', 'retireReason') }} AS retire_reason,
  lower({{ beefy_history_json_text('src.data', 'tokenAddress') }}) AS token_address,
  lower({{ beefy_history_json_text('src.data', 'earnContractAddress') }}) AS earn_contract_address
FROM {{ beefy_history_s3_events() }} AS src
