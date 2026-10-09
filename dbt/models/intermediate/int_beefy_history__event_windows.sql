{{
  config(
    materialized='table',
    tags=['intermediate'],
    engine='MergeTree()',
    order_by=['object_id', 'seq'],
  )
}}

-- Catalog membership and observed status from this event until the next one (valid_to null = still current).
-- in_catalog: not removed. is_active: in catalog and status is missing/empty/active (empty counts as active).

SELECT
  object_id,
  kind,
  chain,
  address,
  seq,
  change_type,
  committed_at,
  committed_at_ts AS valid_from,
  anyOrNull(committed_at) OVER (
    PARTITION BY object_id
    ORDER BY seq
    ROWS BETWEEN 1 FOLLOWING AND 1 FOLLOWING
  ) AS valid_to_unix,
  anyOrNull(committed_at_ts) OVER (
    PARTITION BY object_id
    ORDER BY seq
    ROWS BETWEEN 1 FOLLOWING AND 1 FOLLOWING
  ) AS valid_to,
  change_type != 'removed' AS in_catalog,
  status,
  change_type != 'removed' AND (status IS NULL OR status = 'active') AS is_active,
  config_type,
  is_gov_vault,
  {{ beefy_history_vault_type('config_type', 'is_gov_vault') }} AS vault_type,
  platform_id,
  token_provider_id,
  retire_reason,
  token_address,
  earn_contract_address
FROM {{ ref('stg_beefy_history__events') }}
