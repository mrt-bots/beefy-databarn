from typing import Any
from dlt.destinations.adapters import clickhouse_adapter
from lib.config import BATCH_SIZE, get_beefy_timescaledb_url
from lib.sql_database import try_sql_table

# Small lookup tables still on Heroku beefy-db.
HEROKU_TABLES = {
    "address_metadata": [
        {"name": "chain_id", "primary_key": True },
        {"name": "address", "primary_key": True },
    ],
    "bifi_buyback": [
        {"name": "id", "primary_key": True },
        {"name": "bifi_amount", "data_type": "decimal" },
        {"name": "bifi_price", "data_type": "decimal" },
        {"name": "buyback_total", "data_type": "decimal" },
    ],
    "vault_strategies": [
        {"name": "id", "primary_key": True },
    ],
    "feebatch_harvests": [
        {"name": "chain_id", "primary_key": True },
        {"name": "block_number", "primary_key": True },
    ],
}

# Lookup tables migrated to Tiger Cloud Timescale. Destination schema is unchanged.
TIMESCALEDB_TABLES = {
    "chains": [
        {"name": "chain_id", "primary_key": True },
    ],
    "price_oracles": [{"name": "id", "primary_key": True }],
    "vault_ids": [{"name": "id", "primary_key": True }],
}


def _table_resources(db_url: str, tables: dict[str, list[dict[str, Any]]]) -> list[Any]:
    resources = []
    for table_name, columns in tables.items():
        primary_key_columns = [column["name"] for column in columns if "primary_key" in column and column["primary_key"]]
        resource = try_sql_table(
            credentials=db_url,
            table=table_name,
            backend="sqlalchemy",
            chunk_size=BATCH_SIZE,
            backend_kwargs={"tz": "UTC"},
            reflection_level="full_with_precision",
            primary_key=primary_key_columns,
            write_disposition="append",
        )
        if resource is None:
            continue
        resource.apply_hints(columns=columns)
        resources.append(clickhouse_adapter(resource, table_engine_type="replacing_merge_tree"))

    return resources


def get_beefy_db_other_tables_resources() -> list[Any]:
    resources = _table_resources(get_beefy_timescaledb_url(), HEROKU_TABLES)
    resources.extend(_table_resources(get_beefy_timescaledb_url(), TIMESCALEDB_TABLES))
    return resources
