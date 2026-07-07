#!/usr/bin/env bash
# =============================================================================
# ENCODE REST API regulatory track downloader
#
# 目标：
#   1. 优先使用 ENCODE REST API 生成可复现 manifest。
#   2. 用 FREEZE_DATE 固定查询时间边界，不使用 latest。
#   3. 从 API JSON 提取 accession、href、md5sum、assembly、assay_title。
#   4. 使用官方 md5sum 强校验。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/common.sh"
common_require_version "1.0"

DB_NAME="encode"
RELEASE="ENCODE_API_freeze_2026-07-07"
ENCODE_HOST="https://www.encodeproject.org"
FREEZE_DATE="2026-07-07"
LOCAL_ROOT="/data3/p252701008/genomes/encode"
RUN_ROOT="/data3/p252701008/genomes/encode_runlogs"
USE_PROXY=0

ARIA2_CONNECTIONS=4
ARIA2_MAX_CONCURRENT=8
ARIA2_SPLIT=4
ARIA2_MIN_SPLIT_SIZE="64M"
ARIA2_SUMMARY_INTERVAL=120
VERIFY_AFTER_DOWNLOAD=1
SKIP_VERIFIED_FILES=1
MIN_DISK_GB=200

ASSEMBLIES=(GRCh38 mm10)
FILE_FORMATS=(bigWig bigBed bed)
ASSAY_TITLE_FILTERS=("DNase-seq" "ATAC-seq" "ChIP-seq" "Histone ChIP-seq" "TF ChIP-seq")

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ').$$"
LOG_DIR="${RUN_ROOT}/logs"
PLAN_DIR="${RUN_ROOT}/plans"
MANIFEST_DIR="${RUN_ROOT}/manifests"
TMP_DIR="${RUN_ROOT}/tmp/${RUN_ID}"
TRASH_DIR="${RUN_ROOT}/trash"
DL_LOG="${LOG_DIR}/download_${RUN_ID}.log"
ERR_LOG="${LOG_DIR}/error_${RUN_ID}.log"
PLAN_FILE="${PLAN_DIR}/download_plan_${RUN_ID}.tsv"
ARIA_INPUT="${PLAN_DIR}/aria_${DB_NAME}_${RUN_ID}.txt"
API_JSON="${MANIFEST_DIR}/encode_search_${RUN_ID}.jsonl"
DIFF_REPORT="${MANIFEST_DIR}/diff_report_${RUN_ID}.tsv"

declare -A MD5_MAP
common_init_dirs

build_api_manifest() {
  : > "${API_JSON}"
  local assembly fmt assay url out
  for assembly in "${ASSEMBLIES[@]}"; do
    for fmt in "${FILE_FORMATS[@]}"; do
      for assay in "${ASSAY_TITLE_FILTERS[@]}"; do
        url="${ENCODE_HOST}/search/?type=File&status=released&assembly=${assembly}&file_format=${fmt}&assay_title=${assay// /+}&limit=all&format=json"
        out="${TMP_DIR}/encode_$(safe_name "${assembly}_${fmt}_${assay}").json"
        log "查询 ENCODE API：assembly=${assembly}, format=${fmt}, assay=${assay}"
        if fetch_to_file "${url}" "${out}"; then
          jq -c --arg freeze "${FREEZE_DATE}" '.["@graph"][] | select((.date_created // "1900-01-01")[0:10] <= $freeze)' "${out}" >> "${API_JSON}"
        else
          printf 'api_query\tFAILED\t%s\n' "${url}" >> "${DIFF_REPORT}"
        fi
      done
    done
  done
}

