#!/usr/bin/env bash
# =============================================================================
# BV-BRC FTPS functional annotation downloader
#
# 目标：
#   1. 使用 BV-BRC FTPS 固定入口下载 RELEASE_NOTES 元数据。
#   2. 以 genome_summary / genome_metadata 为中心生成 genome_id 下载计划。
#   3. 默认只下载功能注释表和 GFF，不重复下载 FASTA。
#   4. 使用 lftp pget -c 支持断点续传，用 xargs -P 控制并行。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SH="${SCRIPT_DIR}/../common/common.sh"
source "${COMMON_SH}"
common_require_version "1.0"

DB_NAME="bv_brc"
RELEASE="BV-BRC_FTPS_freeze_2026-07-07"
BASE_URL="ftps://ftp.bvbrc.org"
BV_BRC_API_URL="https://www.bv-brc.org/api/genome/"
LOCAL_ROOT="/data3/p252701008/genomes/bv_brc"
RUN_ROOT="/data3/p252701008/genomes/bv_brc_runlogs"
USE_PROXY=0
PARALLEL_DOWNLOADS=6
LFTP_CONNECTIONS=4
VERIFY_AFTER_DOWNLOAD=1
SKIP_VERIFIED_FILES=1
MIN_DISK_GB=200
DOWNLOAD_FASTA=0
MAX_GENOMES=0

TARGET_SUFFIXES=(
  ".gff"
  ".features.tab"
  ".pathway.tab"
  ".subsystem.tab"
)

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ').$$"
LOG_DIR="${RUN_ROOT}/logs"
PLAN_DIR="${RUN_ROOT}/plans"
MANIFEST_DIR="${RUN_ROOT}/manifests"
TMP_DIR="${RUN_ROOT}/tmp/${RUN_ID}"
TRASH_DIR="${RUN_ROOT}/trash"
DL_LOG="${LOG_DIR}/download_${RUN_ID}.log"
ERR_LOG="${LOG_DIR}/error_${RUN_ID}.log"
PLAN_FILE="${PLAN_DIR}/download_plan_${RUN_ID}.tsv"
DIFF_REPORT="${MANIFEST_DIR}/diff_report_${RUN_ID}.tsv"
API_PROBE_JSON="${MANIFEST_DIR}/bv_brc_api_probe_${RUN_ID}.json"
API_PROBE_REPORT="${MANIFEST_DIR}/bv_brc_api_probe_report_${RUN_ID}.tsv"
GENOME_SUMMARY="${RUN_ROOT}/metadata/genome_summary"
GENOME_METADATA="${RUN_ROOT}/metadata/genome_metadata"

common_init_dirs
mkdir -p "${RUN_ROOT}/metadata"

validate_config() {
  validate_flag USE_PROXY "${USE_PROXY}"
  validate_positive_int PARALLEL_DOWNLOADS "${PARALLEL_DOWNLOADS}"
  validate_positive_int LFTP_CONNECTIONS "${LFTP_CONNECTIONS}"
  validate_flag VERIFY_AFTER_DOWNLOAD "${VERIFY_AFTER_DOWNLOAD}"
  validate_flag DOWNLOAD_FASTA "${DOWNLOAD_FASTA}"
  [[ "${MAX_GENOMES}" =~ ^[0-9]+$ ]] || die "MAX_GENOMES 必须是非负整数。"
}

bv_brc_remote_size() {
  local remote_path="$1"
  lftp -c "set ftp:ssl-force true; set ftp:ssl-protect-data true; open ${BASE_URL}; cls -l ${remote_path}" 2>/dev/null \
    | awk 'NF >= 5 && $5 ~ /^[0-9]+$/ {print $5; exit}'
}

