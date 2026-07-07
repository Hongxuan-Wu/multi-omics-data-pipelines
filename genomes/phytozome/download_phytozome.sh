#!/usr/bin/env bash
# =============================================================================
# Phytozome JGI annotation downloader
#
# 目标：
#   1. 通过 JGI Genome Portal download API 生成下载计划。
#   2. JGI_USER / JGI_PASS 从环境变量或 genomes/.env 读取，不硬编码。
#   3. 只下载注释和功能文件，不重复下载全量基因组 FASTA。
#   4. 用 curl -C - + xargs -P 支持断点续传和并行控制。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SH="${SCRIPT_DIR}/../common/common.sh"
source "${COMMON_SH}"
common_require_version "1.0"

ENV_FILE="${SCRIPT_DIR}/../.env"
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  source "${ENV_FILE}"
  set +a
fi

DB_NAME="phytozome"
RELEASE="Phytozome_Next_freeze_2026-07-07"
JGI_API_BASE="https://files.jgi.doe.gov"
JGI_DOWNLOAD_API_BASE="https://files-download.jgi.doe.gov"
FILE_LIST_ENDPOINT="phytozome_file_list/"
FILE_LIST_QUERY="ff%5Bfile_status%5D=available"
SPECIES_LIST="${SCRIPT_DIR}/species_ids.txt"
FROZEN_MANIFEST="${SCRIPT_DIR}/frozen_file_manifest.tsv"
ALLOW_LIVE_MANIFEST=0
LOCAL_ROOT="/data3/p252701008/genomes/phytozome"
RUN_ROOT="/data3/p252701008/genomes/phytozome_runlogs"
USE_PROXY=0
PARALLEL_DOWNLOADS=6
VERIFY_AFTER_DOWNLOAD=1
SKIP_VERIFIED_FILES=1
MIN_DISK_GB=100

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
CANDIDATE_FROZEN_MANIFEST="${MANIFEST_DIR}/candidate_frozen_file_manifest_${RUN_ID}.tsv"
CANDIDATE_ONLY=0

common_init_dirs

validate_config() {
  validate_flag USE_PROXY "${USE_PROXY}"
  validate_flag ALLOW_LIVE_MANIFEST "${ALLOW_LIVE_MANIFEST}"
  validate_positive_int PARALLEL_DOWNLOADS "${PARALLEL_DOWNLOADS}"
  validate_flag VERIFY_AFTER_DOWNLOAD "${VERIFY_AFTER_DOWNLOAD}"
  validate_flag SKIP_VERIFIED_FILES "${SKIP_VERIFIED_FILES}"
  [[ -n "${JGI_USER:-}" ]] || die "未设置 JGI_USER。请在 genomes/.env 或环境变量中配置。"
  [[ -n "${JGI_PASS:-}" ]] || die "未设置 JGI_PASS。请在 genomes/.env 或环境变量中配置。"
  [[ -s "${SPECIES_LIST}" ]] || die "缺少物种/portal id 清单：${SPECIES_LIST}。请按 species_ids.example.txt 创建。"
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

append_jgi_plan_record() {
  local organism="$1"
  local file_id="$2"
  local file_name="$3"
  local file_size="$4"
  local md5="$5"
  local download_url="$6"
  local out_name role relpath

  out_name="${file_name##*/}"
  role="annotation_or_function"
  relpath="${organism}/${out_name}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${organism}" "${relpath}" "${file_id}" "${download_url}" "${LOCAL_ROOT}/${organism}" "${out_name}" "${md5}" "${file_size}" "${role}" >> "${PLAN_FILE}"
}

validate_jgi_manifest_record() {
  local source_label="$1"
  local organism="$2"
  local file_id="$3"
  local file_name="$4"
  local file_size="$5"
  local md5="$6"
  local download_url="$7"

  [[ -n "${organism}" ]] || die "${source_label} 行字段错误：organism 为空。"
  [[ -n "${file_id}" ]] || die "${source_label} 行字段错误：file_id 为空，organism=${organism}。"
  [[ -n "${file_name}" ]] || die "${source_label} 行字段错误：file_name 为空，organism=${organism} file_id=${file_id}。"
  [[ -z "${file_size}" || "${file_size}" =~ ^[0-9]+$ ]] || die "${source_label} 行字段错误：file_size 必须为空或数字，organism=${organism} file_id=${file_id} value=${file_size}。"
  [[ -z "${md5}" || "${md5}" =~ ^[0-9A-Fa-f]{32}$ ]] || die "${source_label} 行字段错误：md5 必须为空或 32 位 hex，organism=${organism} file_id=${file_id}。"
  case "${download_url}" in
    http://*|https://*) ;;
    *) die "${source_label} 行字段错误：download_url 必须是 http(s) URL，organism=${organism} file_id=${file_id}。" ;;
  esac
}

