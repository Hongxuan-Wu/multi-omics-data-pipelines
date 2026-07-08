from __future__ import annotations

import csv
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest


duckdb = pytest.importorskip("duckdb")

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "step2_join_accessions_visibility" / "build_sra_run_members_public_head.py"


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
]

ACCESSIONS_COLUMNS = [
    "Accession",
    "Submission",
    "Status",
    "Updated",
    "Published",
    "Received",
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
    "Type",
]


def write_tsv(path: Path, rows: list[dict[str, object]], columns: list[str]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def make_parquet_inputs(
    tmp_path: Path,
    duplicate_accession: bool = False,
    duplicate_unmatched_accession: bool = False,
    numeric_accession_counts: bool = False,
    matched_missing_visibility: bool = False,
) -> tuple[Path, Path]:
    """Create tiny parquet inputs that mimic Step 1 output and Type=RUN accessions."""
    member_tsv = tmp_path / "member.tsv"
    accessions_tsv = tmp_path / "accessions.tsv"
    member_parquet = tmp_path / "member.parquet"
    accessions_parquet = tmp_path / "accessions.parquet"

    member_rows = [
        {
            "Run": "SRR000001",
            "Member_Name": "default",
            "Experiment": "SRX000001",
            "Sample": "SRS000001",
            "BioSample": "SAMN000001",
            "Study": "SRP000001",
            "Spots": 10,
            "Bases": 100,
            "Status": "live",
        },
        {
            "Run": "SRR000002",
            "Member_Name": "default",
            "Experiment": "SRX000002",
            "Sample": "SRS000002",
            "BioSample": "SAMN000002",
            "Study": "SRP000001",
            "Spots": 20,
            "Bases": 200,
            "Status": "live",
        },
        {
            "Run": "SRR000003",
            "Member_Name": "default",
            "Experiment": "SRX000003",
            "Sample": "SRS000003",
            "BioSample": "SAMN000003",
            "Study": "SRP000001",
            "Spots": 30,
            "Bases": 300,
            "Status": "live",
        },
        {
            "Run": "SRR000004",
            "Member_Name": "default",
            "Experiment": "SRX000004",
            "Sample": "SRS000004",
            "BioSample": "SAMN000004",
            "Study": "SRP000001",
            "Spots": 40,
            "Bases": 400,
            "Status": "live",
        },
        {
            "Run": "SRR000005",
            "Member_Name": "member_A",
            "Experiment": "SRX000005",
            "Sample": "SRS000005A",
            "BioSample": "SAMN000005A",
            "Study": "SRP000001",
            "Spots": 50,
            "Bases": 500,
            "Status": "live",
        },
        {
            "Run": "SRR000005",
            "Member_Name": "member_B",
            "Experiment": "SRX000005",
            "Sample": "SRS000005B",
            "BioSample": "SAMN000005B",
            "Study": "SRP000001",
            "Spots": 51,
            "Bases": 510,
            "Status": "live",
        },
        {
            "Run": "SRR000006",
            "Member_Name": "default",
            "Experiment": "SRX000006",
            "Sample": "SRS000006",
            "BioSample": "SAMN000006",
            "Study": "SRP000001",
            "Spots": 60,
            "Bases": 600,
            "Status": "live",
        },
    ]

    accessions_rows = [
        accession_row("SRR000001", "live", "public", "SRX000001", "SRS000001", "SAMN000001", 10, 100, "RUN"),
        accession_row("SRR000002", "live", "controlled_access", "SRX000002", "SRS000002", "SAMN000002", 20, 200, "RUN"),
        accession_row("SRR000004", "suppressed", "public", "SRX000004", "SRS000004", "SAMN000004", 40, 400, "RUN"),
        accession_row("SRR000005", "live", "public", "SRX000005", "SRS000005", "SAMN000005", 101, 1010, "RUN"),
        accession_row("SRR000006", "live", "public", "SRX000006", "SRS000006", "SAMN000006", 60, 600, "SAMPLE"),
        accession_row("SRR000007", "live", "public", "SRX000007", "SRS000007", "SAMN000007", 70, 700, "RUN"),
    ]
    if duplicate_accession:
        accessions_rows.append(accession_row("SRR000001", "live", "public", "SRX000001", "SRS000001", "SAMN000001", 10, 100, "RUN"))
    if duplicate_unmatched_accession:
        accessions_rows.append(
            accession_row("SRR999999", "suppressed", "public", "-", "-", "-", 0, 0, "RUN")
        )
        accessions_rows.append(
            accession_row("SRR999999", "suppressed", "public", "-", "-", "-", 0, 0, "RUN")
        )
    if matched_missing_visibility:
        accessions_rows.append(accession_row("SRR000003", "live", "-", "SRX000003", "SRS000003", "SAMN000003", 30, 300, "RUN"))

    write_tsv(member_tsv, member_rows, MEMBER_COLUMNS)
    write_tsv(accessions_tsv, accessions_rows, ACCESSIONS_COLUMNS)

    con = duckdb.connect()
    con.execute(
        f"COPY (SELECT * FROM read_csv('{member_tsv.as_posix()}', delim='\\t', header=true, all_varchar=true)) "
        f"TO '{member_parquet.as_posix()}' (FORMAT PARQUET)"
    )
    if numeric_accession_counts:
        con.execute(
            f"""
            COPY (
                SELECT
                    Accession,
                    Submission,
                    Status,
                    Updated,
                    Published,
                    Received,
                    Center,
                    Visibility,
                    Alias,
                    Experiment,
                    Sample,
                    Study,
                    Loaded,
                    CAST(Spots AS BIGINT) AS Spots,
                    CAST(Bases AS BIGINT) AS Bases,
                    Md5sum,
                    BioSample,
                    BioProject,
                    ReplacedBy,
                    Type
                FROM read_csv('{accessions_tsv.as_posix()}', delim='\\t', header=true, all_varchar=true)
            ) TO '{accessions_parquet.as_posix()}' (FORMAT PARQUET)
            """
        )
    else:
        con.execute(
            f"COPY (SELECT * FROM read_csv('{accessions_tsv.as_posix()}', delim='\\t', header=true, all_varchar=true)) "
            f"TO '{accessions_parquet.as_posix()}' (FORMAT PARQUET)"
        )
    con.close()
    return member_parquet, accessions_parquet


def accession_row(
    accession: str,
    status: str,
    visibility: str,
    experiment: str,
    sample: str,
    biosample: str,
    spots: int,
    bases: int,
    type_: str,
) -> dict[str, object]:
    return {
        "Accession": accession,
        "Submission": "SRA000000",
        "Status": status,
        "Updated": "2026-01-01T00:00:00Z",
        "Published": "2026-01-01T00:00:00Z",
        "Received": "2026-01-01T00:00:00Z",
        "Center": "TEST",
        "Visibility": visibility,
        "Alias": accession,
        "Experiment": experiment,
        "Sample": sample,
        "Study": "SRP000001",
        "Loaded": "1",
        "Spots": spots,
        "Bases": bases,
        "Md5sum": "-",
        "BioSample": biosample,
        "BioProject": "PRJTEST",
        "ReplacedBy": "-",
        "Type": type_,
    }


def test_dry_plan_does_not_require_existing_inputs(tmp_path: Path) -> None:
    outdir = tmp_path / "out"

    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--member-head",
            str(tmp_path / "missing_member.parquet"),
            "--accessions-run",
            str(tmp_path / "missing_accessions.parquet"),
            "--outdir",
            str(outdir),
        ],
        check=True,
        text=True,
        capture_output=True,
    )

    payload = json.loads(result.stdout)
    assert payload["execute"] is False
    assert payload["gate"] == "SRA_Accessions.Visibility = public"
    assert not outdir.exists()


