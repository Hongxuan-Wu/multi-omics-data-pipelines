#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


KEY_COLUMNS = [
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

PRESENCE_COLUMNS = [
    "Submission",
    "Experiment",
    "Sample",
    "Study",
    "Loaded",
    "Spots",
    "Bases",
    "BioSample",
    "BioProject",
    "ReplacedBy",
]

TOP_N = 20


def normalize_value(value: str) -> str:
    value = value.strip()
    return value if value and value != "-" else "-"


def prefix_of(accession: str) -> str:
    accession = accession.strip()
    if accession.startswith("SRA"):
        return "SRA"
    if accession.startswith("ERA"):
        return "ERA"
    if accession.startswith("DRA"):
        return "DRA"
    return "OTHER"


def safe_int(value: str) -> int | None:
    value = normalize_value(value)
    if value == "-":
        return None
    try:
        return int(value)
    except ValueError:
        return None


def top_counter(counter: Counter[str], n: int = TOP_N) -> list[dict[str, int | str]]:
    return [{"value": key, "count": count} for key, count in counter.most_common(n)]


def top_numeric_counter(counter: Counter[int], n: int = TOP_N) -> list[dict[str, int]]:
    return [{"value": key, "count": count} for key, count in counter.most_common(n)]


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def render_markdown(result: dict, json_path: Path, script_path: Path) -> str:
    matrix_rows = result["prefix_type_matrix"]
    lines = [
        f"# SRA_Accessions 审计报告",
        "",
        f"- 输入文件: `{result['input_path']}`",
        f"- 代码路径: `{script_path}`",
        f"- JSON 结果: `{json_path}`",
        f"- 扫描时间(UTC): `{result['generated_at_utc']}`",
        "",
        "## 基本情况",
        f"- 总行数(含表头): `{result['total_lines_including_header']}`",
        f"- 数据行数(不含表头): `{result['data_lines']}`",
        f"- 字段数: `{result['column_count']}`",
        f"- 表头: `{', '.join(result['header'])}`",
        "",
        "## Accession 前缀分布",
    ]
    for item in result["prefix_counts"]:
        lines.append(f"- `{item['value']}`: `{item['count']}`")

    lines.extend(
        [
            "",
            "## Type 分布",
        ]
    )
    for item in result["type_counts"]:
        lines.append(f"- `{item['value']}`: `{item['count']}`")

    lines.extend(
        [
            "",
            "## Status 分布",
        ]
    )
    for item in result["status_counts"]:
        lines.append(f"- `{item['value']}`: `{item['count']}`")

    lines.extend(
        [
            "",
            "## Visibility 分布",
        ]
    )
    for item in result["visibility_counts"]:
        lines.append(f"- `{item['value']}`: `{item['count']}`")

    lines.extend(
        [
            "",
            "## 前缀 × Type",
        ]
    )
    for prefix, row in matrix_rows.items():
        pieces = [f"{type_name}={count}" for type_name, count in row.items()]
        lines.append(f"- `{prefix}`: " + ", ".join(pieces))

    lines.extend(
        [
            "",
            "## 关键字段非缺失计数",
        ]
    )
    for key, value in result["presence_counts"].items():
        lines.append(f"- `{key}`: `{value}`")

    lines.extend(
        [
            "",
            "## 数值字段",
            f"- `Spots` 非缺失: `{result['spots_non_missing']}`",
            f"- `Spots` 总和: `{result['spots_sum']}`",
            f"- `Spots` 最大值: `{result['spots_max']}`",
            f"- `Bases` 非缺失: `{result['bases_non_missing']}`",
            f"- `Bases` 总和: `{result['bases_sum']}`",
            f"- `Bases` 最大值: `{result['bases_max']}`",
            "",
            "## Top 20 Center",
        ]
    )
    for item in result["top_centers"]:
        lines.append(f"- `{item['value']}`: `{item['count']}`")

    lines.extend(
        [
            "",
            "## Top 20 BioSample 前缀",
        ]
    )
    for item in result["biosample_prefix_counts"]:
        lines.append(f"- `{item['value']}`: `{item['count']}`")

    return "\n".join(lines) + "\n"


def audit_file(input_path: Path) -> dict:
    total_lines = 0
    data_lines = 0
    prefix_counts: Counter[str] = Counter()
    type_counts: Counter[str] = Counter()
    status_counts: Counter[str] = Counter()
    visibility_counts: Counter[str] = Counter()
    center_counts: Counter[str] = Counter()
    biosample_prefix_counts: Counter[str] = Counter()
    prefix_type_matrix: dict[str, Counter[str]] = defaultdict(Counter)
    presence_counts: Counter[str] = Counter()
    spots_non_missing = 0
    bases_non_missing = 0
    spots_sum = 0
    bases_sum = 0
    spots_max = 0
    bases_max = 0

    with input_path.open("r", encoding="utf-8", errors="replace", newline="") as handle:
        reader = csv.reader(handle, delimiter="\t")
        try:
            header = next(reader)
        except StopIteration as exc:
            raise ValueError(f"Empty file: {input_path}") from exc

        total_lines += 1
        if header != KEY_COLUMNS:
            raise ValueError(f"Unexpected header in {input_path}: {header}")

        for row in reader:
            total_lines += 1
            if not row:
                continue
            if len(row) != len(header):
                raise ValueError(
                    f"Malformed row at line {total_lines}: expected {len(header)} columns, got {len(row)}"
                )

            data_lines += 1
            record = dict(zip(header, row))

            accession = normalize_value(record["Accession"])
            prefix = prefix_of(accession)
            type_value = normalize_value(record["Type"])
            status_value = normalize_value(record["Status"])
            visibility_value = normalize_value(record["Visibility"])
            center_value = normalize_value(record["Center"])
            biosample_value = normalize_value(record["BioSample"])

            prefix_counts[prefix] += 1
            type_counts[type_value] += 1
            status_counts[status_value] += 1
            visibility_counts[visibility_value] += 1
            center_counts[center_value] += 1
            prefix_type_matrix[prefix][type_value] += 1

            for col in PRESENCE_COLUMNS:
                if normalize_value(record[col]) != "-":
                    presence_counts[col] += 1

            if biosample_value != "-":
                biosample_prefix_counts[prefix_of(biosample_value)] += 1

            spots = safe_int(record["Spots"])
            if spots is not None:
                spots_non_missing += 1
                spots_sum += spots
                if spots > spots_max:
                    spots_max = spots

            bases = safe_int(record["Bases"])
            if bases is not None:
                bases_non_missing += 1
                bases_sum += bases
                if bases > bases_max:
                    bases_max = bases

    return {
        "input_path": str(input_path),
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "total_lines_including_header": total_lines,
        "data_lines": data_lines,
        "column_count": len(header),
        "header": header,
        "prefix_counts": top_counter(prefix_counts, n=len(prefix_counts)),
        "type_counts": top_counter(type_counts, n=len(type_counts)),
        "status_counts": top_counter(status_counts, n=len(status_counts)),
        "visibility_counts": top_counter(visibility_counts, n=len(visibility_counts)),
        "top_centers": top_counter(center_counts, n=TOP_N),
        "biosample_prefix_counts": top_counter(biosample_prefix_counts, n=len(biosample_prefix_counts)),
        "prefix_type_matrix": {
            prefix: dict(sorted(counter.items(), key=lambda item: (-item[1], item[0])))
            for prefix, counter in sorted(prefix_type_matrix.items())
        },
        "presence_counts": {key: presence_counts.get(key, 0) for key in PRESENCE_COLUMNS},
        "spots_non_missing": spots_non_missing,
        "spots_sum": spots_sum,
        "spots_max": spots_max,
        "bases_non_missing": bases_non_missing,
        "bases_sum": bases_sum,
        "bases_max": bases_max,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Audit NCBI SRA_Accessions TSV with streaming statistics.")
    parser.add_argument("--input", type=Path, required=True, help="Path to SRA_Accessions")
    parser.add_argument("--outdir", type=Path, required=True, help="Directory for JSON and Markdown outputs")
    parser.add_argument(
        "--script-path",
        type=Path,
        default=Path(__file__).resolve(),
        help="Path to the script written into the audit outputs for provenance",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    args.outdir.mkdir(parents=True, exist_ok=True)
    result = audit_file(args.input)

    json_path = args.outdir / "sra_accessions_audit.json"
    md_path = args.outdir / "sra_accessions_audit.md"

    write_json(json_path, result)
    md_path.write_text(render_markdown(result, json_path=json_path, script_path=args.script_path), encoding="utf-8")


if __name__ == "__main__":
    main()
