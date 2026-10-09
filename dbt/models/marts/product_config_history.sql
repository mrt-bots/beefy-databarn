{{
  config(
    materialized='table',
    engine='MergeTree',
    tags=['marts', 'beefy_history'],
    order_by=['chain_id', 'product_address', 'seq'],
  )
}}

-- Catalog change facts. Grain is seq. Join chain / product / platform / token on the FK columns;
-- do not keep a parallel objects mart. product_type is null when the contract is not in `product`
-- (API-dropped / history-only). Current snapshot: valid_to_unix IS NULL.

SELECT
  e.seq,
  e.object_id,
  e.kind,
  ck.chain_id,
  e.chain AS chain_beefy_key,
  e.address AS product_address,
  p.product_type,
  e.beefy_id,
  e.change_type,
  e.reason,
  e.source,
  e.commit_repo,
  e.commit_sha,
  e.committed_at,
  e.committed_at_ts,
  e.authored_at,
  e.authored_at_ts,
  e.commit_subject,
  concat('https://github.com/beefyfinance/', e.commit_repo, '/commit/', e.commit_sha) AS commit_url,
  if(
    e.path IS NULL OR e.source != e.commit_repo,
    NULL,
    concat('https://github.com/beefyfinance/', e.commit_repo, '/blob/', e.commit_sha, '/', e.path)
  ) AS file_url,
  e.path,
  {{ beefy_history_config_layer('e.path') }} AS config_layer,
  e.changed_keys,
  e.status,
  w.vault_type,
  e.platform_id,
  l.platform AS stats_platform,
  e.token_address AS token_representation_address,
  e.retire_reason,
  {{ beefy_history_retire_reason_group('coalesce(l.retire_reason, e.retire_reason)') }} AS retire_reason_group,
  w.in_catalog,
  w.is_active,
  e.committed_at AS valid_from_unix,
  w.valid_from,
  w.valid_to_unix,
  w.valid_to,
  l.counts_for_stats,
  l.is_clm_wrapper,
  l.clm_parent_address,
  l.is_retired,
  l.is_paused,
  l.first_active_at,
  l.last_active_end_at,
  l.launch_quarter,
  l.retirement_quarter,
  l.lifespan_months,
  if(
    e.change_type = 'changed',
    anyLastIf(e.data, e.data IS NOT NULL) OVER (
      PARTITION BY e.object_id
      ORDER BY e.seq
      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    ),
    NULL
  ) AS prev_data,
  e.data
FROM {{ ref('stg_beefy_history__events') }} e
LEFT JOIN {{ ref('int_chain_keys') }} ck
  ON {{ normalize_network_beefy_key('e.chain') }} = ck.beefy_key
LEFT JOIN {{ ref('product') }} p
  ON ck.chain_id = p.chain_id
  AND e.address = p.product_address
LEFT JOIN {{ ref('int_beefy_history__event_windows') }} w
  ON e.object_id = w.object_id
  AND e.seq = w.seq
LEFT JOIN {{ ref('int_beefy_history__vault_lifecycle') }} l
  ON e.object_id = l.object_id
