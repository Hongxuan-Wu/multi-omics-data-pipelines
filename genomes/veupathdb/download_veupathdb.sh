#!/usr/bin/env bash
# =============================================================================
# VEuPathDB fixed release downloader
#
# 目标：
#   1. 使用固定 release/phase 目录，不使用 latest/current 入口。
#   2. 递归读取 HTML/Apache index，生成文件级下载计划。
#   3. 先写差异报告，再执行 aria2 并行下载与弱校验。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/common.sh"
common_require_version "1.0"

DB_NAME="veupathdb"
RELEASE="PlasmoDB_release_68"
LOCAL_ROOT="/data3/p252701008/genomes/veupathdb_plasmodb_r68"
RUN_ROOT="/data3/p252701008/genomes/veupathdb_plasmodb_r68_runlogs"
USE_PROXY=0

ARIA2_CONNECTIONS=4
ARIA2_MAX_CONCURRENT=6
ARIA2_SPLIT=4
ARIA2_MIN_SPLIT_SIZE="64M"
ARIA2_SUMMARY_INTERVAL=120
VERIFY_AFTER_DOWNLOAD=1
SKIP_VERIFIED_FILES=1
MIN_DISK_GB=100

# group | root_url | max_depth | include_regex
ROOT_RECORDS=(
  "plasmodb_r68|https://plasmodb.org/common/downloads/release-68|3|(README|readme|release|\.txt$|\.xml$|\.gff$|\.gff\.gz$|\.fasta$|\.fasta\.gz$|\.fa$|\.fa\.gz$)"
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
ARIA_INPUT="${PLAN_DIR}/aria_${DB_NAME}_${RUN_ID}.txt"
DIFF_REPORT="${MANIFEST_DIR}/diff_report_${RUN_ID}.tsv"

common_init_dirs

extract_hrefs() {
  awk 'BEGIN{IGNORECASE=1} {line=$0; while (match(line, /href[[:space:]]*=[[:space:]]*"[^"]+"/)) {href=substr(line,RSTART,RLENGTH); sub(/^[^"]*"/,"",href); sub(/"$/,"",href); print href; line=substr(line,RSTART+RLENGTH)}}'
}

append_plan_record() {
  local group="$1"
  local relpath="$2"
  local url="$3"
  local local_dir="${LOCAL_ROOT}/${relpath%/*}"
  local out_name="${relpath##*/}"
  printf '%s\t%s\t%s\t%s\t%s\n' "${group}" "${relpath}" "${url}" "${local_dir}" "${out_name}" >> "${PLAN_FILE}"
}

normalise_child_url() {
  local base="$1"
  local href="$2"
  href="${href%%#*}"
  href="${href%%\?*}"
  case "${href}" in
    ""|"../"|"/"*|"http://"*|"https://"*|"?"*|"#"*) return 1 ;;
  esac
  printf '%s/%s' "${base%/}" "${href#./}"
}

collect_root() {
  local group="$1"
  local root_url="$2"
  local max_depth="$3"
  local include_regex="$4"
  local queue_file next_queue current depth index_file href child_url relpath root_label

  root_label="$(safe_name "${group}")"
  queue_file="${TMP_DIR}/queue_${root_label}_0.tsv"
  printf '%s\t0\n' "${root_url%/}" > "${queue_file}"

  while [[ -s "${queue_file}" ]]; do
    next_queue="${TMP_DIR}/queue_${root_label}_next.tsv"
    : > "${next_queue}"
    while IFS=$'\t' read -r current depth; do
      index_file="${TMP_DIR}/index_$(safe_name "${current}").html"
      if ! fetch_to_stdout "${current}/" > "${index_file}"; then
        printf 'listing\tUNREADABLE\t%s\n' "${current}/" >> "${DIFF_REPORT}"
        continue
      fi
      while IFS= read -r href; do
        child_url="$(normalise_child_url "${current}" "${href}" || true)"
        [[ -n "${child_url}" ]] || continue
        if [[ "${href}" == */ ]]; then
          if [[ "${depth}" -lt "${max_depth}" ]]; then
            printf '%s\t%s\n' "${child_url%/}" "$((depth + 1))" >> "${next_queue}"
          fi
        else
          relpath="${group}/${child_url#${root_url%/}/}"
          if [[ "${relpath}" =~ ${include_regex} ]]; then
            append_plan_record "${group}" "${relpath}" "${child_url}"
          else
            printf 'listing_vs_plan\tREMOTE_NOT_SELECTED\t%s\n' "${child_url}" >> "${DIFF_REPORT}"
          fi
        fi
      done < <(extract_hrefs < "${index_file}")
    done < "${queue_file}"
    queue_file="${next_queue}"
  done
}

