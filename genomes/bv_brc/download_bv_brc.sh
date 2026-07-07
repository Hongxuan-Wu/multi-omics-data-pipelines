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
source "${SCRIPT_DIR}/../common/common.sh"
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
  printf '# genome_id\trelative_path\turl\tlocal_dir\tout_name\trole\n' >> "${PLAN_FILE}"
  printf '# check\tstatus\tdetail\n' >> "${DIFF_REPORT}"
  [[ -s "${API_PROBE_REPORT}" ]] && cat "${API_PROBE_REPORT}" >> "${DIFF_REPORT}"

  local genome_id suffix count=0
  awk -F'\t' 'NR>1 && $1 != "" {print $1}' "${GENOME_SUMMARY}" | while IFS= read -r genome_id; do
    [[ -n "${genome_id}" ]] || continue
    if [[ "${MAX_GENOMES}" -gt 0 && "${count}" -ge "${MAX_GENOMES}" ]]; then
      break
    fi
    for suffix in "${TARGET_SUFFIXES[@]}"; do
      printf '%s\tgenomes/%s/%s%s\t%s/genomes/%s/%s%s\t%s/genomes/%s\t%s%s\tfunctional_annotation\n' \
        "${genome_id}" "${genome_id}" "${genome_id}" "${suffix}" "${BASE_URL}" "${genome_id}" "${genome_id}" "${suffix}" \
        "${LOCAL_ROOT}" "${genome_id}" "${genome_id}" "${suffix}" >> "${PLAN_FILE}"
    done
    if [[ "${DOWNLOAD_FASTA}" == "1" ]]; then
      printf '%s\tgenomes/%s/%s.fna\t%s/genomes/%s/%s.fna\t%s/genomes/%s\t%s.fna\tgenome_sequence_optional\n' \
        "${genome_id}" "${genome_id}" "${genome_id}" "${BASE_URL}" "${genome_id}" "${genome_id}" \
        "${LOCAL_ROOT}" "${genome_id}" "${genome_id}" >> "${PLAN_FILE}"
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
    move_to_trash "${local_dir}/${out_name}" "bv_brc_download_failed"
    return 1
  fi
}
export -f download_one_lftp
export LFTP_CONNECTIONS TRASH_DIR RUN_ID LOCAL_ROOT DL_LOG ERR_LOG

run_parallel_downloads() {
  local queue_file="${TMP_DIR}/download_queue_${RUN_ID}.nul"
  local genome_id relpath url local_dir out_name role local_file count=0 skipped=0
  check_disk_space
  : > "${queue_file}"
  while IFS=$'\t' read -r genome_id relpath url local_dir out_name role; do
    [[ "${genome_id}" == "# genome_id" ]] && continue
    mkdir -p "${local_dir}"
    local_file="${local_dir}/${out_name}"
    if existing_file_is_complete "${relpath}" "${url}" "${local_file}" ""; then
      skipped=$((skipped + 1))
      continue
    fi
    printf '%s\0%s\0%s\0' "${url}" "${local_dir}" "${out_name}" >> "${queue_file}"
    count=$((count + 1))
  done < "${PLAN_FILE}"
  log "BV-BRC 下载队列：需下载 ${count} 个，已跳过 ${skipped} 个。"
  xargs -0 -r -n 3 -P "${PARALLEL_DOWNLOADS}" bash -c 'download_one_lftp "$0" "$1" "$2"' < "${queue_file}"
}

verify_after_download() {
  [[ "${VERIFY_AFTER_DOWNLOAD}" == "1" ]] || return 0
  local genome_id relpath url local_dir out_name role failed=0
  while IFS=$'\t' read -r genome_id relpath url local_dir out_name role; do
    [[ "${genome_id}" == "# genome_id" ]] && continue
    if ! weak_verify_file "${local_dir}/${out_name}" "${relpath}"; then
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
