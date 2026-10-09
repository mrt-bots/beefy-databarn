from typing import Any

from dlt.sources.sql_database import sql_table

from lib.config import ZAP_BATCH_SIZE, get_beefy_timescaledb_url
from lib.sql_database import (
    compose_query_adapters,
    hex_encode_bytea_columns,
    postgres_array_as_json_text,
)


async def get_beefy_db_zap_records_resource() -> Any:
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
        "event_idx": {
            "data_type": "bigint",
            "primary_key": True,
            "nullable": False,
        },
        "txn_hash": {
            "data_type": "text",
            "nullable": False,
        },
        "caller_address": {
            "data_type": "text",
            "nullable": False,
        },
        "recipient_address": {
            "data_type": "text",
            "nullable": False,
        },
        "source_chain_id": {
            "data_type": "bigint",
        },
        "target_chain_id": {
            "data_type": "bigint",
        },
        "vault_id": {
            "data_type": "text",
        },
        "action": {
            "data_type": "text",
        },
        "total_usd": {
            "data_type": "decimal",
            "scale": 18,
            "precision": 30,
        },
        "cctp_hash": {
            "data_type": "text",
        },
        "swap_source": {
            "data_type": "text",
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
        table="zap_records",
        backend="pyarrow",
        chunk_size=ZAP_BATCH_SIZE,
        backend_kwargs={"tz": "UTC"},
        reflection_level="full_with_precision",
        query_adapter_callback=compose_query_adapters(
            hex_encode_bytea_columns(
                {"txn_hash", "caller_address", "recipient_address", "cctp_hash"}
            ),
            postgres_array_as_json_text({"swap_source"}),
        ),
        primary_key=pk,
        write_disposition="replace",
    )
    resource.apply_hints(columns=[{"name": name, **c} for name, c in columns.items()])
    return resource