build_download_plan() {
  : > "${PLAN_FILE}"
  : > "${DIFF_REPORT}"
  printf '# accession\trelative_path\turl\tlocal_dir\tout_name\tmd5\n' >> "${PLAN_FILE}"
  printf '# check\tstatus\tdetail\n' >> "${DIFF_REPORT}"
  build_api_manifest
  local api_tsv="${TMP_DIR}/encode_api_records_${RUN_ID}.tsv"
  local missing_md5=0
  jq -r '
    def normalized_assembly:
      (.assembly // null) as $assembly
      | if ($assembly | type) == "array" then
          (($assembly[0] // "unknown") | if . == "" then "unknown" else . end)
        elif ($assembly | type) == "string" then
          (if $assembly == "" then "unknown" else $assembly end)
        else
          "unknown"
        end;
    [.accession, (.href // ""), (.md5sum // ""), normalized_assembly, (.file_format // "unknown")] | @tsv
  ' "${API_JSON}" | sort -u > "${api_tsv}"
  while IFS=$'\t' read -r accession href md5 assembly fmt; do
    [[ -n "${accession}" && -n "${href}" ]] || continue
    out_name="${accession}.${fmt}"
    case "${href}" in
      *.gz) out_name="${out_name}.gz" ;;
      *.bigWig) out_name="${accession}.bigWig" ;;
      *.bigBed) out_name="${accession}.bigBed" ;;
    esac
    relpath="${assembly}/${fmt}/${out_name}"
    if [[ -z "${md5}" ]]; then
      printf 'api_manifest\tNO_MD5_EXCLUDED\t%s\t%s\n' "${accession}" "${href}" >> "${DIFF_REPORT}"
      missing_md5=1
      continue
    fi
    printf '%s\t%s\t%s%s\t%s/%s/%s\t%s\t%s\n' "${accession}" "${relpath}" "${ENCODE_HOST}" "${href}" "${LOCAL_ROOT}" "${assembly}" "${fmt}" "${out_name}" "${md5}" >> "${PLAN_FILE}"
    MD5_MAP["${relpath}"]="${md5}"
  done < "${api_tsv}"
  [[ "${missing_md5}" -eq 0 ]] || die "ENCODE API manifest 存在缺失 md5sum 的记录；已写入差异报告并排除下载计划：${DIFF_REPORT}"
  local planned_count
  planned_count=$(grep -Evc '^(#|[[:space:]]*$)' "${PLAN_FILE}" || true)
  [[ "${planned_count}" -gt 0 ]] || die "ENCODE 下载计划为空。请检查 API 查询条件或 FREEZE_DATE。"
  log "下载计划生成完成：${PLAN_FILE}，文件数 ${planned_count}"
}

write_aria_input() {
  : > "${ARIA_INPUT}"
  local accession relpath url local_dir out_name md5 local_file count=0 skipped=0
  while IFS=$'\t' read -r accession relpath url local_dir out_name md5; do
    [[ "${accession}" == "# accession" ]] && continue
    if [[ -z "${md5}" ]]; then
      printf 'aria_input\tMISSING_MD5_BLOCKED\t%s\n' "${accession}" >> "${DIFF_REPORT}"
      die "ENCODE 下载计划包含缺失 md5sum 的记录：${accession}。差异报告：${DIFF_REPORT}"
    fi
    mkdir -p "${local_dir}"
    local_file="${local_dir}/${out_name}"
    if existing_file_is_complete "${relpath}" "${url}" "${local_file}" "${md5}"; then
      skipped=$((skipped + 1))
      continue
    fi
    printf '%s\n  dir=%s\n  out=%s\n' "${url}" "${local_dir}" "${out_name}" >> "${ARIA_INPUT}"
    [[ -n "${md5}" ]] && printf '  checksum=md5=%s\n' "${md5}" >> "${ARIA_INPUT}"
    count=$((count + 1))
  done < "${PLAN_FILE}"
  log "aria2 输入文件：${ARIA_INPUT}，需下载 ${count} 个，已跳过 ${skipped} 个。"
}

verify_after_download() {
  [[ "${VERIFY_AFTER_DOWNLOAD}" == "1" ]] || return 0
  local accession relpath url local_dir out_name md5 failed=0
  while IFS=$'\t' read -r accession relpath url local_dir out_name md5; do
    [[ "${accession}" == "# accession" ]] && continue
    if [[ -z "${md5}" ]]; then
      printf 'verify\tMISSING_MD5_BLOCKED\t%s\n' "${relpath}" >> "${DIFF_REPORT}"
      failed=1
      continue
    fi
    if ! (cd "${LOCAL_ROOT}" && printf '%s  %s\n' "${md5}" "${relpath}" | md5sum --check --quiet); then
      errlog "ENCODE MD5 校验失败：${relpath}"
      move_to_trash "${local_dir}/${out_name}" "encode_md5_failed"
      failed=1
    fi
  done < "${PLAN_FILE}"
  [[ "${failed}" -eq 0 ]] || die "ENCODE 至少一个文件 MD5 校验失败。"
  log "ENCODE 下载后校验完成。"
}

main() {
  require_command curl
  require_command aria2c
  require_command jq
  require_command md5sum
  common_validate_download_config
  log "========== ENCODE 下载开始：${RELEASE} =========="
  build_download_plan
  write_aria_input
  run_aria2_input "${DB_NAME}" "${ARIA_INPUT}"
  verify_after_download
  log "========== ENCODE 下载流程结束 =========="
  log "下载计划：${PLAN_FILE}"
  log "差异报告：${DIFF_REPORT}"
}

main "$@"
