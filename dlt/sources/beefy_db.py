from typing import Any, Awaitable, Callable, Optional

import dlt
from sqlalchemy.exc import NoSuchTableError

from lib.sql_database import log_missing_table
from .resources.beefy_db.harvests import get_beefy_db_harvests_resource
from .resources.beefy_db.prices import get_beefy_db_prices_resource
from .resources.beefy_db.tvls import get_beefy_db_tvls_resource
from .resources.beefy_db.apys import get_beefy_db_apys_resource
from .resources.beefy_db.tvl_by_chain import get_beefy_db_tvl_by_chain_resource
from .resources.beefy_db.tables import get_beefy_db_other_tables_resources
from .resources.beefy_db.zap_records import get_beefy_db_zap_records_resource
from .resources.beefy_db.zap_parent_transactions import (
    get_beefy_db_zap_parent_transactions_resource,
)
from .resources.beefy_db.zap_token_transfers_v2 import (
    get_beefy_db_zap_token_transfers_v2_resource,
)


async def _optional_resource(
    name: str, factory: Callable[[], Awaitable[Any]]
) -> Optional[Any]:
    # Soft-skip missing Postgres tables so other resources still load.
    # Omitting the resource keeps its dlt incremental state unchanged for the next run.
    try:
        return await factory()
    except NoSuchTableError as e:
        log_missing_table(name, e)
        return None


@dlt.source(name="beefy_db", parallelized=True)
async def beefy_db_source() -> Any:
    """Expose Beefy DB resources for use by dlt pipelines.

    All beefy-db tables are read from Tiger Cloud Timescale. ClickHouse
    destination names and schemas are unchanged.
    """

    candidates = [
        await _optional_resource("harvests", get_beefy_db_harvests_resource),
        await _optional_resource("prices", get_beefy_db_prices_resource),
        await _optional_resource("tvls", get_beefy_db_tvls_resource),
        await _optional_resource("apys", get_beefy_db_apys_resource),
        await _optional_resource("tvl_by_chain", get_beefy_db_tvl_by_chain_resource),
        await _optional_resource("zap_records", get_beefy_db_zap_records_resource),
        await _optional_resource(
            "zap_parent_transactions",
            get_beefy_db_zap_parent_transactions_resource,
        ),
        await _optional_resource(
            "zap_token_transfers_v2",
            get_beefy_db_zap_token_transfers_v2_resource,
        ),
    ]
    resources = [r for r in candidates if r is not None]
    resources.extend(get_beefy_db_other_tables_resources())

    return resources
