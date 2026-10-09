#!/usr/bin/env python3
"""
Scheduler for DLT pipelines using APScheduler.
Runs four DLT pipelines, plus the beefy-history parquet producer (not a dlt source).
"""
from __future__ import annotations
import logging
import asyncio
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger

import alerts
from process import run_pipeline_script

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)


async def beefy_api_pipeline():
    """Run the beefy_api pipeline."""
    await run_pipeline_script("beefy_api_pipeline.py")

async def beefy_db_pipeline():
    """Run the beefy_db pipeline."""
    await run_pipeline_script("beefy_db_pipeline.py")

async def github_files_pipeline():
    """Run the github_files pipeline."""
    await run_pipeline_script("github_files_pipeline.py")

async def beefy_cctp_api_pipeline():
    """Run the beefy_cctp_api pipeline."""
    await run_pipeline_script("beefy_cctp_api_pipeline.py")

async def optimize_replacing_tables():
    """Collapse ReplacingMergeTree duplicates. Slow; not run after every load."""
    # Daily at 05:00 UTC (1h before dbt tests); kill after 1h so tests start clean.
    await run_pipeline_script("optimize_replacing_tables.py", timeout=60 * 60)

async def cleanup_pipeline_state():
    """Delete superseded `_dlt_pipeline_state` rows older than the retention window."""
    await run_pipeline_script("cleanup_pipeline_state.py", timeout=2 * 60 * 60)

async def beefy_history_pipeline():
    """Walk git mirrors with the pinned CLI and publish parquet to RustFS. Not a dlt source."""
    # First clone of beefy-app + beefy-v2 is ~450 MB; later hourly runs rebuild the store (~30 s).
    await run_pipeline_script("beefy_history_pipeline.py", timeout=90 * 60)

async def main():
    """Main async function to run the scheduler."""
    logger.info(
        "Starting DLT scheduler with 4 pipeline tasks, beefy-history parquet publish, daily optimize, and state cleanup..."
    )

    scheduler = AsyncIOScheduler()

    # Schedule beefy_api pipeline to run every 5 minutes at :00, :05, :10, etc.
    scheduler.add_job(
        beefy_api_pipeline,
        trigger=CronTrigger(minute="0/5"),
        id="beefy_api_pipeline",
        name="Beefy API Pipeline",
        max_instances=1,  # Prevent overlapping runs
        coalesce=True,   # Combine multiple pending runs into one
    )

    # Schedule github_files pipeline to run every 5 minutes at :01, :06, :11, etc.
    scheduler.add_job(
        github_files_pipeline,
        trigger=CronTrigger(minute="1/5"),
        id="github_files_pipeline",
        name="GitHub Files Pipeline",
        max_instances=1,  # Prevent overlapping runs
        coalesce=True,   # Combine multiple pending runs into one
    )

    # Schedule beefy_db pipeline to run every 5 minutes at :02, :07, :12, etc.
    scheduler.add_job(
        beefy_db_pipeline,
        trigger=CronTrigger(minute="2/5"),
        id="beefy_db_pipeline",
        name="Beefy DB Pipeline",
        max_instances=1,  # Prevent overlapping runs
        coalesce=True,   # Combine multiple pending runs into one
    )

    # Schedule beefy_cctp_api pipeline to run every 5 minutes at :03, :08, :13, etc.
    scheduler.add_job(
        beefy_cctp_api_pipeline,
        trigger=CronTrigger(minute="3/5"),
        id="beefy_cctp_api_pipeline",
        name="Beefy CCTP API Pipeline",
        max_instances=1,  # Prevent overlapping runs
        coalesce=True,   # Combine multiple pending runs into one
    )

    # OPTIMIZE FINAL is too slow for the 5-minute load loop; run daily before dbt tests.
    scheduler.add_job(
        optimize_replacing_tables,
        trigger=CronTrigger(hour=5, minute=0),
        id="optimize_replacing_tables",
        name="Optimize ReplacingMergeTree tables",
        max_instances=1,
        coalesce=True,
    )

    # Historical pipeline-state snapshots, per pipeline_name:
    # drop rows older than 30 days, but keep at least 50 newest. Every 3 days at 04:00 UTC.
    scheduler.add_job(
        cleanup_pipeline_state,
        trigger=CronTrigger(day="*/3", hour=4, minute=0),
        id="cleanup_pipeline_state",
        name="Cleanup deprecated dlt pipeline state",
        max_instances=1,
        coalesce=True,
    )

    # Catalog history from git (not api.beefy.finance). Hourly; dbt glob only current/.
    scheduler.add_job(
        beefy_history_pipeline,
        trigger=CronTrigger(minute=15),
        id="beefy_history_pipeline",
        name="Beefy history parquet publish",
        max_instances=1,
        coalesce=True,
    )

    scheduler.start()

    # Keep the event loop running
    try:
        await asyncio.Event().wait()
    except (KeyboardInterrupt, SystemExit):
        logger.info("Shutting down scheduler...")
        scheduler.shutdown()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, SystemExit):
        logger.info("Scheduler stopped")
    except Exception as e:
        logger.error(f"dlt scheduler crashed: {e}", exc_info=True)
        alerts.alert_scheduler_crash(e)
        raise
