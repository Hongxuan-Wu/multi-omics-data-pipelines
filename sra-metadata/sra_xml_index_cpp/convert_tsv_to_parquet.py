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
    "inventory/xml_path_inventory.tsv": "inventory/xml_path_inventory",
}


def read_tsv_relation(path: Path) -> str:
    return f"""
    read_csv(
      '{path}',
      delim='\\t',
      header=true,
      all_varchar=true,
      quote='',
      escape='',
      strict_mode=true
    )
    """


def tsv_data_rows(path: Path) -> int:
    with path.open("rb") as handle:
        lines = sum(1 for _ in handle)
    return max(0, lines - 1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tsv-root", required=True, type=Path)
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
        src = args.tsv_root / rel_tsv
        if not src.exists():
            continue
        out_dir = args.parquet_root / rel_out
        out_dir.mkdir(parents=True, exist_ok=True)
        out_file = out_dir / "data.parquet"
        relation = read_tsv_relation(src)
        con.execute(
            f"""
            COPY (
              SELECT * FROM {relation}
            )
            TO '{out_file}'
            (FORMAT PARQUET, COMPRESSION ZSTD, COMPRESSION_LEVEL 3)
            """
        )
        rows = con.execute(f"SELECT COUNT(*) FROM read_parquet('{out_file}')").fetchone()[0]
        expected_rows = tsv_data_rows(src)
        row_match = int(rows) == int(expected_rows)
        summary["tables"][rel_out] = {
            "tsv_data_rows": expected_rows,
            "parquet_rows": rows,
            "row_match": row_match,
            "bytes": out_file.stat().st_size,
        }
        if not row_match:
            (args.parquet_root / "conversion_summary.json").write_text(
                json.dumps(summary, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
            raise RuntimeError(f"row count mismatch for {rel_out}: tsv={expected_rows} parquet={rows}")

    summary["elapsed_seconds"] = time.time() - t0

    relation = args.parquet_root / "relation_index" / "data.parquet"
    entity = args.parquet_root / "entity_index" / "data.parquet"
    qc: dict[str, object] = {}
    file_index = args.parquet_root / "file_index" / "data.parquet"
    if relation.exists() and entity.exists():
        for relation_type, dst_type in [
            ("RUN_TO_EXPERIMENT", "EXPERIMENT"),
            ("EXPERIMENT_TO_SAMPLE", "SAMPLE"),
            ("EXPERIMENT_TO_STUDY", "STUDY"),
        ]:
            total, closed, target_xml_exists, target_xml_exists_closed = con.execute(
                f"""
                WITH r AS (
                  SELECT dst_accession, directory_accession FROM read_parquet('{relation}')
                  WHERE relation_type = '{relation_type}' AND dst_accession <> ''
                ),
                e AS (
                  SELECT entity_accession FROM read_parquet('{entity}')
                  WHERE entity_type = '{dst_type}'
                ),
                f AS (
                  SELECT DISTINCT directory_accession
                  FROM read_parquet('{file_index}')
                  WHERE xml_kind = lower('{dst_type}')
                )
                SELECT
                  COUNT(*),
                  SUM(CASE WHEN e.entity_accession IS NOT NULL THEN 1 ELSE 0 END),
                  SUM(CASE WHEN f.directory_accession IS NOT NULL THEN 1 ELSE 0 END),
                  SUM(CASE WHEN f.directory_accession IS NOT NULL AND e.entity_accession IS NOT NULL THEN 1 ELSE 0 END)
                FROM r
                LEFT JOIN e ON r.dst_accession = e.entity_accession
                LEFT JOIN f ON r.directory_accession = f.directory_accession
                """
            ).fetchone()
            total = int(total or 0)
            closed = int(closed or 0)
            target_xml_exists = int(target_xml_exists or 0)
            target_xml_exists_closed = int(target_xml_exists_closed or 0)
            qc[relation_type] = {
                "dst_type": dst_type,
                "total_refs": total,
                "closed_refs": closed,
                "overall_closure_rate": float(closed / total) if total else None,
                "target_xml_exists_refs": target_xml_exists,
                "target_xml_exists_closed_refs": target_xml_exists_closed,
                "target_xml_exists_closure_rate": float(target_xml_exists_closed / target_xml_exists) if target_xml_exists else None,
                "target_xml_missing_unclosed_refs": max(0, total - target_xml_exists),
            }
    missing_qc = {}
    for table_rel, cols in {
        "core/experiment_core": ["library_strategy", "library_source", "library_selection", "platform", "instrument_model"],
        "core/sample_core": ["bio_sample_id", "taxon_id", "scientific_name"],
        "core/study_core": ["bioproject_id", "study_type", "existing_study_type"],
    }.items():
        table_path = args.parquet_root / table_rel / "data.parquet"
        if not table_path.exists():
            continue
        for col in cols:
            total, missing = con.execute(
                f"""
                SELECT COUNT(*), SUM(CASE WHEN {col} IS NULL OR {col} = '' THEN 1 ELSE 0 END)
                FROM read_parquet('{table_path}')
                """
            ).fetchone()
            total = int(total or 0)
            missing = int(missing or 0)
            missing_qc[f"{table_rel}.{col}"] = {
                "total": total,
                "missing": missing,
                "missing_rate": float(missing / total) if total else None,
            }
    summary["qc"] = qc
    summary["missing_qc"] = missing_qc
    (args.parquet_root / "conversion_summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
