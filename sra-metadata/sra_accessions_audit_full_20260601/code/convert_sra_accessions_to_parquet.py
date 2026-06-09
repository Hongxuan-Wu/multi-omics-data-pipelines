#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

import duckdb


HEADER = [
    "Accession",
    "Submission",
    "Status",
    "Updated",
    "Published",
    "Received",
    "Type",
    "Center",
    "Visibility",
    "Alias",
    "Experiment",
    "Sample",
    "Study",
    "Loaded",
    "Spots",
    "Bases",
    "Md5sum",
    "BioSample",
    "BioProject",
    "ReplacedBy",
]

EXPECTED_DATA_ROWS = 148_211_048
EXPECTED_TYPE_COUNTS = {
    "RUN": 50_013_612,
    "EXPERIMENT": 44_607_471,
    "SAMPLE": 44_540_766,
    "SUBMISSION": 7_897_148,
    "STUDY": 807_530,
    "ANALYSIS": 344_521,
}
EXPECTED_STATUS_COUNTS = {
    "live": 131_929_435,
    "unpublished": 11_084_693,
    "suppressed": 5_194_233,
    "withdrawn": 2_687,
}
EXPECTED_VISIBILITY_COUNTS = {
    "public": 139_153_756,
    "controlled_access": 9_057_292,
}
EXPECTED_RUN_QUALITY = {
    "run_spots_zero": 2_212,
    "run_bases_zero": 0,
    "run_spots_missing": 7_876_811,
    "run_bases_missing": 7_876_811,
    "run_spots_non_numeric": 0,
    "run_bases_non_numeric": 0,
}


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def log(message: str) -> None:
    print(f"[{now()}] {message}", flush=True)


def run_command(command: list[str]) -> str:
    return subprocess.check_output(command, text=True).strip()


def csv_relation(source: Path) -> str:
    columns = ", ".join(f"'{col}'" for col in HEADER)
    return f"""
        read_csv(
            '{source}',
            delim='\\t',
            header=true,
            all_varchar=true,
            quote='',
            escape='',
            strict_mode=true,
            force_not_null=[{columns}]
        )
    """


