#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${repo_root}/refseq/refseq_release_dir/download_refseq.sh"
expected='该脚本已归档并禁止执行；当前 RefSeq 数据库请使用 genomes_dir/download_refseq_genomes_api.sh。'

head -n 30 "${script}" | grep -Fq -- "${expected}" || {
  printf 'archived release guard is missing from script header\n' >&2
  exit 1
}

set +e
output="$(bash "${script}" 2>&1)"
status=$?
set -e

if [[ "${status}" -ne 2 || "${output}" != "[FATAL] ${expected}" ]]; then
  printf 'archived release guard failed\nstatus=%s\noutput=%s\n' "${status}" "${output}" >&2
  exit 1
fi

printf 'Archived release entrypoint is guarded.\n'
