"""Produce beefy-history parquet and publish it to RustFS for ClickHouse/dbt.

This is not a dlt source. The CLI walks local git mirrors of beefy-app and
beefy-v2; DuckDB stays inside that CLI. Databarn only stores the parquet on
RustFS and copies it into ClickHouse MergeTree tables.

Pinned CLI: github.com/mrt-bots/beefy-history @ CLI_GIT_SHA (see Dockerfile).
"""
from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping

import pyarrow as pa
import pyarrow.parquet as pq

logger = logging.getLogger(__name__)

# packages/core @ 79dd2fcc18d0373798eeeec9b9726dd876c39b89 (ENGINE_VERSION beefy-history/4+engine/5+parse/3)
CLI_GIT_SHA = "79dd2fcc18d0373798eeeec9b9726dd876c39b89"
CLI_GIT_URL = "https://github.com/mrt-bots/beefy-history.git"
DEFAULT_BUCKET = "beefy-history"
CURRENT_PREFIX = "current"
RUN_PREFIX_ROOT = "run"

# Parquet columns written by the CLI (packages/core/src/store/schema.ts). Nested
# config is NOT a parquet struct: `data` is canonical JSON text (VARCHAR).
# `changedKeys` is a list of strings. `objects` / `latest` are DuckDB views,
# not files — dbt derives them from events.
EVENT_COLUMNS: tuple[str, ...] = (
    "seq",
    "objectId",
    "kind",
    "chain",
    "id",
    "address",
    "type",
    "source",
    "commitRepo",
    "commitSha",
    "committedAt",
    "authoredAt",
    "commitSubject",
    "path",
    "data",
    "dataHash",
    "reason",
    "changedKeys",
)
ISSUE_COLUMNS: tuple[str, ...] = (
    "seq",
    "type",
    "repo",
    "commitSha",
    "committedAt",
    "path",
    "kind",
    "chain",
    "id",
    "message",
    "details",
)

ISSUE_ARROW_SCHEMA = pa.schema(
    [
        ("seq", pa.int64()),
        ("type", pa.string()),
        ("repo", pa.string()),
        ("commitSha", pa.string()),
        ("committedAt", pa.int64()),
        ("path", pa.string()),
        ("kind", pa.string()),
        ("chain", pa.string()),
        ("id", pa.string()),
        ("message", pa.string()),
        ("details", pa.string()),
    ]
)


class BeefyHistoryError(RuntimeError):
    """Producer failed before a successful publish."""


@dataclass(frozen=True)
class ProducerConfig:
    data_dir: Path
    repos_dir: Path
    store_dir: Path
    cli_dir: Path
    node_bin: str
    s3_endpoint: str
    s3_bucket: str
    s3_access_key: str
    s3_secret_key: str
    fetch: bool = True
    keep_runs: int = 3


@dataclass(frozen=True)
class PublishResult:
    run_id: str
    skipped: bool
    events_rows: int
    issues_rows: int
    engine_version: str | None
    checkpoint: dict[str, Any] | None


def _env(name: str, default: str | None = None) -> str | None:
    value = os.environ.get(name)
    if value is None or value == "":
        return default
    return value


def _storage_dir() -> Path:
    storage = _env("STORAGE_DIR")
    if storage:
        return Path(storage)
    return Path("/var")