load_frozen_manifest_if_present() {
  [[ -s "${FROZEN_MANIFEST}" ]] || return 1
  log "使用冻结 JGI manifest：${FROZEN_MANIFEST}"
  local line parsed organism file_id file_name file_size md5 download_url extra
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -n "${line}" && "${line}" != \#* ]] || continue
    parsed="${line//$'\t'/$'\x1f'}"
    IFS=$'\x1f' read -r organism file_id file_name file_size md5 download_url extra <<< "${parsed}"
    [[ -z "${extra:-}" ]] || die "冻结 manifest 行字段错误：列数超过 6，organism=${organism:-unknown}。"
    validate_jgi_manifest_record "冻结 manifest" "${organism}" "${file_id}" "${file_name}" "${file_size}" "${md5}" "${download_url}"
    append_jgi_plan_record "${organism}" "${file_id}" "${file_name}" "${file_size}" "${md5}" "${download_url}"
  done < "${FROZEN_MANIFEST}"
  return 0
}

build_download_plan() {
  : > "${PLAN_FILE}"
  : > "${DIFF_REPORT}"
  : > "${CANDIDATE_FROZEN_MANIFEST}"
  printf '# organism\trelative_path\tfile_id\turl\tlocal_dir\tout_name\tmd5\tfile_size\trole\n' >> "${PLAN_FILE}"
  printf '# check\tstatus\tdetail\n' >> "${DIFF_REPORT}"
  printf '# organism\tfile_id\tfile_name\tfile_size\tmd5\tdownload_url\n' >> "${CANDIDATE_FROZEN_MANIFEST}"

  if load_frozen_manifest_if_present; then
    local frozen_count
    frozen_count=$(grep -Evc '^(#|[[:space:]]*$)' "${PLAN_FILE}" || true)
    [[ "${frozen_count}" -gt 0 ]] || die "冻结 manifest 存在但没有有效记录：${FROZEN_MANIFEST}"
    log "冻结 manifest 加载完成：${frozen_count} 条。"
    return 0
  fi

  [[ "${ALLOW_LIVE_MANIFEST}" == "1" ]] || die "缺少冻结 manifest：${FROZEN_MANIFEST}。如需用 JGI live API 生成候选清单，请临时设置 ALLOW_LIVE_MANIFEST=1。"
  CANDIDATE_ONLY=1
  log "未找到冻结 manifest，将从 JGI live API 生成候选清单：${CANDIDATE_FROZEN_MANIFEST}"

  local organism query_url json file_id file_name file_status md5 file_size download_json download_url encoded_organism file_line parsed extra
  while IFS= read -r organism; do
    [[ -n "${organism}" && "${organism}" != \#* ]] || continue
    encoded_organism="$(urlencode "${organism}")"
    query_url="${JGI_API_BASE}/${FILE_LIST_ENDPOINT}?api_version=2&${FILE_LIST_QUERY}&organism=${encoded_organism}"
    json="${TMP_DIR}/${organism}.json"
    log "读取 JGI file list API：${organism}"
    if ! curl -fsSL --retry 5 --retry-delay 10 -u "${JGI_USER}:${JGI_PASS}" "${query_url}" > "${json}"; then
      printf 'api_file_list\tFAILED\t%s\n' "${query_url}" >> "${DIFF_REPORT}"
      continue
    fi

    jq -r '
      .. | objects
      | select((.file_id? != null) and ((.file_name? // .filename? // "") != ""))
      | [.file_id, (.file_name // .filename), (.file_status // "unknown"), (.md5sum // .md5 // ""), (.file_size // .size // "")] | @tsv
    ' "${json}" | while IFS= read -r file_line; do
        file_line="${file_line%$'\r'}"
        parsed="${file_line//$'\t'/$'\x1f'}"
        IFS=$'\x1f' read -r file_id file_name file_status md5 file_size extra <<< "${parsed}"
        [[ -z "${extra:-}" ]] || {
          printf 'api_file_list\tSKIPPED_BAD_FIELD_COUNT\t%s\n' "${file_line}" >> "${DIFF_REPORT}"
          continue
        }
        case "${file_name}" in
          *gff3.gz|*gff.gz|*protein*.fa.gz|*proteins*.fa.gz|*cds*.fa.gz|*CDS*.fa.gz|*cazy*|*CAZy*|*smurf*|*SMURF*|*annotation*|*Annotation*)
            [[ "${file_status}" == "available" || "${file_status}" == "published" || "${file_status}" == "active" || "${file_status}" == "unknown" ]] || {
              printf 'api_file_status\tSKIPPED_%s\t%s\n' "${file_status}" "${file_name}" >> "${DIFF_REPORT}"
              continue
            }
            download_json="${TMP_DIR}/download_${file_id}.json"
            if ! curl -fsSL --retry 5 --retry-delay 10 -u "${JGI_USER}:${JGI_PASS}" \
              -H 'Content-Type: application/json' \
              -X POST "${JGI_DOWNLOAD_API_BASE}/download_files/" \
              -d "{\"file_ids\":[\"${file_id}\"]}" > "${download_json}"; then
              printf 'download_api\tFAILED\t%s\n' "${file_id}" >> "${DIFF_REPORT}"
              continue
            fi
            download_url="$(jq -r '.. | objects | (.download_url? // .url? // .href? // empty)' "${download_json}" | head -1)"
            if [[ -z "${download_url}" ]]; then
              printf 'download_api\tNO_DOWNLOAD_URL\t%s\t%s\n' "${file_id}" "${file_name}" >> "${DIFF_REPORT}"
              continue
            fi
            if [[ -n "${file_size}" && ! "${file_size}" =~ ^[0-9]+$ ]]; then
              printf 'api_file_size\tINVALID_AS_EMPTY\t%s\t%s\t%s\n' "${organism}" "${file_id}" "${file_size}" >> "${DIFF_REPORT}"
              file_size=""
            fi
            if [[ -n "${md5}" && ! "${md5}" =~ ^[0-9A-Fa-f]{32}$ ]]; then
              printf 'api_md5\tINVALID_AS_EMPTY\t%s\t%s\t%s\n' "${organism}" "${file_id}" "${md5}" >> "${DIFF_REPORT}"
              md5=""
            fi
            validate_jgi_manifest_record "JGI live candidate" "${organism}" "${file_id}" "${file_name}" "${file_size}" "${md5}" "${download_url}"
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${organism}" "${file_id}" "${file_name}" "${file_size}" "${md5}" "${download_url}" >> "${CANDIDATE_FROZEN_MANIFEST}"
            ;;
        esac
      done
  done < "${SPECIES_LIST}"

  local count
  count=$(grep -Evc '^(#|[[:space:]]*$)' "${CANDIDATE_FROZEN_MANIFEST}" || true)
  [[ "${count}" -gt 0 ]] || die "JGI live API 未生成候选 frozen manifest 记录。请检查 species_ids.txt 或 JGI API 返回格式。"
  log "候选 frozen manifest 生成完成：${CANDIDATE_FROZEN_MANIFEST}，文件数 ${count}。请人工审核后复制为 ${FROZEN_MANIFEST} 再执行正式下载。"
}

download_one() {
  local url="$1"
  local local_dir="$2"
  local out_name="$3"
  mkdir -p "${local_dir}"
  if ! curl -fL --retry 5 --retry-delay 10 -C - -u "${JGI_USER}:${JGI_PASS}" -o "${local_dir}/${out_name}" "${url}"; then
    move_to_trash "${local_dir}/${out_name}" "jgi_download_failed"
    return 1
  fi
}
export -f download_one
export JGI_USER JGI_PASS TRASH_DIR RUN_ID LOCAL_ROOT DL_LOG ERR_LOG COMMON_SH

run_parallel_downloads() {
  local queue_file="${TMP_DIR}/download_queue_${RUN_ID}.nul"
  local line parsed extra organism relpath file_id url local_dir out_name md5 file_size role local_file count=0 skipped=0
  check_disk_space
  : > "${queue_file}"
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -n "${line}" && "${line}" != \#* ]] || continue
    parsed="${line//$'\t'/$'\x1f'}"
    IFS=$'\x1f' read -r organism relpath file_id url local_dir out_name md5 file_size role extra <<< "${parsed}"
    [[ -z "${extra:-}" ]] || die "下载计划行字段错误：列数超过 9，relpath=${relpath:-unknown}。"
    mkdir -p "${local_dir}"
    local_file="${local_dir}/${out_name}"
    if existing_file_is_complete "${relpath}" "${url}" "${local_file}" "${md5}" "${file_size}"; then
      skipped=$((skipped + 1))
      continue
    fi
    printf '%s\0%s\0%s\0' "${url}" "${local_dir}" "${out_name}" >> "${queue_file}"
    count=$((count + 1))
  done < "${PLAN_FILE}"
  log "JGI 下载队列：需下载 ${count} 个，已跳过 ${skipped} 个。"
  xargs -0 -r -n 3 -P "${PARALLEL_DOWNLOADS}" bash -c 'source "${COMMON_SH}"; download_one "$0" "$1" "$2"' < "${queue_file}"
}

verify_after_download() {
  [[ "${VERIFY_AFTER_DOWNLOAD}" == "1" ]] || return 0
  local line parsed extra organism relpath file_id url local_dir out_name md5 file_size role local_file local_size failed=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -n "${line}" && "${line}" != \#* ]] || continue
    parsed="${line//$'\t'/$'\x1f'}"
    IFS=$'\x1f' read -r organism relpath file_id url local_dir out_name md5 file_size role extra <<< "${parsed}"
    [[ -z "${extra:-}" ]] || die "下载计划行字段错误：列数超过 9，relpath=${relpath:-unknown}。"
    local_file="${local_dir}/${out_name}"
    if [[ -n "${md5}" ]]; then
      if ! (cd "${LOCAL_ROOT}" && printf '%s  %s\n' "${md5}" "${relpath}" | md5sum --check --quiet); then
        errlog "JGI MD5 校验失败：${relpath}"
        move_to_trash "${local_file}" "jgi_md5_failed"
        failed=1
      fi
    elif [[ "${file_size}" =~ ^[0-9]+$ ]]; then
      local_size="$(stat -c '%s' "${local_file}" 2>/dev/null || printf 0)"
      if [[ "${local_size}" -ne "${file_size}" ]]; then
        errlog "JGI 文件大小校验失败：${relpath} expected=${file_size} actual=${local_size}"
        move_to_trash "${local_file}" "jgi_size_failed"
        failed=1
      else
        weak_verify_file "${local_file}" "${relpath}" || failed=1
      fi
    else
      weak_verify_file "${local_file}" "${relpath}" || failed=1
    fi
  done < "${PLAN_FILE}"
  [[ "${failed}" -eq 0 ]] || die "JGI 至少一个文件校验失败。"
  log "JGI 下载后校验完成。"
}

main() {
  require_command curl
  require_command awk
  require_command grep
  require_command sed
  require_command xargs
  require_command python3
  require_command jq
  validate_config
  log "========== ${DB_NAME} ${RELEASE} 下载开始 =========="
  build_download_plan
  if [[ "${CANDIDATE_ONLY}" == "1" ]]; then
    log "live candidate 模式只生成候选 manifest，不执行下载；正式下载必须提供 ${FROZEN_MANIFEST}。"
    return 0
  fi
  run_parallel_downloads
  verify_after_download
  log "========== ${DB_NAME} ${RELEASE} 下载流程结束 =========="
  log "下载计划：${PLAN_FILE}"
  log "差异报告：${DIFF_REPORT}"
}

main "$@"
