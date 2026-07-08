from __future__ import annotations

import csv
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "step1_hard_filter_run_members" / "build_sra_run_members_hard_filter.py"
FIXTURE = ROOT / "tests" / "step1_hard_filter_run_members" / "fixtures" / "SRA_Run_Members_tiny.tsv"


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def test_dry_plan_does_not_require_existing_input(tmp_path: Path) -> None:
    missing_input = tmp_path / "missing_SRA_Run_Members.tsv"
    outdir = tmp_path / "out"

    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--input",
            str(missing_input),
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


def test_hard_filter_fixture_outputs_expected_rows(tmp_path: Path) -> None:
    import pytest

    duckdb = pytest.importorskip("duckdb")
    outdir = tmp_path / "hard_filter"

    subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--input",
            str(FIXTURE),
            "--outdir",
            str(outdir),
            "--execute",
        ],
        check=True,
        text=True,
        capture_output=True,
    )

    parquet_path = outdir / "tables" / "sra_run_members_hard_filtered_member_level.parquet"
    assert parquet_path.exists()

    rows = duckdb.connect().execute(f"SELECT * FROM read_parquet('{parquet_path.as_posix()}') ORDER BY Run, Member_Name").fetchall()
    assert rows == [
        ("SRR000001", "default", "SRX000001", "SRS000001", "SAMN000001", "SRP000001", 10, 100, "live"),
        ("SRR000008", "member_A", "SRX000008", "SRS000008", "SAMN000008", "SRP000001", 10, 100, "live"),
        ("SRR000008", "member_B", "SRX000008", "SRS000009", "SAMN000009", "SRP000001", 11, 110, "live"),
        ("SRR000013", None, "SRX000013", "SRS000014", "SAMN000014", None, 10, 100, "live"),
    ]

    funnel = read_tsv(outdir / "qc" / "filter_funnel.tsv")
    by_metric = {row["metric"]: row for row in funnel}
    assert by_metric["input_rows"]["rows"] == "14"
    assert by_metric["hard_filtered_rows"]["rows"] == "4"
    assert by_metric["hard_filtered_rows"]["distinct_runs"] == "3"
    assert by_metric["rejected_rows"]["rows"] == "10"

    multiplicity = read_tsv(outdir / "qc" / "filtered_run_multiplicity_summary.tsv")[0]
    assert multiplicity["filtered_distinct_runs"] == "3"
    assert multiplicity["filtered_rows"] == "4"
    assert multiplicity["multi_row_runs"] == "1"
    assert multiplicity["runs_with_multiple_samples"] == "1"
    assert multiplicity["runs_with_multiple_biosamples"] == "1"

    manifest = json.loads((outdir / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["stage"] == "02_stage2_run_members_head_table.step1_hard_filter_run_members"
    assert manifest["filter_conditions"]["BioSample"] == "non-empty"


def test_refuses_non_empty_outdir_without_overwrite(tmp_path: Path) -> None:
    outdir = tmp_path / "hard_filter"
    outdir.mkdir()
    (outdir / "existing.txt").write_text("do not overwrite", encoding="utf-8")

    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--input",
            str(FIXTURE),
            "--outdir",
            str(outdir),
            "--execute",
        ],
        text=True,
        capture_output=True,
    )

    assert result.returncode != 0
    assert "already exists and is not empty" in result.stderr
    assert (outdir / "existing.txt").read_text(encoding="utf-8") == "do not overwrite"


def test_overwrite_moves_existing_outdir_to_backup(tmp_path: Path) -> None:
    outdir = tmp_path / "hard_filter"
    outdir.mkdir()
    (outdir / "old.tsv.gz").write_text("stale", encoding="utf-8")

    subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--input",
            str(FIXTURE),
            "--outdir",
            str(outdir),
            "--overwrite",
            "--execute",
        ],
        check=True,
        text=True,
        capture_output=True,
    )

    backups = list(tmp_path.glob("hard_filter.previous_*"))
    assert len(backups) == 1
    assert (backups[0] / "old.tsv.gz").read_text(encoding="utf-8") == "stale"
    assert not (outdir / "old.tsv.gz").exists()
    assert (outdir / "manifest.json").exists()


def test_header_validation_fails_fast(tmp_path: Path) -> None:
    bad_input = tmp_path / "bad.tsv"
    shutil.copyfile(FIXTURE, bad_input)
    text = bad_input.read_text(encoding="utf-8")
    bad_input.write_text(text.replace("BioSample", "BioSample_missing"), encoding="utf-8")

    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--input",
            str(bad_input),
            "--outdir",
            str(tmp_path / "out"),
            "--execute",
        ],
        text=True,
        capture_output=True,
    )

    assert result.returncode != 0
    assert "BioSample" in result.stderr


def test_empty_input_fails_with_clear_message(tmp_path: Path) -> None:
    empty_input = tmp_path / "empty.tsv"
    empty_input.write_text("", encoding="utf-8")

    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--input",
            str(empty_input),
            "--outdir",
            str(tmp_path / "out"),
            "--execute",
        ],
        text=True,
        capture_output=True,
    )

    assert result.returncode != 0
    assert "has no header" in result.stderr
