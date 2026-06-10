#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import duckdb
import pyarrow as pa
import pyarrow.parquet as pq

from build_targeted_fixture_v1 import (
    GLOBAL_TABLES,
    digest_file,
    table_schema,
    utc_now,
    write_failed_chunks,
    write_table,
)
from validate_schema import load_contract


DERIVED_TABLES = {"build_manifest", "chunk_status_summary", "entity_index", "relation_index", "relation_closure_qc"}


def q(path: Path) -> str:
    return str(path).replace("'", "''")


def sql_list(paths: list[Path]) -> str:
    return "[" + ", ".join(f"'{q(path)}'" for path in paths) + "]"


def done_chunk_roots(output_root: Path) -> list[Path]:
    return sorted((output_root / "chunks").glob("*.done"))


def load_status(done_roots: list[Path]) -> list[dict[str, Any]]:
    rows = []
    for done in done_roots:
        status_path = done / "chunk_status.json"
        if not status_path.exists():
            raise FileNotFoundError(f"missing chunk_status.json: {status_path}")
        rows.append(json.loads(status_path.read_text(encoding="utf-8")))
    return sorted(rows, key=lambda row: row["start_row"])


def chunk_status_summary_row(status: dict[str, Any]) -> dict[str, Any]:
    return {
        "chunk_id": status["chunk_id"],
        "start_row": status["start_row"],
        "row_count": status["row_count"],
        "started_at": datetime.fromisoformat(status["started_at"].rstrip("Z")),
        "finished_at": datetime.fromisoformat(status["finished_at"].rstrip("Z")),
        "exit_code": status["exit_code"],
        "parser_version": status["parser_version"],
        "schema_version": status["schema_version"],
        "input_manifest_hash": status["input_manifest_hash"],
        "output_tables": json.dumps(status["output_tables"], sort_keys=True),
        "row_counts_by_table": json.dumps(status["row_counts_by_table"], sort_keys=True),
        "warning_count": status["warning_count"],
        "error_count": status["error_count"],
    }


def expected_counts(status_rows: list[dict[str, Any]]) -> Counter[str]:
    counts: Counter[str] = Counter()
    for status in status_rows:
        if status.get("exit_code") != 0:
            continue
        for table_name, count in status["row_counts_by_table"].items():
            if table_name not in GLOBAL_TABLES:
                counts[table_name] += int(count)
    return counts


def chunk_table_paths(contract: dict[str, Any], done_roots: list[Path], table_name: str) -> list[Path]:
    rel = contract["tables"][table_name]["path"]
    paths = [done / rel for done in done_roots]
    missing = [path for path in paths if not path.exists()]
    if missing:
        raise FileNotFoundError(f"missing {table_name} chunk table, first missing: {missing[0]}")
    return paths


def copy_to_parquet(con: duckdb.DuckDBPyConnection, query: str, output_path: Path, tmp_root: Path) -> int:
    raise NotImplementedError("use copy_query_to_parquet with a schema contract table name")


def empty_table(schema: pa.Schema) -> pa.Table:
    return pa.Table.from_arrays([pa.array([], type=field.type) for field in schema], schema=schema)


def validate_tmp_parquet(tmp_path: Path, expected_schema: pa.Schema, expected_rows: int) -> None:
    try:
        parquet_file = pq.ParquetFile(tmp_path)
    except Exception as exc:
        raise RuntimeError(f"tmp parquet is not readable: {tmp_path}") from exc

    actual_rows = parquet_file.metadata.num_rows
    if actual_rows != expected_rows:
        raise RuntimeError(f"tmp parquet row count mismatch for {tmp_path}: {actual_rows} != {expected_rows}")

    actual_schema = parquet_file.schema_arrow
    if actual_schema.names != expected_schema.names:
        raise RuntimeError(f"tmp parquet schema names mismatch for {tmp_path}: {actual_schema.names} != {expected_schema.names}")
    for actual_field, expected_field in zip(actual_schema, expected_schema):
        if actual_field.type != expected_field.type:
            raise RuntimeError(
                f"tmp parquet schema type mismatch for {tmp_path}.{expected_field.name}: "
                f"{actual_field.type} != {expected_field.type}"
            )


