#!/usr/bin/env python3
"""Scheduled beefy-history producer: CLI → parquet → RustFS. Not a dlt source."""
from __future__ import annotations

import logging
import sys

from lib.beefy_history import BeefyHistoryError, run_producer

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)


def main() -> int:
    try:
        run_producer()
    except BeefyHistoryError as exc:
        logging.error("%s", exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
