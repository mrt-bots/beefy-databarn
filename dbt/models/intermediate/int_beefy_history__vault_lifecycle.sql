{{
  config(
    materialized='table',
    tags=['intermediate'],
    engine='MergeTree()',
    order_by=['chain_id', 'address'],
  )
}}

-- Vault lifecycle facts joined into product_config_history. Boosts stay in staging.
-- chain_id is the product/chain dimension key (null if the history chain is unknown).
-- Launch = first time in-catalog and active. Retirement = end of last active period if not active now and not paused.
-- CLM collapse: a cowcentrated vault counts once; gov/standard whose deposit token is that CLM on the same chain are wrappers.

WITH vault_events AS (
  SELECT
    object_id,
    chain,
    address,
    seq,
    committed_at_ts,
    change_type,
    status,
    config_type,
    is_gov_vault,
    platform_id,
    token_provider_id,
    retire_reason,
    token_address,
    change_type != 'removed' AND (status IS NULL OR status = 'active') AS is_active
  FROM {{ ref('stg_beefy_history__events') }}
  WHERE kind = 'vault'
),

last_active AS (
  SELECT
    object_id,
    max(if(is_active, seq, NULL)) AS last_active_seq
  FROM vault_events
  GROUP BY object_id
),

last_active_end AS (
  SELECT
    e.object_id,
    min(e.committed_at_ts) AS last_active_end_at
  FROM vault_events e
  INNER JOIN last_active a
    ON e.object_id = a.object_id
    AND a.last_active_seq IS NOT NULL
    AND e.seq > a.last_active_seq
  GROUP BY e.object_id
),

per_vault AS (
  SELECT
    e.object_id,
    argMax(e.chain, e.seq) AS chain,
    argMax(e.address, e.seq) AS address,
    argMax(e.status, e.seq) AS latest_event_status,
    argMaxIf(e.status, e.seq, e.change_type != 'removed') AS status,
    argMaxIf(e.config_type, e.seq, e.change_type != 'removed') AS config_type,
    argMaxIf(e.is_gov_vault, e.seq, e.change_type != 'removed') AS is_gov_vault,
    argMaxIf(e.platform_id, e.seq, e.change_type != 'removed') AS platform_id,
    argMaxIf(e.token_provider_id, e.seq, e.change_type != 'removed') AS token_provider_id,
    argMaxIf(e.retire_reason, e.seq, e.change_type != 'removed') AS retire_reason,
    argMaxIf(e.token_address, e.seq, e.change_type != 'removed') AS token_address,
    argMax(e.change_type, e.seq) AS last_change_type,
    min(if(e.is_active, e.committed_at_ts, NULL)) AS first_active_at,
    max(if(e.is_active, e.seq, NULL)) AS last_active_seq
  FROM vault_events e
  GROUP BY e.object_id
),

typed AS (
  SELECT
    p.*,
    {{ beefy_history_vault_type('p.config_type', 'ifNull(p.is_gov_vault, false)') }} AS vault_type,
    p.last_change_type != 'removed' AS in_catalog,
    e.last_active_end_at AS last_active_end_at
  FROM per_vault p
  LEFT JOIN last_active_end e
    ON p.object_id = e.object_id
),

clms AS (
  SELECT
    chain,
    address AS clm_address
  FROM typed
  WHERE vault_type = 'cowcentrated'
),

lifecycle AS (
  SELECT
    t.object_id,
    ck.chain_id,
    t.chain,
    t.address,
    t.in_catalog,
    t.status AS observed_status,
    t.vault_type,
    if(t.vault_type = 'cowcentrated', t.token_provider_id, t.platform_id) AS platform,
    t.platform_id,
    t.token_provider_id,
    t.token_address,
    t.retire_reason,
    t.first_active_at,
    t.last_active_end_at,
    t.status = 'paused' AND t.in_catalog AS is_paused,
    t.last_active_end_at IS NOT NULL
      AND (t.latest_event_status IS NULL OR t.latest_event_status != 'paused') AS is_retired,
    c.clm_address AS clm_parent_address,
    c.clm_address IS NOT NULL AS is_clm_wrapper,
    t.first_active_at IS NOT NULL AND c.clm_address IS NULL AS counts_for_stats
  FROM typed t
  LEFT JOIN clms c
    ON t.vault_type IN ('gov', 'standard')
    AND t.chain = c.chain
    AND t.token_address = c.clm_address
  LEFT JOIN {{ ref('int_chain_keys') }} ck
    ON {{ normalize_network_beefy_key('t.chain') }} = ck.beefy_key
)

SELECT
  object_id,
  chain_id,
  chain,
  address,
  in_catalog,
  observed_status,
  vault_type,
  platform,
  platform_id,
  token_provider_id,
  token_address,
  retire_reason,
  {{ beefy_history_retire_reason_group('retire_reason') }} AS retire_reason_group,
  first_active_at,
  last_active_end_at,
  is_paused,
  is_retired,
  clm_parent_address,
  is_clm_wrapper,
  counts_for_stats,
  if(
    first_active_at IS NULL,
    NULL,
    concat(toString(toYear(first_active_at)), '-Q', toString(toQuarter(first_active_at)))
  ) AS launch_quarter,
  if(
    NOT is_retired OR last_active_end_at IS NULL,
    NULL,
    concat(toString(toYear(last_active_end_at)), '-Q', toString(toQuarter(last_active_end_at)))
  ) AS retirement_quarter,
  if(
    is_retired AND first_active_at IS NOT NULL AND last_active_end_at IS NOT NULL,
    toUInt32(
      intDiv(
        toUnixTimestamp(last_active_end_at) - toUnixTimestamp(first_active_at),
        {{ beefy_history_month_seconds() }}
      )
    ),
    NULL
  ) AS lifespan_months
FROM lifecycle
