
import logging
from typing import Any
from datetime import datetime, timezone
import dlt
from dlt.sources.sql_database import sql_table
from lib.config import BATCH_SIZE, get_beefy_timescaledb_url
from lib.clickhouse import get_clickhouse_client
from lib.postgres import connect_beefy_timescaledb
from lib.sql_database import time_bounded_select, time_window_bounds

logger = logging.getLogger(__name__)

SOURCE_NAME = "beefy_db"
RESOURCE_NAME= "harvests"
FULL_TABLE_NAME = f"{SOURCE_NAME}___{RESOURCE_NAME}"

DATE_RANGE_SIZE_IN_DAYS = 120

# custom sql to use ReplacingMergeTree and compression codecs
TABLE_SQL = f"""
    CREATE TABLE IF NOT EXISTS {FULL_TABLE_NAME}
    (
        `chain_id` Int64 CODEC(Delta, ZSTD),
        `block_number` Int64 CODEC(Delta, ZSTD),
        `txn_idx` Int32 CODEC(Delta, ZSTD),
        `event_idx` Int32 CODEC(Delta, ZSTD),
        `txn_timestamp` Nullable(DateTime64(6, 'UTC')) CODEC(DoubleDelta, ZSTD),
        `txn_hash` Nullable(String) CODEC(ZSTD),
        `vault_id` Nullable(String) CODEC(ZSTD),
        `call_fee` Nullable(Decimal(76, 20)) CODEC(ZSTD),
        `gas_fee` Nullable(Decimal(76, 20)) CODEC(ZSTD),
        `platform_fee` Nullable(Decimal(76, 20)) CODEC(ZSTD),
        `strategist_fee` Nullable(Decimal(76, 20)) CODEC(ZSTD),
        `harvest_amount` Nullable(Decimal(76, 20)) CODEC(ZSTD),
        `native_price` Nullable(Decimal(76, 20)) CODEC(ZSTD),
        `want_price` Nullable(Decimal(76, 20)) CODEC(ZSTD),
        `is_cowllector` Nullable(Bool) CODEC(LZ4),
        `strategist_address` Nullable(String) CODEC(ZSTD)
    )
    ENGINE = ReplacingMergeTree
    PRIMARY KEY (chain_id, block_number, txn_idx, event_idx)
    ORDER BY (chain_id, block_number, txn_idx, event_idx)
    SETTINGS index_granularity = 8192;
"""

CHAINS_SQL = "SELECT DISTINCT chain_id FROM chains ORDER BY chain_id"
        

async def _init_resource() -> list[int]:
    client = await get_clickhouse_client()
    await client.query(TABLE_SQL)

    conn = connect_beefy_timescaledb()
    try:
        with conn.cursor() as cur:
            cur.execute(CHAINS_SQL)
            return [row[0] for row in cur.fetchall()]
    finally:
        conn.close()

        
async def get_beefy_db_harvests_resource() -> Any:
    chain_ids = await _init_resource()

    # Time window is required so Timescale can exclude compressed chunks.
    def harvests_query_adapter_callback(query, table, incremental=None, engine=None):
        start_value, end_value = time_window_bounds(
            incremental,
            default_start=datetime(2022, 1, 13, 0, 0, 0, tzinfo=timezone.utc),  # 2022-01-13 08:32:56+00
            window_days=DATE_RANGE_SIZE_IN_DAYS,
        )

        logger.info(f"harvests_query_adapter_callback: {start_value} {end_value}")

        return time_bounded_select(
            table,
            time_column="txn_timestamp",
            start_value=start_value,
            end_value=end_value,
            any_filters={"chain_id": ("chain_ids", chain_ids)},
        )
        
    harvests = sql_table(
        credentials=get_beefy_timescaledb_url(),
        table=RESOURCE_NAME,
        backend="pyarrow",
        chunk_size=BATCH_SIZE,
        backend_kwargs={"tz": "UTC"},
        reflection_level="full_with_precision",
        query_adapter_callback=harvests_query_adapter_callback,
        primary_key=["chain_id", "block_number", "txn_idx", "event_idx"],
        write_disposition="append",
        incremental=dlt.sources.incremental(
            "txn_timestamp", 
            initial_value=None,
            primary_key=["chain_id", "block_number", "txn_idx", "event_idx"],
            last_value_func=max,
            row_order="asc" 
        ),
    )
    harvests.apply_hints(
        columns=[
            # force keys to be non-nullable
            {"name": "chain_id", "nullable": False },
            {"name": "block_number", "nullable": False },
            {"name": "txn_idx", "nullable": False },
            {"name": "event_idx", "nullable": False },
            # ClickHouse Decimal(76, 20) / Decimal256. Arrow may warn and fall back
            # while converting Postgres numeric; destination type stays Decimal.
            {"name": "call_fee", "data_type": "decimal", "scale": 20, "precision": 76 },
            {"name": "gas_fee", "data_type": "decimal", "scale": 20, "precision": 76 },
            {"name": "platform_fee", "data_type": "decimal", "scale": 20, "precision": 76 },
            {"name": "strategist_fee", "data_type": "decimal", "scale": 20, "precision": 76 },
            {"name": "harvest_amount", "data_type": "decimal", "scale": 20, "precision": 76 },
            {"name": "native_price", "data_type": "decimal", "scale": 20, "precision": 76 },
            {"name": "want_price", "data_type": "decimal", "scale": 20, "precision": 76 },
        ]
    )

    return harvests