def test_visibility_join_outputs_expected_member_and_run_tables(tmp_path: Path) -> None:
    member_parquet, accessions_parquet = make_parquet_inputs(tmp_path)
    outdir = tmp_path / "public_head"

    subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--member-head",
            str(member_parquet),
            "--accessions-run",
            str(accessions_parquet),
            "--outdir",
            str(outdir),
            "--execute",
        ],
        check=True,
        text=True,
        capture_output=True,
    )

    member_output = outdir / "tables" / "sra_run_members_live_nonzero_public_member_level.parquet"
    run_output = outdir / "tables" / "sra_run_members_live_nonzero_public_run_level.parquet"
    assert member_output.exists()
    assert run_output.exists()

    con = duckdb.connect()
    member_rows = con.execute(
        f"SELECT Run, Member_Name, Accessions_Visibility, Accessions_Status "
        f"FROM read_parquet('{member_output.as_posix()}') ORDER BY Run, Member_Name"
    ).fetchall()
    assert member_rows == [
        ("SRR000001", "default", "public", "live"),
        ("SRR000004", "default", "public", "suppressed"),
        ("SRR000005", "member_A", "public", "live"),
        ("SRR000005", "member_B", "public", "live"),
    ]

    run_rows = con.execute(
        f"SELECT Run, member_rows, has_multiple_samples, has_multiple_biosamples "
        f"FROM read_parquet('{run_output.as_posix()}') ORDER BY Run"
    ).fetchall()
    assert run_rows == [
        ("SRR000001", 1, False, False),
        ("SRR000004", 1, False, False),
        ("SRR000005", 2, True, True),
    ]
    con.close()

    funnel = {row["metric"]: row for row in read_tsv(outdir / "qc" / "filter_funnel.tsv")}
    assert funnel["member_input"]["rows"] == "7"
    assert funnel["visibility_public"]["rows"] == "4"
    assert funnel["visibility_public"]["distinct_runs"] == "3"
    assert funnel["visibility_not_public_or_missing"]["rows"] == "3"

    run_summary = read_tsv(outdir / "qc" / "run_level_summary.tsv")[0]
    assert run_summary["public_distinct_runs"] == "3"
    assert run_summary["multi_row_runs"] == "1"
    assert run_summary["runs_with_accessions_status_not_live_or_missing"] == "1"

    field_qc = {row["field"]: row for row in read_tsv(outdir / "qc" / "field_mismatch_counts.tsv")}
    assert field_qc["Sample"]["any_difference_rows"] == "2"
    assert field_qc["BioSample"]["any_difference_rows"] == "2"

    manifest = json.loads((outdir / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["filter_conditions"]["Accessions_Visibility"] == "trim(Visibility) = 'public'"
    assert "audit only" in manifest["filter_conditions"]["Accessions_Status"]


def test_numeric_accession_spots_bases_do_not_break_normalization(tmp_path: Path) -> None:
    member_parquet, accessions_parquet = make_parquet_inputs(tmp_path, numeric_accession_counts=True)
    outdir = tmp_path / "public_head_numeric"

    subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--member-head",
            str(member_parquet),
            "--accessions-run",
            str(accessions_parquet),
            "--outdir",
            str(outdir),
            "--execute",
        ],
        check=True,
        text=True,
        capture_output=True,
    )

    con = duckdb.connect()
    rows = con.execute(
        f"SELECT Run, Accessions_Spots, Accessions_Bases "
        f"FROM read_parquet('{(outdir / 'tables' / 'sra_run_members_live_nonzero_public_run_level.parquet').as_posix()}') "
        f"WHERE Run = 'SRR000001'"
    ).fetchall()
    con.close()
    assert rows == [("SRR000001", 10, 100)]