def write_tsv(path: Path, header: list[str], rows: list[tuple]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        handle.write("\t".join(header) + "\n")
        for row in rows:
            handle.write("\t".join(str(value) for value in row) + "\n")


def compare_counts(name: str, observed: dict[str, int], expected: dict[str, int]) -> list[str]:
    problems: list[str] = []
    for key, expected_value in expected.items():
        observed_value = observed.get(key)
        if observed_value != expected_value:
            problems.append(f"{name}:{key}: observed={observed_value} expected={expected_value}")
    extra = sorted(set(observed) - set(expected))
    for key in extra:
        problems.append(f"{name}:{key}: unexpected observed={observed[key]}")
    return problems


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source",
        type=Path,
        default=Path("/data/p252701008/datasets/SRA/NCBI_SRA_Metadata_Full_20260516/SRA_Accessions"),
    )
    parser.add_argument("--base", type=Path, default=Path("/data/shared/sra_parquet"))
    parser.add_argument("--threads", type=int, default=16)
    parser.add_argument("--memory-limit", default="96GB")
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()

    source = args.source
    base = args.base
    pilot_dir = base / "pilot"
    out_dir = base / "sra_accessions_by_type"
    derived_dir = base / "derived"
    qc_dir = base / "qc"
    tmp_dir = base / "tmp_duckdb"

    if not source.exists():
        raise FileNotFoundError(source)
    if args.overwrite:
        for target in [pilot_dir, out_dir, derived_dir, qc_dir, tmp_dir]:
            if target.exists():
                shutil.rmtree(target)
    for target in [pilot_dir, out_dir, derived_dir, qc_dir, tmp_dir]:
        target.mkdir(parents=True, exist_ok=True)

    con = duckdb.connect()
    con.execute(f"PRAGMA threads={args.threads}")
    con.execute(f"PRAGMA memory_limit='{args.memory_limit}'")
    con.execute(f"SET temp_directory='{tmp_dir}'")
    con.execute("SET preserve_insertion_order=false")

    source_stat = source.stat()
    manifest = {
        "source_file": str(source),
        "source_size_bytes": source_stat.st_size,
        "source_mtime": datetime.fromtimestamp(source_stat.st_mtime, timezone.utc).isoformat(),
        "base_dir": str(base),
        "out_dir": str(out_dir),
        "derived_dir": str(derived_dir),
        "duckdb_version": duckdb.__version__,
        "threads": args.threads,
        "memory_limit": args.memory_limit,
        "started_at_utc": now(),
        "expected_data_rows": EXPECTED_DATA_ROWS,
    }
    (qc_dir / "conversion_manifest_start.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    relation = csv_relation(source)

    log("starting 1M pilot conversion")
    pilot_path = pilot_dir / "sra_accessions_pilot_1M.parquet"
    t0 = time.time()
    con.execute(
        f"""
        COPY (
            SELECT * FROM {relation}
            LIMIT 1000000
        )
        TO '{pilot_path}'
        (
            FORMAT PARQUET,
            COMPRESSION ZSTD,
            COMPRESSION_LEVEL 3,
            ROW_GROUP_SIZE 500000
        )
        """
    )
    pilot_seconds = time.time() - t0
    pilot_rows = con.execute(f"SELECT COUNT(*) FROM read_parquet('{pilot_path}')").fetchone()[0]
    write_tsv(qc_dir / "pilot_qc.tsv", ["metric", "value"], [("pilot_rows", pilot_rows), ("seconds", f"{pilot_seconds:.3f}")])
    if pilot_rows != 1_000_000:
        raise RuntimeError(f"Pilot row count mismatch: {pilot_rows}")
    log(f"pilot conversion passed in {pilot_seconds:.1f}s")

    log("starting full partitioned Parquet conversion")
    t0 = time.time()
    con.execute(
        f"""
        COPY (
            SELECT {", ".join(HEADER)}
            FROM {relation}
        )
        TO '{out_dir}'
        (
            FORMAT PARQUET,
            COMPRESSION ZSTD,
            COMPRESSION_LEVEL 3,
            PARTITION_BY (Type),
            ROW_GROUP_SIZE 500000,
            OVERWRITE_OR_IGNORE true
        )
        """
    )
    full_seconds = time.time() - t0
    log(f"full conversion finished in {full_seconds:.1f}s")

    parquet_glob = str(out_dir / "**" / "*.parquet")
    log("starting full Parquet QC")
    total_rows = con.execute(
        f"SELECT COUNT(*) FROM read_parquet('{parquet_glob}', hive_partitioning=true)"
    ).fetchone()[0]
    type_rows = con.execute(
        f"""
        SELECT Type, COUNT(*) AS n
        FROM read_parquet('{parquet_glob}', hive_partitioning=true)
        GROUP BY Type
        ORDER BY n DESC
        """
    ).fetchall()
    status_rows = con.execute(
        f"""
        SELECT Status, COUNT(*) AS n
        FROM read_parquet('{parquet_glob}', hive_partitioning=true)
        GROUP BY Status
        ORDER BY n DESC
        """
    ).fetchall()
    visibility_rows = con.execute(
        f"""
        SELECT Visibility, COUNT(*) AS n
        FROM read_parquet('{parquet_glob}', hive_partitioning=true)
        GROUP BY Visibility
        ORDER BY n DESC
        """
    ).fetchall()
    tsv_rows = con.execute(
        f"""
        SELECT Type, Status, Visibility, COUNT(*) AS n
        FROM read_parquet('{parquet_glob}', hive_partitioning=true)
        GROUP BY Type, Status, Visibility
        ORDER BY n DESC
        """
    ).fetchall()
    run_quality = con.execute(
        f"""
        SELECT
            SUM(CASE WHEN Spots = '0' THEN 1 ELSE 0 END) AS run_spots_zero,
            SUM(CASE WHEN Bases = '0' THEN 1 ELSE 0 END) AS run_bases_zero,
            SUM(CASE WHEN Spots = '-' OR Spots = '' OR Spots IS NULL THEN 1 ELSE 0 END) AS run_spots_missing,
            SUM(CASE WHEN Bases = '-' OR Bases = '' OR Bases IS NULL THEN 1 ELSE 0 END) AS run_bases_missing,
            SUM(CASE WHEN Spots <> '-' AND Spots <> '' AND Spots IS NOT NULL AND TRY_CAST(Spots AS BIGINT) IS NULL THEN 1 ELSE 0 END) AS run_spots_non_numeric,
            SUM(CASE WHEN Bases <> '-' AND Bases <> '' AND Bases IS NOT NULL AND TRY_CAST(Bases AS BIGINT) IS NULL THEN 1 ELSE 0 END) AS run_bases_non_numeric
        FROM read_parquet('{out_dir / "Type=RUN" / "*.parquet"}', hive_partitioning=true)
        """
    ).fetchone()

    write_tsv(qc_dir / "type_counts.tsv", ["Type", "n"], type_rows)
    write_tsv(qc_dir / "status_counts.tsv", ["Status", "n"], status_rows)
    write_tsv(qc_dir / "visibility_counts.tsv", ["Visibility", "n"], visibility_rows)
    write_tsv(qc_dir / "type_status_visibility.tsv", ["Type", "Status", "Visibility", "n"], tsv_rows)
    write_tsv(
        qc_dir / "run_qc_counts.tsv",
        list(EXPECTED_RUN_QUALITY),
        [run_quality],
    )
    write_tsv(qc_dir / "parquet_total_rows.tsv", ["metric", "value"], [("parquet_rows", total_rows)])

    observed_type = {key: int(value) for key, value in type_rows}
    observed_status = {key: int(value) for key, value in status_rows}
    observed_visibility = {key: int(value) for key, value in visibility_rows}
    observed_run_quality = {key: int(value) for key, value in zip(EXPECTED_RUN_QUALITY, run_quality)}
    problems: list[str] = []
    if total_rows != EXPECTED_DATA_ROWS:
        problems.append(f"rows: observed={total_rows} expected={EXPECTED_DATA_ROWS}")
    problems.extend(compare_counts("type", observed_type, EXPECTED_TYPE_COUNTS))
    problems.extend(compare_counts("status", observed_status, EXPECTED_STATUS_COUNTS))
    problems.extend(compare_counts("visibility", observed_visibility, EXPECTED_VISIBILITY_COUNTS))
    problems.extend(compare_counts("run_quality", observed_run_quality, EXPECTED_RUN_QUALITY))

    log("creating derived RUN live public nonzero Parquet files")
    con.execute(
        f"""
        COPY (
            SELECT *
            FROM read_parquet('{out_dir / "Type=RUN" / "*.parquet"}', hive_partitioning=true)
            WHERE Status = 'live'
              AND Visibility = 'public'
              AND Spots <> '0' AND Spots <> '-'
              AND Bases <> '0' AND Bases <> '-'
        )
        TO '{derived_dir / "sra_run_live_public_nonzero.parquet"}'
        (
            FORMAT PARQUET,
            COMPRESSION ZSTD,
            COMPRESSION_LEVEL 3,
            ROW_GROUP_SIZE 500000
        )
        """
    )
    con.execute(
        f"""
        COPY (
            SELECT
                *,
                TRY_CAST(NULLIF(Spots, '-') AS BIGINT) AS Spots_i64,
                TRY_CAST(NULLIF(Bases, '-') AS BIGINT) AS Bases_i64
            FROM read_parquet('{out_dir / "Type=RUN" / "*.parquet"}', hive_partitioning=true)
            WHERE Status = 'live'
              AND Visibility = 'public'
              AND TRY_CAST(NULLIF(Spots, '-') AS BIGINT) > 0
              AND TRY_CAST(NULLIF(Bases, '-') AS BIGINT) > 0
        )
        TO '{derived_dir / "sra_run_live_public_nonzero_typed.parquet"}'
        (
            FORMAT PARQUET,
            COMPRESSION ZSTD,
            COMPRESSION_LEVEL 3,
            ROW_GROUP_SIZE 500000
        )
        """
    )
    derived_rows = con.execute(
        f"SELECT COUNT(*) FROM read_parquet('{derived_dir / 'sra_run_live_public_nonzero_typed.parquet'}')"
    ).fetchone()[0]
    write_tsv(qc_dir / "derived_qc.tsv", ["metric", "value"], [("live_public_nonzero_run_rows", derived_rows)])

    manifest.update(
        {
            "finished_at_utc": now(),
            "pilot_seconds": pilot_seconds,
            "full_conversion_seconds": full_seconds,
            "parquet_total_rows": total_rows,
            "type_counts": observed_type,
            "status_counts": observed_status,
            "visibility_counts": observed_visibility,
            "run_numeric_quality": observed_run_quality,
            "derived_live_public_nonzero_run_rows": derived_rows,
            "qc_status": "pass" if not problems else "fail",
            "qc_problems": problems,
            "parquet_file_count": len(list(out_dir.rglob("*.parquet"))),
            "out_dir_size": run_command(["du", "-sh", str(out_dir)]),
            "derived_dir_size": run_command(["du", "-sh", str(derived_dir)]),
        }
    )
    (qc_dir / "conversion_manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    if problems:
        raise RuntimeError("QC failed: " + "; ".join(problems))
    log("conversion and QC passed")
    print(json.dumps(manifest, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