def copy_query_to_parquet(
    con: duckdb.DuckDBPyConnection,
    contract: dict[str, Any],
    table_name: str,
    query: str,
    output_path: Path,
    tmp_root: Path,
    rows_per_batch: int = 100_000,
) -> int:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = tmp_root / (output_path.name + ".tmp.parquet")
    if tmp_path.exists():
        tmp_path.unlink()
    expected_schema = table_schema(contract, table_name)
    reader = con.execute(query).fetch_record_batch(rows_per_batch)
    rows = 0
    writer: pq.ParquetWriter | None = None
    try:
        for batch in reader:
            table = pa.Table.from_batches([batch])
            table = table.select(expected_schema.names).cast(expected_schema)
            if writer is None:
                writer = pq.ParquetWriter(tmp_path, expected_schema)
            writer.write_table(table)
            rows += table.num_rows
        if writer is None:
            pq.write_table(empty_table(expected_schema), tmp_path)
    finally:
        if writer is not None:
            writer.close()
    validate_tmp_parquet(tmp_path, expected_schema, rows)
    os.replace(tmp_path, output_path)
    return rows


def progress(output_root: Path, stage: str, **extra: Any) -> None:
    payload = {"stage": stage, "updated_at": utc_now().isoformat() + "Z", **extra}
    (output_root / "finalize_progress.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def write_query_to_existing_writer(
    con: duckdb.DuckDBPyConnection,
    contract: dict[str, Any],
    table_name: str,
    query: str,
    writer: pq.ParquetWriter,
    rows_per_batch: int = 100_000,
) -> int:
    expected_schema = table_schema(contract, table_name)
    rows = 0
    reader = con.execute(query).fetch_record_batch(rows_per_batch)
    for batch in reader:
        table = pa.Table.from_batches([batch])
        table = table.select(expected_schema.names).cast(expected_schema)
        writer.write_table(table)
        rows += table.num_rows
    return rows


def compact_table(con: duckdb.DuckDBPyConnection, contract: dict[str, Any], output_root: Path, tmp_root: Path, done_roots: list[Path], table_name: str) -> int:
    paths = chunk_table_paths(contract, done_roots, table_name)
    output_path = output_root / contract["tables"][table_name]["path"]
    return copy_query_to_parquet(con, contract, table_name, f"SELECT * FROM read_parquet({sql_list(paths)})", output_path, tmp_root)


def build_entity_index(con: duckdb.DuckDBPyConnection, contract: dict[str, Any], output_root: Path, tmp_root: Path) -> int:
    output_path = output_root / contract["tables"]["entity_index"]["path"]
    source = output_root / contract["tables"]["entity_record_index"]["path"]
    query = f"""
    WITH base AS (
        SELECT *
        FROM read_parquet('{q(source)}')
        WHERE entity_accession IS NOT NULL AND entity_accession <> ''
    ),
    ranked AS (
        SELECT
            *,
            row_number() OVER (
                PARTITION BY source_snapshot_id, entity_type, entity_accession
                ORDER BY
                    CASE WHEN occurrence_role = 'primary' AND parse_status = 'ok' THEN 0 ELSE 1 END,
                    directory_accession,
                    file_id,
                    entity_ordinal,
                    entity_record_id
            ) AS rn
        FROM base
    ),
    grouped AS (
        SELECT
            source_snapshot_id,
            entity_accession,
            entity_type,
            count(*)::BIGINT AS record_count,
            sum(CASE WHEN occurrence_role = 'primary' AND parse_status = 'ok' THEN 1 ELSE 0 END)::BIGINT AS primary_record_count,
            count(DISTINCT file_id)::BIGINT AS file_count,
            count(DISTINCT directory_id)::BIGINT AS directory_count
        FROM base
        GROUP BY source_snapshot_id, entity_accession, entity_type
    ),
    canonical AS (
        SELECT
            source_snapshot_id,
            entity_accession,
            entity_type,
            entity_record_id AS canonical_entity_record_id,
            file_id AS canonical_file_id,
            directory_id AS canonical_directory_id,
            occurrence_role,
            parse_status
        FROM ranked
        WHERE rn = 1
    )
    SELECT
        g.source_snapshot_id,
        g.entity_accession,
        g.entity_type,
        g.record_count,
        g.primary_record_count,
        (g.record_count - g.primary_record_count)::BIGINT AS reference_record_count,
        (g.primary_record_count > 0) AS has_primary_record,
        (g.record_count > g.primary_record_count) AS has_reference_record,
        CASE WHEN g.primary_record_count > 0 THEN 'primary_present' ELSE 'reference_only' END AS entity_presence_status,
        g.file_count,
        g.directory_count,
        CASE WHEN g.primary_record_count > 0 THEN c.canonical_entity_record_id ELSE NULL END AS canonical_entity_record_id,
        CASE WHEN g.primary_record_count > 0 THEN c.canonical_file_id ELSE NULL END AS canonical_file_id,
        CASE WHEN g.primary_record_count > 0 THEN c.canonical_directory_id ELSE NULL END AS canonical_directory_id,
        CASE WHEN g.primary_record_count > 0 THEN 'first_primary_by_manifest_order' ELSE 'none_reference_only' END AS canonical_rule,
        false AS has_conflict,
        NULL::VARCHAR AS conflict_type,
        0::BIGINT AS conflict_field_count
    FROM grouped g
    JOIN canonical c
      ON g.source_snapshot_id = c.source_snapshot_id
     AND g.entity_type = c.entity_type
     AND g.entity_accession = c.entity_accession
    ORDER BY g.entity_type, g.entity_accession
    """
    return copy_query_to_parquet(con, contract, "entity_index", query, output_path, tmp_root)


