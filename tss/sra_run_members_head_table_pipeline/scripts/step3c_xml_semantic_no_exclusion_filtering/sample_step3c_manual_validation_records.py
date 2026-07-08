#!/usr/bin/env python3
"""Sample Step 3c no-exclusion Runs for manual website validation.

Input:
    The merged Step 3c member-level parquet produced by the H100 production run.

Output:
    A small manual-validation bundle with:
      - sample_records.tsv
      - sample_records.csv
      - manifest.json
      - README.md

Workflow position:
    This is an audit helper after Step 3c production. It does not change the
    production tables. It only reads the final member-level table and writes a
    reproducible random sample for website checks.
"""

from __future__ import annotations

import argparse
import csv
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    import duckdb
except ImportError as exc:  # pragma: no cover
    raise SystemExit("duckdb is required in the active Python environment.") from exc


DEFAULT_MEMBER_PARQUET = Path(
    "/home/m252202014/TSS/02_stage2_run_members_head_table/"
    "step3c_xml_semantic_no_exclusion_filtering/production_runs/"
    "wildtype_ab_no_exclusion_transcriptomic_rnaseq_generic_index_20260707/"
    "merged/tables/wildtype_ab_no_exclusion_transcriptomic_rnaseq_member_level.parquet"
)
DEFAULT_OUTDIR = Path("manual_validation/step3c_no_exclusion_random_50_20260708")
DEFAULT_SEED = 20260708
DEFAULT_N = 50

OUTPUT_COLUMNS = [
    "sample_no",
    "Run",
    "archive_prefix",
    "archive_label",
    "primary_official_url",
    "ncbi_sra_url",
    "ncbi_run_browser_url",
    "ena_browser_url",
    "ddbj_search_url",
    "Member_Name",
    "Experiment",
    "Sample",
    "BioSample",
    "Study",
    "Spots",
    "Bases",
    "Visibility",
    "library_strategy",
    "library_source",
    "library_selection",
    "taxon_id",
    "scientific_name",
    "wildtype_evidence_level_set",
    "wildtype_evidence_tag_set",
    "wildtype_evidence_value_set",
    "member_filter_status",
    "manual_official_rnaseq_confirmed",
    "manual_official_wildtype_confirmed",
    "manual_notes",
]


def utc_now() -> str:
    """Return an ISO timestamp for manifest lineage."""
    return datetime.now(timezone.utc).isoformat()


def sql_quote(value: str | Path) -> str:
    """Quote paths and literals for DuckDB SQL."""
    return "'" + str(value).replace("'", "''") + "'"


def archive_label(run: str) -> str:
    """Map Run accession prefix to the primary archive label used for review."""
    prefix = run[:3]
    if prefix == "SRR":
        return "NCBI/SRA"
    if prefix == "ERR":
        return "ENA"
    if prefix == "DRR":
        return "DDBJ/DRA"
    return "UNKNOWN"


def official_urls(run: str) -> dict[str, str]:
    """Build website URLs used during manual validation.

    The primary URL follows the accession prefix, while the cross-archive URLs
    are retained because INSDC records can often be searched at more than one
    archive portal.
    """
    ncbi_sra = f"https://www.ncbi.nlm.nih.gov/sra/{run}"
    ncbi_run_browser = f"https://trace.ncbi.nlm.nih.gov/Traces/?view=run_browser&acc={run}"
    ena = f"https://www.ebi.ac.uk/ena/browser/view/{run}"
    ddbj = f"https://ddbj.nig.ac.jp/search/entry/sra-run/{run}"
    prefix = run[:3]
    if prefix == "ERR":
        primary = ena
    elif prefix == "DRR":
        primary = ddbj
    else:
        primary = ncbi_run_browser
    return {
        "primary_official_url": primary,
        "ncbi_sra_url": ncbi_sra,
        "ncbi_run_browser_url": ncbi_run_browser,
        "ena_browser_url": ena,
        "ddbj_search_url": ddbj,
    }


def read_sample(con: Any, member_parquet: Path, seed: int, n: int) -> list[dict[str, Any]]:
    """Read a deterministic pseudo-random sample from the final member table."""
    query = f"""
        SELECT
            Run,
            Member_Name,
            Experiment,
            Sample,
            BioSample,
            Study,
            Spots,
            Bases,
            Visibility,
            library_strategy,
            library_source,
            library_selection,
            taxon_id,
            scientific_name,
            wildtype_evidence_level_set,
            wildtype_evidence_tag_set,
            wildtype_evidence_value_set,
            member_filter_status
        FROM read_parquet({sql_quote(member_parquet.as_posix())})
        ORDER BY hash(Run || {sql_quote(str(seed))})
        LIMIT {int(n)}
    """
    columns = [item[0] for item in con.execute(query).description]
    return [dict(zip(columns, row)) for row in con.fetchall()]