append_bv_brc_plan_record() {
  local genome_id="$1"
  local suffix="$2"
  local role="$3"
  local remote_path url local_dir out_name remote_size

  remote_path="genomes/${genome_id}/${genome_id}${suffix}"
  url="${BASE_URL}/${remote_path}"
  local_dir="${LOCAL_ROOT}/genomes/${genome_id}"
  out_name="${genome_id}${suffix}"
  remote_size="$(bv_brc_remote_size "${remote_path}" || true)"
  if [[ -n "${remote_size}" && ! "${remote_size}" =~ ^[0-9]+$ ]]; then
    printf 'remote_size\tINVALID\t%s\t%s\n' "${remote_path}" "${remote_size}" >> "${DIFF_REPORT}"
    remote_size=""
  fi
  if [[ -z "${remote_size}" ]]; then
    printf 'remote_size\tUNKNOWN\t%s\n' "${remote_path}" >> "${DIFF_REPORT}"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${genome_id}" "${remote_path}" "${url}" "${local_dir}" "${out_name}" "${remote_size}" "${role}" >> "${PLAN_FILE}"
}

download_metadata() {
  log "下载 BV-BRC RELEASE_NOTES metadata"
  if curl -fsSL --retry 5 --retry-delay 10 "${BV_BRC_API_URL}?limit(10)&select(genome_id,genome_name,genome_status)" > "${API_PROBE_JSON}"; then
    log "BV-BRC Data API probe 已保存：${API_PROBE_JSON}"
  else
    printf 'api_probe\tFAILED\t%s\n' "${BV_BRC_API_URL}" >> "${API_PROBE_REPORT}"
    errlog "BV-BRC Data API probe 失败；继续使用 FTPS metadata。"
  fi
  lftp -c "set ftp:ssl-force true; set ftp:ssl-protect-data true; open ${BASE_URL}; pget -c -n ${LFTP_CONNECTIONS} -o ${GENOME_SUMMARY} RELEASE_NOTES/genome_summary; pget -c -n ${LFTP_CONNECTIONS} -o ${GENOME_METADATA} RELEASE_NOTES/genome_metadata"
  [[ -s "${GENOME_SUMMARY}" ]] || die "genome_summary 为空或下载失败。"
  [[ -s "${GENOME_METADATA}" ]] || die "genome_metadata 为空或下载失败。"
}

