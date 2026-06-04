#!/usr/bin/env python3
import argparse
import json
import os
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a stable top-level SRA directory manifest.")
    parser.add_argument("--root", required=True, help="NCBI SRA metadata snapshot root.")
    parser.add_argument("--out", required=True, help="Output text file with one absolute directory path per line.")
    parser.add_argument("--limit", type=int, default=0, help="Maximum directory count; 0 means full scan.")
    args = parser.parse_args()

    root = Path(args.root)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    summary_path = out.with_suffix(out.suffix + ".summary.json")

    t0 = time.monotonic()
    count = 0
    prefix_counts: dict[str, int] = {}

    with os.scandir(root) as it, out.open("w", encoding="utf-8", newline="\n") as fh:
        for entry in it:
            try:
                if not entry.is_dir(follow_symlinks=False):
                    continue
            except OSError:
                continue
            name = entry.name
            prefix = name[:3]
            prefix_counts[prefix] = prefix_counts.get(prefix, 0) + 1
            fh.write(entry.path)
            fh.write("\n")
            count += 1
            if count % 100000 == 0:
                elapsed = time.monotonic() - t0
                print(f"progress directories={count} seconds={elapsed:.2f}", flush=True)
            if args.limit and count >= args.limit:
                break

    elapsed = time.monotonic() - t0
    summary = {
        "root": str(root),
        "manifest": str(out),
        "directory_count": count,
        "limit": args.limit,
        "elapsed_seconds": elapsed,
        "prefix_counts": dict(sorted(prefix_counts.items())),
    }
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
