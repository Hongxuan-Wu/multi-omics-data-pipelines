#!/usr/bin/env bash
set -euo pipefail

ROOT=${ROOT:-/data/p252701008/datasets/SRA/NCBI_SRA_Metadata_Full_20260516}
CODE_ROOT=${CODE_ROOT:-/home/m252202014/SRA/code/sra_xml_index_cpp}
BASE_OUT=${BASE_OUT:-/data/shared/sra_xml_index_20260516_cpp_stress_100000_tsv_chunks}
LIMIT_TOTAL=${LIMIT_TOTAL:-100000}
CHUNK_SIZE=${CHUNK_SIZE:-500}
CHUNK_TIMEOUT=${CHUNK_TIMEOUT:-300}
WORKERS=${WORKERS:-16}
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

TASKS="$BASE_OUT/chunk_tasks.tsv"
STATUS_DIR="$BASE_OUT/status"
mkdir -p "$STATUS_DIR"
: > "$TASKS"

start=0
while (( start < LIMIT_TOTAL )); do
  remaining=$(( LIMIT_TOTAL - start ))
  limit=$CHUNK_SIZE
  if (( remaining < limit )); then
    limit=$remaining
  fi
  printf "%s\t%s\n" "$start" "$limit" >> "$TASKS"
  start=$(( start + limit ))
done

export CODE_ROOT BASE_OUT MANIFEST CHUNK_TIMEOUT STATUS_DIR

run_one_chunk() {
  local start="$1"
  local limit="$2"
  local chunk_id out status_file
  chunk_id=$(printf '%06d' "$start")
  out="$BASE_OUT/chunk_${chunk_id}"
  status_file="$STATUS_DIR/chunk_${chunk_id}.status"
  rm -rf "$out"
  mkdir -p "$out"
  echo "launch chunk start=${start} limit=${limit} out=${out}" >&2
  if timeout "$CHUNK_TIMEOUT" /usr/bin/time -f 'wall_elapsed=%E' "$CODE_ROOT/sra_xml_indexer" "$MANIFEST" "$out" "$limit" "$start" \
      > "$out/run.stdout" 2> "$out/run.stderr"; then
    printf "%s\t%s\tok\n" "$start" "$limit" > "$status_file"
    return 0
  fi
  printf "%s\t%s\tfailed_or_timed_out\n" "$start" "$limit" > "$status_file"
  return 1
}

export -f run_one_chunk
if ! xargs -r -P "$WORKERS" -n 2 bash -c 'run_one_chunk "$0" "$1"' < "$TASKS"; then
  true
fi

FAILED="$BASE_OUT/failed_chunks.tsv"
echo -e "start\tlimit\tstatus" > "$FAILED"
cat "$STATUS_DIR"/*.status | sort -n -k1,1 | awk -F '\t' '$3!="ok"{print}' >> "$FAILED"
if [[ $(wc -l < "$FAILED") -gt 1 ]]; then
  echo "some chunks failed; see $FAILED" >&2
  exit 1
fi

echo "all chunks completed: $BASE_OUT" >&2
