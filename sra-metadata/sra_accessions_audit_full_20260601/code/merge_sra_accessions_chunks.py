#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

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


def add_counter(dst: Counter, src: dict[str, int]) -> None:
    for key, value in src.items():
        dst[key] += value


def top_list(counter: Counter) -> list[dict[str, int | str]]:
    return [{"value": key, "count": value} for key, value in counter.most_common()]


def load_chunks(chunk_dir: Path) -> list[dict]:
    chunks = []
    for path in sorted(chunk_dir.glob("chunk_*.json")):
        chunks.append(json.loads(path.read_text(encoding="utf-8")))
    if not chunks:
        raise ValueError(f"No chunk json files found in {chunk_dir}")
    return chunks


def merge(chunks: list[dict], input_path: str, script_paths: list[str]) -> dict:
    prefix_counts = Counter()
    type_counts = Counter()
    status_counts = Counter()
    visibility_counts = Counter()
    presence_counts = Counter()
    prefix_type_matrix: dict[str, Counter] = defaultdict(Counter)
    data_lines = 0

    for chunk in chunks:
        data_lines += chunk["data_lines"]
        add_counter(prefix_counts, chunk["prefix_counts"])
        add_counter(type_counts, chunk["type_counts"])
        add_counter(status_counts, chunk["status_counts"])
        add_counter(visibility_counts, chunk["visibility_counts"])
        add_counter(presence_counts, chunk["presence_counts"])
        for prefix, inner in chunk["prefix_type_matrix"].items():
            add_counter(prefix_type_matrix[prefix], inner)

    return {
        "input_path": input_path,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "script_paths": script_paths,
        "chunk_count": len(chunks),
        "total_lines_including_header": data_lines + 1,
        "data_lines": data_lines,
        "column_count": len(HEADER),
        "header": HEADER,
        "prefix_counts": top_list(prefix_counts),
        "type_counts": top_list(type_counts),
        "status_counts": top_list(status_counts),
        "visibility_counts": top_list(visibility_counts),
        "presence_counts": {k: presence_counts[k] for k in ["Experiment", "Sample", "Study", "Loaded", "BioSample", "BioProject"]},
        "prefix_type_matrix": {
            prefix: dict(sorted(inner.items(), key=lambda item: (-item[1], item[0])))
            for prefix, inner in sorted(prefix_type_matrix.items())
        },
    }


def render_markdown(result: dict, json_path: Path) -> str:
    lines = [
        "# SRA_Accessions 并行审计报告",
        "",
        f"- 输入文件: `{result['input_path']}`",
        f"- JSON 结果: `{json_path}`",
        f"- 代码路径: `{result['script_paths'][0]}`",
        f"- 合并脚本: `{result['script_paths'][1]}`",
        f"- 分片数: `{result['chunk_count']}`",
        f"- 总行数(含表头): `{result['total_lines_including_header']}`",
        f"- 数据行数(不含表头): `{result['data_lines']}`",
        f"- 字段数: `{result['column_count']}`",
        f"- 表头: `{', '.join(result['header'])}`",
        "",
        "## Accession 前缀分布",
    ]
    for item in result["prefix_counts"]:
        lines.append(f"- `{item['value']}`: `{item['count']}`")
    lines.append("")
    lines.append("## Type 分布")
    for item in result["type_counts"]:
        lines.append(f"- `{item['value']}`: `{item['count']}`")
    lines.append("")
    lines.append("## Status 分布")
    for item in result["status_counts"]:
        lines.append(f"- `{item['value']}`: `{item['count']}`")
    lines.append("")
    lines.append("## Visibility 分布")
    for item in result["visibility_counts"]:
        lines.append(f"- `{item['value']}`: `{item['count']}`")
    lines.append("")
    lines.append("## 关键字段非缺失计数")
    for key, value in result["presence_counts"].items():
        lines.append(f"- `{key}`: `{value}`")
    lines.append("")
    lines.append("## 前缀 × Type")
    for prefix, row in result["prefix_type_matrix"].items():
        parts = [f"{name}={count}" for name, count in row.items()]
        lines.append(f"- `{prefix}`: " + ", ".join(parts))
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--chunk-dir", type=Path, required=True)
    parser.add_argument("--json-out", type=Path, required=True)
    parser.add_argument("--md-out", type=Path, required=True)
    parser.add_argument("--input-path", required=True)
    parser.add_argument("--worker-script", required=True)
    parser.add_argument("--merge-script", required=True)
    args = parser.parse_args()

    chunks = load_chunks(args.chunk_dir)
    result = merge(
        chunks,
        input_path=args.input_path,
        script_paths=[args.worker_script, args.merge_script],
    )

    args.json_out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    args.md_out.write_text(render_markdown(result, args.json_out), encoding="utf-8")


if __name__ == "__main__":
    main()