def load_primary_entity_lookup(contract: dict[str, Any], output_root: Path, batch_size: int) -> dict[str, str]:
    entity_index_path = output_root / contract["tables"]["entity_index"]["path"]
    lookup: dict[str, str] = {}
    pf = pq.ParquetFile(entity_index_path)
    for batch in pf.iter_batches(
        batch_size=batch_size,
        columns=["entity_type", "entity_accession", "canonical_entity_record_id", "has_primary_record"],
    ):
        data = pa.Table.from_batches([batch]).to_pydict()
        for entity_type, accession, record_id, has_primary in zip(
            data["entity_type"],
            data["entity_accession"],
            data["canonical_entity_record_id"],
            data["has_primary_record"],
        ):
            if has_primary and entity_type and accession and record_id:
                lookup[f"{entity_type}\x1f{accession}"] = record_id
    return lookup


def build_relation_index(
    con: duckdb.DuckDBPyConnection,
    contract: dict[str, Any],
    output_root: Path,
    tmp_root: Path,
    done_roots: list[Path],
    batch_size: int,
) -> int:
    output_path = output_root / contract["tables"]["relation_index"]["path"]
    relation_paths = chunk_table_paths(contract, done_roots, "relation_index")
    progress(output_root, "build_primary_entity_lookup_start")
    lookup = load_primary_entity_lookup(contract, output_root, batch_size)
    progress(output_root, "build_primary_entity_lookup_done", lookup_count=len(lookup))

    tmp_path = tmp_root / (output_path.name + ".tmp.parquet")
    if tmp_path.exists():
        tmp_path.unlink()
    expected_schema = table_schema(contract, "relation_index")
    writer = pq.ParquetWriter(tmp_path, expected_schema)
    total_rows = 0
    try:
        for idx, relation_path in enumerate(relation_paths, start=1):
            pf = pq.ParquetFile(relation_path)
            chunk_rows = 0
            for batch in pf.iter_batches(batch_size=batch_size):
                table = pa.Table.from_batches([batch])
                data = table.to_pydict()
                dst_record_ids: list[str | None] = []
                dst_primary_exists: list[bool] = []
                dst_status: list[str] = []
                closure_status: list[str] = []
                for is_internal, dst_type, dst_accession in zip(
                    data["dst_is_internal_entity"],
                    data["dst_type"],
                    data["dst_accession"],
                ):
                    if not is_internal:
                        dst_record_ids.append(None)
                        dst_primary_exists.append(False)
                        dst_status.append("external_reference")
                        closure_status.append("external_reference")
                        continue
                    record_id = lookup.get(f"{dst_type}\x1f{dst_accession}")
                    if record_id:
                        dst_record_ids.append(record_id)
                        dst_primary_exists.append(True)
                        dst_status.append("primary_present")
                        closure_status.append("closed")
                    else:
                        dst_record_ids.append(None)
                        dst_primary_exists.append(False)
                        dst_status.append("missing_dst_entity")
                        closure_status.append("missing_dst_entity")
                data["dst_entity_record_id"] = dst_record_ids
                data["dst_primary_exists"] = dst_primary_exists
                data["dst_entity_index_status"] = dst_status
                data["closure_status"] = closure_status
                out = pa.Table.from_pydict(data).select(expected_schema.names).cast(expected_schema)
                writer.write_table(out)
                chunk_rows += out.num_rows
                total_rows += out.num_rows
            if idx == 1 or idx % 10 == 0 or idx == len(relation_paths):
                progress(output_root, "build_relation_index_batch", batch=idx, total_batches=len(relation_paths), chunk_rows=chunk_rows, rows_written=total_rows)
    finally:
        writer.close()
    validate_tmp_parquet(tmp_path, expected_schema, total_rows)
    os.replace(tmp_path, output_path)
    return total_rows


