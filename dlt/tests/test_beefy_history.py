from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pyarrow as pa
import pyarrow.parquet as pq
import pytest

from lib.beefy_history import (
    CLI_GIT_SHA,
    EVENT_COLUMNS,
    ISSUE_COLUMNS,
    BeefyHistoryError,
    ProducerConfig,
    assert_parquet_columns,
    load_config,
    publish_current,
    read_store_manifest,
    stage_publish_files,
    sync_store,
    write_empty_issues_parquet,
)


def _config(tmp_path: Path, **overrides: Any) -> ProducerConfig:
    data = tmp_path / "data"
    cli = tmp_path / "cli"
    (cli / "packages" / "core" / "src").mkdir(parents=True)
    (cli / "packages" / "core" / "src" / "cli.ts").write_text("// stub\n")
    values = dict(
        data_dir=data,
        repos_dir=data / "repos",
        store_dir=data / "store",
        cli_dir=cli,
        node_bin="node",
        s3_endpoint="http://rustfs:9000",
        s3_bucket="beefy-history",
        s3_access_key="admin",
        s3_secret_key="secret",
        fetch=False,
        keep_runs=2,
    )
    values.update(overrides)
    return ProducerConfig(**values)


def _write_parquet(path: Path, columns: tuple[str, ...], extra: dict[str, list[Any]] | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data: dict[str, list[Any]] = {}
    for name in columns:
        if name in {"seq", "committedAt", "authoredAt"}:
            data[name] = [1]
        elif name == "changedKeys":
            data[name] = [["status"]]
        else:
            data[name] = ["x"]
    if extra:
        data.update(extra)
        # keep row count 1 for extra scalar columns
        for key, value in list(data.items()):
            if key not in extra:
                continue
            if value and not isinstance(value[0], list):
                data[key] = value
    table = pa.table(data)
    pq.write_table(table, path)


class MemoryS3:
    def __init__(self) -> None:
        self.objects: dict[str, bytes] = {}

    def exists(self, key: str) -> bool:
        return key in self.objects

    def cat(self, key: str) -> bytes:
        return self.objects[key]

    def open(self, key: str, mode: str):
        fs = self

        class _Handle:
            def __init__(self) -> None:
                self.chunks: list[bytes] = []

            def write(self, data: bytes) -> int:
                self.chunks.append(data)
                return len(data)

            def __enter__(self) -> "_Handle":
                return self

            def __exit__(self, *args: object) -> None:
                fs.objects[key] = b"".join(self.chunks)

        return _Handle()

    def ls(self, bucket: str, detail: bool = False) -> list[str]:
        prefixes: set[str] = set()
        for key in self.objects:
            if key.startswith(bucket + "/"):
                prefixes.add(key.split("/")[1])
        return [f"{bucket}/{name}" for name in sorted(prefixes)]

    def rm(self, prefix: str, recursive: bool = False) -> None:
        dead = [key for key in self.objects if key == prefix or key.startswith(prefix.rstrip("/") + "/")]
        for key in dead:
            del self.objects[key]


def test_load_config_reuses_rustfs_keys(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv("STORAGE_DIR", str(tmp_path))
    monkeypatch.setenv("RUSTFS_ACCESS_KEY", "rk")
    monkeypatch.setenv("RUSTFS_SECRET_KEY", "rs")
    monkeypatch.delenv("BEEFY_HISTORY_S3_SECRET_KEY", raising=False)
    monkeypatch.delenv("CLICKHOUSE_BACKUP_S3_SECRET_KEY", raising=False)
    cfg = load_config()
    assert cfg.s3_bucket == "beefy-history"
    assert cfg.s3_access_key == "rk"
    assert cfg.s3_secret_key == "rs"
    assert cfg.data_dir == tmp_path / "beefy-history"
    assert cfg.s3_bucket != "clickhouse-backups"


def test_schema_contract_rejects_missing_column(tmp_path: Path) -> None:
    path = tmp_path / "events.parquet"
    _write_parquet(path, EVENT_COLUMNS[:-1])
    with pytest.raises(BeefyHistoryError, match="missing columns"):
        assert_parquet_columns(path, EVENT_COLUMNS, table="events")


def test_schema_contract_allows_extra_columns(tmp_path: Path) -> None:
    path = tmp_path / "events.parquet"
    _write_parquet(path, EVENT_COLUMNS, extra={"bonus": ["y"]})
    assert_parquet_columns(path, EVENT_COLUMNS, table="events")


def test_stage_publish_files_flattens_compact_names(tmp_path: Path) -> None:
    store = tmp_path / "store"
    events = store / "events" / "base-000012.parquet"
    issues = store / "issues" / "issues-000012.parquet"
    _write_parquet(events, EVENT_COLUMNS)
    _write_parquet(issues, ISSUE_COLUMNS)
    (store / "manifest.json").write_text(
        json.dumps(
            {
                "generation": 12,
                "checkpoint": {"engineVersion": "beefy-history/4+engine/5+parse/3", "lastEventSeq": 1},
                "events": [{"file": "events/base-000012.parquet"}],
                "issues": [{"file": "issues/issues-000012.parquet"}],
            }
        )
    )
    out = stage_publish_files(store, tmp_path / "staging")
    assert out["events"].name == "events.parquet"
    assert out["issues"].name == "issues.parquet"
    assert pq.read_schema(out["events"]).names[1] == "objectId"


def test_stage_publish_files_writes_empty_issues_when_absent(tmp_path: Path) -> None:
    store = tmp_path / "store"
    events = store / "events" / "base-000001.parquet"
    _write_parquet(events, EVENT_COLUMNS)
    (store / "manifest.json").write_text(
        json.dumps({"events": [{"file": "events/base-000001.parquet"}], "issues": []})
    )
    out = stage_publish_files(store, tmp_path / "staging")
    assert pq.ParquetFile(out["issues"]).metadata.num_rows == 0
    assert list(pq.read_schema(out["issues"]).names) == list(ISSUE_COLUMNS)


def test_publish_writes_run_then_current(tmp_path: Path) -> None:
    cfg = _config(tmp_path)
    files = {
        "events": tmp_path / "events.parquet",
        "issues": tmp_path / "issues.parquet",
    }
    _write_parquet(files["events"], EVENT_COLUMNS)
    write_empty_issues_parquet(files["issues"])
    fs = MemoryS3()
    result = publish_current(
        cfg,
        files,
        {"generation": 1, "checkpoint": {"lastEventSeq": 9, "engineVersion": "beefy-history/4+engine/5+parse/3"}},
        fs=fs,
        run_id="r1",
    )
    assert result.skipped is False
    assert fs.exists("beefy-history/run=r1/events.parquet")
    assert fs.exists("beefy-history/current/events.parquet")
    assert fs.exists("beefy-history/current/manifest.json")
    manifest = json.loads(fs.cat("beefy-history/current/manifest.json"))
    assert manifest["cli_git_sha"] == CLI_GIT_SHA
    assert manifest["checkpoint"]["lastEventSeq"] == 9
    assert "clickhouse-backups" not in fs.objects


def test_publish_skips_identical_checkpoint(tmp_path: Path) -> None:
    cfg = _config(tmp_path)
    files = {
        "events": tmp_path / "events.parquet",
        "issues": tmp_path / "issues.parquet",
    }
    _write_parquet(files["events"], EVENT_COLUMNS)
    write_empty_issues_parquet(files["issues"])
    checkpoint = {"lastEventSeq": 9, "engineVersion": "beefy-history/4+engine/5+parse/3"}
    fs = MemoryS3()
    publish_current(cfg, files, {"checkpoint": checkpoint}, fs=fs, run_id="r1")
    again = publish_current(cfg, files, {"checkpoint": checkpoint}, fs=fs, run_id="r2")
    assert again.skipped is True
    assert "beefy-history/run=r2/events.parquet" not in fs.objects


def test_sync_store_rebuilds_into_fresh_out(tmp_path: Path) -> None:
    cfg = _config(tmp_path)
    leftover = cfg.store_dir / "stale.txt"
    leftover.parent.mkdir(parents=True)
    leftover.write_text("nope")
    calls: list[list[str]] = []

    def fake_run(cmd: list[str], **kwargs: Any) -> Any:
        calls.append(cmd)

        class Result:
            returncode = 0
            stdout = "ok"
            stderr = ""

        return Result()

    sync_store(cfg, run=fake_run)
    assert leftover.exists() is False
    assert ["sync", "--out", str(cfg.store_dir), "--repos-dir", str(cfg.repos_dir), "--no-fetch"] in [
        c[2:] for c in calls
    ]
    assert any(c[2:4] == ["compact", "--out"] for c in calls)


def test_read_store_manifest_requires_file(tmp_path: Path) -> None:
    with pytest.raises(BeefyHistoryError, match="manifest missing"):
        read_store_manifest(tmp_path)
