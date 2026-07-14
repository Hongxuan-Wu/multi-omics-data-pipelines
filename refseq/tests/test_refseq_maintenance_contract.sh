#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
refseq_root="${repo_root}/refseq"
api_script="${refseq_root}/genomes_dir/download_refseq_genomes_api.sh"
ftp_script="${refseq_root}/genomes_dir/download_refseq_genomes_ftp.sh"
readme="${refseq_root}/readme.md"
release_doc="${refseq_root}/refseq_release_dir/refseq_release_download.md"
release_script="${refseq_root}/refseq_release_dir/download_refseq.sh"
release_verifier="${refseq_root}/refseq_release_dir/verify_refseq_truly_full.sh"
release_python_verifier="${refseq_root}/refseq_release_dir/verify_md5_parallel.py"
refseq_gitignore="${refseq_root}/.gitignore"

fail() {
  printf 'maintenance contract failed: %s\n' "$*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -f "${path}" ]] || fail "missing file: ${path}"
}

require_text() {
  local path="$1"
  local text="$2"
  grep -Fq -- "${text}" "${path}" || fail "missing text in ${path}: ${text}"
}

require_file "${refseq_root}/check_refseq.sh"
require_file "${api_script}"
require_file "${ftp_script}"
require_file "${readme}"
require_file "${release_doc}"
require_file "${release_script}"
require_file "${release_verifier}"
require_file "${release_python_verifier}"
require_file "${refseq_gitignore}"

require_text "${api_script}" 'STORAGE_DISK_CANDIDATES=(/data2 /data1 /data4 /data5 /data3)'
require_text "${api_script}" 'STORAGE_MIN_FREE_GB=200'
require_text "${api_script}" 'SHARD_SIZE=5000'
require_text "${api_script}" 'INCLUDE_FILES="all"'
require_text "${api_script}" 'FILTER_ASSEMBLY_LEVELS="all"'
require_text "${api_script}" 'REHYDRATE_MAX_WORKERS=30'
require_text "${api_script}" 'REHYDRATE_GZIP=1'
require_text "${api_script}" 'NCBI_API_KEY="${NCBI_API_KEY:-}"'
require_text "${api_script}" '唯一生产入口'

require_text "${ftp_script}" 'LOCAL_ROOT="/data2/p252701008/refseq_genomes"'
require_text "${ftp_script}" 'RUN_ROOT="/data2/p252701008/refseq_genomes_runlogs"'
require_text "${release_script}" 'LOCAL_ROOT="/data2/p252701008/refseq_release"'
require_text "${release_script}" 'RUN_ROOT="/data2/p252701008/refseq_release_runlogs"'
require_text "${release_verifier}" 'LOCAL_ROOT="${1:-/data2/p252701008/refseq_release}"'
require_text "${release_verifier}" 'RUN_ROOT="${2:-/data2/p252701008/refseq_release_runlogs}"'
require_text "${release_python_verifier}" 'DEFAULT_LOCAL_ROOT = Path("/data2/p252701008/refseq_release")'
require_text "${release_python_verifier}" 'DEFAULT_RUN_ROOT = Path("/data2/p252701008/refseq_release_runlogs")'

require_text "${readme}" '唯一生产入口'
require_text "${readme}" 'refseq_RefSeq_include_all_gzip_refseq_shards_size_5000_4067231603'
require_text "${readme}" 'assembly_summary_context_token: 2073201968_235955682'
require_text "${readme}" 'pipeline_context_id: 4067231603'
require_text "${readme}" '3,711,941 / 3,711,948'
require_text "${readme}" 'GCF_036905835.1'
require_text "${readme}" '历史脚本'
require_text "${readme}" 'bash refseq/check_refseq.sh'
require_text "${readme}" 'assembly summary validation passed'
require_text "${readme}" 'ln -- "${current_file}" "${archive_file}"'

require_text "${release_doc}" 'conda create -n refseq_tools python=3.11'
require_text "${refseq_gitignore}" 'assembly_summary_refseq.txt.partial.*'
require_text "${ftp_script}" '历史备用脚本'
require_text "${refseq_root}/resources/getProkaryotesGenomes.py" '历史研究脚本'
require_text "${refseq_root}/resources/preProkaryotesGeneExpression_prokaryotes.py" '历史研究脚本'

if grep -ERq \
  --include='*.sh' \
  --include='*.py' \
  --include='*.md' \
  "NCBI_API_KEY=[[:space:]]*['\"]?[[:xdigit:]]{32,}" \
  "${refseq_root}"; then
  fail "potential hard-coded NCBI API key found under ${refseq_root}"
fi

if grep -ERq \
  --include='*.sh' \
  --include='*.py' \
  'rm[[:space:]]+-rf' \
  "${refseq_root}"; then
  fail "destructive recursive deletion command found under ${refseq_root}"
fi

for markdown_file in "${readme}" "${release_doc}"; do
  fence_count="$(grep -c '^```' "${markdown_file}" || true)"
  ((fence_count % 2 == 0)) || fail "unbalanced fenced code blocks: ${markdown_file}"
done

printf 'RefSeq maintenance contract passed.\n'
