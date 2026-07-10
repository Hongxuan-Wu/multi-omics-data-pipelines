#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SAMPLES_FILE="${SAMPLES_FILE:-${COMMON_PROJECT_ROOT}/config/samples.tsv}"
PHASE=""
RUN_ID=""

usage() {
    printf 'usage: %s --run-id ID --phase before|after\n' "$0" >&2
}

while (( $# > 0 )); do
    case "$1" in
        --run-id)
            (( $# >= 2 )) || { usage; exit 2; }
            RUN_ID="$2"
            shift 2
            ;;
        --phase)
            (( $# >= 2 )) || { usage; exit 2; }
            PHASE="$2"
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

require_run_id
case "${PHASE}" in
    before|after) ;;
    *) usage; exit 2 ;;
esac
assert_absolute "${SAMPLES_FILE}"
[[ -f "${SAMPLES_FILE}" ]] || die "缺少样本表：${SAMPLES_FILE}"

set_run_paths
[[ -d "${RUN_REPORT_ROOT}" && -d "${RUN_LOG_ROOT}" ]] || \
    die "run 布局尚未初始化：${RUN_ID}"

manifest_path="${RUN_REPORT_ROOT}/input_manifest.${PHASE}.tsv"
manifest_tmp="${RUN_LOG_ROOT}/input_manifest.${PHASE}.tmp.$$"
assert_report_output_path "${manifest_path}"
assert_process_output_path "${manifest_tmp}"
[[ ! -e "${manifest_path}" ]] || die "输入快照已存在：${manifest_path}"

validate_input_path() {
    local path="$1"

    assert_absolute "${path}" || return 1
    [[ "${path}" != *$'\t'* && "${path}" != *$'\n'* ]] || \
        die "输入路径包含 TSV 非法字符：${path}"
    [[ -f "${path}" && -r "${path}" ]] || die "输入文件缺失或不可读：${path}"
}

append_sha256() {
    local kind="$1"
    local path="$2"
    local size_bytes mtime_epoch checksum

    validate_input_path "${path}" || return 1
    size_bytes="$(stat -c '%s' -- "${path}")"
    mtime_epoch="$(stat -c '%Y' -- "${path}")"
    checksum="$(sha256sum -- "${path}" | awk '{print $1}')"
    printf '%s\t%s\t%s\t%s\tsha256\t%s\n' \
        "${kind}" "${path}" "${size_bytes}" "${mtime_epoch}" "${checksum}" \
        >> "${manifest_tmp}"
}

append_fastq_md5() {
    local fastq_path="$1"
    local md5_path="$2"
    local md5_line expected_md5 listed_name size_bytes mtime_epoch

    validate_input_path "${fastq_path}" || return 1
    validate_input_path "${md5_path}" || return 1
    IFS= read -r md5_line < "${md5_path}" || [[ -n "${md5_line}" ]] || \
        die "MD5 文件为空：${md5_path}"
    if [[ "${md5_line}" =~ ^([0-9A-Fa-f]{32})[[:space:]]+\*?(.+)$ ]]; then
        expected_md5="${BASH_REMATCH[1],,}"
        listed_name="${BASH_REMATCH[2]}"
    else
        die "MD5 文件格式非法：${md5_path}"
    fi
    [[ "${listed_name}" == "$(basename -- "${fastq_path}")" ]] || \
        die "MD5 文件指向错误输入：${md5_path} -> ${listed_name}"
    (
        cd "$(dirname -- "${md5_path}")"
        md5sum -c -- "$(basename -- "${md5_path}")" >/dev/null
    ) || die "FASTQ MD5 校验失败：${fastq_path}"

    size_bytes="$(stat -c '%s' -- "${fastq_path}")"
    mtime_epoch="$(stat -c '%Y' -- "${fastq_path}")"
    printf 'fastq\t%s\t%s\t%s\tmd5\t%s\n' \
        "${fastq_path}" "${size_bytes}" "${mtime_epoch}" "${expected_md5}" \
        >> "${manifest_tmp}"
    append_sha256 md5 "${md5_path}"
}

printf 'kind\tpath\tsize_bytes\tmtime_epoch\tchecksum_type\tchecksum\n' > "${manifest_tmp}"
for resource_path in "${REFERENCE_FASTA}" "${REFERENCE_GFF}" "${COMPANY_GFF}" "${FLOW_IMAGE}"; do
    append_sha256 resource "${resource_path}"
done

expected_header=$'sample_id\tr1\tr2\tr1_md5\tr2_md5'
IFS= read -r actual_header < "${SAMPLES_FILE}" || die "样本表为空：${SAMPLES_FILE}"
[[ "${actual_header}" == "${expected_header}" ]] || die "样本表表头不匹配：${SAMPLES_FILE}"

sample_count=0
while IFS=$'\t' read -r sample_id r1 r2 r1_md5 r2_md5 extra; do
    [[ -n "${sample_id}" && -n "${r1}" && -n "${r2}" && -n "${r1_md5}" && -n "${r2_md5}" && -z "${extra:-}" ]] || \
        die "样本表数据行非法：${sample_id:-<empty>}"
    append_fastq_md5 "${r1}" "${r1_md5}"
    append_fastq_md5 "${r2}" "${r2_md5}"
    sample_count=$((sample_count + 1))
done < <(tail -n +2 "${SAMPLES_FILE}")
[[ "${sample_count}" -eq 9 ]] || die "样本表必须包含 9 个样本，实际 ${sample_count}"

mv -- "${manifest_tmp}" "${manifest_path}"
assert_report_output_path "${manifest_path}"

if [[ "${PHASE}" == "after" ]]; then
    before_path="${RUN_REPORT_ROOT}/input_manifest.before.tsv"
    [[ -f "${before_path}" ]] || die "缺少 before 输入快照：${before_path}"
    cmp -s -- "${before_path}" "${manifest_path}" || \
        die "before/after 输入快照不一致：${RUN_ID}"
fi

printf '%s\n' "${manifest_path}"
