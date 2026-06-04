#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import time
from pathlib import Path

import duckdb


TABLES = {
    "directory_index.tsv": "directory_index",
    "file_index.tsv": "file_index",
    "entity_index.tsv": "entity_index",
    "relation_index.tsv": "relation_index",
    "core/run_core.tsv": "core/run_core",
    "core/experiment_core.tsv": "core/experiment_core",
    "core/sample_core.tsv": "core/sample_core",
    "core/sample_attribute_core.tsv": "core/sample_attribute_core",
    "core/study_core.tsv": "core/study_core",
    "core/submission_core.tsv": "core/submission_core",
    "core/analysis_core.tsv": "core/analysis_core",
    "fields/xml_field_long_selected.tsv": "fields/xml_field_long_selected",
}


def chunk_glob(chunks_root: Path, rel_tsv: str) -> str:
    return str(chunks_root / "chunk_*" / rel_tsv)


def read_tsv_relation(glob: str) -> str:
    return f"""
    read_csv(
      '{glob}',
      delim='\\t',
      header=true,
      all_varchar=true,
      quote='',
      escape='',
      strict_mode=true
    )
    """


def tsv_data_rows(chunks_root: Path, rel_tsv: str) -> int:
    total = 0
    for path in chunks_root.glob(f"chunk_*/{rel_tsv}"):
        with path.open("rb") as handle:
            lines = sum(1 for _ in handle)
        total += max(0, lines - 1)
    return total


def convert_regular_table(con: duckdb.DuckDBPyConnection, chunks_root: Path, parquet_root: Path, rel_tsv: str, rel_out: str) -> dict:
    glob = chunk_glob(chunks_root, rel_tsv)
    out_dir = parquet_root / rel_out
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / "data.parquet"
    con.execute(
        f"""
        COPY (
          SELECT * FROM {read_tsv_relation(glob)}
        )
        TO '{out_file}'
        (FORMAT PARQUET, COMPRESSION ZSTD, COMPRESSION_LEVEL 3)
        """
    )
    parquet_rows = con.execute(f"SELECT COUNT(*) FROM read_parquet('{out_file}')").fetchone()[0]
    expected_rows = tsv_data_rows(chunks_root, rel_tsv)
    return {
        "tsv_data_rows": expected_rows,
        "parquet_rows": int(parquet_rows),
        "row_match": int(parquet_rows) == expected_rows,
        "bytes": out_file.stat().st_size,
    }


def convert_inventory(con: duckdb.DuckDBPyConnection, chunks_root: Path, parquet_root: Path) -> dict:
    rel_tsv = "inventory/xml_path_inventory.tsv"
    glob = chunk_glob(chunks_root, rel_tsv)
    out_dir = parquet_root / "inventory/xml_path_inventory"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / "data.parquet"
    con.execute(
        f"""
        COPY (
          SELECT
            xml_kind,
            entity_type,
            field_path,
            attribute_name,
            value_kind,
            SUM(CAST(occurrence_count AS BIGINT)) AS occurrence_count,
            SUM(CAST(non_empty_count AS BIGINT)) AS non_empty_count,
            ANY_VALUE(example_value) FILTER (WHERE example_value <> '') AS example_value,
            BOOL_OR(value_truncated = 'true') AS value_truncated
          FROM {read_tsv_relation(glob)}
          GROUP BY xml_kind, entity_type, field_path, attribute_name, value_kind
        )
        TO '{out_file}'
        (FORMAT PARQUET, COMPRESSION ZSTD, COMPRESSION_LEVEL 3)
        """
    )
    parquet_rows = con.execute(f"SELECT COUNT(*) FROM read_parquet('{out_file}')").fetchone()[0]
    source_rows = tsv_data_rows(chunks_root, rel_tsv)
    return {"source_tsv_rows": source_rows, "parquet_rows": int(parquet_rows), "bytes": out_file.stat().st_size}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--chunks-root", required=True, type=Path)
    parser.add_argument("--parquet-root", required=True, type=Path)
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--threads", type=int, default=16)
    args = parser.parse_args()
    if args.overwrite and args.parquet_root.exists():
        shutil.rmtree(args.parquet_root)
    args.parquet_root.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect()
    con.execute(f"PRAGMA threads={args.threads}")
    summary: dict[str, object] = {"tables": {}, "threads": args.threads}
    t0 = time.time()
    for rel_tsv, rel_out in TABLES.items():
        if not list(args.chunks_root.glob(f"chunk_*/{rel_tsv}")):
            continue
        result = convert_regular_table(con, args.chunks_root, args.parquet_root, rel_tsv, rel_out)
        summary["tables"][rel_out] = result
        if not result["row_match"]:
            (args.parquet_root / "conversion_summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
            raise RuntimeError(f"row count mismatch for {rel_out}: {result}")
    if list(args.chunks_root.glob("chunk_*/inventory/xml_path_inventory.tsv")):
        summary["tables"]["inventory/xml_path_inventory"] = convert_inventory(con, args.chunks_root, args.parquet_root)
    summary["elapsed_seconds"] = time.time() - t0
    (args.parquet_root / "conversion_summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

