#!/usr/bin/env bash
set -euo pipefail

ROOT=${ROOT:-/data/p252701008/datasets/SRA/NCBI_SRA_Metadata_Full_20260516}
CODE_ROOT=${CODE_ROOT:-/home/m252202014/SRA/code/sra_xml_index_cpp}
BASE_OUT=${BASE_OUT:-/data/shared/sra_xml_index_20260516_cpp_fixed2_stress_100000_tsv_chunks}
LIMIT_TOTAL=${LIMIT_TOTAL:-100000}
CHUNK_SIZE=${CHUNK_SIZE:-500}
CHUNK_TIMEOUT=${CHUNK_TIMEOUT:-120}
RETRIES=${RETRIES:-2}
MANIFEST=${MANIFEST:-/data/shared/sra_xml_index_20260516_directory_manifest/dirs_first_${LIMIT_TOTAL}.txt}

mkdir -p "$BASE_OUT"
g++ -O3 -std=c++17 "$CODE_ROOT/sra_xml_indexer.cpp" -o "$CODE_ROOT/sra_xml_indexer"
if [[ ! -s "$MANIFEST" ]]; then
  mkdir -p "$(dirname "$MANIFEST")"
  echo "generating manifest=$MANIFEST limit=$LIMIT_TOTAL" >&2
  if command -v conda >/dev/null 2>&1; then
    conda run -n ai python "$CODE_ROOT/generate_directory_manifest.py" --root "$ROOT" --out "$MANIFEST" --limit "$LIMIT_TOTAL"
  else
    python3 "$CODE_ROOT/generate_directory_manifest.py" --root "$ROOT" --out "$MANIFEST" --limit "$LIMIT_TOTAL"
  fi
fi

FAILED="$BASE_OUT/failed_chunks.tsv"
echo -e "start\tlimit\tattempt\tstatus" > "$FAILED"

start=0
while (( start < LIMIT_TOTAL )); do
  remaining=$(( LIMIT_TOTAL - start ))
  limit=$CHUNK_SIZE
  if (( remaining < limit )); then
    limit=$remaining
  fi
  chunk_id=$(printf '%06d' "$start")
  out="$BASE_OUT/chunk_${chunk_id}"
  ok=0
  for attempt in $(seq 1 "$RETRIES"); do
    rm -rf "$out"
    mkdir -p "$out"
    echo "launch chunk start=${start} limit=${limit} attempt=${attempt} out=${out}" >&2
    if timeout "$CHUNK_TIMEOUT" /usr/bin/time -f 'wall_elapsed=%E' "$CODE_ROOT/sra_xml_indexer" "$MANIFEST" "$out" "$limit" "$start" \
        > "$out/run.stdout" 2> "$out/run.stderr"; then
      ok=1
      break
    fi
    echo "chunk failed_or_timed_out start=${start} limit=${limit} attempt=${attempt}" >&2
    echo -e "${start}\t${limit}\t${attempt}\tfailed_or_timed_out" >> "$FAILED"
  done
  if (( ok == 0 )); then
    echo "chunk permanently_failed start=${start} limit=${limit}" >&2
  fi
  start=$(( start + limit ))
done

if [[ $(wc -l < "$FAILED") -gt 1 ]]; then
  echo "some chunks failed; see $FAILED" >&2
  exit 1
fi