def test_visibility_counts_distinguish_missing_accession_from_missing_visibility(tmp_path: Path) -> None:
    member_parquet, accessions_parquet = make_parquet_inputs(tmp_path, matched_missing_visibility=True)
    outdir = tmp_path / "public_head_missing_visibility"

    subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--member-head",
            str(member_parquet),
            "--accessions-run",
            str(accessions_parquet),
            "--outdir",
            str(outdir),
            "--execute",
        ],
        check=True,
        text=True,
        capture_output=True,
    )

    visibility_counts = {
        row["visibility"]: row for row in read_tsv(outdir / "qc" / "accessions_visibility_counts.tsv")
    }
    assert visibility_counts["__matched_visibility_missing__"]["rows"] == "1"
    assert visibility_counts["__missing_accession__"]["rows"] == "1"


def test_refuses_duplicate_accession_keys_by_default(tmp_path: Path) -> None:
    member_parquet, accessions_parquet = make_parquet_inputs(tmp_path, duplicate_accession=True)

    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--member-head",
            str(member_parquet),
            "--accessions-run",
            str(accessions_parquet),
            "--outdir",
            str(tmp_path / "out"),
            "--execute",
        ],
        text=True,
        capture_output=True,
    )

    assert result.returncode != 0
    assert "duplicate Accession keys" in result.stderr


