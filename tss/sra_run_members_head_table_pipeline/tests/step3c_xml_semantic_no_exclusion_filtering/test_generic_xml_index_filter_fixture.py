from __future__ import annotations

import csv
import gzip
import json
import subprocess
import sys
from pathlib import Path

import pytest


duckdb = pytest.importorskip("duckdb")

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "step3c_xml_semantic_no_exclusion_filtering" / "build_wildtype_ab_no_exclusion_from_generic_xml_index.py"
RUNNER_SCRIPT = ROOT / "scripts" / "step3c_xml_semantic_no_exclusion_filtering" / "run_generic_index_shards.py"
MERGE_SCRIPT = ROOT / "scripts" / "step3c_xml_semantic_no_exclusion_filtering" / "merge_generic_index_shards.py"
OUTPUT_PREFIX = "wildtype_ab_no_exclusion_transcriptomic_rnaseq"
MEMBER_OUTPUT = f"{OUTPUT_PREFIX}_member_level.parquet"
RUN_OUTPUT = f"{OUTPUT_PREFIX}_runs_for_download.tsv.gz"

MEMBER_COLUMNS = [
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


def write_tsv(path: Path, rows: list[dict[str, object]], columns: list[str]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def tsv_to_parquet(tsv: Path, parquet: Path) -> None:
    con = duckdb.connect()
    con.execute(
        f"COPY (SELECT * FROM read_csv('{tsv.as_posix()}', delim='\\t', header=true, all_varchar=true)) "
        f"TO '{parquet.as_posix()}' (FORMAT PARQUET)"
    )
    con.close()


def read_tsv_gz(path: Path) -> list[dict[str, str]]:
    with gzip.open(path, "rt", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def member_row(run: str, member: str, experiment: str, sample: str, biosample: str) -> dict[str, object]:
    return {
        "Run": run,
        "Member_Name": member,
        "Experiment": experiment,
        "Sample": sample,
        "BioSample": biosample,
        "Study": "SRPTEST",
        "Spots": 100,
        "Bases": 1000,
        "Status": "live",
        "Accessions_Visibility": "public",
    }


def write_parquet_from_rows(path: Path, rows: list[dict[str, object]], columns: list[str]) -> None:
    tsv = path.with_suffix(".tsv")
    write_tsv(tsv, rows, columns)
    tsv_to_parquet(tsv, path)


def make_fixture(tmp_path: Path) -> tuple[Path, Path]:
    member_rows = [
        member_row("SRR_PASS_A", "default", "SRX_PASS_A", "SRS_PASS_A", "SAMN_PASS_A"),
        member_row("SRR_PASS_B", "default", "SRX_PASS_B", "SRS_PASS_B", "SAMN_PASS_B"),
        member_row("SRR_BAD_SELECTION", "default", "SRX_BAD_SELECTION", "SRS_BAD_SELECTION", "SAMN_BAD_SELECTION"),
        member_row("SRR_REVIEW_ONLY", "default", "SRX_REVIEW_ONLY", "SRS_REVIEW_ONLY", "SAMN_REVIEW_ONLY"),
        member_row("SRR_NEGATIVE", "default", "SRX_NEGATIVE", "SRS_NEGATIVE", "SAMN_NEGATIVE"),
        member_row("SRR_NO_TAXON", "default", "SRX_NO_TAXON", "SRS_NO_TAXON", "SAMN_NO_TAXON"),
        member_row("SRR_MISSING_RUN_CORE", "default", "SRX_MISSING_RUN_CORE", "SRS_MISSING_RUN_CORE", "SAMN_MISSING"),
        member_row("SRR_COMMON_CRESS", "default", "SRX_COMMON_CRESS", "SRS_COMMON_CRESS", "SAMN_COMMON_CRESS"),
        member_row("SRR_MULTI", "member_A", "SRX_MULTI", "SRS_MULTI_A", "SAMN_MULTI_A"),
        member_row("SRR_MULTI", "member_B", "SRX_MULTI", "SRS_MULTI_B", "SAMN_MULTI_B"),
    ]
    member_parquet = tmp_path / "member.parquet"
    write_parquet_from_rows(member_parquet, member_rows, MEMBER_COLUMNS)

    core = tmp_path / "core"
    core.mkdir()
    run_rows = [
        {"run_accession": row["Run"], "experiment_accession": row["Experiment"]}
        for row in member_rows
        if row["Run"] != "SRR_MISSING_RUN_CORE"
    ]
    # run_core is one row per Run in the real profile, so collapse duplicate
    # SRR_MULTI rows to the same Run -> Experiment relationship.
    seen_runs: set[str] = set()
    unique_run_rows = []
    for row in run_rows:
        if row["run_accession"] in seen_runs:
            continue
        seen_runs.add(str(row["run_accession"]))
        unique_run_rows.append(row)
    write_parquet_from_rows(core / "run_core.parquet", unique_run_rows, ["run_accession", "experiment_accession"])

    experiment_rows = [
        {"experiment_accession": "SRX_PASS_A", "sample_accession": "SRS_PASS_A", "library_strategy": "RNA-Seq", "library_source": "TRANSCRIPTOMIC", "library_selection": "PolyA"},
        {"experiment_accession": "SRX_PASS_B", "sample_accession": "SRS_PASS_B", "library_strategy": "RNA-Seq", "library_source": "TRANSCRIPTOMIC", "library_selection": "RANDOM PCR"},
        {"experiment_accession": "SRX_BAD_SELECTION", "sample_accession": "SRS_BAD_SELECTION", "library_strategy": "RNA-Seq", "library_source": "TRANSCRIPTOMIC", "library_selection": "size fractionation"},
        {"experiment_accession": "SRX_REVIEW_ONLY", "sample_accession": "SRS_REVIEW_ONLY", "library_strategy": "RNA-Seq", "library_source": "TRANSCRIPTOMIC", "library_selection": "cDNA"},
        {"experiment_accession": "SRX_NEGATIVE", "sample_accession": "SRS_NEGATIVE", "library_strategy": "RNA-Seq", "library_source": "TRANSCRIPTOMIC", "library_selection": "Oligo-dT"},
        {"experiment_accession": "SRX_NO_TAXON", "sample_accession": "SRS_NO_TAXON", "library_strategy": "RNA-Seq", "library_source": "TRANSCRIPTOMIC", "library_selection": "cDNA"},
        {"experiment_accession": "SRX_MISSING_RUN_CORE", "sample_accession": "SRS_MISSING_RUN_CORE", "library_strategy": "RNA-Seq", "library_source": "TRANSCRIPTOMIC", "library_selection": "cDNA"},
        {"experiment_accession": "SRX_COMMON_CRESS", "sample_accession": "SRS_COMMON_CRESS", "library_strategy": "RNA-Seq", "library_source": "TRANSCRIPTOMIC", "library_selection": "cDNA"},
        {"experiment_accession": "SRX_MULTI", "sample_accession": "SRS_MULTI_A", "library_strategy": "RNA-Seq", "library_source": "TRANSCRIPTOMIC", "library_selection": "RT-PCR"},
    ]
    write_parquet_from_rows(
        core / "experiment_core.parquet",
        experiment_rows,
        ["experiment_accession", "sample_accession", "library_strategy", "library_source", "library_selection"],
    )

    sample_rows = [
        {"sample_accession": "SRS_PASS_A", "bio_sample_id": "SAMN_PASS_A", "taxon_id": "9606", "scientific_name": "Homo sapiens"},
        {"sample_accession": "SRS_PASS_B", "bio_sample_id": "SAMN_PASS_B", "taxon_id": "10090", "scientific_name": "Mus musculus"},
        {"sample_accession": "SRS_BAD_SELECTION", "bio_sample_id": "SAMN_BAD_SELECTION", "taxon_id": "9606", "scientific_name": "Homo sapiens"},
        {"sample_accession": "SRS_REVIEW_ONLY", "bio_sample_id": "SAMN_REVIEW_ONLY", "taxon_id": "9606", "scientific_name": "Homo sapiens"},
        {"sample_accession": "SRS_NEGATIVE", "bio_sample_id": "SAMN_NEGATIVE", "taxon_id": "9606", "scientific_name": "Homo sapiens"},
        {"sample_accession": "SRS_NO_TAXON", "bio_sample_id": "SAMN_NO_TAXON", "taxon_id": "-", "scientific_name": "Homo sapiens"},
        {"sample_accession": "SRS_MISSING_RUN_CORE", "bio_sample_id": "SAMN_MISSING", "taxon_id": "9606", "scientific_name": "Homo sapiens"},
        {"sample_accession": "SRS_COMMON_CRESS", "bio_sample_id": "SAMN_COMMON_CRESS", "taxon_id": "3702", "scientific_name": "Arabidopsis thaliana"},
        {"sample_accession": "SRS_MULTI_A", "bio_sample_id": "SAMN_MULTI_A", "taxon_id": "9606", "scientific_name": "Homo sapiens"},
        {"sample_accession": "SRS_MULTI_B", "bio_sample_id": "SAMN_MULTI_B", "taxon_id": "9606", "scientific_name": "Homo sapiens"},
    ]
    write_parquet_from_rows(
        core / "sample_core.parquet",
        sample_rows,
        ["sample_accession", "bio_sample_id", "taxon_id", "scientific_name"],
    )

    attr_rows = [
        {"sample_accession": "SRS_PASS_A", "bio_sample_id": "SAMN_PASS_A", "tag": "genotype", "value": "WT", "value_truncated": False},
        {"sample_accession": "SRS_PASS_B", "bio_sample_id": "SAMN_PASS_B", "tag": "strain", "value": "wild type", "value_truncated": False},
        {"sample_accession": "SRS_BAD_SELECTION", "bio_sample_id": "SAMN_BAD_SELECTION", "tag": "genotype", "value": "WT", "value_truncated": False},
        {"sample_accession": "SRS_REVIEW_ONLY", "bio_sample_id": "SAMN_REVIEW_ONLY", "tag": "source_name", "value": "WT cells", "value_truncated": False},
        {"sample_accession": "SRS_NEGATIVE", "bio_sample_id": "SAMN_NEGATIVE", "tag": "genotype", "value": "WT", "value_truncated": False},
        {"sample_accession": "SRS_NEGATIVE", "bio_sample_id": "SAMN_NEGATIVE", "tag": "treatment", "value": "Estradiol induction", "value_truncated": False},
        {"sample_accession": "SRS_NO_TAXON", "bio_sample_id": "SAMN_NO_TAXON", "tag": "genotype", "value": "WT", "value_truncated": False},
        {"sample_accession": "SRS_MISSING_RUN_CORE", "bio_sample_id": "SAMN_MISSING", "tag": "genotype", "value": "WT", "value_truncated": False},
        {"sample_accession": "SRS_COMMON_CRESS", "bio_sample_id": "SAMN_COMMON_CRESS", "tag": "genotype", "value": "WT", "value_truncated": False},
        {"sample_accession": "SRS_COMMON_CRESS", "bio_sample_id": "SAMN_COMMON_CRESS", "tag": "common name", "value": "thale cress", "value_truncated": False},
        {"sample_accession": "SRS_MULTI_A", "bio_sample_id": "SAMN_MULTI_A", "tag": "genotype", "value": "WT", "value_truncated": False},
        {"sample_accession": "SRS_MULTI_B", "bio_sample_id": "SAMN_MULTI_B", "tag": "genotype", "value": "mutant", "value_truncated": False},
    ]
    write_parquet_from_rows(
        core / "sample_attribute_core.parquet",
        attr_rows,
        ["sample_accession", "bio_sample_id", "tag", "value", "value_truncated"],
    )
    return member_parquet, core


def test_generic_index_script_filters_and_aggregates_runs(tmp_path: Path) -> None:
    member_parquet, core = make_fixture(tmp_path)
    outdir = tmp_path / "out"

    subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--member-head",
            str(member_parquet),
            "--generic-core",
            str(core),
            "--outdir",
            str(outdir),
            "--limit-runs",
            "20",
            "--execute",
        ],
        check=True,
        text=True,
        capture_output=True,
    )

    con = duckdb.connect()
    member_output = outdir / "tables" / MEMBER_OUTPUT
    rows = con.execute(
        f"""
        SELECT Run, Member_Name, Experiment, Sample, member_filter_status
        FROM read_parquet('{member_output.as_posix()}')
        ORDER BY Run, Member_Name
        """
    ).fetchall()
    con.close()
    assert rows == [
        ("SRR_COMMON_CRESS", "default", "SRX_COMMON_CRESS", "SRS_COMMON_CRESS", "pass"),
        ("SRR_MULTI", "member_A", "SRX_MULTI", "SRS_MULTI_A", "pass"),
        ("SRR_NEGATIVE", "default", "SRX_NEGATIVE", "SRS_NEGATIVE", "pass"),
        ("SRR_PASS_A", "default", "SRX_PASS_A", "SRS_PASS_A", "pass"),
        ("SRR_PASS_B", "default", "SRX_PASS_B", "SRS_PASS_B", "pass"),
    ]

    run_rows = read_tsv_gz(outdir / "tables" / RUN_OUTPUT)
    assert [row["Run"] for row in run_rows] == [
        "SRR_COMMON_CRESS",
        "SRR_NEGATIVE",
        "SRR_PASS_A",
        "SRR_PASS_B",
    ]

    member_vs_run = {
        row["run_member_status"]: row["runs"]
        for row in csv.DictReader((outdir / "qc" / "member_vs_run_summary.tsv").open(encoding="utf-8"), delimiter="\t")
    }
    assert member_vs_run["all_members_pass"] == "4"
    assert member_vs_run["partial_members_pass"] == "1"
    assert member_vs_run["no_members_pass"] == "4"

    manifest = json.loads((outdir / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["result_counts"]["strict_member_pass_rows"] == 5
    assert manifest["result_counts"]["strict_run_pass_rows"] == 4
    assert manifest["strict_gates"]["run_aggregation"] == "all member rows in the input scope must pass"
    assert manifest["strict_gates"]["exclusion_terms"] == "recorded as QC only; not a pass/fail gate"
    assert manifest["generic_index_qc"]["wildtype_ab_with_exclusion_terms_rows"] == 1
    assert manifest["generic_index_qc"]["wildtype_ab_with_exclusion_terms_runs"] == 1

    schema = {
        row[0]: row[1]
        for row in duckdb.connect().execute(
            f"DESCRIBE SELECT * FROM read_parquet('{member_output.as_posix()}')"
        ).fetchall()
    }
    assert schema["Spots"] == "BIGINT"
    assert schema["Bases"] == "BIGINT"


def test_generic_index_script_refuses_unbounded_execution(tmp_path: Path) -> None:
    member_parquet, core = make_fixture(tmp_path)
    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--member-head",
            str(member_parquet),
            "--generic-core",
            str(core),
            "--outdir",
            str(tmp_path / "out"),
            "--execute",
        ],
        text=True,
        capture_output=True,
    )
    assert result.returncode != 0
    assert "Refusing unbounded execution" in result.stderr


def test_generic_index_script_refuses_allow_unbounded(tmp_path: Path) -> None:
    member_parquet, core = make_fixture(tmp_path)
    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--member-head",
            str(member_parquet),
            "--generic-core",
            str(core),
            "--outdir",
            str(tmp_path / "out"),
            "--allow-unbounded",
            "--execute",
        ],
        text=True,
        capture_output=True,
    )
    assert result.returncode != 0
    assert "--allow-unbounded is disabled" in result.stderr