def load_config() -> ProducerConfig:
    data_dir = Path(_env("BEEFY_HISTORY_DATA_DIR", str(_storage_dir() / "beefy-history")))
    cli_dir = Path(_env("BEEFY_HISTORY_DIR", "/opt/beefy-history"))
    endpoint = _env(
        "BEEFY_HISTORY_S3_ENDPOINT",
        _env("RUSTFS_ENDPOINT", "http://rustfs:9000"),
    )
    access_key = _env(
        "BEEFY_HISTORY_S3_ACCESS_KEY",
        _env("CLICKHOUSE_BACKUP_S3_ACCESS_KEY", _env("RUSTFS_ACCESS_KEY", "admin")),
    )
    secret_key = _env(
        "BEEFY_HISTORY_S3_SECRET_KEY",
        _env("CLICKHOUSE_BACKUP_S3_SECRET_KEY", _env("RUSTFS_SECRET_KEY")),
    )
    if not secret_key:
        raise BeefyHistoryError(
            "BEEFY_HISTORY_S3_SECRET_KEY (or CLICKHOUSE_BACKUP_S3_SECRET_KEY / RUSTFS_SECRET_KEY) must be set"
        )
    fetch = _env("BEEFY_HISTORY_FETCH", "1") not in {"0", "false", "no"}
    return ProducerConfig(
        data_dir=data_dir,
        repos_dir=Path(_env("BEEFY_HISTORY_REPOS_DIR", str(data_dir / "repos"))),
        store_dir=Path(_env("BEEFY_HISTORY_STORE_DIR", str(data_dir / "store"))),
        cli_dir=cli_dir,
        node_bin=_env("BEEFY_HISTORY_NODE", "node") or "node",
        s3_endpoint=endpoint or "http://rustfs:9000",
        s3_bucket=_env("BEEFY_HISTORY_S3_BUCKET", DEFAULT_BUCKET) or DEFAULT_BUCKET,
        s3_access_key=access_key or "admin",
        s3_secret_key=secret_key,
        fetch=fetch,
        keep_runs=int(_env("BEEFY_HISTORY_KEEP_RUNS", "3") or "3"),
    )


def cli_script(cli_dir: Path) -> Path:
    return cli_dir / "packages" / "core" / "src" / "cli.ts"


def validate_cli(config: ProducerConfig) -> Path:
    script = cli_script(config.cli_dir)
    if not script.is_file():
        raise BeefyHistoryError(
            f"beefy-history CLI not found at {script}. "
            f"Pin {CLI_GIT_SHA} into BEEFY_HISTORY_DIR (image default /opt/beefy-history)."
        )
    return script


