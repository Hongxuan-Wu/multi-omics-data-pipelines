#!/usr/bin/env bash
# =============================================================================
# BV-BRC Data API functional annotation downloader
#
# 目标：
#   1. 使用 BV-BRC Data API 固定查询条件导出 genome metadata。
#   2. 以 API TSV genome_id 清单生成每个 genome 的功能注释下载计划。
#   3. 默认只下载 genome_feature / pathway / subsystem TSV，不重复下载 FASTA。
#   4. 避免依赖目标服务器当前缺失的 lftp/FTPS 客户端。
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SH="${SCRIPT_DIR}/../common/common.sh"
source "${COMMON_SH}"
common_require_version "1.0"

DB_NAME="${DB_NAME:-bv_brc}"
RELEASE="${RELEASE:-BV-BRC_Data_API_freeze_2026-07-07}"
DOWNLOAD_MODE="api"
BV_BRC_API_BASE="${BV_BRC_API_BASE:-https://www.bv-brc.org/api}"
BV_BRC_GENOME_URL="${BV_BRC_API_BASE}/genome/"
BV_BRC_GENOME_QUERY="${BV_BRC_GENOME_QUERY:-eq(genome_status,Complete)&limit(25000)&select(genome_id,genome_name,genome_status,taxon_id,taxon_lineage_names)}"
BV_BRC_API_PROBE_QUERY="${BV_BRC_API_PROBE_QUERY:-eq(genome_status,Complete)&limit(10)&select(genome_id,genome_name,genome_status)}"
BV_BRC_RECORD_LIMIT="${BV_BRC_RECORD_LIMIT:-1000000}"
LOCAL_ROOT="${LOCAL_ROOT:-/data2/p252701008/genomes/bv_brc}"
RUN_ROOT="${RUN_ROOT:-/data/p252701008/datasets/bv_brc_runlogs}"
USE_PROXY="${USE_PROXY:-0}"
PARALLEL_DOWNLOADS="${PARALLEL_DOWNLOADS:-6}"
VERIFY_AFTER_DOWNLOAD="${VERIFY_AFTER_DOWNLOAD:-1}"
SKIP_VERIFIED_FILES="${SKIP_VERIFIED_FILES:-1}"
MIN_DISK_GB="${MIN_DISK_GB:-200}"
MAX_GENOMES="${MAX_GENOMES:-0}"

