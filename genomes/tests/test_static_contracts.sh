#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  grep -Eq "${pattern}" "${file}" || fail "${file} missing pattern: ${pattern}"
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  if grep -Eq "${pattern}" "${file}"; then
    fail "${file} contains forbidden pattern: ${pattern}"
  fi
}

assert_executable() {
  local file="$1"
  [[ -x "${file}" ]] || fail "${file} is not executable"
}

common="${ROOT_DIR}/common/common.sh"
roadmap="${ROOT_DIR}/roadmap/download_roadmap.sh"
bvbrc="${ROOT_DIR}/bv_brc/download_bv_brc.sh"

assert_contains "${common}" '^set -Eeuo pipefail$'
assert_contains "${common}" '^export LC_ALL=C$'
assert_contains "${common}" '^warnlog\(\)'

assert_contains "${roadmap}" 'byFileType/metadata/EID_metadata\.tab'
assert_not_contains "${roadmap}" 'data/metadata/'
assert_not_contains "${roadmap}" 'model_15_coreMarks_dense\.gz'

assert_contains "${bvbrc}" 'eq\(genome_status,Complete\)'
assert_not_contains "${bvbrc}" 'BV_BRC_API_URL.*\?limit\(10\)&select'

for script in "${ROOT_DIR}"/*/download_*.sh "${common}"; do
  assert_executable "${script}"
  bash -n "${script}"
done

if grep -R -n -E '待目标环境确认|Linux 服务器 `bash -n` 仍需补做|本机 Bash/WSL 语法校验受限|jq.*本机未安装' "${ROOT_DIR}"/*/validation_report.md; then
  fail 'validation reports still contain stale local-environment validation status'
fi

printf '[PASS] genomes static contracts\n'