def run_cli(
    config: ProducerConfig,
    args: list[str],
    *,
    timeout: int = 60 * 60,
    run: Callable[..., subprocess.CompletedProcess[str]] | None = None,
) -> subprocess.CompletedProcess[str]:
    script = validate_cli(config)
    cmd = [config.node_bin, str(script), *args]
    logger.info("running %s", " ".join(cmd))
    runner = run or subprocess.run
    result = runner(
        cmd,
        cwd=str(config.cli_dir),
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if result.stdout:
        logger.info(result.stdout.rstrip())
    if result.stderr:
        logger.info(result.stderr.rstrip())
    return result


def sync_store(config: ProducerConfig, *, run: Callable[..., subprocess.CompletedProcess[str]] | None = None) -> None:
    """Full rebuild into a fresh store directory. Git mirrors are kept on disk."""
    config.repos_dir.mkdir(parents=True, exist_ok=True)
    if config.store_dir.exists():
        shutil.rmtree(config.store_dir)
    config.store_dir.mkdir(parents=True, exist_ok=True)

    sync_args = [
        "sync",
        "--out",
        str(config.store_dir),
        "--repos-dir",
        str(config.repos_dir),
    ]
    if not config.fetch:
        sync_args.append("--no-fetch")
    result = run_cli(config, sync_args, run=run)
    if result.returncode != 0:
        raise BeefyHistoryError(
            f"beefy-history sync failed ({result.returncode}): {(result.stderr or result.stdout).strip()}"
        )
    compact = run_cli(config, ["compact", "--out", str(config.store_dir)], run=run)
    if compact.returncode != 0:
        raise BeefyHistoryError(
            f"beefy-history compact failed ({compact.returncode}): {(compact.stderr or compact.stdout).strip()}"
        )


def read_store_manifest(store_dir: Path) -> dict[str, Any]:
    path = store_dir / "manifest.json"
    if not path.is_file():
        raise BeefyHistoryError(f"store manifest missing at {path} (sync produced no commit)")
    return json.loads(path.read_text())


def _segment_file(store_dir: Path, segments: list[Any], table: str) -> Path | None:
    if not segments:
        return None
    if len(segments) != 1:
        raise BeefyHistoryError(
            f"store {table} has {len(segments)} parquet segments after compact; expected 1"
        )
    rel = segments[0].get("file")
    if not isinstance(rel, str):
        raise BeefyHistoryError(f"store manifest {table} segment is missing file")
    path = store_dir / rel
    if not path.is_file():
        raise BeefyHistoryError(f"store parquet missing: {path}")
    return path


def _parquet_columns(path: Path) -> list[str]:
    return list(pq.read_schema(path).names)


def assert_parquet_columns(path: Path, required: tuple[str, ...], *, table: str) -> None:
    names = _parquet_columns(path)
    missing = [col for col in required if col not in names]
    if missing:
        raise BeefyHistoryError(
            f"{table} parquet {path} missing columns {missing}; got {names}. "
            "CLI schema changed — bump CLI_GIT_SHA only after updating staging SQL."
        )


def write_empty_issues_parquet(path: Path) -> None:
    empty = {field.name: pa.array([], type=field.type) for field in ISSUE_ARROW_SCHEMA}
    pq.write_table(pa.table(empty, schema=ISSUE_ARROW_SCHEMA), path)


def stage_publish_files(store_dir: Path, staging_dir: Path) -> dict[str, Path]:
    """Copy compact parquet to stable names events.parquet / issues.parquet."""
    staging_dir.mkdir(parents=True, exist_ok=True)
    manifest = read_store_manifest(store_dir)
    events = _segment_file(store_dir, manifest.get("events") or [], "events")
    if events is None:
        raise BeefyHistoryError("store has no events parquet — refusing to publish an empty catalog")
    assert_parquet_columns(events, EVENT_COLUMNS, table="events")
    events_out = staging_dir / "events.parquet"
    shutil.copy2(events, events_out)

    issues = _segment_file(store_dir, manifest.get("issues") or [], "issues")
    issues_out = staging_dir / "issues.parquet"
    if issues is None:
        logger.warning("store has no issues parquet; publishing an empty file with the contracted schema")
        write_empty_issues_parquet(issues_out)
    else:
        assert_parquet_columns(issues, ISSUE_COLUMNS, table="issues")
        shutil.copy2(issues, issues_out)
    return {"events": events_out, "issues": issues_out}


def parquet_row_count(path: Path) -> int:
    return pq.ParquetFile(path).metadata.num_rows


def open_s3(
    config: ProducerConfig,
    *,
    factory: Callable[..., Any] | None = None,
) -> Any:
    import s3fs

    maker = factory or s3fs.S3FileSystem
    return maker(
        key=config.s3_access_key,
        secret=config.s3_secret_key,
        client_kwargs={"endpoint_url": config.s3_endpoint},
        config_kwargs={"s3": {"addressing_style": "path"}},
        use_listings_cache=False,
    )


def _s3_key(bucket: str, *parts: str) -> str:
    return "/".join((bucket, *parts))


def _read_json(fs: Any, key: str) -> dict[str, Any] | None:
    if not fs.exists(key):
        return None
    raw = fs.cat(key)
    if isinstance(raw, bytes):
        text = raw.decode("utf-8")
    else:
        text = str(raw)
    return json.loads(text)


def _put_bytes(fs: Any, key: str, data: bytes) -> None:
    with fs.open(key, "wb") as handle:
        handle.write(data)


def _put_file(fs: Any, key: str, path: Path) -> None:
    with path.open("rb") as src, fs.open(key, "wb") as dest:
        shutil.copyfileobj(src, dest)


def _list_run_prefixes(fs: Any, bucket: str) -> list[str]:
    prefix = f"{bucket}/{RUN_PREFIX_ROOT}="
    try:
        entries = fs.ls(bucket, detail=False)
    except FileNotFoundError:
        return []
    runs = []
    for entry in entries:
        name = str(entry).rstrip("/").split("/")[-1]
        if name.startswith(f"{RUN_PREFIX_ROOT}="):
            runs.append(name)
    return sorted(runs)


def publish_current(
    config: ProducerConfig,
    files: Mapping[str, Path],
    store_manifest: dict[str, Any],
    *,
    fs: Any,
    run_id: str | None = None,
) -> PublishResult:
    checkpoint = store_manifest.get("checkpoint") if isinstance(store_manifest.get("checkpoint"), dict) else None
    current_manifest_key = _s3_key(config.s3_bucket, CURRENT_PREFIX, "manifest.json")
    existing = _read_json(fs, current_manifest_key)
    if (
        existing is not None
        and existing.get("checkpoint") == checkpoint
        and existing.get("cli_git_sha") == CLI_GIT_SHA
    ):
        logger.info("RustFS current/ already has this store checkpoint; skipping upload")
        return PublishResult(
            run_id=str(existing.get("run_id") or ""),
            skipped=True,
            events_rows=int(existing.get("events_rows") or 0),
            issues_rows=int(existing.get("issues_rows") or 0),
            engine_version=(checkpoint or {}).get("engineVersion"),
            checkpoint=checkpoint,
        )

    run_id = run_id or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    events_rows = parquet_row_count(files["events"])
    issues_rows = parquet_row_count(files["issues"])
    payload = {
        "run_id": run_id,
        "cli_git_sha": CLI_GIT_SHA,
        "cli_git_url": CLI_GIT_URL,
        "published_at": datetime.now(timezone.utc).isoformat(),
        "checkpoint": checkpoint,
        "engine_version": (checkpoint or {}).get("engineVersion"),
        "store_generation": store_manifest.get("generation"),
        "events_rows": events_rows,
        "issues_rows": issues_rows,
        "files": {"events": "events.parquet", "issues": "issues.parquet"},
        "note": (
            "dbt must glob only current/*.parquet. objects/latest are DuckDB views, not files; "
            "data is canonical JSON text, not a nested parquet struct."
        ),
    }
    body = (json.dumps(payload, indent=2) + "\n").encode("utf-8")

    for name, path in files.items():
        key = _s3_key(config.s3_bucket, f"{RUN_PREFIX_ROOT}={run_id}", f"{name}.parquet")
        logger.info("uploading %s", key)
        _put_file(fs, key, path)
    _put_bytes(fs, _s3_key(config.s3_bucket, f"{RUN_PREFIX_ROOT}={run_id}", "manifest.json"), body)

    # Single-object overwrite of current/ is atomic per key. Manifest last so a
    # reader that checks it only sees a complete publish.
    for name, path in files.items():
        key = _s3_key(config.s3_bucket, CURRENT_PREFIX, f"{name}.parquet")
        logger.info("publishing %s", key)
        _put_file(fs, key, path)
    _put_bytes(fs, current_manifest_key, body)

    if config.keep_runs >= 0:
        runs = _list_run_prefixes(fs, config.s3_bucket)
        stale = runs[: max(0, len(runs) - config.keep_runs)]
        for name in stale:
            prefix = _s3_key(config.s3_bucket, name)
            logger.info("removing old publish %s", prefix)
            try:
                fs.rm(prefix, recursive=True)
            except Exception:
                logger.exception("failed to remove %s", prefix)

    return PublishResult(
        run_id=run_id,
        skipped=False,
        events_rows=events_rows,
        issues_rows=issues_rows,
        engine_version=(checkpoint or {}).get("engineVersion"),
        checkpoint=checkpoint,
    )


def run_producer(
    config: ProducerConfig | None = None,
    *,
    run: Callable[..., subprocess.CompletedProcess[str]] | None = None,
    fs_factory: Callable[..., Any] | None = None,
) -> PublishResult:
    config = config or load_config()
    config.data_dir.mkdir(parents=True, exist_ok=True)
    sync_store(config, run=run)
    staging = config.data_dir / "publish-staging"
    if staging.exists():
        shutil.rmtree(staging)
    files = stage_publish_files(config.store_dir, staging)
    store_manifest = read_store_manifest(config.store_dir)
    fs = open_s3(config, factory=fs_factory)
    result = publish_current(config, files, store_manifest, fs=fs)
    logger.info(
        "beefy-history publish run_id=%s skipped=%s events=%s issues=%s engine=%s",
        result.run_id,
        result.skipped,
        result.events_rows,
        result.issues_rows,
        result.engine_version,
    )
    return result