build_download_plan() {
  : > "${PLAN_FILE}"
  : > "${DIFF_REPORT}"
  printf '# group\trelative_path\turl\tlocal_dir\tout_name\n' >> "${PLAN_FILE}"
  printf '# check\tstatus\tdetail\n' >> "${DIFF_REPORT}"
  local rec group root_url max_depth include_regex
  for rec in "${ROOT_RECORDS[@]}"; do
    IFS='|' read -r group root_url max_depth include_regex <<< "${rec}"
    collect_root "${group}" "${root_url}" "${max_depth}" "${include_regex}"
  done
  local planned_count
  planned_count=$(grep -Evc '^(#|[[:space:]]*$)' "${PLAN_FILE}" || true)
  [[ "${planned_count}" -gt 0 ]] || die "下载计划为空。请检查固定目录、递归深度或 include_regex。差异报告：${DIFF_REPORT}"
  log "下载计划生成完成：${PLAN_FILE}，文件数 ${planned_count}"
}

write_aria_input() {
  : > "${ARIA_INPUT}"
  local group relpath url local_dir out_name local_file count=0 skipped=0
  while IFS=$'\t' read -r group relpath url local_dir out_name; do
    [[ "${group}" == "# group" ]] && continue
    mkdir -p "${local_dir}"
    local_file="${local_dir}/${out_name}"
    if existing_file_is_complete "${relpath}" "${url}" "${local_file}" ""; then
      skipped=$((skipped + 1))
      continue
    fi
    printf '%s\n  dir=%s\n  out=%s\n' "${url}" "${local_dir}" "${out_name}" >> "${ARIA_INPUT}"
    count=$((count + 1))
  done < "${PLAN_FILE}"
  log "aria2 输入文件：${ARIA_INPUT}，需下载 ${count} 个，已跳过 ${skipped} 个。"
}

verify_after_download() {
  [[ "${VERIFY_AFTER_DOWNLOAD}" == "1" ]] || return 0
  local group relpath url local_dir out_name failed=0
  while IFS=$'\t' read -r group relpath url local_dir out_name; do
    [[ "${group}" == "# group" ]] && continue
    if ! weak_verify_file "${local_dir}/${out_name}" "${relpath}"; then
      printf 'verify\tFAILED\t%s\n' "${relpath}" >> "${DIFF_REPORT}"
      failed=1
    fi
  done < "${PLAN_FILE}"
  [[ "${failed}" -eq 0 ]] || die "至少一个文件弱校验失败。"
  log "下载后弱校验完成。"
}

main() {
  require_command curl
  require_command aria2c
  require_command awk
  require_command gzip
  common_validate_download_config
  log "========== ${DB_NAME} ${RELEASE} 下载开始 =========="
  build_download_plan
  write_aria_input
  run_aria2_input "${DB_NAME}" "${ARIA_INPUT}"
  verify_after_download
  log "========== ${DB_NAME} ${RELEASE} 下载流程结束 =========="
  log "下载计划：${PLAN_FILE}"
  log "差异报告：${DIFF_REPORT}"
}

main "$@"