def test_limit_rows_requires_qc_only(tmp_path: Path) -> None:
    member_parquet, core = make_fixture(tmp_path)
    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--member-head",
            str(member_parquet),
            "--generic-core",
            str(core),
            "--outdir",
            str(tmp_path / "out"),
            "--limit-rows",
            "1",
            "--execute",
        ],
        text=True,
        capture_output=True,
    )
    assert result.returncode != 0
    assert "--limit-rows can split Run groups" in result.stderr


def test_qc_only_writes_no_tables(tmp_path: Path) -> None:
    member_parquet, core = make_fixture(tmp_path)
    outdir = tmp_path / "qc_only"
    subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--member-head",
            str(member_parquet),
            "--generic-core",
            str(core),
            "--outdir",
            str(outdir),
            "--limit-rows",
            "3",
            "--qc-only",
            "--execute",
        ],
        check=True,
        text=True,
        capture_output=True,
    )
    assert (outdir / "qc" / "filter_funnel.tsv").exists()
    assert not (outdir / "tables").exists()
    manifest = json.loads((outdir / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["parameters"]["qc_only"] is True
    assert manifest["outputs"] == {}


def test_zero_pass_member_head_writes_empty_outputs(tmp_path: Path) -> None:
    member_parquet, core = make_fixture(tmp_path)
    bad_member_parquet = tmp_path / "bad_member.parquet"
    con = duckdb.connect()
    con.execute(
        f"""
        COPY (
            SELECT *
            FROM read_parquet('{member_parquet.as_posix()}')
            WHERE Run = 'SRR_BAD_SELECTION'
        ) TO '{bad_member_parquet.as_posix()}' (FORMAT PARQUET)
        """
    )
    con.close()

    outdir = tmp_path / "zero"
    subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--member-head",
            str(bad_member_parquet),
            "--generic-core",
            str(core),
            "--outdir",
            str(outdir),
            "--limit-runs",
            "1",
            "--execute",
        ],
        check=True,
        text=True,
        capture_output=True,
    )

    con = duckdb.connect()
    member_count = con.execute(
        f"""
        SELECT COUNT(*)
        FROM read_parquet('{(outdir / 'tables' / MEMBER_OUTPUT).as_posix()}')
        """
    ).fetchone()[0]
    con.close()
    assert member_count == 0
    assert read_tsv_gz(outdir / "tables" / RUN_OUTPUT) == []

    manifest = json.loads((outdir / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["result_counts"]["strict_member_pass_rows"] == 0
    assert manifest["result_counts"]["strict_run_pass_rows"] == 0


def test_experiment_semantic_conflict_does_not_pass(tmp_path: Path) -> None:
    member_parquet, core = make_fixture(tmp_path)
    original = core / "experiment_core.parquet"
    replacement = core / "experiment_core_replacement.parquet"
    con = duckdb.connect()
    con.execute(
        f"""
        COPY (
            SELECT *
            FROM read_parquet('{original.as_posix()}')
            UNION ALL
            SELECT
                'SRX_PASS_A' AS experiment_accession,
                'SRS_PASS_A' AS sample_accession,
                'RNA-Seq' AS library_strategy,
                'TRANSCRIPTOMIC' AS library_source,
                'size fractionation' AS library_selection
        ) TO '{replacement.as_posix()}' (FORMAT PARQUET)
        """
    )
    con.close()
    replacement.replace(original)

    outdir = tmp_path / "conflict"
    subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--member-head",
            str(member_parquet),
            "--generic-core",
            str(core),
            "--outdir",
            str(outdir),
            "--limit-runs",
            "20",
            "--execute",
        ],
        check=True,
        text=True,
        capture_output=True,
    )

    con = duckdb.connect()
    passed_runs = {
        row[0]
        for row in con.execute(
            f"""
            SELECT Run
            FROM read_parquet('{(outdir / 'tables' / MEMBER_OUTPUT).as_posix()}')
            """
        ).fetchall()
    }
    con.close()
    assert "SRR_PASS_A" not in passed_runs

    rejection_counts = {
        row["reason"]: row["rows"]
        for row in csv.DictReader((outdir / "qc" / "rejection_reason_counts.tsv").open(encoding="utf-8"), delimiter="\t")
    }
    assert rejection_counts["experiment_core_semantic_conflict"] == "1"


