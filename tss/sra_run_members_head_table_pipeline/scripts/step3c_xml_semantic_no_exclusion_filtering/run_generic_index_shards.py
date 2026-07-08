#!/usr/bin/env python3
"""Run Step 3c no-exclusion generic-index shards with bounded local concurrency.

Stage role:
    This script is the production runner around
    build_wildtype_ab_no_exclusion_from_generic_xml_index.py. It does not decide biological
    semantics. Its only job is to split the already approved Step 3c filter
    into Run-hash shards, launch a controlled number of shard processes, and
    write auditable status files.

Input:
    A shard plan: base output directory, bucket count, target remainders,
    per-shard DuckDB thread count, and max concurrent shard processes.

Output:
    base_outdir/
      logs/
      status/shard_status.tsv
      shards/shard_0000_of_0404/...
      failed_attempts/

Safety:
    - Dry-run by default.
    - Existing DONE shards are skipped unless the caller explicitly chooses a
      different output directory.
    - Existing failed/non-DONE shard directories are moved to failed_attempts/
      only when --retry-failed is provided.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from time import perf_counter, sleep
from typing import Iterable


DEFAULT_SCRIPT = Path(__file__).resolve().parent / "build_wildtype_ab_no_exclusion_from_generic_xml_index.py"
DEFAULT_MEMBER_HEAD = Path(
    "/data3/m252202014/SRA/filtered_tables/"
    "sra_run_members_live_nonzero_public_20260703/tables/"
    "sra_run_members_live_nonzero_public_member_level.parquet"
)
DEFAULT_GENERIC_CORE = Path(
    "/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/"
    "20260516_full_streaming_v1/core"
)
EXPECTED_STAGE = "02_stage2_run_members_head_table.step3c_generic_xml_index_no_exclusion_filtering"
EXPECTED_GATING_MODE = "wildtype_ab_no_exclusion"
EXPECTED_OUTPUT_PREFIX = "wildtype_ab_no_exclusion_transcriptomic_rnaseq"

STATUS_COLUMNS = [
    "shard",
    "buckets",
    "remainder",
    "status",
    "return_code",
    "started_at_utc",
    "ended_at_utc",
    "elapsed_seconds",
    "outdir",
    "stdout_log",
    "stderr_log",
    "input_member_rows",
    "input_run_count",
    # These manifest keys are kept for compatibility with the Step 3b merge
    # schema. In Step 3c they mean rows passing the no-exclusion gates.
    "strict_member_pass_rows",
    "strict_run_pass_rows",
    "message",
]


@dataclass
class ShardTask:
    """One immutable Run-hash shard target.

    Flow position:
        The task is created before any process starts. It maps one remainder
        to one output directory, which keeps failed-rerun behavior explicit.
    """

    buckets: int
    remainder: int
    shard_name: str
    outdir: Path
    stdout_log: Path
    stderr_log: Path


@dataclass
class RunningShard:
    """A currently running subprocess plus the files used to capture logs."""

    task: ShardTask
    process: subprocess.Popen
    stdout_handle: object
    stderr_handle: object
    started_at_utc: str
    started_perf: float


@dataclass
class ShardRecord:
    """Status row written to status/shard_status.tsv."""

    task: ShardTask
    status: str
    return_code: int | None = None
    started_at_utc: str = ""
    ended_at_utc: str = ""
    elapsed_seconds: float | None = None
    input_member_rows: int | None = None
    input_run_count: int | None = None
    strict_member_pass_rows: int | None = None
    strict_run_pass_rows: int | None = None
    message: str = ""
    extra: dict[str, object] = field(default_factory=dict)

    def to_row(self) -> dict[str, object]:
        """Return a stable TSV row for human review and later retry selection."""
        return {
            "shard": self.task.shard_name,
            "buckets": self.task.buckets,
            "remainder": self.task.remainder,
            "status": self.status,
            "return_code": "" if self.return_code is None else self.return_code,
            "started_at_utc": self.started_at_utc,
            "ended_at_utc": self.ended_at_utc,
            "elapsed_seconds": "" if self.elapsed_seconds is None else f"{self.elapsed_seconds:.3f}",
            "outdir": str(self.task.outdir),
            "stdout_log": str(self.task.stdout_log),
            "stderr_log": str(self.task.stderr_log),
            "input_member_rows": "" if self.input_member_rows is None else self.input_member_rows,
            "input_run_count": "" if self.input_run_count is None else self.input_run_count,
            "strict_member_pass_rows": ""
            if self.strict_member_pass_rows is None
            else self.strict_member_pass_rows,
            "strict_run_pass_rows": "" if self.strict_run_pass_rows is None else self.strict_run_pass_rows,
            "message": self.message,
        }


def utc_now() -> str:
    """Return a manifest/status timestamp in UTC for cross-machine logs."""
    return datetime.now(timezone.utc).isoformat()


def parse_remainders(text: str, buckets: int) -> list[int]:
    """Parse comma/range notation such as '0-3,8,10-12'.

    Input:
        User-facing shard remainder string.
    Output:
        Sorted unique remainders validated against [0, buckets).
    """
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
    if not values:
        raise SystemExit("--remainders did not select any shard.")
    invalid = [value for value in values if value < 0 or value >= buckets]
    if invalid:
        raise SystemExit(f"Remainders outside [0, {buckets}): {invalid}")
    return sorted(values)


def shard_name(remainder: int, buckets: int) -> str:
    """Return the canonical shard directory name used by runner and merger."""
    width = max(4, len(str(buckets - 1)))
    return f"shard_{remainder:0{width}d}_of_{buckets:0{width}d}"


def create_tasks(args: argparse.Namespace) -> list[ShardTask]:
    """Build shard tasks and their deterministic output/log paths."""
    remainders = parse_remainders(args.remainders, args.buckets)
    logs_dir = args.base_outdir / "logs"
    shards_dir = args.base_outdir / "shards"
    tasks: list[ShardTask] = []
    for remainder in remainders:
        name = shard_name(remainder, args.buckets)
        tasks.append(
            ShardTask(
                buckets=args.buckets,
                remainder=remainder,
                shard_name=name,
                outdir=shards_dir / name,
                stdout_log=logs_dir / f"{name}.stdout.log",
                stderr_log=logs_dir / f"{name}.stderr.log",
            )
        )
    return tasks


def write_status(status_path: Path, records: Iterable[ShardRecord]) -> None:
    """Rewrite the current status snapshot after every state transition."""
    status_path.parent.mkdir(parents=True, exist_ok=True)
    ordered = sorted(records, key=lambda record: record.task.remainder)
    with status_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=STATUS_COLUMNS, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for record in ordered:
            writer.writerow(record.to_row())


def read_manifest_counts(manifest: Path) -> dict[str, int]:
    """Read core result counts from a completed shard manifest."""
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    counts = payload.get("result_counts", {})
    return {
        "input_member_rows": int(counts.get("input_member_rows", 0)),
        "input_run_count": int(counts.get("input_run_count", 0)),
        "strict_member_pass_rows": int(counts.get("strict_member_pass_rows", 0)),
        "strict_run_pass_rows": int(counts.get("strict_run_pass_rows", 0)),
    }


def existing_manifest_problems(task: ShardTask, args: argparse.Namespace, payload: dict) -> list[str]:
    """Return identity mismatches that make an existing DONE shard unsafe to reuse.

    Flow position:
        This guard runs before SKIPPED_DONE. It prevents an old shard from a
        different input table, generic XML index, parameter set, or gating mode
        from being silently mixed into a new production run.
    """
    params = payload.get("parameters", {})
    inputs = payload.get("inputs", {})
    problems: list[str] = []
    expected_pairs = [
        ("stage", payload.get("stage"), EXPECTED_STAGE),
        ("gating_mode", payload.get("gating_mode"), EXPECTED_GATING_MODE),
        ("output_prefix", payload.get("output_prefix"), EXPECTED_OUTPUT_PREFIX),
        ("inputs.member_head", inputs.get("member_head"), str(args.member_head)),
        ("inputs.generic_core", inputs.get("generic_core"), str(args.generic_core)),
        ("parameters.run_hash_buckets", params.get("run_hash_buckets"), task.buckets),
        ("parameters.run_hash_remainder", params.get("run_hash_remainder"), task.remainder),
        ("parameters.threads", params.get("threads"), args.threads_per_shard),
        ("parameters.qc_only", params.get("qc_only"), args.qc_only),
        # Runner production shards never pass --limit-runs/--limit-rows to the
        # child script. The child manifest records those parser defaults as 0.
        ("parameters.limit_runs", params.get("limit_runs"), 0),
        ("parameters.limit_rows", params.get("limit_rows"), 0),
    ]
    for label, observed, expected in expected_pairs:
        if observed != expected:
            problems.append(f"{label}: observed={observed!r}, expected={expected!r}")
    return problems


def move_existing_failed_dir(task: ShardTask, failed_attempts: Path) -> str:
    """Move a non-DONE shard directory aside before retrying it.

    The move is intentionally used instead of deleting or overwriting. Failed
    stderr/stdout and partial outputs are often the only evidence for why a
    shard failed.
    """
    failed_attempts.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    destination = failed_attempts / f"{task.shard_name}.failed_{stamp}"
    suffix = 1
    while destination.exists():
        destination = failed_attempts / f"{task.shard_name}.failed_{stamp}_{suffix}"
        suffix += 1
    shutil.move(str(task.outdir), str(destination))
    return str(destination)


def preflight_task(task: ShardTask, args: argparse.Namespace) -> ShardRecord | None:
    """Decide whether a shard can be launched, skipped, or must be blocked."""
    manifest = task.outdir / "manifest.json"
    if manifest.exists():
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        problems = existing_manifest_problems(task, args, payload)
        if problems:
            return ShardRecord(
                task=task,
                status="BLOCKED_INCOMPATIBLE_DONE",
                message="existing manifest identity mismatch; use a new base-outdir or move the old shard aside: "
                + " | ".join(problems),
            )
        counts = {
            "input_member_rows": int(payload.get("result_counts", {}).get("input_member_rows", 0)),
            "input_run_count": int(payload.get("result_counts", {}).get("input_run_count", 0)),
            "strict_member_pass_rows": int(payload.get("result_counts", {}).get("strict_member_pass_rows", 0)),
            "strict_run_pass_rows": int(payload.get("result_counts", {}).get("strict_run_pass_rows", 0)),
        }
        return ShardRecord(
            task=task,
            status="SKIPPED_DONE",
            input_member_rows=counts["input_member_rows"],
            input_run_count=counts["input_run_count"],
            strict_member_pass_rows=counts["strict_member_pass_rows"],
            strict_run_pass_rows=counts["strict_run_pass_rows"],
            message="manifest.json already exists; not rerunning a DONE shard",
        )
    if task.outdir.exists() and any(task.outdir.iterdir()):
        if not args.retry_failed:
            return ShardRecord(
                task=task,
                status="BLOCKED_EXISTING_NON_DONE",
                message="existing non-empty shard dir has no manifest; use --retry-failed to move it aside",
            )
        moved_to = move_existing_failed_dir(task, args.base_outdir / "failed_attempts")
        return ShardRecord(task=task, status="RETRY_PREPARED", message=f"moved previous attempt to {moved_to}")
    return None


def build_command(task: ShardTask, args: argparse.Namespace) -> list[str]:
    """Create the child process command for one shard.

    The child command uses argument lists, not shell strings, to avoid quoting
    differences between PowerShell, bash, and SSH sessions.
    """
    command = [
        args.python,
        str(args.script),
        "--member-head",
        str(args.member_head),
        "--generic-core",
        str(args.generic_core),
        "--outdir",
        str(task.outdir),
        "--run-hash-buckets",
        str(task.buckets),
        "--run-hash-remainder",
        str(task.remainder),
        "--threads",
        str(args.threads_per_shard),
        "--execute",
    ]
    if args.qc_only:
        command.append("--qc-only")
    return command


def launch_task(task: ShardTask, args: argparse.Namespace) -> RunningShard:
    """Launch one shard and stream stdout/stderr to per-shard log files."""
    task.stdout_log.parent.mkdir(parents=True, exist_ok=True)
    task.stderr_log.parent.mkdir(parents=True, exist_ok=True)
    command = build_command(task, args)
    stdout_handle = task.stdout_log.open("w", encoding="utf-8")
    stderr_handle = task.stderr_log.open("w", encoding="utf-8")
    stdout_handle.write("$ " + " ".join(command) + "\n")
    stdout_handle.flush()
    process = subprocess.Popen(
        command,
        stdout=stdout_handle,
        stderr=stderr_handle,
        cwd=str(args.workdir),
        text=True,
        env=os.environ.copy(),
    )
    return RunningShard(
        task=task,
        process=process,
        stdout_handle=stdout_handle,
        stderr_handle=stderr_handle,
        started_at_utc=utc_now(),
        started_perf=perf_counter(),
    )


def finish_running(running: RunningShard) -> ShardRecord:
    """Close logs and turn a completed process into a status record."""
    return_code = running.process.returncode
    running.stdout_handle.close()
    running.stderr_handle.close()
    elapsed = perf_counter() - running.started_perf
    manifest = running.task.outdir / "manifest.json"
    ended = utc_now()
    if return_code == 0 and manifest.exists():
        counts = read_manifest_counts(manifest)
        return ShardRecord(
            task=running.task,
            status="DONE",
            return_code=return_code,
            started_at_utc=running.started_at_utc,
            ended_at_utc=ended,
            elapsed_seconds=elapsed,
            input_member_rows=counts["input_member_rows"],
            input_run_count=counts["input_run_count"],
            strict_member_pass_rows=counts["strict_member_pass_rows"],
            strict_run_pass_rows=counts["strict_run_pass_rows"],
        )
    message = "process failed"
    if return_code == 0 and not manifest.exists():
        message = "process returned 0 but manifest.json is missing"
    return ShardRecord(
        task=running.task,
        status="FAILED",
        return_code=return_code,
        started_at_utc=running.started_at_utc,
        ended_at_utc=ended,
        elapsed_seconds=elapsed,
        message=message,
    )


def run(args: argparse.Namespace) -> int:
    """Run the bounded-concurrency shard loop."""
    tasks = create_tasks(args)
    if args.max_concurrent <= 0:
        raise SystemExit("--max-concurrent must be > 0.")
    if args.threads_per_shard <= 0:
        raise SystemExit("--threads-per-shard must be > 0.")
    if not args.script.exists():
        raise SystemExit(f"Script not found: {args.script}")

    if not args.execute:
        for task in tasks:
            print(" ".join(build_command(task, args)))
        print("Dry-run only. Add --execute to launch shards.")
        return 0

    args.base_outdir.mkdir(parents=True, exist_ok=True)
    (args.base_outdir / "status").mkdir(parents=True, exist_ok=True)
    status_path = args.base_outdir / "status" / "shard_status.tsv"

    queued: list[ShardTask] = []
    records: dict[int, ShardRecord] = {}
    for task in tasks:
        preflight = preflight_task(task, args)
        if preflight is None:
            queued.append(task)
            records[task.remainder] = ShardRecord(task=task, status="PENDING")
        else:
            records[task.remainder] = preflight
            if preflight.status == "RETRY_PREPARED":
                queued.append(task)
                records[task.remainder] = ShardRecord(task=task, status="PENDING")

    write_status(status_path, records.values())

    running: list[RunningShard] = []
    while queued or running:
        while queued and len(running) < args.max_concurrent:
            task = queued.pop(0)
            current = launch_task(task, args)
            running.append(current)
            records[task.remainder] = ShardRecord(
                task=task,
                status="RUNNING",
                started_at_utc=current.started_at_utc,
            )
            write_status(status_path, records.values())

        for current in list(running):
            if current.process.poll() is None:
                continue
            running.remove(current)
            records[current.task.remainder] = finish_running(current)
            write_status(status_path, records.values())
        if running:
            sleep(0.2)

    failed = [record for record in records.values() if record.status not in {"DONE", "SKIPPED_DONE"}]
    done = [record for record in records.values() if record.status in {"DONE", "SKIPPED_DONE"}]
    print(f"shards_done_or_skipped={len(done)}")
    print(f"shards_failed_or_blocked={len(failed)}")
    print(f"status={status_path}")
    return 1 if failed else 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse runner arguments without starting any shard."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-outdir", type=Path, required=True)
    parser.add_argument("--buckets", type=int, required=True)
    parser.add_argument("--remainders", required=True, help="Comma/range notation, for example 0-3,8,10-12.")
    parser.add_argument("--max-concurrent", type=int, default=2)
    parser.add_argument("--threads-per-shard", type=int, default=8)
    parser.add_argument("--script", type=Path, default=DEFAULT_SCRIPT)
    parser.add_argument("--member-head", type=Path, default=DEFAULT_MEMBER_HEAD)
    parser.add_argument("--generic-core", type=Path, default=DEFAULT_GENERIC_CORE)
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--workdir", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--qc-only", action="store_true")
    parser.add_argument("--retry-failed", action="store_true")
    parser.add_argument("--execute", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint."""
    return run(parse_args(sys.argv[1:] if argv is None else argv))


if __name__ == "__main__":
    raise SystemExit(main())