def build_relation_closure_qc(con: duckdb.DuckDBPyConnection, contract: dict[str, Any], output_root: Path, tmp_root: Path, snapshot: str) -> int:
    output_path = output_root / contract["tables"]["relation_closure_qc"]["path"]
    relation_source = output_root / contract["tables"]["relation_index"]["path"]
    query = f"""
    SELECT
        '{snapshot}' AS source_snapshot_id,
        relation_type,
        src_type,
        dst_type,
        sum(CASE WHEN dst_is_internal_entity THEN 1 ELSE 0 END)::BIGINT AS internal_relation_count,
        sum(CASE WHEN dst_is_internal_entity AND closure_status = 'closed' THEN 1 ELSE 0 END)::BIGINT AS closed_count,
        CASE
            WHEN sum(CASE WHEN dst_is_internal_entity THEN 1 ELSE 0 END) = 0 THEN NULL
            ELSE
                sum(CASE WHEN dst_is_internal_entity AND closure_status = 'closed' THEN 1 ELSE 0 END)::DOUBLE
                / sum(CASE WHEN dst_is_internal_entity THEN 1 ELSE 0 END)::DOUBLE
        END AS closure_rate,
        CASE
            WHEN relation_type IN ('RUN_TO_EXPERIMENT', 'EXPERIMENT_TO_SAMPLE', 'EXPERIMENT_TO_STUDY')
             AND sum(CASE WHEN dst_is_internal_entity THEN 1 ELSE 0 END) > 0
             AND sum(CASE WHEN dst_is_internal_entity AND closure_status = 'closed' THEN 1 ELSE 0 END) = 0
            THEN 'hard_fail'
            ELSE 'report_only'
        END AS severity
    FROM read_parquet('{q(relation_source)}')
    GROUP BY relation_type, src_type, dst_type
    ORDER BY relation_type, src_type, dst_type
    """
    return copy_query_to_parquet(con, contract, "relation_closure_qc", query, output_path, tmp_root)


def update_build_manifest(contract: dict[str, Any], output_root: Path, status: str) -> None:
    path = output_root / contract["tables"]["build_manifest"]["path"]
    rows = pq.read_table(path).to_pylist()
    if not rows:
        raise RuntimeError(f"empty build manifest: {path}")
    row = rows[0]
    row["build_status"] = status
    row["finished_at"] = utc_now()
    write_table(contract, output_root, "build_manifest", [row])


