#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

import duckdb


FULL_DIRECTORY_COUNT = 7_609_455


def parquet(path: Path) -> str:
    return str(path / "data.parquet")


def table_count(con: duckdb.DuckDBPyConnection, path: Path) -> int:
    if not (path / "data.parquet").exists():
        return 0
    return int(con.execute(f"SELECT COUNT(*) FROM read_parquet('{parquet(path)}')").fetchone()[0])


def missing_rates(con: duckdb.DuckDBPyConnection, table_path: Path, columns: list[str]) -> dict[str, dict[str, float | int]]:
    if not (table_path / "data.parquet").exists():
        return {}
    total = table_count(con, table_path)
    result: dict[str, dict[str, float | int]] = {}
    for col in columns:
        missing = int(
            con.execute(
                f"""
                SELECT COUNT(*)
                FROM read_parquet('{parquet(table_path)}')
                WHERE {col} IS NULL OR {col} = ''
                """
            ).fetchone()[0]
        )
        result[col] = {
            "missing": missing,
            "total": total,
            "missing_rate": (missing / total) if total else None,
        }
    return result


def relation_closure(con: duckdb.DuckDBPyConnection, root: Path, relation_type: str, dst_type: str, dir_flag: str) -> dict[str, float | int | None]:
    rel = parquet(root / "relation_index")
    ent = parquet(root / "entity_index")
    direc = parquet(root / "directory_index")
    row = con.execute(
        f"""
        WITH rels AS (
          SELECT *
          FROM read_parquet('{rel}')
          WHERE relation_type = ? AND dst_accession IS NOT NULL AND dst_accession <> ''
        ),
        joined AS (
          SELECT
            r.*,
            e.entity_accession IS NOT NULL AS closed,
            d.directory_accession IS NOT NULL AND d.{dir_flag} = 'true' AS target_xml_exists
          FROM rels r
          LEFT JOIN read_parquet('{ent}') e
            ON r.dst_accession = e.entity_accession AND e.entity_type = ?
          LEFT JOIN read_parquet('{direc}') d
            ON r.dst_accession = d.directory_accession
        )
        SELECT
          COUNT(*) AS total_refs,
          SUM(CASE WHEN closed THEN 1 ELSE 0 END) AS closed_refs,
          SUM(CASE WHEN target_xml_exists THEN 1 ELSE 0 END) AS target_xml_exists_refs,
          SUM(CASE WHEN target_xml_exists AND closed THEN 1 ELSE 0 END) AS target_xml_exists_closed_refs,
          SUM(CASE WHEN NOT target_xml_exists AND NOT closed THEN 1 ELSE 0 END) AS target_xml_missing_unclosed_refs
        FROM joined
        """,
        [relation_type, dst_type],
    ).fetchone()
    total, closed, target_exists, target_exists_closed, target_missing_unclosed = [int(x or 0) for x in row]
    return {
        "relation_type": relation_type,
        "total_refs": total,
        "closed_refs": closed,
        "overall_closure_rate": (closed / total) if total else None,
        "target_xml_exists_refs": target_exists,
        "target_xml_exists_closed_refs": target_exists_closed,
        "target_xml_exists_closure_rate": (target_exists_closed / target_exists) if target_exists else None,
        "target_xml_missing_unclosed_refs": target_missing_unclosed,
    }


def parse_failure_summary(con: duckdb.DuckDBPyConnection, root: Path) -> dict[str, object]:
    file_index = parquet(root / "file_index")
    total = table_count(con, root / "file_index")
    rows = con.execute(
        f"""
        SELECT parse_status, error_type, COUNT(*) AS n
        FROM read_parquet('{file_index}')
        GROUP BY parse_status, error_type
        ORDER BY n DESC
        """
    ).fetchall()
    failed = sum(int(n) for status, _error, n in rows if status != "ok")
    return {
        "file_count": total,
        "failed_file_count": failed,
        "parse_failure_rate": (failed / total) if total else None,
        "by_status_error": [
            {"parse_status": status, "error_type": error, "count": int(n)}
            for status, error, n in rows
        ],
    }


def chunk_elapsed(chunks_root: Path) -> dict[str, float | int | None]:
    total_dirs = 0
    total_xml = 0
    elapsed_sum = 0.0
    max_elapsed = 0.0
    chunk_count = 0
    for path in chunks_root.glob("chunk_*/summary.json"):
        data = json.loads(path.read_text(encoding="utf-8"))
        dirs = int(data.get("directory_count", 0))
        elapsed = float(data.get("elapsed_seconds", 0.0))
        total_dirs += dirs
        total_xml += int(data.get("xml_file_count", 0))
        elapsed_sum += elapsed
        max_elapsed = max(max_elapsed, elapsed)
        chunk_count += 1
    return {
        "chunk_count": chunk_count,
        "directory_count_from_chunks": total_dirs,
        "xml_file_count_from_chunks": total_xml,
        "sum_chunk_elapsed_seconds": elapsed_sum,
        "max_chunk_elapsed_seconds": max_elapsed,
        "mean_seconds_per_directory_sum_chunk_time": (elapsed_sum / total_dirs) if total_dirs else None,
    }


