#!/usr/bin/env python3
"""Merge completed Step 3c no-exclusion generic-index shard outputs.

Stage role:
    This script runs after shard production. It validates that every expected
    Run-hash shard completed, then combines per-shard member/run outputs and
    QC summaries into one merged directory.

Input:
    shards_root containing shard_XXXX_of_YYYY directories, each produced by
    build_wildtype_ab_no_exclusion_from_generic_xml_index.py.

Output:
    outdir/
      tables/wildtype_ab_no_exclusion_transcriptomic_rnaseq_member_level.parquet
      tables/wildtype_ab_no_exclusion_transcriptomic_rnaseq_member_level.tsv.gz
      tables/wildtype_ab_no_exclusion_transcriptomic_rnaseq_runs_for_download.tsv.gz
      qc/filter_funnel.tsv
      qc/rejection_reason_counts.tsv
      qc/member_vs_run_summary.tsv
      qc/generic_index_qc.tsv
      manifest.json

Safety:
    - Dry-run by default.
    - Refuses incomplete or duplicate shard remainders.
    - Refuses to overwrite a non-empty merged directory unless --overwrite is
      set; overwrite moves the old directory aside instead of deleting it.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import json
import shutil
import sys
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

try:
    import duckdb
except ImportError as exc:  # pragma: no cover
    raise SystemExit("duckdb is required. Install it in the active Python environment.") from exc


MEMBER_PARQUET = "wildtype_ab_no_exclusion_transcriptomic_rnaseq_member_level.parquet"
MEMBER_TSV_GZ = "wildtype_ab_no_exclusion_transcriptomic_rnaseq_member_level.tsv.gz"
RUN_DOWNLOAD_TSV_GZ = "wildtype_ab_no_exclusion_transcriptomic_rnaseq_runs_for_download.tsv.gz"
STAGE = "02_stage2_run_members_head_table.step3c_generic_xml_index_no_exclusion_filtering.merge_shards"
EXPECTED_SHARD_STAGE = "02_stage2_run_members_head_table.step3c_generic_xml_index_no_exclusion_filtering"
GATING_MODE = "wildtype_ab_no_exclusion"
OUTPUT_PREFIX = "wildtype_ab_no_exclusion_transcriptomic_rnaseq"
FILTER_FUNNEL = "filter_funnel.tsv"
REJECTION_REASONS = "rejection_reason_counts.tsv"
MEMBER_VS_RUN = "member_vs_run_summary.tsv"
GENERIC_QC = "generic_index_qc.tsv"


@dataclass(frozen=True)
class ShardOutput:
    """Validated paths and manifest for one completed shard."""

    shard_dir: Path
    buckets: int
    remainder: int
    manifest: dict
    member_parquet: Path
    member_tsv_gz: Path
    run_download_tsv_gz: Path
    filter_funnel: Path
    rejection_reasons: Path
    member_vs_run: Path
    generic_qc: Path


def utc_now() -> str:
    """Return a UTC timestamp for merged manifest lineage."""
    return datetime.now(timezone.utc).isoformat()


def sql_quote(value: Path | str) -> str:
    """Quote a path for DuckDB SQL string literals."""
    return "'" + str(value).replace("'", "''") + "'"


def parse_remainders(text: str | None, buckets: int) -> list[int] | None:
    """Parse expected remainder ranges, or return None to discover all shards."""
    if text is None or not text.strip():
        return None
    values: set[int] = set()
    for part in text.split(","):
        token = part.strip()
        if not token:
            continue
        if "-" in token:
            start_text, end_text = token.split("-", 1)
            start = int(start_text)
            end = int(end_text)
            if end < start:
                raise SystemExit(f"Invalid remainder range: {token}")
            values.update(range(start, end + 1))
        else:
            values.add(int(token))
    invalid = [value for value in values if value < 0 or value >= buckets]
    if invalid:
        raise SystemExit(f"Remainders outside [0, {buckets}): {invalid}")
    return sorted(values)


def shard_name(remainder: int, buckets: int) -> str:
    """Return the canonical shard directory name used by runner and merger."""
    width = max(4, len(str(buckets - 1)))
    return f"shard_{remainder:0{width}d}_of_{buckets:0{width}d}"


def prepare_outdir(outdir: Path, overwrite: bool) -> dict[str, Path]:
    """Create merged output folders while preserving previous output on overwrite."""
    if outdir.exists() and any(outdir.iterdir()) and not overwrite:
        raise SystemExit(f"Output directory already exists and is not empty: {outdir}. Use --overwrite.")
    if outdir.exists() and any(outdir.iterdir()) and overwrite:
        backup = outdir.with_name(f"{outdir.name}.previous_{datetime.now().strftime('%Y%m%d_%H%M%S')}")
        shutil.move(str(outdir), str(backup))
    paths = {"tables": outdir / "tables", "qc": outdir / "qc"}
    for path in paths.values():
        path.mkdir(parents=True, exist_ok=True)
    return paths


def require_file(path: Path, label: str) -> None:
    """Fail early if a shard output file is missing."""
    if not path.exists():
        raise SystemExit(f"Missing {label}: {path}")


def load_shard(shard_dir: Path, expected_buckets: int) -> ShardOutput:
    """Read one shard manifest and validate its required files.

    Flow position:
        This is the merge gate. A shard must pass this gate before any file is
        read into the merged output, preventing partial failed attempts from
        contaminating final tables.
    """
    manifest_path = shard_dir / "manifest.json"
    require_file(manifest_path, "manifest.json")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("stage") != EXPECTED_SHARD_STAGE:
        raise SystemExit(f"{shard_dir} has stage={manifest.get('stage')!r}, expected {EXPECTED_SHARD_STAGE!r}")
    if manifest.get("gating_mode") != GATING_MODE:
        raise SystemExit(f"{shard_dir} has gating_mode={manifest.get('gating_mode')!r}, expected {GATING_MODE!r}")
    if manifest.get("output_prefix") != OUTPUT_PREFIX:
        raise SystemExit(f"{shard_dir} has output_prefix={manifest.get('output_prefix')!r}, expected {OUTPUT_PREFIX!r}")
    params = manifest.get("parameters", {})
    buckets = int(params.get("run_hash_buckets") or -1)
    remainder = int(params.get("run_hash_remainder") if params.get("run_hash_remainder") is not None else -1)
    if buckets != expected_buckets:
        raise SystemExit(f"{shard_dir} has buckets={buckets}, expected {expected_buckets}")
    if not 0 <= remainder < expected_buckets:
        raise SystemExit(f"{shard_dir} has invalid remainder={remainder}")
    if params.get("qc_only"):
        raise SystemExit(f"{shard_dir} is qc_only and cannot be merged into production tables.")

    tables = shard_dir / "tables"
    qc = shard_dir / "qc"
    output = ShardOutput(
        shard_dir=shard_dir,
        buckets=buckets,
        remainder=remainder,
        manifest=manifest,
        member_parquet=tables / MEMBER_PARQUET,
        member_tsv_gz=tables / MEMBER_TSV_GZ,
        run_download_tsv_gz=tables / RUN_DOWNLOAD_TSV_GZ,
        filter_funnel=qc / FILTER_FUNNEL,
        rejection_reasons=qc / REJECTION_REASONS,
        member_vs_run=qc / MEMBER_VS_RUN,
        generic_qc=qc / GENERIC_QC,
    )
    for label, path in {
        MEMBER_PARQUET: output.member_parquet,
        MEMBER_TSV_GZ: output.member_tsv_gz,
        RUN_DOWNLOAD_TSV_GZ: output.run_download_tsv_gz,
        FILTER_FUNNEL: output.filter_funnel,
        REJECTION_REASONS: output.rejection_reasons,
        MEMBER_VS_RUN: output.member_vs_run,
        GENERIC_QC: output.generic_qc,
    }.items():
        require_file(path, label)
    return output


def discover_shards(shards_root: Path, expected_buckets: int, expected_remainders: list[int] | None) -> list[ShardOutput]:
    """Validate and return all shard outputs selected for merging."""
    if expected_remainders is None:
        shard_dirs = sorted(path for path in shards_root.iterdir() if path.is_dir() and path.name.startswith("shard_"))
        if not shard_dirs:
            raise SystemExit(f"No shard directories found under {shards_root}")
        shards = [load_shard(path, expected_buckets) for path in shard_dirs]
    else:
        shards = [
            load_shard(shards_root / shard_name(remainder, expected_buckets), expected_buckets)
            for remainder in expected_remainders
        ]
    seen: dict[int, Path] = {}
    for shard in shards:
        if shard.remainder in seen:
            raise SystemExit(f"Duplicate remainder {shard.remainder}: {seen[shard.remainder]} and {shard.shard_dir}")
        seen[shard.remainder] = shard.shard_dir
    if expected_remainders is not None:
        missing = sorted(set(expected_remainders) - set(seen))
        if missing:
            raise SystemExit(f"Missing expected remainders: {missing}")
    return sorted(shards, key=lambda shard: shard.remainder)


def validate_shard_manifest_consistency(shards: list[ShardOutput]) -> dict[str, object]:
    """Ensure all merged shards come from one coherent Step 3c production run."""
    if not shards:
        raise SystemExit("No shards selected for merge.")
    first = shards[0].manifest
    first_params = first.get("parameters", {})
    first_inputs = first.get("inputs", {})
    reference = {
        "stage": first.get("stage"),
        "gating_mode": first.get("gating_mode"),
        "output_prefix": first.get("output_prefix"),
        "member_head": first_inputs.get("member_head"),
        "generic_core": first_inputs.get("generic_core"),
        "run_hash_buckets": first_params.get("run_hash_buckets"),
        "threads": first_params.get("threads"),
        "qc_only": first_params.get("qc_only"),
        "limit_runs": first_params.get("limit_runs"),
        "limit_rows": first_params.get("limit_rows"),
    }
    mismatches: list[str] = []
    for shard in shards[1:]:
        params = shard.manifest.get("parameters", {})
        inputs = shard.manifest.get("inputs", {})
        observed = {
            "stage": shard.manifest.get("stage"),
            "gating_mode": shard.manifest.get("gating_mode"),
            "output_prefix": shard.manifest.get("output_prefix"),
            "member_head": inputs.get("member_head"),
            "generic_core": inputs.get("generic_core"),
            "run_hash_buckets": params.get("run_hash_buckets"),
            "threads": params.get("threads"),
            "qc_only": params.get("qc_only"),
            "limit_runs": params.get("limit_runs"),
            "limit_rows": params.get("limit_rows"),
        }
        for key, expected in reference.items():
            if observed[key] != expected:
                mismatches.append(
                    f"remainder {shard.remainder} {key}: observed={observed[key]!r}, expected={expected!r}"
                )
    if mismatches:
        raise SystemExit("Shard manifest consistency failed: " + " | ".join(mismatches))
    return reference


def duckdb_file_list(paths: Iterable[Path]) -> str:
    """Return a DuckDB list literal for read_parquet([...])."""
    return "[" + ", ".join(sql_quote(path.as_posix()) for path in paths) + "]"


def merge_member_parquet(shards: list[ShardOutput], output_path: Path) -> int:
    """Merge member parquet files and return the merged row count."""
    con = duckdb.connect()
    con.execute(
        f"""
        COPY (
            SELECT *
            FROM read_parquet({duckdb_file_list(shard.member_parquet for shard in shards)})
        ) TO {sql_quote(output_path.as_posix())} (FORMAT PARQUET)
        """
    )
    row_count = con.execute(
        f"SELECT COUNT(*) FROM read_parquet({sql_quote(output_path.as_posix())})"
    ).fetchone()[0]
    con.close()
    return int(row_count)


def merge_tsv_gz(inputs: Iterable[Path], output_path: Path) -> tuple[int, list[str]]:
    """Merge gzipped TSV files while writing only one header.

    Returns:
        Data row count and the header columns. This is used to verify that the
        run-download table has the expected number of rows and stable columns.
    """
    header: list[str] | None = None
    rows = 0
    with gzip.open(output_path, "wt", encoding="utf-8", newline="") as out:
        for path in inputs:
            with gzip.open(path, "rt", encoding="utf-8", newline="") as handle:
                first_line = handle.readline()
                if first_line == "":
                    continue
                current_header = first_line.rstrip("\n").split("\t")
                if header is None:
                    header = current_header
                    out.write(first_line)
                elif current_header != header:
                    raise SystemExit(f"Header mismatch in {path}")
                for line in handle:
                    out.write(line)
                    rows += 1
    return rows, (header or [])


def read_dict_tsv(path: Path) -> list[dict[str, str]]:
    """Read a small QC TSV into dictionaries."""
    with path.open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def write_dict_tsv(path: Path, rows: list[dict[str, object]], fieldnames: list[str]) -> None:
    """Write a stable QC TSV."""
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def sum_qc_by_key(inputs: Iterable[Path], key: str, numeric_columns: list[str]) -> list[dict[str, object]]:
    """Sum shard QC metrics.

    This is valid because Run-hash shards are disjoint by Run. The script still
    keeps the original metric/reason/status keys so reviewers can compare the
    merged QC with individual shard QC files.
    """
    order: list[str] = []
    totals: dict[str, dict[str, int]] = defaultdict(lambda: {column: 0 for column in numeric_columns})
    for path in inputs:
        for row in read_dict_tsv(path):
            item = row[key]
            if item not in totals:
                order.append(item)
            for column in numeric_columns:
                totals[item][column] += int(row[column])
    output: list[dict[str, object]] = []
    for item in order:
        row: dict[str, object] = {key: item}
        for column in numeric_columns:
            row[column] = totals[item][column]
        output.append(row)
    return output


def count_unique_runs_in_download(path: Path) -> tuple[int, int]:
    """Return row count and distinct Run count from merged run-download TSV."""
    rows = 0
    seen: set[str] = set()
    with gzip.open(path, "rt", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if "Run" not in (reader.fieldnames or []):
            raise SystemExit(f"Run column missing in {path}")
        for row in reader:
            rows += 1
            seen.add(row["Run"])
    return rows, len(seen)


def sum_manifest_counts(shards: list[ShardOutput]) -> dict[str, int]:
    """Sum the core count fields from shard manifests."""
    totals = {
        "input_member_rows": 0,
        "input_run_count": 0,
        "strict_member_pass_rows": 0,
        "strict_run_pass_rows": 0,
    }
    for shard in shards:
        counts = shard.manifest.get("result_counts", {})
        for key in totals:
            totals[key] += int(counts.get(key, 0))
    return totals


def write_manifest(
    outdir: Path,
    args: argparse.Namespace,
    shards: list[ShardOutput],
    outputs: dict[str, str],
    count_sums: dict[str, int],
    validations: dict[str, object],
    shard_identity: dict[str, object],
) -> None:
    """Write the merged manifest used as final lineage for this run."""
    payload = {
        "stage": STAGE,
        "gating_mode": GATING_MODE,
        "output_prefix": OUTPUT_PREFIX,
        "generated_at_utc": utc_now(),
        "shards_root": str(args.shards_root),
        "parameters": {
            "expected_buckets": args.expected_buckets,
            "expected_remainders": args.expected_remainders,
            "shards_merged": len(shards),
        },
        "shards": [
            {
                "remainder": shard.remainder,
                "shard_dir": str(shard.shard_dir),
                "manifest": str(shard.shard_dir / "manifest.json"),
                "strict_run_pass_rows": int(shard.manifest.get("result_counts", {}).get("strict_run_pass_rows", 0)),
            }
            for shard in shards
        ],
        "count_sums_from_shard_manifests": count_sums,
        "validations": validations,
        "shard_identity": shard_identity,
        "outputs": outputs,
    }
    (outdir / "manifest.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def execute(args: argparse.Namespace) -> dict[str, object]:
    """Validate, merge, and verify shard outputs."""
    expected_remainders = parse_remainders(args.expected_remainders, args.expected_buckets)
    shards = discover_shards(args.shards_root, args.expected_buckets, expected_remainders)
    shard_identity = validate_shard_manifest_consistency(shards)

    if not args.execute:
        return {
            "execute": False,
            "shards_root": str(args.shards_root),
            "outdir": str(args.outdir),
            "shards_selected": len(shards),
            "remainders": [shard.remainder for shard in shards],
            "shard_identity": shard_identity,
        }

    paths = prepare_outdir(args.outdir, args.overwrite)
    count_sums = sum_manifest_counts(shards)

    member_parquet = paths["tables"] / MEMBER_PARQUET
    member_tsv_gz = paths["tables"] / MEMBER_TSV_GZ
    run_download_tsv_gz = paths["tables"] / RUN_DOWNLOAD_TSV_GZ

    merged_member_rows = merge_member_parquet(shards, member_parquet)
    merged_member_tsv_rows, _ = merge_tsv_gz((shard.member_tsv_gz for shard in shards), member_tsv_gz)
    merged_run_tsv_rows, _ = merge_tsv_gz((shard.run_download_tsv_gz for shard in shards), run_download_tsv_gz)
    run_rows, distinct_runs = count_unique_runs_in_download(run_download_tsv_gz)

    filter_rows = sum_qc_by_key((shard.filter_funnel for shard in shards), "metric", ["rows", "distinct_runs"])
    rejection_rows = sum_qc_by_key(
        (shard.rejection_reasons for shard in shards), "reason", ["rows", "distinct_runs"]
    )
    member_vs_run_rows = sum_qc_by_key((shard.member_vs_run for shard in shards), "run_member_status", ["runs"])
    generic_qc_rows = sum_qc_by_key((shard.generic_qc for shard in shards), "metric", ["value"])

    write_dict_tsv(paths["qc"] / FILTER_FUNNEL, filter_rows, ["metric", "rows", "distinct_runs"])
    write_dict_tsv(paths["qc"] / REJECTION_REASONS, rejection_rows, ["reason", "rows", "distinct_runs"])
    write_dict_tsv(paths["qc"] / MEMBER_VS_RUN, member_vs_run_rows, ["run_member_status", "runs"])
    write_dict_tsv(paths["qc"] / GENERIC_QC, generic_qc_rows, ["metric", "value"])

    validations = {
        "merged_member_parquet_rows": merged_member_rows,
        "merged_member_tsv_rows": merged_member_tsv_rows,
        "merged_run_download_rows": merged_run_tsv_rows,
        "merged_run_download_distinct_runs": distinct_runs,
        "run_download_has_duplicate_runs": run_rows != distinct_runs,
        "shard_manifest_identity_consistent": True,
        "member_rows_match_manifest_sum": merged_member_rows == count_sums["strict_member_pass_rows"],
        "member_tsv_rows_match_manifest_sum": merged_member_tsv_rows == count_sums["strict_member_pass_rows"],
        "run_rows_match_manifest_sum": merged_run_tsv_rows == count_sums["strict_run_pass_rows"],
        "run_rows_match_distinct_runs": run_rows == distinct_runs,
    }
    required_true = [
        "member_rows_match_manifest_sum",
        "member_tsv_rows_match_manifest_sum",
        "run_rows_match_manifest_sum",
        "run_rows_match_distinct_runs",
        "shard_manifest_identity_consistent",
    ]
    required_false = ["run_download_has_duplicate_runs"]
    failed_checks = [key for key in required_true if not validations[key]]
    failed_checks.extend(key for key in required_false if validations[key])
    if failed_checks:
        raise SystemExit(f"Merged validation failed: {failed_checks}")

    outputs = {
        "member_level_parquet": str(member_parquet),
        "member_level_tsv_gz": str(member_tsv_gz),
        "run_download_tsv_gz": str(run_download_tsv_gz),
        "filter_funnel": str(paths["qc"] / FILTER_FUNNEL),
        "rejection_reason_counts": str(paths["qc"] / REJECTION_REASONS),
        "member_vs_run_summary": str(paths["qc"] / MEMBER_VS_RUN),
        "generic_index_qc": str(paths["qc"] / GENERIC_QC),
    }
    write_manifest(args.outdir, args, shards, outputs, count_sums, validations, shard_identity)
    return {
        "execute": True,
        "outdir": str(args.outdir),
        "shards_merged": len(shards),
        "count_sums_from_shard_manifests": count_sums,
        "validations": validations,
        "shard_identity": shard_identity,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse merge arguments."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shards-root", type=Path, required=True)
    parser.add_argument("--outdir", type=Path, required=True)
    parser.add_argument("--expected-buckets", type=int, required=True)
    parser.add_argument("--expected-remainders", default=None, help="Comma/range notation such as 0-3,8.")
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--execute", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint."""
    summary = execute(parse_args(sys.argv[1:] if argv is None else argv))
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
