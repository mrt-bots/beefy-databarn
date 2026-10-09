{#
  beefy-history parquet on RustFS.

  ClickHouse reads current/ via named collections (infra/clickhouse/config.d/60-beefy-history-s3.xml).
  dbt copies those files into MergeTree tables — never query s3() from marts, never DuckDB.

  Schema surprises (CLI store):
  - `data` is canonical JSON text, not a nested parquet struct.
  - `type` on the event is added|changed|removed|readded. Config type lives in data.type.
  - `objects` / `latest` are DuckDB views, not files.
#}

{% macro beefy_history_s3_events() %}
    s3(beefy_history_s3_events)
{%- endmacro %}

{% macro beefy_history_s3_issues() %}
    s3(beefy_history_s3_issues)
{%- endmacro %}

{# Missing / JSON null / empty string → NULL (empty counts as active downstream). Non-strings as raw JSON text. #}
{% macro beefy_history_json_text(data_expr, key) %}
    if(
        {{ data_expr }} IS NULL
        OR JSONHas({{ data_expr }}, '{{ key }}') = 0
        OR JSONType({{ data_expr }}, '{{ key }}') = 'Null',
        NULL,
        if(
            JSONType({{ data_expr }}, '{{ key }}') = 'String',
            nullIf(JSONExtractString({{ data_expr }}, '{{ key }}'), ''),
            JSONExtractRaw({{ data_expr }}, '{{ key }}')
        )
    )
{%- endmacro %}

{% macro beefy_history_json_bool(data_expr, key) %}
    if(
        {{ data_expr }} IS NULL
        OR JSONHas({{ data_expr }}, '{{ key }}') = 0
        OR JSONType({{ data_expr }}, '{{ key }}') = 'Null',
        false,
        JSONExtract({{ data_expr }}, '{{ key }}', 'Bool')
    )
{%- endmacro %}

{# standard | gov | cowcentrated | erc4626. Fallback: isGovVault → gov, else standard. #}
{% macro beefy_history_vault_type(config_type_expr, is_gov_vault_expr) %}
    coalesce(
        nullIf({{ config_type_expr }}, ''),
        if({{ is_gov_vault_expr }}, 'gov', 'standard')
    )
{%- endmacro %}

{% macro beefy_history_json_string_array(data_expr, key) %}
    if(
        {{ data_expr }} IS NULL
        OR JSONHas({{ data_expr }}, '{{ key }}') = 0
        OR JSONType({{ data_expr }}, '{{ key }}') != 'Array',
        emptyArrayString(),
        JSONExtract({{ data_expr }}, '{{ key }}', 'Array(String)')
    )
{%- endmacro %}

{# Config layer from the snapshot path (mirrors beefy-history packages/queries/src/layer.ts). #}
{% macro beefy_history_config_layer(path_expr) %}
    multiIf(
        {{ path_expr }} IS NULL, NULL,
        match({{ path_expr }}, '^src/config/promos/chain/[^/]+\\.json$'), 'promos',
        match({{ path_expr }}, '^src/config/boost/[^/]+\\.(js|tsx|json)$'), 'boost',
        match({{ path_expr }}, '^src/features/configure/(stake\\.js|stake/[^/]+_stake\\.js)$'), 'stake',
        match({{ path_expr }}, '^src/config/(vault/[^/]+\\.(js|tsx|json)|pools/[^/]+\\.js)$'), 'vault',
        match({{ path_expr }}, '^src/features/configure/(pools\\.js|(vault/)?[^/]+_pools\\.js)$'), 'vault',
        NULL
    )
{%- endmacro %}

{# Groups of beefy-v2 retireReason values, same as history.beefy.rodeo/stats. #}
{% macro beefy_history_retire_reason_group(reason_expr) %}
    multiIf(
        {{ reason_expr }} IS NULL OR {{ reason_expr }} = '', 'none',
        lower({{ reason_expr }}) IN ('rewards'), 'rewards',
        lower({{ reason_expr }}) IN ('tvl'), 'tvl',
        lower({{ reason_expr }}) IN (
            'upgrade', 'replaced', 'bifiv2', 'bevelo', 'beta', 'aerodromemigration26'
        ), 'upgrade',
        lower({{ reason_expr }}) IN (
            'exploit', 'exploitnopanic', 'liquiditypanic', 'liquiditynopanic',
            'stream2025', 'balancer2025', 'scream'
        ), 'incident',
        'other'
    )
{%- endmacro %}

{# 30.4375-day months, same as packages/queries/src/stats.ts MONTH. #}
{% macro beefy_history_month_seconds() %}2629800{%- endmacro %}
