#!/bin/bash
set -euo pipefail

# Validate password: must not contain backticks to avoid unescape issues
validate_password() {
  local var_name="$1"
  local var_value="${!var_name:-}"
  
  if [[ -z "$var_value" ]]; then
    echo "Error: Environment variable $var_name is not set" >&2
    exit 1
  fi
  
  if [[ "$var_value" == *"'"* ]]; then
    echo "Error: Environment variable $var_name contains a tick (single quote), which is not allowed" >&2
    exit 1
  fi
  
  if [[ "$var_value" == *"\`"* ]]; then
    echo "Error: Environment variable $var_name contains a backtick, which is not allowed" >&2
    exit 1
  fi
}

# Validate IP config: must be either "ANY" or "IP '<cidr>'"
validate_ip_config() {
  local var_name="$1"
  local var_value="${!var_name:-}"
  
  if [[ -z "$var_value" ]]; then
    echo "Error: Environment variable $var_name is not set" >&2
    exit 1
  fi
  
  if [[ "$var_value" == "ANY" ]]; then
    return 0
  fi
  
  # Match pattern: IP '...' where ... can contain any characters except single quotes
  # Accept: IP '<cidr>' (single quotes only, without double quotes)
  if [[ "$var_value" =~ ^IP\ \'[^\'\"]+\'$ ]]; then
    return 0
  fi
  
  echo "Error: Environment variable $var_name must be either 'ANY' or 'IP '<cidr>'' (got: $var_value)" >&2
  exit 1
}

# Validate all environment variables
echo "Validating environment variables..."
validate_password CLICKHOUSE_PASSWORD

validate_password DLT_CLICKHOUSE_PASSWORD
validate_ip_config DLT_CLICKHOUSE_ALLOWED_HOST

validate_password DBT_CLICKHOUSE_PASSWORD
validate_ip_config DBT_CLICKHOUSE_ALLOWED_HOST

validate_password GRAFANA_CLICKHOUSE_PASSWORD
validate_ip_config GRAFANA_CLICKHOUSE_ALLOWED_HOST

validate_password SUPERSET_CLICKHOUSE_PASSWORD
validate_ip_config SUPERSET_CLICKHOUSE_ALLOWED_HOST

validate_password API_CLICKHOUSE_PASSWORD
validate_ip_config API_CLICKHOUSE_ALLOWED_HOST

validate_password ENVIO_CLICKHOUSE_PASSWORD
validate_ip_config ENVIO_CLICKHOUSE_ALLOWED_HOST

validate_password ZAPALYTICS_CLICKHOUSE_PASSWORD
validate_ip_config ZAPALYTICS_CLICKHOUSE_ALLOWED_HOST

validate_password CLICKHOUSE_BACKUP_PASSWORD
validate_ip_config CLICKHOUSE_BACKUP_ALLOWED_HOST

echo "Initializing ClickHouse databases..."

clickhouse-client \
  --user default \
  --password "$CLICKHOUSE_PASSWORD" \
  --multiquery <<SQL
    CREATE DATABASE IF NOT EXISTS analytics;
    CREATE DATABASE IF NOT EXISTS dbt;
    CREATE DATABASE IF NOT EXISTS dbt_test__audit;
    CREATE DATABASE IF NOT EXISTS dlt;
    CREATE DATABASE IF NOT EXISTS envio;
    CREATE DATABASE IF NOT EXISTS zapalytics;
    DROP DATABASE IF EXISTS envio_poc1;
    DROP DATABASE IF EXISTS envio_poc2;
    DROP DATABASE IF EXISTS envio_poc3;
SQL


READ_PERM="SELECT"
WRITE_PERM="INSERT, ALTER, CREATE TABLE, DROP TABLE, TRUNCATE, OPTIMIZE, CREATE DICTIONARY, DROP DICTIONARY"
RESET_DB_PERM="DROP DATABASE, CREATE DATABASE"
PROJECT_WRITE_PERM="SELECT, INSERT, CREATE TABLE"

clickhouse-client \
  --user default \
  --password "$CLICKHOUSE_PASSWORD" \
  --multiquery <<SQL
    -------------------------
    -- Users (idempotent)
    -------------------------

    -- dlt
    CREATE USER IF NOT EXISTS dlt IDENTIFIED WITH sha256_password BY '${DLT_CLICKHOUSE_PASSWORD}';
    ALTER USER dlt IDENTIFIED WITH sha256_password BY '${DLT_CLICKHOUSE_PASSWORD}';
    ALTER USER dlt HOST ${DLT_CLICKHOUSE_ALLOWED_HOST};

    -- dbt
    CREATE USER IF NOT EXISTS dbt IDENTIFIED WITH sha256_password BY '${DBT_CLICKHOUSE_PASSWORD}';
    ALTER USER dbt IDENTIFIED WITH sha256_password BY '${DBT_CLICKHOUSE_PASSWORD}';
    ALTER USER dbt HOST ${DBT_CLICKHOUSE_ALLOWED_HOST};

    -- grafana
    CREATE USER IF NOT EXISTS grafana IDENTIFIED WITH sha256_password BY '${GRAFANA_CLICKHOUSE_PASSWORD}';
    ALTER USER grafana IDENTIFIED WITH sha256_password BY '${GRAFANA_CLICKHOUSE_PASSWORD}';
    ALTER USER grafana HOST ${GRAFANA_CLICKHOUSE_ALLOWED_HOST};

    -- superset
    CREATE USER IF NOT EXISTS superset IDENTIFIED WITH sha256_password BY '${SUPERSET_CLICKHOUSE_PASSWORD}';
    ALTER USER superset IDENTIFIED WITH sha256_password BY '${SUPERSET_CLICKHOUSE_PASSWORD}';
    ALTER USER superset HOST ${SUPERSET_CLICKHOUSE_ALLOWED_HOST};

    -- api
    CREATE USER IF NOT EXISTS api IDENTIFIED WITH sha256_password BY '${API_CLICKHOUSE_PASSWORD}';
    ALTER USER api IDENTIFIED WITH sha256_password BY '${API_CLICKHOUSE_PASSWORD}';
    ALTER USER api HOST ${API_CLICKHOUSE_ALLOWED_HOST};

    -- backup sidecar (BACKUP/RESTORE to S3 disk)
    CREATE USER IF NOT EXISTS backup IDENTIFIED WITH sha256_password BY '${CLICKHOUSE_BACKUP_PASSWORD}';
    ALTER USER backup IDENTIFIED WITH sha256_password BY '${CLICKHOUSE_BACKUP_PASSWORD}';
    ALTER USER backup HOST ${CLICKHOUSE_BACKUP_ALLOWED_HOST};
    GRANT CURRENT GRANTS ON *.* TO backup;
    GRANT ACCESS MANAGEMENT ON *.* TO backup;

    -- project: envio
    CREATE USER IF NOT EXISTS envio IDENTIFIED WITH sha256_password BY '${ENVIO_CLICKHOUSE_PASSWORD}';
    ALTER USER envio IDENTIFIED WITH sha256_password BY '${ENVIO_CLICKHOUSE_PASSWORD}';
    ALTER USER envio HOST ${ENVIO_CLICKHOUSE_ALLOWED_HOST};

    -- project: zapalytics
    CREATE USER IF NOT EXISTS zapalytics IDENTIFIED WITH sha256_password BY '${ZAPALYTICS_CLICKHOUSE_PASSWORD}';
    ALTER USER zapalytics IDENTIFIED WITH sha256_password BY '${ZAPALYTICS_CLICKHOUSE_PASSWORD}';
    ALTER USER zapalytics HOST ${ZAPALYTICS_CLICKHOUSE_ALLOWED_HOST};

    -------------------------
    -- Grants (idempotent)
    -------------------------

    -- dlt: RW on dlt.*, R on dbt/analytics/project ingest
    REVOKE ALL PRIVILEGES ON INFORMATION_SCHEMA.*      FROM dlt;
    REVOKE ALL PRIVILEGES ON dlt.*                     FROM dlt;
    REVOKE ALL PRIVILEGES ON dbt.*                     FROM dlt;
    REVOKE ALL PRIVILEGES ON analytics.*               FROM dlt;
    REVOKE ALL PRIVILEGES ON zapalytics.*              FROM dlt;
    REVOKE ALL PRIVILEGES ON envio.*                   FROM dlt;
    GRANT ${READ_PERM}                ON INFORMATION_SCHEMA.*       TO dlt;
    GRANT ${READ_PERM}, ${WRITE_PERM} ON dlt.*                      TO dlt;
    GRANT ${READ_PERM}                ON dbt.*                      TO dlt; -- required to update incremental materialized views
    GRANT ${READ_PERM}                ON analytics.*                TO dlt; -- required to update incremental materialized views
    GRANT ${READ_PERM}                ON zapalytics.*               TO dlt;
    GRANT ${READ_PERM}                ON envio.*                    TO dlt;

    -- dbt: R on dlt.*, RW on dbt.* & analytics.*, RW+CREATE DATABASE on
    -- dbt_test__audit.* (dbt store_failures always issues CREATE DATABASE)
    REVOKE ALL PRIVILEGES ON INFORMATION_SCHEMA.*     FROM dbt;
    REVOKE ALL PRIVILEGES ON dlt.*                    FROM dbt;
    REVOKE ALL PRIVILEGES ON envio.*                  FROM dbt;
    REVOKE ALL PRIVILEGES ON zapalytics.*             FROM dbt;
    REVOKE ALL PRIVILEGES ON dbt.*                    FROM dbt;
    REVOKE ALL PRIVILEGES ON analytics.*              FROM dbt;
    REVOKE ALL PRIVILEGES ON dbt_test__audit.*        FROM dbt;
    GRANT ${READ_PERM}                ON INFORMATION_SCHEMA.*       TO dbt;
    GRANT ${READ_PERM}                ON dlt.*                      TO dbt;
    GRANT ${READ_PERM}                ON envio.*                    TO dbt;
    GRANT ${READ_PERM}                ON zapalytics.*               TO dbt;
    GRANT ${READ_PERM}, ${WRITE_PERM} ON dbt.*                      TO dbt;
    GRANT ${READ_PERM}, ${WRITE_PERM} ON analytics.*                TO dbt;
    GRANT ${READ_PERM}, ${WRITE_PERM}, CREATE DATABASE ON dbt_test__audit.* TO dbt;
    -- Copy beefy-history parquet from RustFS via s3() named collections (not the backup bucket).
    GRANT S3 ON *.* TO dbt;
    GRANT NAMED COLLECTION ON beefy_history_s3_events TO dbt;
    GRANT NAMED COLLECTION ON beefy_history_s3_issues TO dbt;

    -- grafana: R on warehouse + project DBs
    REVOKE ALL PRIVILEGES ON dlt.*           FROM grafana;
    REVOKE ALL PRIVILEGES ON dbt.*           FROM grafana;
    REVOKE ALL PRIVILEGES ON analytics.*     FROM grafana;
    REVOKE ALL PRIVILEGES ON envio.*         FROM grafana;
    REVOKE ALL PRIVILEGES ON zapalytics.*    FROM grafana;
    GRANT ${READ_PERM} ON dlt.*           TO grafana;
    GRANT ${READ_PERM} ON dbt.*           TO grafana;
    GRANT ${READ_PERM} ON analytics.*     TO grafana;
    GRANT ${READ_PERM} ON envio.*         TO grafana;
    GRANT ${READ_PERM} ON zapalytics.*    TO grafana;

    -- superset: R on warehouse + project DBs
    REVOKE ALL PRIVILEGES ON dlt.*           FROM superset;
    REVOKE ALL PRIVILEGES ON dbt.*           FROM superset;
    REVOKE ALL PRIVILEGES ON analytics.*     FROM superset;
    REVOKE ALL PRIVILEGES ON envio.*         FROM superset;
    REVOKE ALL PRIVILEGES ON zapalytics.*    FROM superset;
    GRANT ${READ_PERM} ON dlt.*        TO superset;
    GRANT ${READ_PERM} ON dbt.*        TO superset;
    GRANT ${READ_PERM} ON analytics.*  TO superset;
    GRANT ${READ_PERM} ON envio.*      TO superset;
    GRANT ${READ_PERM} ON zapalytics.* TO superset;

    -- api: R on warehouse + project DBs
    REVOKE ALL PRIVILEGES ON analytics.*    FROM api;
    REVOKE ALL PRIVILEGES ON dlt.*          FROM api;
    REVOKE ALL PRIVILEGES ON dbt.*          FROM api;
    REVOKE ALL PRIVILEGES ON envio.*        FROM api;
    REVOKE ALL PRIVILEGES ON zapalytics.*   FROM api;
    GRANT ${READ_PERM} ON analytics.*    TO api;
    GRANT ${READ_PERM} ON dlt.*          TO api;
    GRANT ${READ_PERM} ON dbt.*          TO api;
    GRANT ${READ_PERM} ON envio.*        TO api;
    GRANT ${READ_PERM} ON zapalytics.*   TO api;

    -- envio: SELECT on analytics.*, project write on envio.*
    REVOKE ALL PRIVILEGES ON analytics.*             FROM envio;
    REVOKE ALL PRIVILEGES ON envio.*                 FROM envio;
    GRANT ${READ_PERM}                             ON analytics.*    TO envio;
    GRANT ${PROJECT_WRITE_PERM}, ${RESET_DB_PERM}  ON envio.*        TO envio;

    -- zapalytics: SELECT on analytics.*, project write on zapalytics.*
    REVOKE ALL PRIVILEGES ON analytics.*             FROM zapalytics;
    REVOKE ALL PRIVILEGES ON zapalytics.*            FROM zapalytics;
    GRANT ${READ_PERM}            ON analytics.*    TO zapalytics;
    GRANT ${PROJECT_WRITE_PERM}   ON zapalytics.*   TO zapalytics;

    -------------------------------------------
    -- Settings profiles (env-synced)
    -------------------------------------------

    -- Web profile: readonly dashboards (grafana + superset + api)
    CREATE SETTINGS PROFILE IF NOT EXISTS web_profile;
    ALTER  SETTINGS PROFILE web_profile
        SETTINGS
            readonly = 1,
            max_execution_time = ${CLICKHOUSE_WEB_MAX_EXECUTION_TIME:-180}
                MIN 0
                MAX 180
                CHANGEABLE_IN_READONLY,
            max_memory_usage = ${CLICKHOUSE_WEB_MAX_MEMORY_USAGE:-6000000000}
                MIN 0
                MAX 10000000000
                CHANGEABLE_IN_READONLY,
            max_result_rows   = ${CLICKHOUSE_WEB_MAX_RESULT_ROWS:-100000},
            max_rows_to_read  = ${CLICKHOUSE_WEB_MAX_ROWS_TO_READ:-1000000},
            use_uncompressed_cache = 0,
            load_balancing = 'random'
        TO grafana, superset, api;

    -- ETL profile: dbt + dlt
    CREATE SETTINGS PROFILE IF NOT EXISTS etl_profile;
    ALTER  SETTINGS PROFILE etl_profile
        SETTINGS
            max_execution_time = 3600,
            max_memory_usage   = ${CLICKHOUSE_MAX_MEMORY_USAGE:-10000000000}
        TO dlt, dbt;

    -- envio: same keys as zapalytics, higher numeric defaults (indexer ingest)
    CREATE SETTINGS PROFILE IF NOT EXISTS envio_profile;
    ALTER  SETTINGS PROFILE envio_profile
        SETTINGS
            enable_lightweight_delete = 0
                MIN 0
                MAX 0,
            max_memory_usage = ${ENVIO_MAX_MEMORY_USAGE:-4000000000}
                MIN 0
                MAX ${ENVIO_MAX_MEMORY_USAGE:-4000000000},
            max_execution_time = ${ENVIO_MAX_EXECUTION_TIME:-120}
                MIN 0
                MAX ${ENVIO_MAX_EXECUTION_TIME:-120},
            max_insert_threads = ${ENVIO_MAX_INSERT_THREADS:-4}
                MIN 0
                MAX ${ENVIO_MAX_INSERT_THREADS:-4},
            max_insert_block_size = ${ENVIO_MAX_INSERT_BLOCK_SIZE:-65536}
                MIN 1
                MAX ${ENVIO_MAX_INSERT_BLOCK_SIZE:-65536},
            max_partitions_per_insert_block = ${ENVIO_MAX_PARTITIONS_PER_INSERT_BLOCK:-100}
                MIN 1
                MAX ${ENVIO_MAX_PARTITIONS_PER_INSERT_BLOCK:-100},
            max_result_rows = ${ENVIO_MAX_RESULT_ROWS:-100000},
            max_rows_to_read = ${ENVIO_MAX_ROWS_TO_READ:-1000000},
            use_uncompressed_cache = 0,
            load_balancing = 'random'
        TO envio;
    ALTER USER envio SETTINGS PROFILE envio_profile;

    -- zapalytics: no lightweight deletes, capped write size
    DROP SETTINGS PROFILE IF EXISTS project_profile;
    CREATE SETTINGS PROFILE IF NOT EXISTS zapalytics_profile;
    ALTER  SETTINGS PROFILE zapalytics_profile
        SETTINGS
            enable_lightweight_delete = 0
                MIN 0
                MAX 0,
            max_memory_usage = ${ZAPALYTICS_MAX_MEMORY_USAGE:-1000000000}
                MIN 0
                MAX ${ZAPALYTICS_MAX_MEMORY_USAGE:-1000000000},
            max_execution_time = ${ZAPALYTICS_MAX_EXECUTION_TIME:-30}
                MIN 0
                MAX ${ZAPALYTICS_MAX_EXECUTION_TIME:-30},
            max_insert_threads = ${ZAPALYTICS_MAX_INSERT_THREADS:-1}
                MIN 0
                MAX ${ZAPALYTICS_MAX_INSERT_THREADS:-1},
            max_insert_block_size = ${ZAPALYTICS_MAX_INSERT_BLOCK_SIZE:-8192}
                MIN 1
                MAX ${ZAPALYTICS_MAX_INSERT_BLOCK_SIZE:-8192},
            max_partitions_per_insert_block = ${ZAPALYTICS_MAX_PARTITIONS_PER_INSERT_BLOCK:-10}
                MIN 1
                MAX ${ZAPALYTICS_MAX_PARTITIONS_PER_INSERT_BLOCK:-10},
            max_result_rows = ${ZAPALYTICS_MAX_RESULT_ROWS:-100000},
            max_rows_to_read = ${ZAPALYTICS_MAX_ROWS_TO_READ:-1000000},
            use_uncompressed_cache = 0,
            load_balancing = 'random'
        TO zapalytics;

    -- Human / Play users (create-user.sql). Do not DROP and do not `TO envio`
    -- (that would unassign existing people). Limits only; assignments stay.
    CREATE SETTINGS PROFILE IF NOT EXISTS external_profile;
    ALTER SETTINGS PROFILE external_profile
        SETTINGS
            max_execution_time = ${CLICKHOUSE_EXTERNAL_MAX_EXECUTION_TIME:-20},
            max_memory_usage = ${CLICKHOUSE_EXTERNAL_MAX_MEMORY_USAGE:-10000000000},
            max_result_rows = ${CLICKHOUSE_EXTERNAL_MAX_RESULT_ROWS:-100000},
            max_rows_to_read = ${CLICKHOUSE_EXTERNAL_MAX_ROWS_TO_READ:-1000000},
            use_uncompressed_cache = 0,
            load_balancing = 'random';


    -------------------------------------------
    -- Quotas
    -------------------------------------------

    -- Optional default quota (effectively unlimited, like XML <default>)
    CREATE QUOTA OR REPLACE default_quota
        FOR INTERVAL 3600 SECOND MAX
            queries        = 0,
            query_selects  = 0,
            errors         = 0,
            result_rows    = 0,
            result_bytes   = 0,
            read_rows      = 0,
            read_bytes     = 0,
            execution_time = 0
        TO dlt, dbt;

    -- Web quota: limit dashboard workloads
    CREATE QUOTA OR REPLACE web_quota
        FOR INTERVAL 3600 SECOND MAX
            queries        = 5000,
            query_selects  = 5000,
            errors         = 1000,
            result_rows    = 10000000000,
            result_bytes   = 10000000000000,
            read_rows      = 100000000000,
            read_bytes     = 100000000000000,
            execution_time = 7200
        TO grafana, superset, api;

    DROP QUOTA IF EXISTS project_quota;

    CREATE QUOTA IF NOT EXISTS external_quota
        FOR INTERVAL 1 SECOND MAX
            queries        = 5000,
            query_selects  = 5000,
            errors         = 1000,
            result_rows    = 10000000000,
            result_bytes   = 10000000000000,
            read_rows      = 100000000000,
            read_bytes     = 100000000000000,
            execution_time = 7200;
    ALTER QUOTA external_quota
        FOR INTERVAL 1 SECOND MAX
            queries        = 5000,
            query_selects  = 5000,
            errors         = 1000,
            result_rows    = 10000000000,
            result_bytes   = 10000000000000,
            read_rows      = 100000000000,
            read_bytes     = 100000000000000,
            execution_time = 7200;

    CREATE QUOTA OR REPLACE envio_quota
        FOR INTERVAL 1 SECOND MAX
            query_inserts = ${ENVIO_QUOTA_INSERTS_PER_SECOND:-200},
            written_bytes  = ${ENVIO_QUOTA_WRITTEN_BYTES_PER_SECOND:-52428800},
        FOR INTERVAL 1 HOUR MAX
            query_inserts = ${ENVIO_QUOTA_INSERTS_PER_HOUR:-500000},
            written_bytes  = ${ENVIO_QUOTA_WRITTEN_BYTES_PER_HOUR:-10737418240},
        FOR INTERVAL 1 DAY MAX
            written_bytes  = ${ENVIO_QUOTA_WRITTEN_BYTES_PER_DAY:-107374182400}
        TO envio;

    CREATE QUOTA OR REPLACE zapalytics_quota
        FOR INTERVAL 1 SECOND MAX
            query_inserts = ${ZAPALYTICS_QUOTA_INSERTS_PER_SECOND:-5},
            written_bytes  = ${ZAPALYTICS_QUOTA_WRITTEN_BYTES_PER_SECOND:-5242880},
        FOR INTERVAL 1 HOUR MAX
            query_inserts = ${ZAPALYTICS_QUOTA_INSERTS_PER_HOUR:-500},
            written_bytes  = ${ZAPALYTICS_QUOTA_WRITTEN_BYTES_PER_HOUR:-104857600},
        FOR INTERVAL 1 DAY MAX
            written_bytes  = ${ZAPALYTICS_QUOTA_WRITTEN_BYTES_PER_DAY:-1073741824}
        TO zapalytics;
SQL

echo "✓ Databases analytics, dbt, dbt_test__audit, dlt, envio & zapalytics initialized"
echo "✓ Users, grants, profiles, quotas reset & synced to env"
