#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import time
from datetime import datetime, timezone
from pathlib import Path

import duckdb


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def non_missing(column: str) -> str:
    return f"({column} IS NOT NULL AND {column} <> '' AND {column} <> '-')"


def metric_rows(metrics: dict[str, int]) -> list[tuple[str, int]]:
    return [(name, value) for name, value in metrics.items()]


def counter_list_to_dict(rows: list[dict]) -> dict[str, int]:
    return {str(row["value"]): int(row["count"]) for row in rows}


def compare_dicts(label: str, source: dict[str, int], parquet: dict[str, int]) -> list[dict[str, int | str]]:
    rows: list[dict[str, int | str]] = []
    for key in sorted(set(source) | set(parquet)):
        source_value = source.get(key)
        parquet_value = parquet.get(key)
        source_int = int(source_value) if source_value is not None else None
        parquet_int = int(parquet_value) if parquet_value is not None else None
        rows.append(
            {
                "group": label,
                "key": key,
                "source": source_int,
                "parquet": parquet_int,
                "delta": (parquet_int - source_int) if source_int is not None and parquet_int is not None else None,
                "match": source_int == parquet_int,
            }
        )
    return rows


def write_comparison_tsv(path: Path, rows: list[dict[str, int | str | bool | None]]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        handle.write("group\tkey\tsource\tparquet\tdelta\tmatch\n")
        for row in rows:
            handle.write(
                f"{row['group']}\t{row['key']}\t{row['source']}\t{row['parquet']}\t{row['delta']}\t{row['match']}\n"
            )


def flatten_source_audit(source_audit: dict) -> dict[str, int]:
    flat: dict[str, int] = {
        "total_lines_including_header": int(source_audit["total_lines_including_header"]),
        "data_lines": int(source_audit["data_lines"]),
        "column_count": int(source_audit["column_count"]),
    }
    for item in source_audit["prefix_counts"]:
        flat[f"prefix_counts|{item['value']}"] = int(item["count"])
    for item in source_audit["type_counts"]:
        flat[f"type_counts|{item['value']}"] = int(item["count"])
    for item in source_audit["status_counts"]:
        flat[f"status_counts|{item['value']}"] = int(item["count"])
    for item in source_audit["visibility_counts"]:
        flat[f"visibility_counts|{item['value']}"] = int(item["count"])
    for key, value in source_audit["presence_counts"].items():
        flat[f"presence_counts|{key}"] = int(value)
    for key, value in source_audit["run_numeric_quality"].items():
        flat[f"run_numeric_quality|{key}"] = int(value)
    for prefix, row in source_audit["prefix_type_matrix"].items():
        for type_value, count in row.items():
            flat[f"prefix_type_matrix|{prefix}|{type_value}"] = int(count)
    for item in source_audit["type_status_counts"]:
        flat[f"type_status_counts|{item['type']}|{item['status']}"] = int(item["count"])
    for item in source_audit["type_visibility_counts"]:
        flat[f"type_visibility_counts|{item['type']}|{item['visibility']}"] = int(item["count"])
    for item in source_audit["type_status_visibility_counts"]:
        flat[f"type_status_visibility_counts|{item['type']}|{item['status']}|{item['visibility']}"] = int(item["count"])
    return flat


def rows_to_nested_count(rows: list[tuple], prefix: str) -> dict[str, int]:
    return {prefix + "|" + "|".join(str(part) for part in row[:-1]): int(row[-1]) for row in rows}


def write_tsv(path: Path, rows: list[tuple[str, int]]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        handle.write("metric\tvalue\n")
        for metric, value in rows:
            handle.write(f"{metric}\t{value}\n")


def write_markdown(path: Path, payload: dict) -> None:
    lines = [
        "# SRA_Accessions Parquet Relation Stats",
        "",
        f"- Generated UTC: `{payload['generated_at_utc']}`",
        f"- Parquet root: `{payload['parquet_root']}`",
        f"- DuckDB version: `{payload['duckdb_version']}`",
        f"- Threads: `{payload['threads']}`",
        f"- Elapsed seconds: `{payload['elapsed_seconds']:.3f}`",
        f"- TSV baseline scan seconds: `{payload['tsv_baseline_seconds']}`",
        f"- Speedup vs TSV baseline: `{payload['speedup_vs_tsv_baseline']:.2f}x`",
        f"- Source audit comparison status: `{payload['source_audit_comparison']['status']}`",
        "",
        "## Full TSV Audit Equivalent Metrics",
    ]
    for metric, value in payload["parquet_audit_equivalent_metrics"].items():
        lines.append(f"- `{metric}`: `{value}`")
    lines.extend(
        [
            "",
            "## Additional Live/Public Relation Metrics",
        ]
    )
    for metric, value in payload["additional_relation_metrics"].items():
        lines.append(f"- `{metric}`: `{value}`")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--parquet-root", type=Path, default=Path("/data/shared/sra_parquet/sra_accessions_by_type"))
    parser.add_argument("--outdir", type=Path, default=Path("/data/shared/sra_parquet_relation_stats_20260603"))
    parser.add_argument("--threads", type=int, default=16)
    parser.add_argument("--tsv-baseline-seconds", type=float, default=963.0)
    parser.add_argument("--source-audit-json", type=Path)
    args = parser.parse_args()

    args.outdir.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect()
    con.execute(f"PRAGMA threads={args.threads}")
    con.execute("SET preserve_insertion_order=false")

    root = args.parquet_root
    started = time.perf_counter()
    generated_at = utc_now()

    con.execute(
        f"""
        CREATE TEMP TABLE run_lp AS
        SELECT Accession, Experiment, Sample, Study, BioSample, BioProject, Loaded, Spots, Bases, ReplacedBy
        FROM read_parquet('{root / "Type=RUN" / "*.parquet"}', hive_partitioning=true)
        WHERE Status = 'live' AND Visibility = 'public'
        """
    )
    con.execute(
        f"""
        CREATE TEMP TABLE experiment_lp AS
        SELECT Accession, Sample, Study
        FROM read_parquet('{root / "Type=EXPERIMENT" / "*.parquet"}', hive_partitioning=true)
        WHERE Status = 'live' AND Visibility = 'public'
        """
    )
    con.execute(
        f"""
        CREATE TEMP TABLE sample_lp AS
        SELECT Accession, Study
        FROM read_parquet('{root / "Type=SAMPLE" / "*.parquet"}', hive_partitioning=true)
        WHERE Status = 'live' AND Visibility = 'public'
        """
    )
    con.execute(
        f"""
        CREATE TEMP TABLE study_lp AS
        SELECT Accession
        FROM read_parquet('{root / "Type=STUDY" / "*.parquet"}', hive_partitioning=true)
        WHERE Status = 'live' AND Visibility = 'public'
        """
    )

    con.execute("CREATE TEMP TABLE experiment_lp_keys AS SELECT DISTINCT Accession FROM experiment_lp")
    con.execute("CREATE TEMP TABLE sample_lp_keys AS SELECT DISTINCT Accession FROM sample_lp")
    con.execute("CREATE TEMP TABLE study_lp_keys AS SELECT DISTINCT Accession FROM study_lp")

    run_counts = con.execute(
        f"""
        SELECT
            COUNT(*) AS run_live_public_total,
            SUM(CASE WHEN {non_missing('Experiment')} THEN 1 ELSE 0 END) AS run_live_public_experiment_non_missing,
            SUM(CASE WHEN {non_missing('Sample')} THEN 1 ELSE 0 END) AS run_live_public_sample_non_missing,
            SUM(CASE WHEN {non_missing('Study')} THEN 1 ELSE 0 END) AS run_live_public_study_non_missing,
            SUM(CASE WHEN {non_missing('BioSample')} THEN 1 ELSE 0 END) AS run_live_public_biosample_non_missing,
            SUM(CASE WHEN {non_missing('BioProject')} THEN 1 ELSE 0 END) AS run_live_public_bioproject_non_missing,
            SUM(CASE WHEN {non_missing('Loaded')} THEN 1 ELSE 0 END) AS run_live_public_loaded_non_missing,
            SUM(CASE WHEN NOT {non_missing('Spots')} THEN 1 ELSE 0 END) AS run_live_public_spots_missing,
            SUM(CASE WHEN NOT {non_missing('Bases')} THEN 1 ELSE 0 END) AS run_live_public_bases_missing,
            SUM(CASE WHEN Spots = '0' THEN 1 ELSE 0 END) AS run_live_public_spots_zero,
            SUM(CASE WHEN Bases = '0' THEN 1 ELSE 0 END) AS run_live_public_bases_zero,
            SUM(CASE
                WHEN TRY_CAST(NULLIF(Spots, '-') AS BIGINT) > 0
                 AND TRY_CAST(NULLIF(Bases, '-') AS BIGINT) > 0
                THEN 1 ELSE 0 END
            ) AS run_live_public_spots_gt0_bases_gt0,
            SUM(CASE WHEN {non_missing('ReplacedBy')} THEN 1 ELSE 0 END) AS run_live_public_replacedby_non_missing
        FROM run_lp
        """
    ).fetchone()

    relation_counts = con.execute(
        f"""
        SELECT
            (
                SELECT COUNT(*)
                FROM run_lp r
                LEFT JOIN experiment_lp_keys e ON r.Experiment = e.Accession
                WHERE {non_missing('r.Experiment')} AND e.Accession IS NULL
            ) AS run_live_public_experiment_not_found_in_filtered_experiment,
            (
                SELECT COUNT(*)
                FROM run_lp r
                LEFT JOIN sample_lp_keys s ON r.Sample = s.Accession
                WHERE {non_missing('r.Sample')} AND s.Accession IS NULL
            ) AS run_live_public_sample_not_found_in_filtered_sample,
            (
                SELECT COUNT(*)
                FROM run_lp r
                LEFT JOIN study_lp_keys st ON r.Study = st.Accession
                WHERE {non_missing('r.Study')} AND st.Accession IS NULL
            ) AS run_live_public_study_not_found_in_filtered_study,
            (
                SELECT COUNT(*)
                FROM experiment_lp
            ) AS experiment_live_public_total,
            (
                SELECT COUNT(*)
                FROM experiment_lp e
                LEFT JOIN sample_lp_keys s ON e.Sample = s.Accession
                WHERE {non_missing('e.Sample')} AND s.Accession IS NULL
            ) AS experiment_live_public_sample_not_found_in_filtered_sample,
            (
                SELECT COUNT(*)
                FROM experiment_lp e
                LEFT JOIN study_lp_keys st ON e.Study = st.Accession
                WHERE {non_missing('e.Study')} AND st.Accession IS NULL
            ) AS experiment_live_public_study_not_found_in_filtered_study,
            (
                SELECT COUNT(*)
                FROM sample_lp s
                LEFT JOIN study_lp_keys st ON s.Study = st.Accession
                WHERE {non_missing('s.Study')} AND st.Accession IS NULL
            ) AS sample_live_public_study_not_found_in_filtered_study
        """
    ).fetchone()

    all_glob = root / "**" / "*.parquet"
    run_glob = root / "Type=RUN" / "*.parquet"
    parquet_audit_equivalent_metrics: dict[str, int] = {}
    parquet_audit_equivalent_metrics["data_lines"] = int(
        con.execute(
            f"SELECT COUNT(*)::BIGINT FROM read_parquet('{all_glob}', hive_partitioning=true)"
        ).fetchone()[0]
    )
    parquet_audit_equivalent_metrics["total_lines_including_header"] = (
        parquet_audit_equivalent_metrics["data_lines"] + 1
    )
    parquet_audit_equivalent_metrics["column_count"] = 20

    prefix_rows = con.execute(
        f"""
        SELECT
            CASE
                WHEN starts_with(Accession, 'SRA') THEN 'SRA'
                WHEN starts_with(Accession, 'ERA') THEN 'ERA'
                WHEN starts_with(Accession, 'DRA') THEN 'DRA'
                ELSE 'OTHER'
            END AS Prefix,
            COUNT(*)::BIGINT AS n
        FROM read_parquet('{all_glob}', hive_partitioning=true)
        GROUP BY Prefix
        """
    ).fetchall()
    parquet_audit_equivalent_metrics.update(rows_to_nested_count(prefix_rows, "prefix_counts"))

    type_rows = con.execute(
        f"""
        SELECT Type, COUNT(*)::BIGINT AS n
        FROM read_parquet('{all_glob}', hive_partitioning=true)
        GROUP BY Type
        """
    ).fetchall()
    parquet_audit_equivalent_metrics.update(rows_to_nested_count(type_rows, "type_counts"))

    status_rows = con.execute(
        f"""
        SELECT Status, COUNT(*)::BIGINT AS n
        FROM read_parquet('{all_glob}', hive_partitioning=true)
        GROUP BY Status
        """
    ).fetchall()
    parquet_audit_equivalent_metrics.update(rows_to_nested_count(status_rows, "status_counts"))

    visibility_rows = con.execute(
        f"""
        SELECT Visibility, COUNT(*)::BIGINT AS n
        FROM read_parquet('{all_glob}', hive_partitioning=true)
        GROUP BY Visibility
        """
    ).fetchall()
    parquet_audit_equivalent_metrics.update(rows_to_nested_count(visibility_rows, "visibility_counts"))

    presence_row = con.execute(
        f"""
        SELECT
            SUM(CASE WHEN {non_missing('Experiment')} THEN 1 ELSE 0 END)::BIGINT AS Experiment,
            SUM(CASE WHEN {non_missing('Sample')} THEN 1 ELSE 0 END)::BIGINT AS Sample,
            SUM(CASE WHEN {non_missing('Study')} THEN 1 ELSE 0 END)::BIGINT AS Study,
            SUM(CASE WHEN {non_missing('Loaded')} THEN 1 ELSE 0 END)::BIGINT AS Loaded,
            SUM(CASE WHEN {non_missing('BioSample')} THEN 1 ELSE 0 END)::BIGINT AS BioSample,
            SUM(CASE WHEN {non_missing('BioProject')} THEN 1 ELSE 0 END)::BIGINT AS BioProject
        FROM read_parquet('{all_glob}', hive_partitioning=true)
        """
    ).fetchone()
    for key, value in zip(["Experiment", "Sample", "Study", "Loaded", "BioSample", "BioProject"], presence_row):
        parquet_audit_equivalent_metrics[f"presence_counts|{key}"] = int(value)

    run_quality_row = con.execute(
        f"""
        SELECT
            SUM(CASE WHEN Spots = '0' THEN 1 ELSE 0 END)::BIGINT AS run_spots_zero,
            SUM(CASE WHEN Bases = '0' THEN 1 ELSE 0 END)::BIGINT AS run_bases_zero,
            SUM(CASE WHEN NOT {non_missing('Spots')} THEN 1 ELSE 0 END)::BIGINT AS run_spots_missing,
            SUM(CASE WHEN NOT {non_missing('Bases')} THEN 1 ELSE 0 END)::BIGINT AS run_bases_missing,
            SUM(CASE WHEN {non_missing('Spots')} AND TRY_CAST(Spots AS BIGINT) IS NULL THEN 1 ELSE 0 END)::BIGINT AS run_spots_non_numeric,
            SUM(CASE WHEN {non_missing('Bases')} AND TRY_CAST(Bases AS BIGINT) IS NULL THEN 1 ELSE 0 END)::BIGINT AS run_bases_non_numeric
        FROM read_parquet('{run_glob}', hive_partitioning=true)
        """
    ).fetchone()
    for key, value in zip(
        [
            "run_spots_zero",
            "run_bases_zero",
            "run_spots_missing",
            "run_bases_missing",
            "run_spots_non_numeric",
            "run_bases_non_numeric",
        ],
        run_quality_row,
    ):
        parquet_audit_equivalent_metrics[f"run_numeric_quality|{key}"] = int(value)

    prefix_type_rows = con.execute(
        f"""
        SELECT
            CASE
                WHEN starts_with(Accession, 'SRA') THEN 'SRA'
                WHEN starts_with(Accession, 'ERA') THEN 'ERA'
                WHEN starts_with(Accession, 'DRA') THEN 'DRA'
                ELSE 'OTHER'
            END AS Prefix,
            Type,
            COUNT(*)::BIGINT AS n
        FROM read_parquet('{all_glob}', hive_partitioning=true)
        GROUP BY Prefix, Type
        """
    ).fetchall()
    parquet_audit_equivalent_metrics.update(rows_to_nested_count(prefix_type_rows, "prefix_type_matrix"))

    type_status_rows = con.execute(
        f"""
        SELECT Type, Status, COUNT(*)::BIGINT AS n
        FROM read_parquet('{all_glob}', hive_partitioning=true)
        GROUP BY Type, Status
        """
    ).fetchall()
    parquet_audit_equivalent_metrics.update(rows_to_nested_count(type_status_rows, "type_status_counts"))

    type_visibility_rows = con.execute(
        f"""
        SELECT Type, Visibility, COUNT(*)::BIGINT AS n
        FROM read_parquet('{all_glob}', hive_partitioning=true)
        GROUP BY Type, Visibility
        """
    ).fetchall()
    parquet_audit_equivalent_metrics.update(rows_to_nested_count(type_visibility_rows, "type_visibility_counts"))

    type_status_visibility_rows = con.execute(
        f"""
        SELECT Type, Status, Visibility, COUNT(*)::BIGINT AS n
        FROM read_parquet('{all_glob}', hive_partitioning=true)
        GROUP BY Type, Status, Visibility
        """
    ).fetchall()
    parquet_audit_equivalent_metrics.update(
        rows_to_nested_count(type_status_visibility_rows, "type_status_visibility_counts")
    )

    source_audit_comparison = {"status": "not_requested", "rows": []}
    if args.source_audit_json:
        source_audit = json.loads(args.source_audit_json.read_text(encoding="utf-8"))
        comparison_rows = []
        source_flat = flatten_source_audit(source_audit)
        for key in sorted(set(source_flat) | set(parquet_audit_equivalent_metrics)):
            source_value = source_flat.get(key)
            parquet_value = parquet_audit_equivalent_metrics.get(key)
            comparison_rows.append(
                {
                    "group": key.split("|", 1)[0],
                    "key": key,
                    "source": source_value,
                    "parquet": parquet_value,
                    "delta": (parquet_value - source_value)
                    if source_value is not None and parquet_value is not None
                    else None,
                    "match": source_value == parquet_value,
                }
            )
        source_audit_comparison = {
            "status": "pass" if all(row["match"] for row in comparison_rows) else "fail",
            "source_audit_json": str(args.source_audit_json),
            "rows": comparison_rows,
        }

    metric_names = [
        "RUN live public total",
        "RUN live public + Experiment non-missing",
        "RUN live public + Sample non-missing",
        "RUN live public + Study non-missing",
        "RUN live public + BioSample non-missing",
        "RUN live public + BioProject non-missing",
        "RUN live public + Loaded non-missing",
        "RUN live public + Spots missing",
        "RUN live public + Bases missing",
        "RUN live public + Spots = 0",
        "RUN live public + Bases = 0",
        "RUN live public + Spots > 0 + Bases > 0",
        "RUN live public + ReplacedBy non-missing",
        "RUN live public with Experiment not found in filtered EXPERIMENT",
        "RUN live public with Sample not found in filtered SAMPLE",
        "RUN live public with Study not found in filtered STUDY",
        "EXPERIMENT live public total",
        "EXPERIMENT live public with Sample not found in filtered SAMPLE",
        "EXPERIMENT live public with Study not found in filtered STUDY",
        "SAMPLE live public with Study not found in filtered STUDY",
    ]
    values = tuple(run_counts) + tuple(relation_counts)
    additional_relation_metrics = {name: int(value) for name, value in zip(metric_names, values)}

    elapsed = time.perf_counter() - started
    payload = {
        "generated_at_utc": generated_at,
        "parquet_root": str(root),
        "outdir": str(args.outdir),
        "duckdb_version": duckdb.__version__,
        "threads": args.threads,
        "elapsed_seconds": elapsed,
        "tsv_baseline_seconds": args.tsv_baseline_seconds,
        "speedup_vs_tsv_baseline": args.tsv_baseline_seconds / elapsed if elapsed else None,
        "parquet_audit_equivalent_metrics": dict(sorted(parquet_audit_equivalent_metrics.items())),
        "additional_relation_metrics": additional_relation_metrics,
        "source_audit_comparison": source_audit_comparison,
    }

    (args.outdir / "sra_parquet_relation_stats.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    write_tsv(
        args.outdir / "parquet_full_tsv_audit_equivalent_metrics.tsv",
        metric_rows(payload["parquet_audit_equivalent_metrics"]),
    )
    write_tsv(args.outdir / "additional_live_public_relation_metrics.tsv", metric_rows(additional_relation_metrics))
    if source_audit_comparison["rows"]:
        write_comparison_tsv(args.outdir / "source_tsv_vs_parquet_comparison.tsv", source_audit_comparison["rows"])
    write_markdown(args.outdir / "sra_parquet_relation_stats.md", payload)
    print(json.dumps(payload, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
