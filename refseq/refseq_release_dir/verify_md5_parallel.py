#!/usr/bin/env python3
"""
RefSeq 官方 MD5 并行校验脚本。

默认读取 download_refseq.sh 在 RUN_ROOT/manifests 下生成的最新
target_files_<RUN_ID>.tsv，只校验有官方 MD5 的文件。没有官方 MD5 的文件
仍需要用 verify_refseq_truly_full.sh 做 gzip/非空弱校验。

常用用法：
    python3 verify_md5_parallel.py
    python3 verify_md5_parallel.py --run-id 20260702T132418Z.1820503
    MD5_WORKERS=16 python3 verify_md5_parallel.py --manifest /path/target_files_x.tsv
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
from typing import Iterable


# DEFAULT_LOCAL_ROOT：download_refseq.sh 默认本地镜像根目录。
DEFAULT_LOCAL_ROOT = Path("/data3/p252701008/refseq_release")
# DEFAULT_RUN_ROOT：download_refseq.sh 默认运行日志与 manifest 根目录。
DEFAULT_RUN_ROOT = Path("/data3/p252701008/refseq_release_runlogs")
# CHUNK_SIZE：每次读取 1 MiB，避免一次性把大文件读进内存。
CHUNK_SIZE = 1 << 20
# MD5_RE：官方 MD5 字段必须是 32 位十六进制字符串。
MD5_RE = re.compile(r"^[0-9a-fA-F]{32}$")


def compute_md5(filepath: Path, chunk_size: int = CHUNK_SIZE) -> str:
    """逐块计算单个文件的 MD5。"""
    h = hashlib.md5()
    with filepath.open("rb") as f:
        while chunk := f.read(chunk_size):
            h.update(chunk)
    return h.hexdigest()


def is_safe_relative_path(rel_path: str) -> bool:
    """确认 manifest 中的路径不能是绝对路径，也不能包含 ..。"""
    if not rel_path or rel_path == ".":
        return False
    rel = Path(rel_path)
    return not rel.is_absolute() and ".." not in rel.parts


def is_within_local_root(local_root: Path, local_path: Path) -> bool:
    """确认文件解析符号链接后仍位于 LOCAL_ROOT 内。"""
    try:
        root_real = local_root.resolve(strict=True)
        path_real = local_path.resolve(strict=True)
        path_real.relative_to(root_real)
    except (OSError, ValueError):
        return False
    return True


def check_one(args: tuple[str, str, str]) -> tuple[str, str, str, str]:
    """校验单个文件，返回 rel_path、状态、期望 MD5、实际值或错误信息。"""
    expected_md5, rel_path, local_root = args
    if not is_safe_relative_path(rel_path):
        return (rel_path, "ERROR", expected_md5, "unsafe relative path")

    local_root_path = Path(local_root)
    local_path = local_root_path / rel_path
    if not local_path.exists():
        return (rel_path, "MISSING", expected_md5, "")
    if not is_within_local_root(local_root_path, local_path):
        return (rel_path, "ERROR", expected_md5, "path resolves outside local_root")

    try:
        actual = compute_md5(local_path)
        status = "OK" if actual.lower() == expected_md5.lower() else "FAILED"
        return (rel_path, status, expected_md5, actual)
    except Exception as exc:  # noqa: BLE001 - keep batch verification running.
        return (rel_path, "ERROR", expected_md5, str(exc))


def parse_header_line(line: str) -> tuple[str, str] | None:
    """解析 '# key<TAB>value' 或 '# key value' 形式的 manifest 头。"""
    text = line.lstrip("#").strip()
    if not text:
        return None
    if "\t" in text:
        key, value = text.split("\t", 1)
    else:
        parts = text.split(None, 1)
        if len(parts) != 2:
            return None
        key, value = parts
    return key.strip(), value.strip()


def read_manifest_header(target_manifest: Path) -> dict[str, str]:
    """读取 manifest 注释头，保留 release、local_root、run_id 等元信息。"""
    header: dict[str, str] = {}
    with target_manifest.open(encoding="utf-8") as f:
        for line in f:
            if not line.startswith("#"):
                break
            parsed = parse_header_line(line)
            if parsed is not None:
                key, value = parsed
                header[key] = value
    return header


def load_manifest(target_manifest: Path, local_root: Path) -> list[tuple[str, str, str]]:
    """加载 target_files_<RUN_ID>.tsv，跳过 # 注释头。"""
    tasks: list[tuple[str, str, str]] = []
    with target_manifest.open(encoding="utf-8") as f:
        for line_no, line in enumerate(f, start=1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue

            parts = line.split("\t")
            if len(parts) != 2:
                raise ValueError(
                    f"manifest 第 {line_no} 行不是 <md5>\\t<relative_path> 格式: {line!r}"
                )

            expected_md5, rel_path = parts
            if not MD5_RE.match(expected_md5):
                raise ValueError(f"manifest 第 {line_no} 行 MD5 格式错误: {expected_md5!r}")
            if not rel_path:
                raise ValueError(f"manifest 第 {line_no} 行 relative_path 为空")
            if not is_safe_relative_path(rel_path):
                raise ValueError(f"manifest 第 {line_no} 行包含不安全相对路径: {rel_path!r}")

            tasks.append((expected_md5.lower(), rel_path, str(local_root)))

    return tasks


def find_latest_manifest(run_root: Path) -> Path:
    """从 RUN_ROOT/manifests 自动选择最新 target_files_<RUN_ID>.tsv。"""
    manifest_dir = run_root / "manifests"
    files = sorted(
        manifest_dir.glob("target_files_*.tsv"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not files:
        raise FileNotFoundError(f"未找到 target_files_*.tsv：{manifest_dir}")
    return files[0]


def manifest_from_run_id(run_root: Path, run_id: str) -> Path:
    """按 RUN_ID 定位 target manifest。"""
    return run_root / "manifests" / f"target_files_{run_id}.tsv"


def run_id_from_manifest(path: Path, header: dict[str, str]) -> str:
    """优先从 manifest header 读取 run_id，失败时从文件名解析。"""
    if header.get("run_id"):
        return header["run_id"]
    name = path.name
    prefix = "target_files_"
    suffix = ".tsv"
    if name.startswith(prefix) and name.endswith(suffix):
        return name[len(prefix) : -len(suffix)]
    return "unknown_run"


def validate_target_manifest_metadata(path: Path, header: dict[str, str]) -> None:
    """确认输入确实是 download_refseq.sh 生成的 target manifest。"""
    if not (path.name.startswith("target_files_") and path.name.endswith(".tsv")):
        raise ValueError(f"manifest 文件名必须匹配 target_files_<RUN_ID>.tsv：{path}")

    required_keys = ("release", "base_url", "local_root", "run_id", "columns")
    missing = [key for key in required_keys if not header.get(key)]
    if missing:
        missing_text = ", ".join(f"# {key}" for key in missing)
        raise ValueError(f"manifest 缺少 download_refseq.sh 生成的头信息：{missing_text}")

    file_run_id = path.name[len("target_files_") : -len(".tsv")]
    if header["run_id"] != file_run_id:
        raise ValueError(
            "manifest run_id 与文件名不一致："
            f"header run_id={header['run_id']!r}, 文件名 run_id={file_run_id!r}"
        )

    columns = header.get("columns")
    if columns.split() != ["md5", "relative_path"]:
        raise ValueError(
            "manifest columns 必须是 'md5<TAB>relative_path'，"
            f"当前为：{columns!r}"
        )


def iter_results(tasks: Iterable[tuple[str, str, str]], workers: int):
    """用多进程并行校验 MD5。"""
    with ProcessPoolExecutor(max_workers=workers) as pool:
        yield from pool.map(check_one, tasks, chunksize=50)


def parse_workers(cli_workers: int | None) -> int:
    """解析并行进程数；命令行优先，其次 MD5_WORKERS，最后自动上限 8。"""
    default_workers = min(os.cpu_count() or 4, 8)
    raw = str(cli_workers) if cli_workers is not None else os.environ.get("MD5_WORKERS", str(default_workers))
    try:
        workers = int(raw)
    except ValueError:
        raise ValueError(f"MD5_WORKERS/--workers 必须是正整数，当前值：{raw!r}") from None
    if workers < 1:
        raise ValueError(f"MD5_WORKERS/--workers 必须 >= 1，当前值：{workers}")
    return workers


def build_parser() -> argparse.ArgumentParser:
    """构建命令行参数解析器。"""
    parser = argparse.ArgumentParser(description="并行校验 RefSeq target_files_<RUN_ID>.tsv 中的官方 MD5 文件。")
    parser.add_argument(
        "local_root_pos",
        nargs="?",
        help="本地 RefSeq 镜像根目录；默认读取 manifest header 或 /data3/p252701008/refseq_release。",
    )
    parser.add_argument("--local-root", help="本地 RefSeq 镜像根目录，优先级高于位置参数。")
    parser.add_argument("--run-root", default=str(DEFAULT_RUN_ROOT), help="download_refseq.sh 的 RUN_ROOT。")
    parser.add_argument("--run-id", help="指定 RUN_ID；不指定时自动选择最新 target_files_*.tsv。")
    parser.add_argument("--manifest", help="直接指定 target_files_<RUN_ID>.tsv 路径。")
    parser.add_argument("--workers", type=int, help="并行进程数；默认读取 MD5_WORKERS 或自动上限 8。")
    parser.add_argument("--failed-output", help="失败明细输出路径；默认写入 RUN_ROOT/logs/md5_failed_parallel_<RUN_ID>.txt。")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    run_root = Path(args.run_root)

    if args.manifest:
        target_manifest = Path(args.manifest)
    elif args.run_id:
        target_manifest = manifest_from_run_id(run_root, args.run_id)
    else:
        try:
            target_manifest = find_latest_manifest(run_root)
        except FileNotFoundError as exc:
            print(f"[ERROR] {exc}")
            print("        请先运行 download_refseq.sh，或用 --manifest 指定 manifest。")
            return 1

    if not target_manifest.exists() or target_manifest.stat().st_size == 0:
        print(f"[ERROR] 目标 manifest 不存在或为空：{target_manifest}")
        print("        请先运行 download_refseq.sh，或确认 --run-root/--run-id/--manifest 是否正确。")
        return 1

    header = read_manifest_header(target_manifest)
    local_root_raw = args.local_root or args.local_root_pos or header.get("local_root") or str(DEFAULT_LOCAL_ROOT)
    local_root = Path(local_root_raw)
    run_id = run_id_from_manifest(target_manifest, header)

    try:
        validate_target_manifest_metadata(target_manifest, header)
        tasks = load_manifest(target_manifest, local_root)
        workers = parse_workers(args.workers)
    except ValueError as exc:
        print(f"[ERROR] {exc}")
        return 1

    if not tasks:
        print(f"[ERROR] 目标 manifest 没有 MD5 数据行：{target_manifest}")
        print("        若本轮只下载无官方 MD5 文件，请使用 verify_refseq_truly_full.sh 做弱校验。")
        return 1

    print("Manifest 信息：")
    print(f"  target_manifest: {target_manifest}")
    print(f"  local_root:      {local_root}")
    print(f"  run_root:        {run_root}")
    print(f"  run_id:          {run_id}")
    for key in ("release", "base_url", "columns"):
        if key in header:
            print(f"  {key}: {header[key]}")
    print()

    print(f"共 {len(tasks)} 个官方 MD5 文件待校验，启动 {workers} 个进程...")
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
        failed_file = Path(args.failed_output) if args.failed_output else run_root / "logs" / f"md5_failed_parallel_{run_id}.txt"
        failed_file.parent.mkdir(parents=True, exist_ok=True)
        failed_file.write_text("\n".join(failed_lines) + "\n", encoding="utf-8")
        print(f"失败/缺失列表：{failed_file}")
        print("处理建议：确认没有 .aria2 续传文件后，重跑 download_refseq.sh；异常旧文件会由下载脚本移入垃圾箱。")
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
