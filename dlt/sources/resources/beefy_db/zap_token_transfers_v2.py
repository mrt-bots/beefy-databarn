from typing import Any

from dlt.sources.sql_database import sql_table

from lib.config import ZAP_BATCH_SIZE, get_beefy_timescaledb_url
from lib.sql_database import hex_encode_bytea_columns


async def get_beefy_db_zap_token_transfers_v2_resource() -> Any:
    columns = {
        "chain_id": {
            "data_type": "bigint",
            "primary_key": True,
            "nullable": False,
        },
        "block_number": {
            "data_type": "bigint",
            "primary_key": True,
            "nullable": False,
        },
        "txn_idx": {
            "data_type": "bigint",
            "primary_key": True,
            "nullable": False,
        },
        "parent_event_idx": {
            "data_type": "bigint",
            "nullable": False,
        },
        "event_idx": {
            "data_type": "bigint",
            "primary_key": True,
            "nullable": False,
        },
        "zap_type": {
            "data_type": "text",
            "nullable": False,
        },
        "token_id": {
            "data_type": "bigint",
        },
        "token_amount": {
            "data_type": "decimal",
            "scale": 18,
            "precision": 36,
            "nullable": False,
        },
        "usd_value": {
            "data_type": "decimal",
            "scale": 18,
            "precision": 30,
        },
        "token_address": {
            "data_type": "text",
            "nullable": False,
        },
        "created_at": {
            "data_type": "timestamp",
            "nullable": False,
        },
        "updated_at": {
            "data_type": "timestamp",
            "nullable": False,
        },
    }

    pk = [name for name, c in columns.items() if c.get("primary_key")]
    resource = sql_table(
        credentials=get_beefy_timescaledb_url(),
        # Source Postgres table is still zap_token_transfers; destination
        # resource is renamed to avoid colliding with the legacy CH table.
        table="zap_token_transfers",
        backend="pyarrow",
        chunk_size=ZAP_BATCH_SIZE,
        backend_kwargs={"tz": "UTC"},
        reflection_level="full_with_precision",
        query_adapter_callback=hex_encode_bytea_columns({"token_address"}),
        primary_key=pk,
        write_disposition="replace",
    )
    resource.apply_hints(columns=[{"name": name, **c} for name, c in columns.items()])
    return resource.with_name("zap_token_transfers_v2")
