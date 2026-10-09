from typing import Any

from dlt.sources.sql_database import sql_table

from lib.config import ZAP_BATCH_SIZE, get_beefy_timescaledb_url
from lib.sql_database import hex_encode_bytea_columns


async def get_beefy_db_zap_parent_transactions_resource() -> Any:
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
        "txn_timestamp": {
            "data_type": "timestamp",
            "nullable": False,
        },
        "txn_hash": {
            "data_type": "text",
            "nullable": False,
        },
        "value": {
            "data_type": "decimal",
            "scale": 18,
            "precision": 36,
            "nullable": False,
        },
        "effective_gas_price": {
            "data_type": "bigint",
            "nullable": False,
        },
        "gas_limit": {
            "data_type": "bigint",
            "nullable": False,
        },
        "gas_used": {
            "data_type": "bigint",
            "nullable": False,
        },
        "native_price": {
            "data_type": "decimal",
            "scale": 18,
            "precision": 30,
        },
        "from_address": {
            "data_type": "text",
            "nullable": False,
        },
        "to_address": {
            "data_type": "text",
            "nullable": False,
        },
        "calldata": {
            "data_type": "text",
            "nullable": False,
        },
        "success": {
            "data_type": "bool",
            "nullable": False,
        },
        "created_at": {
            "data_type": "timestamp",
            "nullable": False,
        },
    }

    pk = [name for name, c in columns.items() if c.get("primary_key")]
    resource = sql_table(
        credentials=get_beefy_timescaledb_url(),
        table="zap_parent_transactions",
        backend="pyarrow",
        chunk_size=ZAP_BATCH_SIZE,
        backend_kwargs={"tz": "UTC"},
        reflection_level="full_with_precision",
        query_adapter_callback=hex_encode_bytea_columns(
            {"txn_hash", "from_address", "to_address", "calldata"}
        ),
        primary_key=pk,
        write_disposition="replace",
    )
    resource.apply_hints(columns=[{"name": name, **c} for name, c in columns.items()])
    return resource