def main() -> int:
    parser = argparse.ArgumentParser(description="Finalize an existing chunked SRA XML build without rerunning parser chunks.")
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--schema", type=Path, default=Path(__file__).resolve().parents[1] / "schema" / "v1" / "schema.json")
    parser.add_argument("--source-snapshot-id", default="20260516")
    parser.add_argument("--duckdb-temp-dir", type=Path, default=None)
    parser.add_argument("--duckdb-memory-limit", default="1500GB")
    parser.add_argument("--duckdb-threads", type=int, default=32)
    parser.add_argument("--relation-batch-size", type=int, default=100_000)
    args = parser.parse_args()

    started = time.time()
    contract = load_contract(args.schema)
    output_root = args.output_root
    tmp_root = output_root / "tmp" / f"finalize_{os.getpid()}"
    if tmp_root.exists():
        shutil.rmtree(tmp_root)
    tmp_root.mkdir(parents=True, exist_ok=True)
    timings: dict[str, float] = {}
    done_roots = done_chunk_roots(output_root)
    status = load_status(done_roots)
    failures = [
        {
            "chunk_id": row["chunk_id"],
            "start_row": row["start_row"],
            "row_count": row["row_count"],
            "exit_code": row["exit_code"],
            "error_type": row.get("error_type", "unknown"),
            "log_path": str(output_root / "logs"),
            "retry_count": 0,
        }
        for row in status
        if row.get("exit_code") != 0
    ]
    write_failed_chunks(output_root / "failed_chunks.tsv", failures)
    if failures:
        update_build_manifest(contract, output_root, "failed")
        raise RuntimeError(f"{len(failures)} chunk(s) failed; not finalizing")

    expected = expected_counts(status)
    con = duckdb.connect()
    con.execute(f"PRAGMA threads={args.duckdb_threads}")
    con.execute(f"PRAGMA memory_limit='{args.duckdb_memory_limit}'")
    temp_dir = args.duckdb_temp_dir or (output_root / "tmp" / "duckdb")
    temp_dir.mkdir(parents=True, exist_ok=True)
    con.execute(f"PRAGMA temp_directory='{q(temp_dir)}'")

    try:
        t0 = time.time()
        progress(output_root, "write_chunk_status_summary_start", chunks=len(status))
        write_table(contract, output_root, "chunk_status_summary", [chunk_status_summary_row(row) for row in status])
        timings["chunk_status_summary_seconds"] = time.time() - t0
        progress(output_root, "write_chunk_status_summary_done", seconds=timings["chunk_status_summary_seconds"])

        compact_tables = [
            name
            for name in contract["tables"]
            if name not in DERIVED_TABLES and name not in {"directory_manifest", "chunk_manifest"}
        ]
        t0 = time.time()
        final_counts: dict[str, int] = {}
        for table_name in compact_tables:
            progress(output_root, "compact_table_start", table=table_name)
            final_counts[table_name] = compact_table(con, contract, output_root, tmp_root, done_roots, table_name)
            if final_counts[table_name] != expected.get(table_name, 0):
                raise RuntimeError(f"compact row count mismatch for {table_name}: {final_counts[table_name]} != {expected.get(table_name, 0)}")
            progress(output_root, "compact_table_done", table=table_name, rows=final_counts[table_name])
        timings["compact_seconds"] = time.time() - t0
        progress(output_root, "compact_all_done", seconds=timings["compact_seconds"])

        t0 = time.time()
        progress(output_root, "entity_index_start")
        final_counts["entity_index"] = build_entity_index(con, contract, output_root, tmp_root)
        duplicate_count = con.execute(
            f"""
            SELECT count(*)
            FROM (
                SELECT source_snapshot_id, entity_type, entity_accession, count(*) AS n
                FROM read_parquet('{q(output_root / contract["tables"]["entity_index"]["path"])}')
                GROUP BY source_snapshot_id, entity_type, entity_accession
                HAVING n > 1
            )
            """
        ).fetchone()[0]
        if duplicate_count:
            raise RuntimeError(f"canonical entity key duplicates: {duplicate_count}")
        timings["entity_index_seconds"] = time.time() - t0
        progress(output_root, "entity_index_done", rows=final_counts["entity_index"], seconds=timings["entity_index_seconds"])

        t0 = time.time()
        progress(output_root, "relation_index_start")
        final_counts["relation_index"] = build_relation_index(con, contract, output_root, tmp_root, done_roots, args.relation_batch_size)
        if final_counts["relation_index"] != expected.get("relation_index", 0):
            raise RuntimeError(f"relation_index row count mismatch: {final_counts['relation_index']} != {expected.get('relation_index', 0)}")
        timings["relation_index_seconds"] = time.time() - t0
        progress(output_root, "relation_index_done", rows=final_counts["relation_index"], seconds=timings["relation_index_seconds"])

        t0 = time.time()
        progress(output_root, "relation_closure_qc_start")
        final_counts["relation_closure_qc"] = build_relation_closure_qc(con, contract, output_root, tmp_root, args.source_snapshot_id)
        hard_fails = con.execute(
            f"SELECT count(*) FROM read_parquet('{q(output_root / contract['tables']['relation_closure_qc']['path'])}') WHERE severity = 'hard_fail'"
        ).fetchone()[0]
        if hard_fails:
            raise RuntimeError(f"relation closure hard failures: {hard_fails}")
        timings["relation_closure_qc_seconds"] = time.time() - t0
        progress(output_root, "relation_closure_qc_done", rows=final_counts["relation_closure_qc"], seconds=timings["relation_closure_qc_seconds"])

        update_build_manifest(contract, output_root, "succeeded")
        timings["total_seconds"] = time.time() - started
        timings["final_counts"] = final_counts
        timings["schema_contract_hash"] = digest_file(args.schema)
        (output_root / "build_timing.json").write_text(json.dumps(timings, ensure_ascii=False, indent=2), encoding="utf-8")
    except Exception:
        update_build_manifest(contract, output_root, "failed")
        raise
    finally:
        con.close()

    print(json.dumps({"output_root": str(output_root), "status": "succeeded", "timings": timings}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
