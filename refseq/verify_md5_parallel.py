#!/usr/bin/env python3
"""
RefSeq 目标集 MD5 并行校验脚本。

用法：
    python3 verify_md5_parallel.py /data3/p252701008/refseq_release

前提：
    download_refseq_truly_full.sh 已生成 /data3/p252701008/refseq_release/logs/target_files.tsv

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


# 每次读取 1 MiB，避免一次性把大文件读进内存。
CHUNK_SIZE = 1 << 20


def compute_md5(filepath: Path, chunk_size: int = CHUNK_SIZE) -> str:
    # hashlib.md5() 逐块更新；适合 GB 级 gzip 文件。
    h = hashlib.md5()
    with filepath.open("rb") as f:
        while chunk := f.read(chunk_size):
            h.update(chunk)
    return h.hexdigest()


def check_one(args: tuple[str, str, str]) -> tuple[str, str, str, str]:
    # 单个文件的校验任务；返回统一四元组，方便主进程统计。
    expected_md5, rel_path, local_root = args
    rel = Path(rel_path)
    # manifest 中的路径必须是相对路径，不能逃出 local_root。
    if rel.is_absolute() or ".." in rel.parts:
        return (rel_path, "ERROR", expected_md5, "unsafe relative path")
    local_path = Path(local_root) / rel
    # 文件缺失不抛异常，返回 MISSING，让批量校验继续跑完。
    if not local_path.exists():
        return (rel_path, "MISSING", expected_md5, "")
    try:
        # 计算实际 MD5，并和 manifest 中的期望值比较。
        actual = compute_md5(local_path)
        status = "OK" if actual == expected_md5 else "FAILED"
        return (rel_path, status, expected_md5, actual)
    except Exception as exc:  # noqa: BLE001 - keep batch verification running.
        return (rel_path, "ERROR", expected_md5, str(exc))


def load_manifest(target_manifest: Path, local_root: str) -> list[tuple[str, str, str]]:
    """加载 manifest 文件，跳过 # 开头的注释行。"""
    # tasks 中每个元素就是一个 ProcessPoolExecutor 要处理的文件校验任务。
    tasks: list[tuple[str, str, str]] = []
    # header_info 保存 release、download_started、base_url 等注释头，打印给用户确认来源。
    header_info: list[str] = []
    with target_manifest.open(encoding="utf-8") as f:
        for line_no, line in enumerate(f, start=1):
            line = line.rstrip("\n")
            if not line:
                continue
            if line.startswith("#"):
                # manifest 的头部注释不参与校验，只用于展示元信息。
                header_info.append(line.lstrip("# ").strip())
                continue
            parts = line.split("\t")
            # 下载脚本生成的 target_files.tsv 必须严格是 md5<TAB>relative_path。
            if len(parts) != 2:
                raise ValueError(
                    f"manifest 第 {line_no} 行不是 <md5>\\t<relative_path> 格式: {line!r}"
                )
            rel = Path(parts[1])
            # 这里再次做路径安全检查，防止损坏或手工改过的 manifest 访问外部路径。
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
    # 使用多进程而不是多线程：MD5 计算偏 CPU/IO 混合，多进程更稳定。
    with ProcessPoolExecutor(max_workers=workers) as pool:
        # chunksize=50 可以降低进程间调度开销，适合大量小文件。
        yield from pool.map(check_one, tasks, chunksize=50)


def parse_workers() -> int:
    # 默认最多 8 个进程，避免把共享磁盘 IO 打满。
    default_workers = min(os.cpu_count() or 4, 8)
    # 用户可以用 MD5_WORKERS=16 python3 ... 临时覆盖并行度。
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
    # Python 版本不内置默认路径，强制用户显式传 local_root，避免误校验旧目录。
    if len(sys.argv) < 2:
        print("用法: python3 verify_md5_parallel.py <local_root>")
        print("示例: python3 verify_md5_parallel.py /data3/p252701008/refseq_release")
        return 1

    local_root = sys.argv[1]
    # 并行脚本只读取 target_files.tsv；无 MD5 文件的 gzip CRC 由 Shell 验证脚本负责。
    target_manifest = Path(local_root) / "logs" / "target_files.tsv"
    if not target_manifest.exists() or target_manifest.stat().st_size == 0:
        print(f"[ERROR] 目标 manifest 不存在或为空：{target_manifest}")
        print("        请先运行 download_refseq_truly_full.sh。")
        return 1

    try:
        # 读取 manifest 时会同时验证格式和路径安全。
        tasks = load_manifest(target_manifest, local_root)
    except ValueError as exc:
        print(f"[ERROR] {exc}")
        return 1

    if not tasks:
        print(f"[ERROR] 目标 manifest 没有数据行：{target_manifest}")
        return 1

    workers = parse_workers()

    print(f"共 {len(tasks)} 个目标文件待校验，启动 {workers} 个进程...")
    # stats 记录四类状态；failed_lines 保存需要写入失败报告的明细。
    stats = {"OK": 0, "FAILED": 0, "MISSING": 0, "ERROR": 0}
    failed_lines: list[str] = []

    # enumerate 从 1 开始，便于直接打印“已处理文件数”。
    for i, result in enumerate(iter_results(tasks, workers), start=1):
        rel_path, status, expected, actual = result
        stats[status] = stats.get(status, 0) + 1
        if status != "OK":
            # 非 OK 文件统一写入 md5_failed_parallel.txt，便于后续续传/隔离。
            failed_lines.append(f"{status}\t{rel_path}\t{expected}\t{actual}")
        if i % 500 == 0:
            # 每 500 个文件打印一次进度，避免日志过密。
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
        # 只有失败/缺失/错误文件才会生成这个明细文件。
        failed_file = Path(local_root) / "logs" / "md5_failed_parallel.txt"
        failed_file.parent.mkdir(parents=True, exist_ok=True)
        failed_file.write_text("\n".join(failed_lines) + "\n", encoding="utf-8")
        print(f"失败/缺失列表：{failed_file}")
        print("建议将异常文件移入本地垃圾箱/隔离目录后，重跑下载脚本续传。")
        return 1

    return 0


if __name__ == "__main__":
    # main() 返回的状态码直接作为进程退出码，方便 nohup/调度器判断成功失败。
    raise SystemExit(main())
