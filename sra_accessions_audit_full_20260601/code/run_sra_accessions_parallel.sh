#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <input_path> <audit_root> <workers>" >&2
  exit 1
fi

INPUT_PATH="$1"
AUDIT_ROOT="$2"
WORKERS="$3"

CHUNK_DIR="${AUDIT_ROOT}/outputs/chunks"
FINAL_JSON="${AUDIT_ROOT}/outputs/sra_accessions_parallel_audit.json"
FINAL_MD="${AUDIT_ROOT}/outputs/sra_accessions_parallel_audit.md"
WORKER_SCRIPT="${AUDIT_ROOT}/code/sra_accessions_chunk_audit.cpp"
MERGE_SCRIPT="${AUDIT_ROOT}/code/merge_sra_accessions_chunks.py"
WORKER_BIN="${AUDIT_ROOT}/code/sra_accessions_chunk_audit"

mkdir -p "${CHUNK_DIR}" "${AUDIT_ROOT}/logs"
rm -f "${CHUNK_DIR}"/chunk_*.json

FILE_SIZE=$(stat -c '%s' "${INPUT_PATH}")
CHUNK_SIZE=$(( (FILE_SIZE + WORKERS - 1) / WORKERS ))

for ((i=0; i<WORKERS; i++)); do
  start=$(( i * CHUNK_SIZE ))
  end=$(( (i + 1) * CHUNK_SIZE ))
  if (( end > FILE_SIZE )); then
    end=${FILE_SIZE}
  fi
  include_header=0
  if (( i == 0 )); then
    include_header=1
  fi
  echo "launch chunk ${i}: start=${start} end=${end}" >&2
  "${WORKER_BIN}" "${INPUT_PATH}" "${start}" "${end}" "${include_header}" "${CHUNK_DIR}/chunk_${i}.json" \
    > "${AUDIT_ROOT}/logs/chunk_${i}.stdout" \
    2> "${AUDIT_ROOT}/logs/chunk_${i}.stderr" &
done

wait

python3 "${MERGE_SCRIPT}" \
  --chunk-dir "${CHUNK_DIR}" \
  --json-out "${FINAL_JSON}" \
  --md-out "${FINAL_MD}" \
  --input-path "${INPUT_PATH}" \
  --worker-script "${WORKER_SCRIPT}" \
  --merge-script "${MERGE_SCRIPT}"