def test_unmatched_duplicate_accession_keys_are_qc_not_blockers(tmp_path: Path) -> None:
    member_parquet, accessions_parquet = make_parquet_inputs(tmp_path, duplicate_unmatched_accession=True)
    outdir = tmp_path / "out"

    subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--member-head",
            str(member_parquet),
            "--accessions-run",
            str(accessions_parquet),
            "--outdir",
            str(outdir),
            "--execute",
        ],
        check=True,
        text=True,
        capture_output=True,
    )

    key_qc = {row["scope"]: row for row in read_tsv(outdir / "qc" / "accessions_key_qc.tsv")}
    assert key_qc["global_accessions_run"]["duplicate_accession_rows"] == "1"
    assert key_qc["matched_member_runs"]["duplicate_accession_rows"] == "0"


def test_refuses_non_empty_outdir_without_overwrite(tmp_path: Path) -> None:
    member_parquet, accessions_parquet = make_parquet_inputs(tmp_path)
    outdir = tmp_path / "public_head"
    outdir.mkdir()
    (outdir / "old.txt").write_text("stale", encoding="utf-8")

    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--member-head",
            str(member_parquet),
            "--accessions-run",
            str(accessions_parquet),
            "--outdir",
            str(outdir),
            "--execute",
        ],
        text=True,
        capture_output=True,
    )

    assert result.returncode != 0
    assert "already exists and is not empty" in result.stderr
    assert (outdir / "old.txt").read_text(encoding="utf-8") == "stale"


def test_overwrite_moves_existing_outdir_to_backup(tmp_path: Path) -> None:
    member_parquet, accessions_parquet = make_parquet_inputs(tmp_path)
    outdir = tmp_path / "public_head"
    outdir.mkdir()
    (outdir / "old.txt").write_text("stale", encoding="utf-8")

    subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--member-head",
            str(member_parquet),
            "--accessions-run",
            str(accessions_parquet),
            "--outdir",
            str(outdir),
            "--overwrite",
            "--execute",
        ],
        check=True,
        text=True,
        capture_output=True,
    )

    backups = list(tmp_path.glob("public_head.previous_*"))
    assert len(backups) == 1
    assert (backups[0] / "old.txt").read_text(encoding="utf-8") == "stale"
    assert not (outdir / "old.txt").exists()
    assert (outdir / "manifest.json").exists()


def test_header_validation_fails_fast(tmp_path: Path) -> None:
    member_parquet, accessions_parquet = make_parquet_inputs(tmp_path)
    bad_member_tsv = tmp_path / "bad_member.tsv"
    bad_member_parquet = tmp_path / "bad_member.parquet"
    shutil.copyfile(tmp_path / "member.tsv", bad_member_tsv)
    bad_text = bad_member_tsv.read_text(encoding="utf-8").replace("BioSample", "BioSample_missing")
    bad_member_tsv.write_text(bad_text, encoding="utf-8")
    con = duckdb.connect()
    con.execute(
        f"COPY (SELECT * FROM read_csv('{bad_member_tsv.as_posix()}', delim='\\t', header=true, all_varchar=true)) "
        f"TO '{bad_member_parquet.as_posix()}' (FORMAT PARQUET)"
    )
    con.close()

    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--member-head",
            str(bad_member_parquet),
            "--accessions-run",
            str(accessions_parquet),
            "--outdir",
            str(tmp_path / "out"),
            "--execute",
        ],
        text=True,
        capture_output=True,
    )

    assert result.returncode != 0
    assert "BioSample" in result.stderr
    assert member_parquet.exists()