build_download_plan() {
  : > "${PLAN_FILE}"
  : > "${DIFF_REPORT}"
  printf '# genome_id\trelative_path\turl\tlocal_dir\tout_name\tremote_size\trole\n' >> "${PLAN_FILE}"
  printf '# check\tstatus\tdetail\n' >> "${DIFF_REPORT}"
  [[ -s "${API_PROBE_REPORT}" ]] && cat "${API_PROBE_REPORT}" >> "${DIFF_REPORT}"

  local genome_id suffix count=0
  awk -F'\t' 'NR>1 && $1 != "" {print $1}' "${GENOME_SUMMARY}" | while IFS= read -r genome_id; do
    [[ -n "${genome_id}" ]] || continue
    if [[ ! "${genome_id}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      printf 'metadata\tSKIPPED_INVALID_GENOME_ID\t%s\n' "${genome_id}" >> "${DIFF_REPORT}"
      continue
    fi
    if [[ "${MAX_GENOMES}" -gt 0 && "${count}" -ge "${MAX_GENOMES}" ]]; then
      break
    fi
    for suffix in "${TARGET_SUFFIXES[@]}"; do
      append_bv_brc_plan_record "${genome_id}" "${suffix}" "functional_annotation"
    done
    if [[ "${DOWNLOAD_FASTA}" == "1" ]]; then
      append_bv_brc_plan_record "${genome_id}" ".fna" "genome_sequence_optional"
    fi
    count=$((count + 1))
  done

  local planned
  planned=$(grep -Evc '^(#|[[:space:]]*$)' "${PLAN_FILE}" || true)
  [[ "${planned}" -gt 0 ]] || die "BV-BRC 下载计划为空。"
  log "下载计划生成完成：${PLAN_FILE}，文件数 ${planned}"
}

download_one_lftp() {
  local url="$1"
  local local_dir="$2"
  local out_name="$3"
  mkdir -p "${local_dir}"
  if ! lftp -c "set ftp:ssl-force true; set ftp:ssl-protect-data true; pget -c -n ${LFTP_CONNECTIONS} -o ${local_dir}/${out_name} ${url}"; then
    printf 'download\tFAILED\t%s\t%s\n' "${url}" "${local_dir}/${out_name}" >> "${DIFF_REPORT}"
    move_to_trash "${local_dir}/${out_name}" "bv_brc_download_failed"
    return 1
  fi
}
export -f download_one_lftp
export LFTP_CONNECTIONS TRASH_DIR RUN_ID LOCAL_ROOT DL_LOG ERR_LOG DIFF_REPORT COMMON_SH

run_parallel_downloads() {
  local queue_file="${TMP_DIR}/download_queue_${RUN_ID}.nul"
  local line parsed extra genome_id relpath url local_dir out_name remote_size role local_file count=0 skipped=0
  check_disk_space
  : > "${queue_file}"
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -n "${line}" && "${line}" != \#* ]] || continue
    parsed="${line//$'\t'/$'\x1f'}"
    IFS=$'\x1f' read -r genome_id relpath url local_dir out_name remote_size role extra <<< "${parsed}"
    [[ -z "${extra:-}" ]] || die "下载计划行字段错误：列数超过 7，relpath=${relpath:-unknown}。"
    mkdir -p "${local_dir}"
    local_file="${local_dir}/${out_name}"
    if existing_file_is_complete "${relpath}" "${url}" "${local_file}" "" "${remote_size}"; then
      skipped=$((skipped + 1))
      continue
    fi
    printf '%s\0%s\0%s\0' "${url}" "${local_dir}" "${out_name}" >> "${queue_file}"
    count=$((count + 1))
  done < "${PLAN_FILE}"
  log "BV-BRC 下载队列：需下载 ${count} 个，已跳过 ${skipped} 个。"
  xargs -0 -r -n 3 -P "${PARALLEL_DOWNLOADS}" bash -c 'source "${COMMON_SH}"; download_one_lftp "$0" "$1" "$2"' < "${queue_file}"
}

verify_after_download() {
  [[ "${VERIFY_AFTER_DOWNLOAD}" == "1" ]] || return 0
  local line parsed extra genome_id relpath url local_dir out_name remote_size role local_file local_size failed=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -n "${line}" && "${line}" != \#* ]] || continue
    parsed="${line//$'\t'/$'\x1f'}"
    IFS=$'\x1f' read -r genome_id relpath url local_dir out_name remote_size role extra <<< "${parsed}"
    [[ -z "${extra:-}" ]] || die "下载计划行字段错误：列数超过 7，relpath=${relpath:-unknown}。"
    local_file="${local_dir}/${out_name}"
    if [[ -n "${remote_size}" && "${remote_size}" =~ ^[0-9]+$ ]]; then
      local_size="$(stat -c '%s' "${local_file}" 2>/dev/null || printf 0)"
      if [[ "${local_size}" -ne "${remote_size}" ]]; then
        errlog "BV-BRC 文件大小校验失败：${relpath} expected=${remote_size} actual=${local_size}"
        printf 'verify\tSIZE_MISMATCH\t%s\texpected=%s\tactual=%s\n' "${relpath}" "${remote_size}" "${local_size}" >> "${DIFF_REPORT}"
        move_to_trash "${local_file}" "bv_brc_size_failed"
        failed=1
        continue
      fi
    elif [[ "${out_name}" != *.gz && "${out_name}" != *.tgz ]]; then
      errlog "BV-BRC 非 gzip 文本缺少远端 size，不能完成 size 弱校验：${relpath}"
      printf 'verify\tREMOTE_SIZE_MISSING\t%s\n' "${relpath}" >> "${DIFF_REPORT}"
      weak_verify_file "${local_file}" "${relpath}" || true
      failed=1
      continue
    fi
    if ! weak_verify_file "${local_file}" "${relpath}"; then
      printf 'verify\tFAILED\t%s\n' "${relpath}" >> "${DIFF_REPORT}"
      failed=1
    fi
  done < "${PLAN_FILE}"
  [[ "${failed}" -eq 0 ]] || die "BV-BRC 至少一个文件弱校验失败。"
  log "BV-BRC 下载后弱校验完成。"
}

main() {
  require_command lftp
  require_command curl
  require_command awk
  require_command xargs
  validate_config
  log "========== BV-BRC 下载开始：${RELEASE} =========="
  download_metadata
  build_download_plan
  run_parallel_downloads
  verify_after_download
  log "========== BV-BRC 下载流程结束 =========="
  log "下载计划：${PLAN_FILE}"
  log "差异报告：${DIFF_REPORT}"
}

main "$@"
