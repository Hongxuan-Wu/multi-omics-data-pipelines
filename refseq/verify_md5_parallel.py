#!/usr/bin/env python3
"""
RefSeq 目标集 MD5 并行校验脚本。

用法：
    python3 verify_md5_parallel.py /data/refseq_release

前提：
    download_refseq_truly_full.sh 已生成 /data/refseq_release/logs/target_files.tsv

manifest 格式（支持 # 开头的注释行）：
    # release\t235
    # download_started\t2026-07-01T...
    # base_url\thttps://...
    <md5>\t<relative_path>
    <md5>\t<relative_path>
    ...
"""
from __future__ import annotations

import hashlib
import os
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
from typing import Iterable


CHUNK_SIZE = 1 << 20


def compute_md5(filepath: Path, chunk_size: int = CHUNK_SIZE) -> str:
    h = hashlib.md5()
    with filepath.open("rb") as f:
        while chunk := f.read(chunk_size):
            h.update(chunk)
    return h.hexdigest()


def check_one(args: tuple[str, str, str]) -> tuple[str, str, str, str]:
    expected_md5, rel_path, local_root = args
    rel = Path(rel_path)
    if rel.is_absolute() or ".." in rel.parts:
        return (rel_path, "ERROR", expected_md5, "unsafe relative path")
    local_path = Path(local_root) / rel
    if not local_path.exists():
        return (rel_path, "MISSING", expected_md5, "")
    try:
        actual = compute_md5(local_path)
        status = "OK" if actual == expected_md5 else "FAILED"
        return (rel_path, status, expected_md5, actual)
    except Exception as exc:  # noqa: BLE001 - keep batch verification running.
        return (rel_path, "ERROR", expected_md5, str(exc))


def load_manifest(target_manifest: Path, local_root: str) -> list[tuple[str, str, str]]:
    """加载 manifest 文件，跳过 # 开头的注释行。"""
    tasks: list[tuple[str, str, str]] = []
    header_info: list[str] = []
    with target_manifest.open(encoding="utf-8") as f:
        for line_no, line in enumerate(f, start=1):
            line = line.rstrip("\n")
            if not line:
                continue
            if line.startswith("#"):
                header_info.append(line.lstrip("# ").strip())
                continue
            parts = line.split("\t")
            if len(parts) != 2:
                raise ValueError(
                    f"manifest 第 {line_no} 行不是 <md5>\\t<relative_path> 格式: {line!r}"
                )
            rel = Path(parts[1])
            if rel.is_absolute() or ".." in rel.parts:
                raise ValueError(f"manifest 第 {line_no} 行包含不安全相对路径: {parts[1]!r}")
            tasks.append((parts[0], parts[1], local_root))

    if header_info:
        print("Manifest 信息：")
        for info in header_info:
            print(f"  {info}")
        print()

    return tasks


def iter_results(tasks: Iterable[tuple[str, str, str]], workers: int):
    with ProcessPoolExecutor(max_workers=workers) as pool:
        yield from pool.map(check_one, tasks, chunksize=50)


def parse_workers() -> int:
    default_workers = min(os.cpu_count() or 4, 8)
    raw = os.environ.get("MD5_WORKERS", str(default_workers))
    try:
        workers = int(raw)
    except ValueError:
        print(f"[ERROR] MD5_WORKERS 必须是正整数，当前值：{raw!r}")
        raise SystemExit(1)
    if workers < 1:
        print(f"[ERROR] MD5_WORKERS 必须 >= 1，当前值：{workers}")
        raise SystemExit(1)
    return workers


def main() -> int:
    if len(sys.argv) < 2:
        print("用法: python3 verify_md5_parallel.py <local_root>")
        print("示例: python3 verify_md5_parallel.py /data/refseq_release")
        return 1

    local_root = sys.argv[1]
    target_manifest = Path(local_root) / "logs" / "target_files.tsv"
    if not target_manifest.exists() or target_manifest.stat().st_size == 0:
        print(f"[ERROR] 目标 manifest 不存在或为空：{target_manifest}")
        print("        请先运行 download_refseq_truly_full.sh。")
        return 1

    try:
        tasks = load_manifest(target_manifest, local_root)
    except ValueError as exc:
        print(f"[ERROR] {exc}")
        return 1

    if not tasks:
        print(f"[ERROR] 目标 manifest 没有数据行：{target_manifest}")
        return 1

    workers = parse_workers()

    print(f"共 {len(tasks)} 个目标文件待校验，启动 {workers} 个进程...")
    stats = {"OK": 0, "FAILED": 0, "MISSING": 0, "ERROR": 0}
    failed_lines: list[str] = []

    for i, result in enumerate(iter_results(tasks, workers), start=1):
        rel_path, status, expected, actual = result
        stats[status] = stats.get(status, 0) + 1
        if status != "OK":
            failed_lines.append(f"{status}\t{rel_path}\t{expected}\t{actual}")
        if i % 500 == 0:
            print(
                f"  进度 {i}/{len(tasks)}  "
                f"OK={stats['OK']}  FAIL={stats['FAILED']}  "
                f"MISS={stats['MISSING']}  ERROR={stats['ERROR']}"
            )

    print("\n========== 校验摘要 ==========")
    for key in ("OK", "FAILED", "MISSING", "ERROR"):
        print(f"  {key}: {stats[key]}")

    pass_rate = stats["OK"] / len(tasks) * 100
    print(f"\n  通过率：{pass_rate:.1f}%")

    if failed_lines:
        failed_file = Path(local_root) / "logs" / "md5_failed_parallel.txt"
        failed_file.parent.mkdir(parents=True, exist_ok=True)
        failed_file.write_text("\n".join(failed_lines) + "\n", encoding="utf-8")
        print(f"失败/缺失列表：{failed_file}")
        print("建议将异常文件移入本地垃圾箱/隔离目录后，重跑下载脚本续传。")
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())