TARGET_API_TABLES=(
  "features:genome_feature:genome_id,feature_id,annotation,feature_type,start,end,strand,product:functional_annotation"
  "pathway:pathway:genome_id,pathway_id,pathway_name,pathway_class,annotation:pathway_annotation"
  "subsystem:subsystem:genome_id,subsystem_id,subsystem_name,superclass,class,subclass,role_name,active,product:subsystem_annotation"
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
API_PROBE_JSON="${MANIFEST_DIR}/bv_brc_api_probe_${RUN_ID}.tsv"
API_PROBE_REPORT="${MANIFEST_DIR}/bv_brc_api_probe_report_${RUN_ID}.tsv"
GENOME_SUMMARY="${RUN_ROOT}/metadata/genome_summary"
GENOME_METADATA="${RUN_ROOT}/metadata/genome_metadata"

common_init_dirs
mkdir -p "${RUN_ROOT}/metadata"

validate_config() {
  validate_flag USE_PROXY "${USE_PROXY}"
  validate_positive_int PARALLEL_DOWNLOADS "${PARALLEL_DOWNLOADS}"
  validate_flag VERIFY_AFTER_DOWNLOAD "${VERIFY_AFTER_DOWNLOAD}"
  validate_flag SKIP_VERIFIED_FILES "${SKIP_VERIFIED_FILES}"
  validate_positive_int BV_BRC_RECORD_LIMIT "${BV_BRC_RECORD_LIMIT}"
  [[ "${MAX_GENOMES}" =~ ^[0-9]+$ ]] || die "MAX_GENOMES 必须是非负整数。"
  [[ "${DOWNLOAD_MODE}" == "api" ]] || die "DOWNLOAD_MODE 只支持 api，当前值为：${DOWNLOAD_MODE}"
}

bv_brc_api_tsv_url() {
  local data_type="$1"
  local query="$2"
  printf '%s/%s/?%s&http_accept=text/tsv' "${BV_BRC_API_BASE}" "${data_type}" "${query}"
}

append_bv_brc_api_plan_record() {
  local genome_id="$1"
  local table_name="$2"
  local data_type="$3"
  local select_fields="$4"
  local role="$5"
  local relpath url local_dir out_name query

  query="eq(genome_id,${genome_id})&select(${select_fields})&limit(${BV_BRC_RECORD_LIMIT})"
  relpath="genomes/${genome_id}/${genome_id}.${table_name}.tab"
  url="$(bv_brc_api_tsv_url "${data_type}" "${query}")"
  local_dir="${LOCAL_ROOT}/genomes/${genome_id}"
  out_name="${genome_id}.${table_name}.tab"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${genome_id}" "${relpath}" "${url}" "${local_dir}" "${out_name}" "" "${role}" >> "${PLAN_FILE}"
}

download_metadata() {
  log "下载 BV-BRC Data API metadata"
  if fetch_to_file "$(bv_brc_api_tsv_url "genome" "${BV_BRC_API_PROBE_QUERY}")" "${API_PROBE_JSON}"; then
    log "BV-BRC Data API probe TSV 已保存：${API_PROBE_JSON}"
  else
    printf 'api_probe\tFAILED\t%s?%s\n' "${BV_BRC_GENOME_URL}" "${BV_BRC_API_PROBE_QUERY}" >> "${API_PROBE_REPORT}"
    die "BV-BRC Data API probe 失败；请检查本服务器网络、代理或 BV-BRC API 可用性。"
  fi
  fetch_to_file "$(bv_brc_api_tsv_url "genome" "${BV_BRC_GENOME_QUERY}")" "${GENOME_SUMMARY}" \
    || die "BV-BRC genome metadata API 下载失败：${BV_BRC_GENOME_URL}?${BV_BRC_GENOME_QUERY}"
  cp -- "${GENOME_SUMMARY}" "${GENOME_METADATA}"
  [[ -s "${GENOME_SUMMARY}" ]] || die "genome_summary 为空或下载失败。"
  [[ -s "${GENOME_METADATA}" ]] || die "genome_metadata 为空或下载失败。"
}

build_download_plan() {
  : > "${PLAN_FILE}"
  : > "${DIFF_REPORT}"
  printf '# genome_id\trelative_path\turl\tlocal_dir\tout_name\tremote_size\trole\n' >> "${PLAN_FILE}"
  printf '# check\tstatus\tdetail\n' >> "${DIFF_REPORT}"
  [[ -s "${API_PROBE_REPORT}" ]] && cat "${API_PROBE_REPORT}" >> "${DIFF_REPORT}"

  local genome_list="${TMP_DIR}/bv_brc_genome_ids_${RUN_ID}.txt"
  local genome_id table_spec table_name data_type select_fields role count=0
  awk -F'\t' 'NR>1 && $1 != "" {gsub(/^"|"$/, "", $1); print $1}' "${GENOME_SUMMARY}" > "${genome_list}"
  while IFS= read -r genome_id; do
    [[ -n "${genome_id}" ]] || continue
    if [[ ! "${genome_id}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      printf 'metadata\tSKIPPED_INVALID_GENOME_ID\t%s\n' "${genome_id}" >> "${DIFF_REPORT}"
      continue
    fi
    if [[ "${MAX_GENOMES}" -gt 0 && "${count}" -ge "${MAX_GENOMES}" ]]; then
      break
    fi
    for table_spec in "${TARGET_API_TABLES[@]}"; do
      IFS=':' read -r table_name data_type select_fields role <<< "${table_spec}"
      append_bv_brc_api_plan_record "${genome_id}" "${table_name}" "${data_type}" "${select_fields}" "${role}"
    done
    count=$((count + 1))
  done < "${genome_list}"

  local planned
  planned=$(grep -Evc '^(#|[[:space:]]*$)' "${PLAN_FILE}" || true)
  [[ "${planned}" -gt 0 ]] || die "BV-BRC 下载计划为空。"
  log "Data API 下载计划生成完成：${PLAN_FILE}，文件数 ${planned}"
}

api_existing_file_is_complete() {
  local relpath="$1"
  local local_file="$2"
  [[ "${SKIP_VERIFIED_FILES}" == "1" ]] || return 1
  [[ -f "${local_file}" ]] || return 1
  if weak_verify_file "${local_file}" "${relpath}"; then
    log "跳过已完成 Data API TSV：${relpath}"
    return 0
  fi
  return 1
}

download_one_api() {
  local url="$1"
  local local_dir="$2"
  local out_name="$3"
  local relpath="$4"
  mkdir -p "${local_dir}"
  if ! fetch_to_file "${url}" "${local_dir}/${out_name}"; then
    printf 'download\tFAILED\t%s\t%s\n' "${url}" "${local_dir}/${out_name}" >> "${DIFF_REPORT}"
    return 1
  fi
  weak_verify_file "${local_dir}/${out_name}" "${relpath}"
}
export -f download_one_api
export TRASH_DIR RUN_ID LOCAL_ROOT DL_LOG ERR_LOG DIFF_REPORT COMMON_SH

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
    if api_existing_file_is_complete "${relpath}" "${local_file}"; then
      skipped=$((skipped + 1))
      continue
    fi
    printf '%s\0%s\0%s\0%s\0' "${url}" "${local_dir}" "${out_name}" "${relpath}" >> "${queue_file}"
    count=$((count + 1))
  done < "${PLAN_FILE}"
  log "BV-BRC Data API 下载队列：需下载 ${count} 个，已跳过 ${skipped} 个。"
  xargs -0 -r -n 4 -P "${PARALLEL_DOWNLOADS}" bash -c 'source "${COMMON_SH}"; download_one_api "$0" "$1" "$2" "$3"' < "${queue_file}"
}

verify_after_download() {
  [[ "${VERIFY_AFTER_DOWNLOAD}" == "1" ]] || return 0
  local line parsed extra genome_id relpath url local_dir out_name remote_size role local_file failed=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -n "${line}" && "${line}" != \#* ]] || continue
    parsed="${line//$'\t'/$'\x1f'}"
    IFS=$'\x1f' read -r genome_id relpath url local_dir out_name remote_size role extra <<< "${parsed}"
    [[ -z "${extra:-}" ]] || die "下载计划行字段错误：列数超过 7，relpath=${relpath:-unknown}。"
    local_file="${local_dir}/${out_name}"
    if ! weak_verify_file "${local_file}" "${relpath}"; then
      printf 'verify\tFAILED\t%s\n' "${relpath}" >> "${DIFF_REPORT}"
      failed=1
    fi
  done < "${PLAN_FILE}"
  [[ "${failed}" -eq 0 ]] || die "BV-BRC 至少一个文件弱校验失败。"
  log "BV-BRC Data API TSV 下载后弱校验完成。"
}

main() {
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