def test_run_experiment_ref_mismatch_does_not_pass(tmp_path: Path) -> None:
    member_parquet, core = make_fixture(tmp_path)
    original = core / "run_core.parquet"
    replacement = core / "run_core_replacement.parquet"
    con = duckdb.connect()
    con.execute(
        f"""
        COPY (
            SELECT
                run_accession,
                CASE
                    WHEN run_accession = 'SRR_PASS_A' THEN 'SRX_WRONG'
                    ELSE experiment_accession
                END AS experiment_accession
            FROM read_parquet('{original.as_posix()}')
        ) TO '{replacement.as_posix()}' (FORMAT PARQUET)
        """
    )
    con.close()
    replacement.replace(original)

    outdir = tmp_path / "run_mismatch"
    subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--member-head",
            str(member_parquet),
            "--generic-core",
            str(core),
            "--outdir",
            str(outdir),
            "--limit-runs",
            "20",
            "--execute",
        ],
        check=True,
        text=True,
        capture_output=True,
    )

    con = duckdb.connect()
    passed_runs = {
        row[0]
        for row in con.execute(
            f"""
            SELECT Run
            FROM read_parquet('{(outdir / 'tables' / MEMBER_OUTPUT).as_posix()}')
            """
        ).fetchall()
    }
    con.close()
    assert "SRR_PASS_A" not in passed_runs

    rejection_counts = {
        row["reason"]: row["rows"]
        for row in csv.DictReader((outdir / "qc" / "rejection_reason_counts.tsv").open(encoding="utf-8"), delimiter="\t")
    }
    assert rejection_counts["run_experiment_ref_mismatch"] == "1"