def tree_size(path: Path) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += (Path(root) / name).stat().st_size
            except OSError:
                pass
    return total


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--parquet-root", required=True, type=Path)
    parser.add_argument("--chunks-root", required=True, type=Path)
    parser.add_argument("--out-json", required=True, type=Path)
    parser.add_argument("--out-md", required=True, type=Path)
    args = parser.parse_args()

    con = duckdb.connect()
    root = args.parquet_root
    counts = {
        "directories": table_count(con, root / "directory_index"),
        "xml_files": table_count(con, root / "file_index"),
        "entities": table_count(con, root / "entity_index"),
        "relations": table_count(con, root / "relation_index"),
        "sample_attribute_rows": table_count(con, root / "core/sample_attribute_core"),
        "selected_field_long_rows": table_count(con, root / "fields/xml_field_long_selected"),
        "path_inventory_rows": table_count(con, root / "inventory/xml_path_inventory"),
    }
    timings = chunk_elapsed(args.chunks_root)
    parquet_bytes = tree_size(root)
    scale = FULL_DIRECTORY_COUNT / counts["directories"] if counts["directories"] else None

    report = {
        "parquet_root": str(root),
        "chunks_root": str(args.chunks_root),
        "counts": counts,
        "parse_failures": parse_failure_summary(con, root),
        "relation_closure": {
            "RUN_TO_EXPERIMENT": relation_closure(con, root, "RUN_TO_EXPERIMENT", "EXPERIMENT", "has_experiment_xml"),
            "EXPERIMENT_TO_SAMPLE": relation_closure(con, root, "EXPERIMENT_TO_SAMPLE", "SAMPLE", "has_sample_xml"),
            "EXPERIMENT_TO_STUDY": relation_closure(con, root, "EXPERIMENT_TO_STUDY", "STUDY", "has_study_xml"),
        },
        "core_missing_rates": {
            "experiment_core": missing_rates(
                con,
                root / "core/experiment_core",
                ["library_strategy", "library_source", "library_selection", "platform", "instrument_model", "design_description", "center_name"],
            ),
            "sample_core": missing_rates(con, root / "core/sample_core", ["bio_sample_id", "taxon_id", "scientific_name"]),
            "study_core": missing_rates(con, root / "core/study_core", ["bioproject_id", "study_type", "existing_study_type"]),
            "submission_core": missing_rates(con, root / "core/submission_core", ["center_name", "lab_name"]),
        },
        "external_accessions": con.execute(
            f"""
            SELECT src_type, COUNT(*) AS relation_count
            FROM read_parquet('{parquet(root / "relation_index")}')
            WHERE dst_type = 'ExternalAccession'
            GROUP BY src_type
            ORDER BY relation_count DESC
            """
        ).fetchall(),
        "timings": timings,
        "parquet_bytes": parquet_bytes,
        "mean_parquet_bytes_per_directory": (parquet_bytes / counts["directories"]) if counts["directories"] else None,
        "estimated_full_parquet_bytes": int(parquet_bytes * scale) if scale else None,
        "estimated_full_sum_chunk_elapsed_seconds": timings["sum_chunk_elapsed_seconds"] * scale if scale else None,
        "full_directory_count_target": FULL_DIRECTORY_COUNT,
    }

    args.out_json.parent.mkdir(parents=True, exist_ok=True)
    args.out_md.parent.mkdir(parents=True, exist_ok=True)
    args.out_json.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    md = [
        "# SRA XML Index 100k Stress Pilot QC",
        "",
        f"- Parquet root: `{root}`",
        f"- Chunks root: `{args.chunks_root}`",
        f"- Directories: {counts['directories']:,}",
        f"- XML files: {counts['xml_files']:,}",
        f"- Entities: {counts['entities']:,}",
        f"- Relations: {counts['relations']:,}",
        f"- Sample attribute rows: {counts['sample_attribute_rows']:,}",
        f"- Selected field-long rows: {counts['selected_field_long_rows']:,}",
        f"- Path inventory rows: {counts['path_inventory_rows']:,}",
        f"- Parse failure rate: {report['parse_failures']['parse_failure_rate']}",
        f"- Sum chunk elapsed seconds: {timings['sum_chunk_elapsed_seconds']:.2f}",
        f"- Mean seconds per directory: {timings['mean_seconds_per_directory_sum_chunk_time']:.6f}",
        f"- Parquet bytes: {parquet_bytes:,}",
        f"- Estimated full Parquet bytes: {report['estimated_full_parquet_bytes']:,}",
        f"- Estimated full sum chunk elapsed seconds: {report['estimated_full_sum_chunk_elapsed_seconds']:.2f}",
        "",
        "## Relation Closure",
    ]
    for name, data in report["relation_closure"].items():
        md.append(
            f"- {name}: overall={data['overall_closure_rate']}, "
            f"target_xml_exists={data['target_xml_exists_closure_rate']}, "
            f"target_xml_missing_unclosed={data['target_xml_missing_unclosed_refs']}"
        )
    md.append("")
    md.append("## Core Missing Rates")
    for table, cols in report["core_missing_rates"].items():
        for col, data in cols.items():
            md.append(f"- {table}.{col}: {data['missing_rate']} ({data['missing']}/{data['total']})")
    args.out_md.write_text("\n".join(md) + "\n", encoding="utf-8")
    print(json.dumps({"out_json": str(args.out_json), "out_md": str(args.out_md)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
