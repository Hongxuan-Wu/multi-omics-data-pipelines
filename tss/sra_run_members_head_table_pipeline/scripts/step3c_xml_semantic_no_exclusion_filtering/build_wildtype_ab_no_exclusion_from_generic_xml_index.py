#!/usr/bin/env python3
"""Build no-exclusion transcriptomic wildtype RNA-seq head tables from the generic XML index.

Stage role:
    Step 3c production route. This script replaces row-by-row XML parsing with
    lookups against the previously built XML-derived core tables:

        member-level public head table
          + run_core
          + experiment_core
          + sample_core
          + sample_attribute_core
          -> wildtype A/B no-exclusion member-level output
          -> all-members-pass Run download table

    Difference from Step 3b:
        Step 3b rejected rows with mutant/treated/disease/transgenic-like
        exclusion terms. Step 3c keeps those rows when they satisfy the
        ordinary transcriptomic RNA-seq and strong A/B wildtype evidence gates.
        Exclusion terms are still recorded in QC for audit.

Inputs:
    1. Step 2 public member-level head table.
    2. Generic XML index core directory.

Outputs:
    tables/wildtype_ab_no_exclusion_transcriptomic_rnaseq_member_level.parquet
    tables/wildtype_ab_no_exclusion_transcriptomic_rnaseq_member_level.tsv.gz
    tables/wildtype_ab_no_exclusion_transcriptomic_rnaseq_runs_for_download.tsv.gz
    qc/filter_funnel.tsv
    qc/rejection_reason_counts.tsv
    qc/member_vs_run_summary.tsv
    qc/generic_index_qc.tsv
    manifest.json

Safety:
    The script is dry-run by default. With --execute it still refuses an
    unbounded full run. Use --limit-runs for pilots or
    --run-hash-buckets/--run-hash-remainder for sharded production runs.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import json
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from time import perf_counter
from typing import Any, Iterable

try:
    import duckdb
except ImportError as exc:  # pragma: no cover
    raise SystemExit("duckdb is required. Install it in the active Python environment.") from exc

from xml_semantic_common import (
    LIBRARY_SELECTION_ALLOWLIST,
    evaluate_wildtype,
    is_selection_allowed,
    is_source_transcriptomic,
    is_strategy_rnaseq,
    normalize_text,
)


DEFAULT_MEMBER_HEAD = Path(
    "/data3/m252202014/SRA/filtered_tables/"
    "sra_run_members_live_nonzero_public_20260703/tables/"
    "sra_run_members_live_nonzero_public_member_level.parquet"
)
DEFAULT_GENERIC_CORE = Path(
    "/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/"
    "20260516_full_streaming_v1/core"
)
DEFAULT_OUTDIR = Path(
    "/data3/m252202014/SRA/filtered_tables/"
    "wildtype_ab_no_exclusion_transcriptomic_rnaseq_generic_index_20260707"
)

STAGE = "02_stage2_run_members_head_table.step3c_generic_xml_index_no_exclusion_filtering"
GATING_MODE = "wildtype_ab_no_exclusion"
OUTPUT_PREFIX = "wildtype_ab_no_exclusion_transcriptomic_rnaseq"

MEMBER_REQUIRED_COLUMNS = [
    "Run",
    "Member_Name",
    "Experiment",
    "Sample",
    "BioSample",
    "Study",
    "Spots",
    "Bases",
    "Status",
    "Accessions_Visibility",
]
CORE_REQUIRED = {
    "run_core": ["run_accession", "experiment_accession"],
    "experiment_core": [
        "experiment_accession",
        "sample_accession",
        "library_strategy",
        "library_source",
        "library_selection",
    ],
    "sample_core": ["sample_accession", "bio_sample_id", "taxon_id", "scientific_name"],
    "sample_attribute_core": ["sample_accession", "tag", "value", "value_truncated"],
}

MEMBER_OUTPUT_COLUMNS = [
    "Run",
    "Member_Name",
    "Experiment",
    "Sample",
    "BioSample",
    "Study",
    "Spots",
    "Bases",
    "Status",
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
]
RUN_DOWNLOAD_COLUMNS = [
    "Run",
    "Experiment_Set",
    "Sample_Set",
    "BioSample_Set",
    "Study_Set",
    "member_rows_total",
    "member_rows_passed",
    "Spots",
    "Bases",
    "Visibility",
    "run_filter_status",
]


@dataclass(frozen=True)
class ExperimentSemantic:
    """Experiment-level XML semantics used by the ordinary transcriptome gate.

    Flow position:
        After member candidates are selected and before member-level pass/fail
        evaluation.
    Input:
        Rows from generic experiment_core for candidate Experiment accessions.
    Output:
        Normalized library fields plus the three boolean gates used by the
        ordinary transcriptomic RNA-seq rule.
    """

    sample_accession: str | None
    library_strategy: str | None
    library_source: str | None
    library_selection: str | None
    strategy_pass: bool
    source_pass: bool
    selection_pass: bool
    core_rows: int
    distinct_semantic_rows: int
    has_conflict: bool


@dataclass(frozen=True)
class SampleSemantic:
    """Sample-level XML semantics used by taxon and strong wildtype gates.

    Flow position:
        After sample_core and sample_attribute_core are joined to candidate
        Samples.
    Input:
        TAXON_ID/scientific_name from sample_core and A/B evidence/exclusion
        evaluation from sample_attribute_core.
    Output:
        Sample pass/fail ingredients reused by every member row pointing to the
        same Sample accession.
    """

    taxon_id: str | None
    scientific_name: str | None
    wildtype_ab_strong: bool
    exclusion_terms_present: bool
    evidence_levels: list[str]
    evidence_tags: list[str]
    evidence_values: list[str]
    core_rows: int
    distinct_taxon_ids: int
    has_truncated_attribute: bool
    has_taxon_conflict: bool


def utc_now() -> str:
    """Return an ISO-8601 UTC timestamp for manifest lineage."""
    return datetime.now(timezone.utc).isoformat()


def sql_quote(value: str | Path) -> str:
    """Escape a path/string for use as a DuckDB SQL single-quoted literal."""
    return str(value).replace("'", "''")


def describe_parquet(con: Any, path: Path) -> list[str]:
    """Read a Parquet schema before scanning the data body."""
    rows = con.execute(f"DESCRIBE SELECT * FROM read_parquet('{sql_quote(path)}')").fetchall()
    return [row[0] for row in rows]


def validate_columns(actual: list[str], required: list[str], label: str) -> None:
    """Fail fast when an input table does not match the expected contract."""
    missing = [column for column in required if column not in actual]
    if missing:
        raise SystemExit(f"{label} is missing required columns: {', '.join(missing)}")


def core_path(core_dir: Path, table_name: str) -> Path:
    """Resolve a generic XML core table path from the core directory."""
    return core_dir / f"{table_name}.parquet"


def require_file(path: Path, label: str) -> None:
    """Protect the pipeline from silently treating a missing input as zero rows."""
    if not path.exists():
        raise SystemExit(f"{label} does not exist: {path}")


def prepare_outdir(outdir: Path, overwrite: bool, qc_only: bool) -> dict[str, Path]:
    """Create the output layout and prevent accidental mixing of old/new runs.

    Non-empty output directories are refused unless --overwrite is explicit.
    When overwritten, the previous directory is renamed instead of deleted so
    the run remains recoverable.
    """
    if outdir.exists() and any(outdir.iterdir()) and not overwrite:
        raise SystemExit(f"Output directory already exists and is not empty: {outdir}. Use --overwrite.")
    if outdir.exists() and any(outdir.iterdir()) and overwrite:
        backup = outdir.with_name(f"{outdir.name}.previous_{datetime.now().strftime('%Y%m%d_%H%M%S')}")
        outdir.rename(backup)

    paths = {"qc": outdir / "qc"}
    if not qc_only:
        paths["tables"] = outdir / "tables"
    for path in paths.values():
        path.mkdir(parents=True, exist_ok=True)
    return paths


def write_dict_tsv(path: Path, rows: list[dict[str, Any]]) -> None:
    """Write small QC tables as UTF-8 TSV files."""
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    columns = list(rows[0].keys())
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def write_tsv_gz(path: Path, rows: list[dict[str, Any]], columns: list[str]) -> None:
    """Write compressed TSV output with a stable column order."""
    with gzip.open(path, "wt", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def create_member_input(con: Any, member_head: Path, args: argparse.Namespace) -> dict[str, Any]:
    """Materialize the candidate member table for this pilot or shard.

    Flow position:
        This is the boundary between Step 2 and Step 3c. All downstream XML
        semantic joins are limited to these member rows.
    Why it is written this way:
        --limit-runs selects complete Run groups, which avoids accidentally
        splitting multi-member Runs during pilots. --limit-rows exists only for
        QC-only smoke tests because it can cut through a multi-member Run and
        would make a Run download table unsafe.
    """
    source = f"read_parquet('{sql_quote(member_head)}')"
    visibility_expr = "Accessions_Visibility"
    base_select = f"""
        SELECT
            Run,
            Member_Name,
            Experiment,
            Sample,
            BioSample,
            Study,
            TRY_CAST(Spots AS BIGINT) AS Spots,
            TRY_CAST(Bases AS BIGINT) AS Bases,
            Status,
            {visibility_expr} AS Visibility
        FROM {source}
    """
    filters: list[str] = []
    scope = "unbounded"
    if args.run_hash_buckets is not None:
        filters.append(f"hash(Run) % {int(args.run_hash_buckets)} = {int(args.run_hash_remainder)}")
        scope = f"run_hash_{args.run_hash_remainder}_of_{args.run_hash_buckets}"
    where_sql = f"WHERE {' AND '.join(filters)}" if filters else ""

    if args.limit_runs:
        scope = f"{scope}.limit_runs_{args.limit_runs}" if filters else f"limit_runs_{args.limit_runs}"
        con.execute(
            f"""
            CREATE OR REPLACE TEMP TABLE member_base AS
            {base_select}
            {where_sql}
            """
        )
        con.execute(
            f"""
            CREATE OR REPLACE TEMP TABLE picked_runs AS
            SELECT Run
            FROM member_base
            WHERE Run IS NOT NULL AND trim(Run) <> ''
            GROUP BY Run
            ORDER BY Run
            LIMIT {int(args.limit_runs)}
            """
        )
        con.execute(
            """
            CREATE OR REPLACE TEMP TABLE member_input AS
            SELECT b.*
            FROM member_base AS b
            INNER JOIN picked_runs AS p
              ON b.Run = p.Run
            ORDER BY b.Run, b.Member_Name, b.Experiment, b.Sample
            """
        )
    elif args.limit_rows:
        scope = f"{scope}.limit_rows_{args.limit_rows}" if filters else f"limit_rows_{args.limit_rows}"
        con.execute(
            f"""
            CREATE OR REPLACE TEMP TABLE member_input AS
            {base_select}
            {where_sql}
            LIMIT {int(args.limit_rows)}
            """
        )
    else:
        con.execute(
            f"""
            CREATE OR REPLACE TEMP TABLE member_input AS
            {base_select}
            {where_sql}
            """
        )

    rows, runs, experiments, samples = con.execute(
        """
        SELECT
            COUNT(*) AS rows,
            COUNT(DISTINCT Run) AS runs,
            COUNT(DISTINCT Experiment) AS experiments,
            COUNT(DISTINCT Sample) AS samples
        FROM member_input
        """
    ).fetchone()
    return {
        "scope": scope,
        "input_member_rows": int(rows),
        "input_run_count": int(runs),
        "input_experiment_count": int(experiments),
        "input_sample_count": int(samples),
    }


def fetch_member_rows(con: Any) -> list[dict[str, Any]]:
    """Load candidate members into Python for strict per-member aggregation."""
    columns = [row[0] for row in con.execute("DESCRIBE member_input").fetchall()]
    return [dict(zip(columns, row)) for row in con.execute("SELECT * FROM member_input").fetchall()]


def load_run_semantics(con: Any, run_core: Path) -> dict[str, dict[str, Any]]:
    """Load Run existence and Run->Experiment_REF QC from generic run_core."""
    rows = con.execute(
        f"""
        WITH wanted AS (
            SELECT DISTINCT Run
            FROM member_input
            WHERE Run IS NOT NULL AND trim(Run) <> ''
        )
        SELECT
            r.run_accession,
            any_value(r.experiment_accession) AS experiment_accession,
            count(*) AS core_rows,
            count(DISTINCT coalesce(r.experiment_accession, '')) AS distinct_experiment_refs
        FROM read_parquet('{sql_quote(run_core)}') AS r
        INNER JOIN wanted AS w
          ON r.run_accession = w.Run
        GROUP BY r.run_accession
        """
    ).fetchall()
    return {
        row[0]: {
            "experiment_accession": row[1],
            "core_rows": int(row[2]),
            "distinct_experiment_refs": int(row[3]),
        }
        for row in rows
    }


def load_experiment_semantics(con: Any, experiment_core: Path) -> dict[str, ExperimentSemantic]:
    """Load and evaluate ordinary transcriptomic RNA-seq fields per Experiment."""
    rows = con.execute(
        f"""
        WITH wanted AS (
            SELECT DISTINCT Experiment
            FROM member_input
            WHERE Experiment IS NOT NULL AND trim(Experiment) <> ''
        )
        SELECT
            e.experiment_accession,
            any_value(e.sample_accession) AS sample_accession,
            any_value(e.library_strategy) AS library_strategy,
            any_value(e.library_source) AS library_source,
            any_value(e.library_selection) AS library_selection,
            count(*) AS core_rows,
            count(DISTINCT concat_ws(
                '|',
                coalesce(e.sample_accession, ''),
                coalesce(e.library_strategy, ''),
                coalesce(e.library_source, ''),
                coalesce(e.library_selection, '')
            )) AS distinct_semantic_rows
        FROM read_parquet('{sql_quote(experiment_core)}') AS e
        INNER JOIN wanted AS w
          ON e.experiment_accession = w.Experiment
        GROUP BY e.experiment_accession
        """
    ).fetchall()
    semantics: dict[str, ExperimentSemantic] = {}
    for row in rows:
        strategy = normalize_text(row[2])
        source = normalize_text(row[3])
        selection = normalize_text(row[4])
        semantics[row[0]] = ExperimentSemantic(
            sample_accession=row[1],
            library_strategy=strategy,
            library_source=source,
            library_selection=selection,
            strategy_pass=is_strategy_rnaseq(strategy),
            source_pass=is_source_transcriptomic(source),
            selection_pass=is_selection_allowed(selection),
            core_rows=int(row[5]),
            distinct_semantic_rows=int(row[6]),
            has_conflict=int(row[6]) > 1,
        )
    return semantics


def load_sample_core_semantics(con: Any, sample_core: Path) -> dict[str, dict[str, Any]]:
    """Load TAXON_ID and organism label for candidate Samples."""
    rows = con.execute(
        f"""
        WITH wanted AS (
            SELECT DISTINCT Sample
            FROM member_input
            WHERE Sample IS NOT NULL AND trim(Sample) <> ''
        )
        SELECT
            s.sample_accession,
            any_value(s.taxon_id) AS taxon_id,
            any_value(s.scientific_name) AS scientific_name,
            count(*) AS core_rows,
            count(DISTINCT coalesce(s.taxon_id, '')) AS distinct_taxon_ids
        FROM read_parquet('{sql_quote(sample_core)}') AS s
        INNER JOIN wanted AS w
          ON s.sample_accession = w.Sample
        GROUP BY s.sample_accession
        """
    ).fetchall()
    return {
        row[0]: {
            "taxon_id": normalize_text(row[1]),
            "scientific_name": normalize_text(row[2]),
            "core_rows": int(row[3]),
            "distinct_taxon_ids": int(row[4]),
        }
        for row in rows
    }


def load_sample_attributes(
    con: Any, sample_attribute_core: Path
) -> tuple[dict[str, list[tuple[str, str]]], set[str], dict[str, int]]:
    """Load SAMPLE_ATTRIBUTE rows for candidate Samples only.

    Flow position:
        This is the only place where sample_attribute_core can expand row
        counts. The semi-join with member_input prevents scanning results for
        irrelevant Samples from being returned to Python.
    """
    rows = con.execute(
        f"""
        WITH wanted AS (
            SELECT DISTINCT Sample
            FROM member_input
            WHERE Sample IS NOT NULL AND trim(Sample) <> ''
        )
        SELECT
            a.sample_accession,
            a.tag,
            a.value,
            coalesce(TRY_CAST(a.value_truncated AS BOOLEAN), false) AS value_truncated
        FROM read_parquet('{sql_quote(sample_attribute_core)}') AS a
        INNER JOIN wanted AS w
          ON a.sample_accession = w.Sample
        WHERE a.tag IS NOT NULL
          AND trim(a.tag) <> ''
          AND a.value IS NOT NULL
          AND trim(a.value) <> ''
        """
    ).fetchall()

    attributes: dict[str, list[tuple[str, str]]] = defaultdict(list)
    truncated_samples: set[str] = set()
    truncated_rows = 0
    for sample_accession, tag, value, value_truncated in rows:
        attributes[sample_accession].append((str(tag), str(value)))
        if value_truncated:
            truncated_rows += 1
            truncated_samples.add(sample_accession)

    return attributes, truncated_samples, {
        "sample_attribute_rows": len(rows),
        "samples_with_attributes": len(attributes),
        "value_truncated_rows": truncated_rows,
        "samples_with_value_truncated_attributes": len(truncated_samples),
    }


def evaluate_samples(
    sample_core_semantics: dict[str, dict[str, Any]],
    attributes_by_sample: dict[str, list[tuple[str, str]]],
    truncated_samples: set[str],
) -> dict[str, SampleSemantic]:
    """Apply TAXON_ID and strict A/B wildtype gates at Sample level."""
    semantics: dict[str, SampleSemantic] = {}
    for sample_accession, core in sample_core_semantics.items():
        evidence = evaluate_wildtype(attributes_by_sample.get(sample_accession, []))
        semantics[sample_accession] = SampleSemantic(
            taxon_id=core["taxon_id"],
            scientific_name=core["scientific_name"],
            wildtype_ab_strong=evidence.has_ab_evidence,
            exclusion_terms_present=evidence.has_exclusion,
            evidence_levels=evidence.evidence_levels,
            evidence_tags=evidence.evidence_tags,
            evidence_values=evidence.evidence_values,
            core_rows=core["core_rows"],
            distinct_taxon_ids=core["distinct_taxon_ids"],
            has_truncated_attribute=sample_accession in truncated_samples,
            has_taxon_conflict=core["distinct_taxon_ids"] > 1,
        )
    return semantics


def join_set(values: Iterable[str]) -> str:
    """Join unique non-empty values in deterministic order."""
    return ";".join(sorted({value for value in values if value}))


def member_output_row(
    row: dict[str, Any],
    experiment_info: ExperimentSemantic,
    sample_info: SampleSemantic,
) -> dict[str, Any]:
    """Build one passed member-level output row."""
    return {
        "Run": row.get("Run"),
        "Member_Name": row.get("Member_Name"),
        "Experiment": row.get("Experiment"),
        "Sample": row.get("Sample"),
        "BioSample": row.get("BioSample"),
        "Study": row.get("Study"),
        "Spots": row.get("Spots"),
        "Bases": row.get("Bases"),
        "Status": row.get("Status"),
        "Visibility": row.get("Visibility"),
        "library_strategy": experiment_info.library_strategy,
        "library_source": experiment_info.library_source,
        "library_selection": experiment_info.library_selection,
        "taxon_id": sample_info.taxon_id,
        "scientific_name": sample_info.scientific_name,
        "wildtype_evidence_level_set": ";".join(sample_info.evidence_levels),
        "wildtype_evidence_tag_set": ";".join(sample_info.evidence_tags),
        "wildtype_evidence_value_set": ";".join(sample_info.evidence_values),
        "member_filter_status": "pass",
    }


def evaluate_members(
    member_rows: list[dict[str, Any]],
    run_semantics: dict[str, dict[str, Any]],
    experiment_semantics: dict[str, ExperimentSemantic],
    sample_semantics: dict[str, SampleSemantic],
) -> dict[str, Any]:
    """Join semantic dictionaries back to member rows and apply no-exclusion gates.

    The member-level table records rows that pass all non-exclusion gates.
    The Run download table is stricter: every member row for the Run in this
    input scope must pass, otherwise that Run is excluded from the download
    list. Exclusion terms remain QC only in Step 3c.
    """
    passed_members: list[dict[str, Any]] = []
    run_totals: Counter[str] = Counter()
    run_passed: Counter[str] = Counter()
    run_values: dict[str, dict[str, set[str]]] = defaultdict(lambda: defaultdict(set))
    run_numeric: dict[str, dict[str, int]] = defaultdict(dict)
    run_visibility: dict[str, str | None] = {}
    funnel_counts: Counter[str] = Counter()
    funnel_runs: dict[str, set[str]] = defaultdict(set)
    reason_counts: Counter[str] = Counter()
    reason_runs: dict[str, set[str]] = defaultdict(set)
    run_experiment_ref_mismatch = 0
    experiment_sample_ref_mismatch = 0
    wildtype_ab_with_exclusion_terms = 0
    wildtype_ab_with_exclusion_runs: set[str] = set()
    passed_samples_with_truncated_attrs: set[str] = set()

    def mark(metric: str, row: dict[str, Any]) -> None:
        funnel_counts[metric] += 1
        if row.get("Run"):
            funnel_runs[metric].add(str(row["Run"]))

    def reject(reason: str, row: dict[str, Any]) -> None:
        reason_counts[reason] += 1
        if row.get("Run"):
            reason_runs[reason].add(str(row["Run"]))

    for row in member_rows:
        run = str(row.get("Run") or "")
        experiment = str(row.get("Experiment") or "")
        sample = str(row.get("Sample") or "")
        run_totals[run] += 1
        run_visibility[run] = row.get("Visibility")
        for field, set_name in [
            ("Experiment", "Experiment_Set"),
            ("Sample", "Sample_Set"),
            ("BioSample", "BioSample_Set"),
            ("Study", "Study_Set"),
        ]:
            value = normalize_text(row.get(field))
            if value:
                run_values[run][set_name].add(value)
        for field in ["Spots", "Bases"]:
            try:
                numeric = int(row.get(field) or 0)
            except (TypeError, ValueError):
                numeric = 0
            run_numeric[run][field] = max(run_numeric[run].get(field, 0), numeric)

        mark("input_member_rows", row)
        run_info = run_semantics.get(run)
        experiment_info = experiment_semantics.get(experiment)
        sample_info = sample_semantics.get(sample)

        run_present = run_info is not None
        run_unambiguous = (
            run_present and int(run_info.get("distinct_experiment_refs") or 0) <= 1
        )
        run_ref_matches = (
            run_unambiguous and run_info.get("experiment_accession") == experiment
        )
        experiment_present = experiment_info is not None
        experiment_unambiguous = experiment_present and not experiment_info.has_conflict
        sample_present = sample_info is not None
        sample_unambiguous = sample_present and not sample_info.has_taxon_conflict

        # This block intentionally separates two concepts:
        # - rejection reasons are diagnostic and mostly non-exclusive;
        # - filter_funnel metrics are ordered and only count rows that survived
        #   all previous gates, so the table can be read top-to-bottom.
        if run_present:
            mark("run_core_resolved", row)
            if run_info.get("experiment_accession") != experiment:
                run_experiment_ref_mismatch += 1
        else:
            reject("run_core_missing", row)
        if run_present and not run_unambiguous:
            reject("run_core_experiment_ref_conflict", row)
        if run_unambiguous:
            mark("run_core_experiment_ref_unambiguous", row)
            if run_ref_matches:
                mark("run_experiment_ref_matches", row)
            else:
                reject("run_experiment_ref_mismatch", row)

        if run_ref_matches and experiment_present:
            mark("experiment_core_resolved", row)
        elif run_ref_matches:
            reject("experiment_core_missing", row)
        if experiment_present and experiment_info.sample_accession != sample:
            experiment_sample_ref_mismatch += 1
        if experiment_present and not experiment_unambiguous:
            reject("experiment_core_semantic_conflict", row)
        if run_ref_matches and experiment_unambiguous:
            mark("experiment_core_unambiguous", row)

        if run_ref_matches and experiment_unambiguous and sample_present:
            mark("sample_core_resolved", row)
        elif run_ref_matches and experiment_unambiguous:
            reject("sample_core_missing", row)
        if sample_present and not sample_unambiguous:
            reject("sample_core_taxon_conflict", row)
        if run_ref_matches and experiment_unambiguous and sample_unambiguous:
            mark("sample_core_taxon_unambiguous", row)

        if experiment_unambiguous and not experiment_info.strategy_pass:
            reject("library_strategy_not_rnaseq", row)
        library_strategy_gate = (
            run_ref_matches
            and experiment_unambiguous
            and sample_unambiguous
            and experiment_info.strategy_pass
        )
        if library_strategy_gate:
            mark("library_strategy_rnaseq", row)

        if experiment_unambiguous and experiment_info.strategy_pass and not experiment_info.source_pass:
            reject("library_source_not_transcriptomic", row)
        library_source_gate = library_strategy_gate and experiment_info.source_pass
        if library_source_gate:
            mark("library_source_transcriptomic", row)

        if (
            experiment_unambiguous
            and experiment_info.strategy_pass
            and experiment_info.source_pass
            and not experiment_info.selection_pass
        ):
            reject("library_selection_not_allowed", row)
        library_selection_gate = library_source_gate and experiment_info.selection_pass
        if library_selection_gate:
            mark("library_selection_allowlist", row)

        taxon_present = sample_unambiguous and sample_info.taxon_id is not None
        if library_selection_gate and taxon_present:
            mark("taxon_id_nonempty", row)
        elif library_selection_gate:
            reject("taxon_id_missing", row)

        if library_selection_gate and taxon_present and sample_info.wildtype_ab_strong:
            mark("wildtype_ab_strong", row)
        elif library_selection_gate and taxon_present:
            reject("no_ab_wildtype_evidence", row)

        if library_selection_gate and taxon_present and sample_info.wildtype_ab_strong:
            if sample_info.exclusion_terms_present:
                wildtype_ab_with_exclusion_terms += 1
                wildtype_ab_with_exclusion_runs.add(run)
            else:
                mark("wildtype_ab_without_exclusion_terms_qc", row)

        # Step 3c intentionally stops at strong wildtype A/B evidence. The
        # exclusion flag is still counted above, but it no longer removes rows
        # from the member-level pass table or Run download table.
        member_pass = (
            library_selection_gate
            and taxon_present
            and sample_info.wildtype_ab_strong
        )
        if member_pass:
            mark("strict_member_pass", row)
            run_passed[run] += 1
            passed_members.append(member_output_row(row, experiment_info, sample_info))
            if sample_info.has_truncated_attribute:
                passed_samples_with_truncated_attrs.add(sample)

    run_download_rows = build_run_download_rows(run_totals, run_passed, run_values, run_numeric, run_visibility)
    funnel_counts["strict_run_pass"] = len(run_download_rows)
    funnel_runs["strict_run_pass"] = {row["Run"] for row in run_download_rows}

    return {
        "passed_members": passed_members,
        "run_download_rows": run_download_rows,
        "filter_funnel": build_filter_funnel(funnel_counts, funnel_runs),
        "rejection_reason_counts": build_rejection_reason_counts(reason_counts, reason_runs),
        "member_vs_run_summary": build_member_vs_run_summary(run_totals, run_passed),
        "generic_index_qc": {
            "run_experiment_ref_mismatch_rows": run_experiment_ref_mismatch,
            "experiment_sample_ref_mismatch_rows": experiment_sample_ref_mismatch,
            "wildtype_ab_with_exclusion_terms_rows": wildtype_ab_with_exclusion_terms,
            "wildtype_ab_with_exclusion_terms_runs": len(wildtype_ab_with_exclusion_runs),
            "passed_samples_with_value_truncated_attributes": len(passed_samples_with_truncated_attrs),
        },
        "run_totals": run_totals,
    }


def build_run_download_rows(
    run_totals: Counter[str],
    run_passed: Counter[str],
    run_values: dict[str, dict[str, set[str]]],
    run_numeric: dict[str, dict[str, int]],
    run_visibility: dict[str, str | None],
) -> list[dict[str, Any]]:
    """Create one-row-per-Run download candidates for all-members-pass Runs."""
    rows: list[dict[str, Any]] = []
    for run in sorted(run_totals):
        if run and run_totals[run] == run_passed[run] and run_passed[run] > 0:
            values = run_values[run]
            rows.append(
                {
                    "Run": run,
                    "Experiment_Set": join_set(values.get("Experiment_Set", set())),
                    "Sample_Set": join_set(values.get("Sample_Set", set())),
                    "BioSample_Set": join_set(values.get("BioSample_Set", set())),
                    "Study_Set": join_set(values.get("Study_Set", set())),
                    "member_rows_total": run_totals[run],
                    "member_rows_passed": run_passed[run],
                    "Spots": run_numeric[run].get("Spots", 0),
                    "Bases": run_numeric[run].get("Bases", 0),
                    "Visibility": run_visibility.get(run),
                    "run_filter_status": "pass_all_members",
                }
            )
    return rows


def build_filter_funnel(counts: Counter[str], run_sets: dict[str, set[str]]) -> list[dict[str, Any]]:
    """Convert cumulative gate counters into a stable QC funnel table."""
    metrics = [
        "input_member_rows",
        "run_core_resolved",
        "run_core_experiment_ref_unambiguous",
        "run_experiment_ref_matches",
        "experiment_core_resolved",
        "experiment_core_unambiguous",
        "sample_core_resolved",
        "sample_core_taxon_unambiguous",
        "library_strategy_rnaseq",
        "library_source_transcriptomic",
        "library_selection_allowlist",
        "taxon_id_nonempty",
        "wildtype_ab_strong",
        "strict_member_pass",
        "strict_run_pass",
        "wildtype_ab_without_exclusion_terms_qc",
    ]
    return [
        {
            "metric": metric,
            "rows": counts.get(metric, 0),
            "distinct_runs": len(run_sets.get(metric, set())),
        }
        for metric in metrics
    ]


def build_rejection_reason_counts(counts: Counter[str], run_sets: dict[str, set[str]]) -> list[dict[str, Any]]:
    """Write non-exclusive rejection reasons for diagnostics."""
    reasons = [
        "run_core_missing",
        "run_core_experiment_ref_conflict",
        "run_experiment_ref_mismatch",
        "experiment_core_missing",
        "experiment_core_semantic_conflict",
        "sample_core_missing",
        "sample_core_taxon_conflict",
        "library_strategy_not_rnaseq",
        "library_source_not_transcriptomic",
        "library_selection_not_allowed",
        "taxon_id_missing",
        "no_ab_wildtype_evidence",
    ]
    return [
        {
            "reason": reason,
            "rows": counts.get(reason, 0),
            "distinct_runs": len(run_sets.get(reason, set())),
        }
        for reason in reasons
    ]


def build_member_vs_run_summary(run_totals: Counter[str], run_passed: Counter[str]) -> list[dict[str, Any]]:
    """Summarize the all-members-pass rule at Run level."""
    buckets = Counter()
    for run, total in run_totals.items():
        passed = run_passed[run]
        if passed == total and passed > 0:
            buckets["all_members_pass"] += 1
        elif passed > 0:
            buckets["partial_members_pass"] += 1
        else:
            buckets["no_members_pass"] += 1
    return [
        {"run_member_status": "all_members_pass", "runs": buckets["all_members_pass"]},
        {"run_member_status": "partial_members_pass", "runs": buckets["partial_members_pass"]},
        {"run_member_status": "no_members_pass", "runs": buckets["no_members_pass"]},
    ]


def write_member_parquet(con: Any, tables_dir: Path, member_rows: list[dict[str, Any]]) -> Path:
    """Write passed member rows to Parquet through a temporary TSV.

    DuckDB can infer a stable schema from the TSV and then emit Parquet. This
    avoids depending on pyarrow on the H100 user environment.
    """
    tsv = tables_dir / f"_{OUTPUT_PREFIX}_member_level.tmp.tsv"
    parquet = tables_dir / f"{OUTPUT_PREFIX}_member_level.parquet"
    with tsv.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=MEMBER_OUTPUT_COLUMNS, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(member_rows)
    con.execute(
        f"""
        COPY (
            SELECT
                Run,
                Member_Name,
                Experiment,
                Sample,
                BioSample,
                Study,
                TRY_CAST(Spots AS BIGINT) AS Spots,
                TRY_CAST(Bases AS BIGINT) AS Bases,
                Status,
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
            FROM read_csv('{sql_quote(tsv)}', delim='\\t', header=true, all_varchar=true)
        ) TO '{sql_quote(parquet)}' (FORMAT PARQUET)
        """
    )
    tsv.unlink()
    return parquet


def write_outputs(
    con: Any,
    paths: dict[str, Path],
    evaluation: dict[str, Any],
    qc_only: bool,
) -> dict[str, str]:
    """Write tables and QC files for this run."""
    outputs: dict[str, str] = {}
    if not qc_only:
        tables_dir = paths["tables"]
        member_parquet = write_member_parquet(con, tables_dir, evaluation["passed_members"])
        member_tsv_gz = tables_dir / f"{OUTPUT_PREFIX}_member_level.tsv.gz"
        run_tsv_gz = tables_dir / f"{OUTPUT_PREFIX}_runs_for_download.tsv.gz"
        write_tsv_gz(member_tsv_gz, evaluation["passed_members"], MEMBER_OUTPUT_COLUMNS)
        write_tsv_gz(run_tsv_gz, evaluation["run_download_rows"], RUN_DOWNLOAD_COLUMNS)
        outputs.update(
            {
                "member_level_parquet": str(member_parquet),
                "member_level_tsv_gz": str(member_tsv_gz),
                "run_download_tsv_gz": str(run_tsv_gz),
            }
        )

    write_dict_tsv(paths["qc"] / "filter_funnel.tsv", evaluation["filter_funnel"])
    write_dict_tsv(paths["qc"] / "rejection_reason_counts.tsv", evaluation["rejection_reason_counts"])
    write_dict_tsv(paths["qc"] / "member_vs_run_summary.tsv", evaluation["member_vs_run_summary"])
    return outputs


def write_manifest(
    outdir: Path,
    args: argparse.Namespace,
    input_counts: dict[str, Any],
    semantic_counts: dict[str, Any],
    outputs: dict[str, str],
    result_counts: dict[str, Any],
    timing: dict[str, float],
) -> None:
    """Write manifest.json with lineage, parameters, gates and counts."""
    payload = {
        "stage": STAGE,
        "gating_mode": GATING_MODE,
        "output_prefix": OUTPUT_PREFIX,
        "generated_at_utc": utc_now(),
        "inputs": {
            "member_head": str(args.member_head),
            "generic_core": str(args.generic_core),
        },
        "parameters": {
            "limit_runs": args.limit_runs,
            "limit_rows": args.limit_rows,
            "run_hash_buckets": args.run_hash_buckets,
            "run_hash_remainder": args.run_hash_remainder,
            "threads": args.threads,
            "qc_only": args.qc_only,
        },
        "input_counts": input_counts,
        # Keep the old semantic_counts key for shard/merge compatibility, and
        # expose the same payload under the reader-facing QC file name.
        "semantic_counts": semantic_counts,
        "generic_index_qc": semantic_counts,
        "strict_gates": {
            "library_strategy": "RNA-Seq",
            "library_source": "TRANSCRIPTOMIC",
            "library_selection": LIBRARY_SELECTION_ALLOWLIST,
            "wildtype_evidence": "sample_attribute A/B only",
            "exclusion_terms": "recorded as QC only; not a pass/fail gate",
            "taxon_id": "non-empty",
            "run_aggregation": "all member rows in the input scope must pass",
        },
        "outputs": outputs,
        "result_counts": result_counts,
        "timing_seconds": timing,
    }
    (outdir / "manifest.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def build_dry_plan(args: argparse.Namespace) -> dict[str, Any]:
    """Return a plan without checking large remote inputs or creating outputs."""
    return {
        "stage": STAGE,
        "gating_mode": GATING_MODE,
        "output_prefix": OUTPUT_PREFIX,
        "execute": False,
        "inputs": {
            "member_head": str(args.member_head),
            "generic_core": str(args.generic_core),
        },
        "outdir": str(args.outdir),
        "selection": {
            "limit_runs": args.limit_runs,
            "limit_rows": args.limit_rows,
            "run_hash_buckets": args.run_hash_buckets,
            "run_hash_remainder": args.run_hash_remainder,
            "allow_unbounded": args.allow_unbounded,
            "unbounded_supported": False,
        },
        "strict_gates": {
            "library_strategy": "RNA-Seq",
            "library_source": "TRANSCRIPTOMIC",
            "library_selection": LIBRARY_SELECTION_ALLOWLIST,
            "wildtype_evidence": "sample_attribute A/B only",
            "exclusion_terms": "recorded as QC only; not a pass/fail gate",
            "taxon_id": "non-empty",
        },
    }


def validate_execution_scope(args: argparse.Namespace) -> None:
    """Prevent accidental full-scale execution during pilot development."""
    if args.allow_unbounded:
        raise SystemExit(
            "--allow-unbounded is disabled for this Python aggregation route. "
            "Use --run-hash-buckets/--run-hash-remainder for production shards."
        )
    if args.limit_runs and args.limit_rows:
        raise SystemExit("Use only one of --limit-runs or --limit-rows.")
    if args.limit_rows and not args.qc_only:
        raise SystemExit("--limit-rows can split Run groups; use --qc-only or switch to --limit-runs.")
    if args.run_hash_buckets is None and args.run_hash_remainder is not None:
        raise SystemExit("--run-hash-remainder requires --run-hash-buckets.")
    if args.run_hash_buckets is not None:
        if args.run_hash_buckets <= 0:
            raise SystemExit("--run-hash-buckets must be > 0.")
        if args.run_hash_remainder is None:
            raise SystemExit("--run-hash-remainder is required with --run-hash-buckets.")
        if not 0 <= args.run_hash_remainder < args.run_hash_buckets:
            raise SystemExit("--run-hash-remainder must be in [0, --run-hash-buckets).")
    bounded = args.limit_runs or args.limit_rows or args.run_hash_buckets is not None
    if args.execute and not bounded:
        raise SystemExit(
            "Refusing unbounded execution. Use --limit-runs for pilots, "
            "or --run-hash-buckets/--run-hash-remainder for shards."
        )


def execute(args: argparse.Namespace) -> dict[str, Any]:
    """Run the generic-index Step 3c no-exclusion filter."""
    validate_execution_scope(args)
    con = duckdb.connect()
    con.execute(f"PRAGMA threads={int(args.threads)}")

    require_file(args.member_head, "member head")
    validate_columns(describe_parquet(con, args.member_head), MEMBER_REQUIRED_COLUMNS, "member head")
    for table_name, required in CORE_REQUIRED.items():
        path = core_path(args.generic_core, table_name)
        require_file(path, f"generic {table_name}")
        validate_columns(describe_parquet(con, path), required, f"generic {table_name}")

    paths = prepare_outdir(args.outdir, args.overwrite, args.qc_only)
    started = perf_counter()

    t0 = perf_counter()
    input_counts = create_member_input(con, args.member_head, args)
    member_rows = fetch_member_rows(con)
    member_load_elapsed = perf_counter() - t0

    t0 = perf_counter()
    run_semantics = load_run_semantics(con, core_path(args.generic_core, "run_core"))
    run_elapsed = perf_counter() - t0

    t0 = perf_counter()
    experiment_semantics = load_experiment_semantics(con, core_path(args.generic_core, "experiment_core"))
    experiment_elapsed = perf_counter() - t0

    t0 = perf_counter()
    sample_core_semantics = load_sample_core_semantics(con, core_path(args.generic_core, "sample_core"))
    sample_core_elapsed = perf_counter() - t0

    t0 = perf_counter()
    attributes_by_sample, truncated_samples, attribute_metrics = load_sample_attributes(
        con, core_path(args.generic_core, "sample_attribute_core")
    )
    sample_attribute_elapsed = perf_counter() - t0

    sample_semantics = evaluate_samples(sample_core_semantics, attributes_by_sample, truncated_samples)
    evaluation = evaluate_members(member_rows, run_semantics, experiment_semantics, sample_semantics)
    generic_qc = {
        "run_core_candidate_rows": len(run_semantics),
        "experiment_core_candidate_rows": len(experiment_semantics),
        "sample_core_candidate_rows": len(sample_core_semantics),
        "sample_attribute_rows": attribute_metrics["sample_attribute_rows"],
        "samples_with_attributes": attribute_metrics["samples_with_attributes"],
        "value_truncated_rows": attribute_metrics["value_truncated_rows"],
        "samples_with_value_truncated_attributes": attribute_metrics["samples_with_value_truncated_attributes"],
        "experiment_core_conflict_count": sum(
            1 for item in experiment_semantics.values() if item.distinct_semantic_rows > 1
        ),
        "sample_core_taxon_conflict_count": sum(
            1 for item in sample_core_semantics.values() if item["distinct_taxon_ids"] > 1
        ),
        "run_core_experiment_ref_conflict_count": sum(
            1 for item in run_semantics.values() if item["distinct_experiment_refs"] > 1
        ),
        **evaluation["generic_index_qc"],
    }
    write_dict_tsv(paths["qc"] / "generic_index_qc.tsv", [{"metric": k, "value": v} for k, v in generic_qc.items()])
    outputs = write_outputs(con, paths, evaluation, args.qc_only)

    result_counts = {
        "input_member_rows": input_counts["input_member_rows"],
        "input_run_count": input_counts["input_run_count"],
        "strict_member_pass_rows": len(evaluation["passed_members"]),
        "strict_run_pass_rows": len(evaluation["run_download_rows"]),
    }
    timing = {
        "member_input_load": member_load_elapsed,
        "run_core_lookup": run_elapsed,
        "experiment_core_lookup": experiment_elapsed,
        "sample_core_lookup": sample_core_elapsed,
        "sample_attribute_lookup": sample_attribute_elapsed,
        "total": perf_counter() - started,
    }
    write_manifest(args.outdir, args, input_counts, generic_qc, outputs, result_counts, timing)
    con.close()

    summary = {
        "stage": STAGE,
        "outdir": str(args.outdir),
        "qc_only": args.qc_only,
        **result_counts,
        "timing_seconds": timing,
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    return summary


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse command line arguments for dry-run, pilot, shard and full modes."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--member-head", type=Path, default=DEFAULT_MEMBER_HEAD)
    parser.add_argument("--generic-core", type=Path, default=DEFAULT_GENERIC_CORE)
    parser.add_argument("--outdir", type=Path, default=DEFAULT_OUTDIR)
    parser.add_argument("--limit-runs", type=int, default=0, help="Select complete groups for the first N Runs.")
    parser.add_argument("--limit-rows", type=int, default=0, help="Select only the first N member rows; QC-only smoke tests only.")
    parser.add_argument("--run-hash-buckets", type=int, default=None, help="Shard count for hash(Run) sharding.")
    parser.add_argument("--run-hash-remainder", type=int, default=None, help="Shard remainder for hash(Run) sharding.")
    parser.add_argument("--threads", type=int, default=8)
    parser.add_argument("--qc-only", action="store_true", help="Write QC and manifest only, not result tables.")
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--allow-unbounded", action="store_true", help="Disabled safety valve; use hash shards instead.")
    parser.add_argument("--execute", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    validate_execution_scope(args)
    if args.limit_runs < 0 or args.limit_rows < 0:
        raise SystemExit("--limit-runs and --limit-rows must be >= 0.")
    if args.threads <= 0:
        raise SystemExit("--threads must be > 0.")
    if not args.execute:
        print(json.dumps(build_dry_plan(args), ensure_ascii=False, indent=2))
        return 0
    execute(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