def test_shard_runner_and_merge_scripts(tmp_path: Path) -> None:
    member_parquet, core = make_fixture(tmp_path)
    base_outdir = tmp_path / "sharded"

    subprocess.run(
        [
            sys.executable,
            str(RUNNER_SCRIPT),
            "--base-outdir",
            str(base_outdir),
            "--buckets",
            "2",
            "--remainders",
            "0-1",
            "--max-concurrent",
            "2",
            "--threads-per-shard",
            "1",
            "--script",
            str(SCRIPT),
            "--member-head",
            str(member_parquet),
            "--generic-core",
            str(core),
            "--python",
            sys.executable,
            "--execute",
        ],
        check=True,
        capture_output=True,
        text=True,
    )

    status_rows = list(
        csv.DictReader((base_outdir / "status" / "shard_status.tsv").open(encoding="utf-8"), delimiter="\t")
    )
    assert len(status_rows) == 2
    assert {row["status"] for row in status_rows} == {"DONE"}

    repeat = subprocess.run(
        [
            sys.executable,
            str(RUNNER_SCRIPT),
            "--base-outdir",
            str(base_outdir),
            "--buckets",
            "2",
            "--remainders",
            "0-1",
            "--max-concurrent",
            "2",
            "--threads-per-shard",
            "1",
            "--script",
            str(SCRIPT),
            "--member-head",
            str(member_parquet),
            "--generic-core",
            str(core),
            "--python",
            sys.executable,
            "--execute",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    assert "shards_done_or_skipped=2" in repeat.stdout
    status_rows = list(
        csv.DictReader((base_outdir / "status" / "shard_status.tsv").open(encoding="utf-8"), delimiter="\t")
    )
    assert {row["status"] for row in status_rows} == {"SKIPPED_DONE"}

    merged_outdir = base_outdir / "merged"
    subprocess.run(
        [
            sys.executable,
            str(MERGE_SCRIPT),
            "--shards-root",
            str(base_outdir / "shards"),
            "--outdir",
            str(merged_outdir),
            "--expected-buckets",
            "2",
            "--expected-remainders",
            "0-1",
            "--execute",
        ],
        check=True,
        capture_output=True,
        text=True,
    )

    merged_runs = read_tsv_gz(
        merged_outdir / "tables" / RUN_OUTPUT
    )
    assert sorted(row["Run"] for row in merged_runs) == [
        "SRR_COMMON_CRESS",
        "SRR_NEGATIVE",
        "SRR_PASS_A",
        "SRR_PASS_B",
    ]

    manifest = json.loads((merged_outdir / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["stage"] == (
        "02_stage2_run_members_head_table.step3c_generic_xml_index_no_exclusion_filtering.merge_shards"
    )
    assert manifest["gating_mode"] == "wildtype_ab_no_exclusion"
    assert manifest["output_prefix"] == OUTPUT_PREFIX
    assert manifest["parameters"]["shards_merged"] == 2
    assert manifest["count_sums_from_shard_manifests"]["strict_run_pass_rows"] == 4
    assert manifest["validations"]["run_rows_match_manifest_sum"] is True
    assert manifest["validations"]["run_download_has_duplicate_runs"] is False
    assert manifest["validations"]["shard_manifest_identity_consistent"] is True

    shard_manifest = base_outdir / "shards" / "shard_0000_of_0002" / "manifest.json"
    payload = json.loads(shard_manifest.read_text(encoding="utf-8"))
    payload["inputs"]["member_head"] = "different_member_head.parquet"
    shard_manifest.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    rerun = subprocess.run(
        [
            sys.executable,
            str(RUNNER_SCRIPT),
            "--base-outdir",
            str(base_outdir),
            "--buckets",
            "2",
            "--remainders",
            "0-1",
            "--max-concurrent",
            "2",
            "--threads-per-shard",
            "1",
            "--script",
            str(SCRIPT),
            "--member-head",
            str(member_parquet),
            "--generic-core",
            str(core),
            "--python",
            sys.executable,
            "--execute",
        ],
        capture_output=True,
        text=True,
    )
    assert rerun.returncode != 0
    status_rows = list(
        csv.DictReader((base_outdir / "status" / "shard_status.tsv").open(encoding="utf-8"), delimiter="\t")
    )
    row_by_shard = {row["shard"]: row for row in status_rows}
    assert row_by_shard["shard_0000_of_0002"]["status"] == "BLOCKED_INCOMPATIBLE_DONE"
    assert "inputs.member_head" in row_by_shard["shard_0000_of_0002"]["message"]

    inconsistent_merge = subprocess.run(
        [
            sys.executable,
            str(MERGE_SCRIPT),
            "--shards-root",
            str(base_outdir / "shards"),
            "--outdir",
            str(base_outdir / "merged_inconsistent"),
            "--expected-buckets",
            "2",
            "--expected-remainders",
            "0-1",
            "--execute",
        ],
        capture_output=True,
        text=True,
    )
    assert inconsistent_merge.returncode != 0
    assert "Shard manifest consistency failed" in inconsistent_merge.stderr


def test_generic_index_dry_run_does_not_touch_missing_inputs(tmp_path: Path) -> None:
    outdir = tmp_path / "dry"
    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--member-head",
            str(tmp_path / "missing_member.parquet"),
            "--generic-core",
            str(tmp_path / "missing_core"),
            "--outdir",
            str(outdir),
        ],
        check=True,
        text=True,
        capture_output=True,
    )
    payload = json.loads(result.stdout)
    assert payload["execute"] is False
    assert not outdir.exists()