def total_rows(con: Any, member_parquet: Path) -> int:
    """Count the Step 3c population represented by the member-level table."""
    value = con.execute(
        f"SELECT COUNT(*) FROM read_parquet({sql_quote(member_parquet.as_posix())})"
    ).fetchone()[0]
    return int(value)


def enrich_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Add review URLs, archive labels, and blank manual-review columns."""
    output: list[dict[str, Any]] = []
    for index, row in enumerate(rows, start=1):
        run = str(row["Run"])
        urls = official_urls(run)
        enriched = {
            "sample_no": index,
            "Run": run,
            "archive_prefix": run[:3],
            "archive_label": archive_label(run),
            **urls,
        }
        for key in [
            "Member_Name",
            "Experiment",
            "Sample",
            "BioSample",
            "Study",
            "Spots",
            "Bases",
            "Visibility",
            "library_strategy",
            "library_source",
            "library_selection",
            "taxon_id",
            "scientific_name",
            "wildtype_evidence_level_set",
            "wildtype_evidence_tag_set",
            "wildtype_evidence_value_set",
            "member_filter_status",
        ]:
            enriched[key] = row.get(key)
        enriched["manual_official_rnaseq_confirmed"] = ""
        enriched["manual_official_wildtype_confirmed"] = ""
        enriched["manual_notes"] = ""
        output.append(enriched)
    return output


def write_tsv(path: Path, rows: list[dict[str, Any]]) -> None:
    """Write the sample table as UTF-8 TSV for spreadsheet/manual review."""
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=OUTPUT_COLUMNS, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    """Write a CSV copy for tools that do not handle TSV conveniently."""
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=OUTPUT_COLUMNS)
        writer.writeheader()
        writer.writerows(rows)


def write_readme(path: Path, manifest: dict[str, Any]) -> None:
    """Write concise manual-validation instructions beside the sample table."""
    body = f"""# Step 3c no-exclusion 随机 50 条官网人工校验表

## 目的

从 Step 3c no-exclusion 最终 `471,792` 条 Run 中抽取 50 条，用于到官方网页人工核验：

```text
1. 是否为 RNA-seq / TRANSCRIPTOMIC
2. 是否有 wildtype 相关证据
```

## 抽样口径

```text
population_table = {manifest["input_member_parquet"]}
population_rows = {manifest["population_rows"]}
sample_size = {manifest["sample_size"]}
seed = {manifest["seed"]}
method = {manifest["sampling_method"]}
```

## 文件

```text
sample_records.tsv
sample_records.csv
manifest.json
README.md
```

## 官网链接使用

`primary_official_url` 根据 Run 前缀选择：

```text
SRR -> NCBI SRA Run Browser
ERR -> ENA Browser
DRR -> DDBJ Search
```

同时保留 `ncbi_sra_url`、`ncbi_run_browser_url`、`ena_browser_url`、`ddbj_search_url`，方便交叉检索。

## 人工记录列

```text
manual_official_rnaseq_confirmed
manual_official_wildtype_confirmed
manual_notes
```

这三个列留空，供人工检索后填写。
"""
    path.write_text(body, encoding="utf-8")


def execute(args: argparse.Namespace) -> dict[str, Any]:
    """Generate the manual-validation bundle."""
    args.outdir.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect()
    population = total_rows(con, args.member_parquet)
    rows = enrich_rows(read_sample(con, args.member_parquet, args.seed, args.sample_size))
    con.close()

    write_tsv(args.outdir / "sample_records.tsv", rows)
    write_csv(args.outdir / "sample_records.csv", rows)
    manifest = {
        "generated_at_utc": utc_now(),
        "input_member_parquet": str(args.member_parquet),
        "population_rows": population,
        "sample_size": len(rows),
        "seed": args.seed,
        "sampling_method": "ORDER BY hash(Run || seed) LIMIT sample_size",
        "outputs": {
            "sample_records_tsv": "sample_records.tsv",
            "sample_records_csv": "sample_records.csv",
            "readme": "README.md",
        },
    }
    (args.outdir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    write_readme(args.outdir / "README.md", manifest)
    return manifest


def parse_args() -> argparse.Namespace:
    """Parse CLI arguments."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--member-parquet", type=Path, default=DEFAULT_MEMBER_PARQUET)
    parser.add_argument("--outdir", type=Path, default=DEFAULT_OUTDIR)
    parser.add_argument("--sample-size", type=int, default=DEFAULT_N)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    return parser.parse_args()


def main() -> int:
    """CLI entrypoint."""
    manifest = execute(parse_args())
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
