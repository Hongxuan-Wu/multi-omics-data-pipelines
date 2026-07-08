#!/usr/bin/env bash
# =============================================================================
# UCSC hg38/mm39 track downloader
#
# 目标：
#   1. 锁定固定版本，不使用 latest/current 作为数据版本。
#   2. 先生成下载计划和差异报告，再执行下载。
#   3. metadata 与序列/注释文件同等优先级。
#   4. 有官方 MD5 时强校验；没有官方 MD5 时执行 gzip -t 或非空弱校验。
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SH="${SCRIPT_DIR}/../common/common.sh"
source "${COMMON_SH}"
common_require_version "1.0"

# ==================== 用户配置 ====================
DB_NAME="ucsc"
RELEASE="hg38_mm39_static_targets_2026-07-07_live_md5_audit"
FREEZE_POLICY="static_target_urls_frozen_2026-07-07_with_live_official_md5_audit"
LOCAL_ROOT="/data3/p252701008/genomes/ucsc_hg38_mm39"
RUN_ROOT="/data3/p252701008/genomes/ucsc_hg38_mm39_runlogs"
USE_PROXY=0

ARIA2_CONNECTIONS=4
ARIA2_MAX_CONCURRENT=6
ARIA2_SPLIT=4
ARIA2_MIN_SPLIT_SIZE="128M"
ARIA2_SUMMARY_INTERVAL=120
VERIFY_AFTER_DOWNLOAD=1
SKIP_VERIFIED_FILES=1
MIN_DISK_GB=100

# 官方 checksum 文件。留空表示该库未找到可直接用于目标文件的官方 MD5。
CHECKSUM_URLS=(
  "https://hgdownload.soe.ucsc.edu/goldenPath/hg38/bigZips/md5sum.txt"
  "https://hgdownload.soe.ucsc.edu/goldenPath/mm39/bigZips/md5sum.txt"
)
CHECKSUM_REQUIRED=1
EXPECTED_METALINK_VERSION=""
REMOTE_LISTING_URLS=(

)

# group | relative_path | url | role
TARGET_RECORDS=(
  "hg38|hg38/bigZips/hg38.2bit|https://hgdownload.soe.ucsc.edu/goldenPath/hg38/bigZips/hg38.2bit|human_2bit"
  "hg38|hg38/bigZips/hg38.chrom.sizes|https://hgdownload.soe.ucsc.edu/goldenPath/hg38/bigZips/hg38.chrom.sizes|human_chrom_sizes"
  "hg38|hg38/phastCons100way/hg38.phastCons100way.bw|https://hgdownload.soe.ucsc.edu/goldenPath/hg38/phastCons100way/hg38.phastCons100way.bw|human_conservation"
  "mm39|mm39/bigZips/mm39.2bit|https://hgdownload.soe.ucsc.edu/goldenPath/mm39/bigZips/mm39.2bit|mouse_2bit"
  "mm39|mm39/bigZips/mm39.chrom.sizes|https://hgdownload.soe.ucsc.edu/goldenPath/mm39/bigZips/mm39.chrom.sizes|mouse_chrom_sizes"
  "mm39|mm39/phastCons60way/mm39.phastCons60way.bw|https://hgdownload.soe.ucsc.edu/goldenPath/mm39/phastCons60way/mm39.phastCons60way.bw|mouse_conservation"
)

# ==================== 派生路径 ====================
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
CHECKSUM_FILE="${MANIFEST_DIR}/official_checksums_${RUN_ID}.txt"
REMOTE_LISTING_MANIFEST="${MANIFEST_DIR}/remote_listing_${RUN_ID}.tsv"
REMOTE_LISTING_ISSUES="${MANIFEST_DIR}/remote_listing_issues_${RUN_ID}.tsv"
TARGET_MANIFEST="${MANIFEST_DIR}/target_files_${RUN_ID}.tsv"
UNVERIFIED_MANIFEST="${MANIFEST_DIR}/unverified_files_${RUN_ID}.tsv"
DIFF_REPORT="${MANIFEST_DIR}/diff_report_${RUN_ID}.tsv"
MD5_CHECK_FILE="${MANIFEST_DIR}/md5_check_${RUN_ID}.txt"

declare -A MD5_MAP

common_init_dirs

validate_config() {
  common_validate_download_config
  validate_flag CHECKSUM_REQUIRED "${CHECKSUM_REQUIRED}"
  [[ "${#TARGET_RECORDS[@]}" -gt 0 ]] || die "TARGET_RECORDS 为空。"
}

append_plan_record() {
  local group="$1"
  local relpath="$2"
  local url="$3"
  local role="$4"
  local parent_dir
  local local_dir
  local out_name

  if [[ "${relpath}" == */* ]]; then
    parent_dir="${relpath%/*}"
    local_dir="${LOCAL_ROOT}/${parent_dir}"
    out_name="${relpath##*/}"
  else
    local_dir="${LOCAL_ROOT}"
    out_name="${relpath}"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${group}" "${relpath}" "${url}" "${local_dir}" "${out_name}" "${role}" >> "${PLAN_FILE}"
}

extract_hrefs() {
  awk '{line=$0; while (match(line, /[Hh][Rr][Ee][Ff][[:space:]]*=[[:space:]]*"[^"]+"/)) {href=substr(line,RSTART,RLENGTH); sub(/^[^"]*"/,"",href); sub(/"$/,"",href); print href; line=substr(line,RSTART+RLENGTH)}}'
}

normalise_listing_child_url() {
  local base="$1"
  local href="$2"
  href="${href%%#*}"
  href="${href%%\?*}"
  case "${href}" in
    ""|"../"|"/"*|"http://"*|"https://"*|"?"*|"#"*) return 1 ;;
  esac
  printf '%s/%s' "${base%/}" "${href#./}"
}

download_remote_listings() {
  : > "${REMOTE_LISTING_MANIFEST}"
  : > "${REMOTE_LISTING_ISSUES}"
  printf '# listing_url\tfile_name\turl\n' >> "${REMOTE_LISTING_MANIFEST}"
  local listing index_file href child_url
  for listing in "${REMOTE_LISTING_URLS[@]}"; do
    [[ -n "${listing}" ]] || continue
    index_file="${TMP_DIR}/listing_$(safe_name "${listing}").html"
    log "保存远端目录 listing：${listing}"
    if ! fetch_to_stdout "${listing%/}/" > "${index_file}"; then
      printf 'remote_listing\tUNREADABLE\t%s\n' "${listing}" >> "${REMOTE_LISTING_ISSUES}"
      continue
    fi
    while IFS= read -r href; do
      child_url="$(normalise_listing_child_url "${listing}" "${href}" || true)"
      [[ -n "${child_url}" ]] || continue
      [[ "${href}" == */ ]] && continue
      printf '%s\t%s\t%s\n' "${listing%/}/" "${href}" "${child_url}" >> "${REMOTE_LISTING_MANIFEST}"
    done < <(extract_hrefs < "${index_file}")
  done
}

build_download_plan() {
  : > "${PLAN_FILE}"
  printf '# group\trelative_path\turl\tlocal_dir\tout_name\trole\n' >> "${PLAN_FILE}"

  local record group relpath url role
  for record in "${TARGET_RECORDS[@]}"; do
    IFS='|' read -r group relpath url role <<< "${record}"
    append_plan_record "${group}" "${relpath}" "${url}" "${role}"
  done

  local planned_count
  planned_count=$(grep -Evc '^(#|[[:space:]]*$)' "${PLAN_FILE}" || true)
  [[ "${planned_count}" -gt 0 ]] || die "下载计划为空。"
  log "下载计划生成完成：${PLAN_FILE}，文件数 ${planned_count}"
}

download_official_checksums() {
  : > "${CHECKSUM_FILE}"
  local url out
  for url in "${CHECKSUM_URLS[@]}"; do
    [[ -n "${url}" ]] || continue
    out="${TMP_DIR}/checksum_$(safe_name "${url}")"
    log "下载官方 checksum：${url}"
    if fetch_to_file "${url}" "${out}"; then
      printf '# source\t%s\n' "${url}" >> "${CHECKSUM_FILE}"
      cat "${out}" >> "${CHECKSUM_FILE}"
    elif [[ "${CHECKSUM_REQUIRED}" == "1" ]]; then
      die "官方 checksum 下载失败：${url}"
    else
      errlog "官方 checksum 下载失败，后续对该库使用弱校验：${url}"
    fi
  done

  if [[ -n "${EXPECTED_METALINK_VERSION}" ]]; then
    if ! grep -q "<version>${EXPECTED_METALINK_VERSION}</version>" "${CHECKSUM_FILE}"; then
      die "RELEASE.metalink 版本不匹配：expected=${EXPECTED_METALINK_VERSION}。远端入口可能已经漂移，请改用归档 URL 或更新 RELEASE。"
    fi
    log "RELEASE.metalink 版本断言通过：${EXPECTED_METALINK_VERSION}"
  fi
}

load_md5_map() {
  local md5 path clean_path count=0
  [[ -s "${CHECKSUM_FILE}" ]] || return 0
  while read -r md5 path _rest; do
    [[ -n "${md5:-}" && -n "${path:-}" ]] || continue
    [[ "${md5}" =~ ^[0-9a-fA-F]{32}$ ]] || continue
    clean_path="${path#\*}"
    clean_path="${clean_path#./}"
    MD5_MAP["${clean_path}"]="${md5}"
    MD5_MAP["${clean_path##*/}"]="${md5}"
    count=$((count + 1))
  done < "${CHECKSUM_FILE}"

  # 兼容 metalink checksum 格式：同一 <file name="..."> 块内包含 <hash type="md5">。
  while IFS=$'\t' read -r md5 path; do
    [[ -n "${md5:-}" && -n "${path:-}" ]] || continue
    MD5_MAP["${path}"]="${md5}"
    MD5_MAP["${path##*/}"]="${md5}"
    count=$((count + 1))
  done < <(awk '
    /<file name="/ {
      name=$0
      sub(/^.*<file name="/, "", name)
      sub(/".*$/, "", name)
    }
    /<hash type="md5">/ && name != "" {
      md5=$0
      sub(/^.*<hash type="md5">/, "", md5)
      sub(/<\/hash>.*/, "", md5)
      if (length(md5) == 32 && md5 !~ /[^0-9a-fA-F]/) {
        print md5 "\t" name
      }
    }
  ' "${CHECKSUM_FILE}")
  log "MD5 映射加载完成：${count} 条。"
}

lookup_md5() {
  local relpath="$1"
  local basename_only="${relpath##*/}"
  if [[ -n "${MD5_MAP[${relpath}]:-}" ]]; then
    printf '%s' "${MD5_MAP[${relpath}]}"
  elif [[ -n "${MD5_MAP[${basename_only}]:-}" ]]; then
    printf '%s' "${MD5_MAP[${basename_only}]}"
  fi
}

weak_checksum_reason() {
  local relpath="$1"
  case "${relpath}" in
    hg38/phastCons100way/hg38.phastCons100way.bw)
      printf '%s' "no_official_md5_for_ucsc_phastcons100way_bigwig; weak_nonempty_policy"
      return 0
      ;;
    mm39/phastCons60way/mm39.phastCons60way.bw)
      printf '%s' "no_official_md5_for_ucsc_phastcons60way_bigwig; weak_nonempty_policy"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

write_manifests_and_diff() {
  : > "${TARGET_MANIFEST}"
  : > "${UNVERIFIED_MANIFEST}"
  : > "${DIFF_REPORT}"
  : > "${MD5_CHECK_FILE}"
  printf '# md5\trelative_path\n' >> "${TARGET_MANIFEST}"
  printf '# relative_path\treason\n' >> "${UNVERIFIED_MANIFEST}"
  printf '# check\tstatus\tdetail\n' >> "${DIFF_REPORT}"
  [[ -s "${REMOTE_LISTING_ISSUES}" ]] && cat "${REMOTE_LISTING_ISSUES}" >> "${DIFF_REPORT}"

  local group relpath url local_dir out_name role md5 weak_reason missing_required=0
  while IFS=$'\t' read -r group relpath url local_dir out_name role; do
    [[ "${group}" == "# group" ]] && continue
    md5="$(lookup_md5 "${relpath}")"
    if [[ -n "${md5}" ]]; then
      printf '%s\t%s\n' "${md5}" "${relpath}" >> "${TARGET_MANIFEST}"
      printf '%s  %s\n' "${md5}" "${relpath}" >> "${MD5_CHECK_FILE}"
    else
      if weak_reason="$(weak_checksum_reason "${relpath}")"; then
        printf '%s\tEXPLICIT_WEAK_POLICY\t%s\n' "${relpath}" "${weak_reason}" >> "${UNVERIFIED_MANIFEST}"
        printf 'plan_vs_checksum\tEXPLICIT_WEAK_POLICY\t%s\t%s\n' "${relpath}" "${weak_reason}" >> "${DIFF_REPORT}"
      else
        printf '%s\tNO_OFFICIAL_MD5_MATCHED\n' "${relpath}" >> "${UNVERIFIED_MANIFEST}"
        printf 'plan_vs_checksum\tPLANNED_WITHOUT_MD5\t%s\n' "${relpath}" >> "${DIFF_REPORT}"
        [[ "${CHECKSUM_REQUIRED}" == "1" ]] && missing_required=1
      fi
    fi
  done < "${PLAN_FILE}"

  if [[ -s "${CHECKSUM_FILE}" ]]; then
    while read -r md5 path _rest; do
      [[ "${md5}" =~ ^[0-9a-fA-F]{32}$ ]] || continue
      path="${path#\*}"
      path="${path#./}"
      if ! awk -F'\t' -v p="${path}" -v b="${path##*/}" '($2==p || $5==b){found=1} END{exit found?0:1}' "${PLAN_FILE}"; then
        printf 'checksum_vs_plan\tCHECKSUM_NOT_PLANNED\t%s\n' "${path}" >> "${DIFF_REPORT}"
      fi
    done < "${CHECKSUM_FILE}"

    # 兼容 metalink checksum 格式：报告 metalink 中有 checksum 但脚本未纳入计划的文件。
    while IFS= read -r path; do
      [[ -n "${path:-}" ]] || continue
      if ! awk -F'\t' -v p="${path}" -v b="${path##*/}" '($2==p || $5==b){found=1} END{exit found?0:1}' "${PLAN_FILE}"; then
        printf 'metalink_vs_plan\tCHECKSUM_NOT_PLANNED\t%s\n' "${path}" >> "${DIFF_REPORT}"
      fi
    done < <(awk '
      /<file name="/ {
        name=$0
        sub(/^.*<file name="/, "", name)
        sub(/".*$/, "", name)
        print name
      }
    ' "${CHECKSUM_FILE}")
  fi

  if [[ -s "${REMOTE_LISTING_MANIFEST}" ]]; then
    while IFS=$'\t' read -r listing file_name remote_url; do
      [[ "${listing}" == "# listing_url" ]] && continue
      if ! awk -F'\t' -v u="${remote_url}" -v f="${file_name}" '($3==u || $5==f){found=1} END{exit found?0:1}' "${PLAN_FILE}"; then
        printf 'remote_listing_vs_plan\tREMOTE_NOT_PLANNED\t%s\n' "${remote_url}" >> "${DIFF_REPORT}"
      fi
    done < "${REMOTE_LISTING_MANIFEST}"

    while IFS=$'\t' read -r group relpath url local_dir out_name role; do
      [[ "${group}" == "# group" ]] && continue
      if ! awk -F'\t' -v u="${url}" '($3==u){found=1} END{exit found?0:1}' "${REMOTE_LISTING_MANIFEST}"; then
        printf 'plan_vs_remote_listing\tPLANNED_NOT_IN_LISTING\t%s\t%s\n' "${relpath}" "${url}" >> "${DIFF_REPORT}"
      fi
    done < "${PLAN_FILE}"
  fi
  if [[ "${CHECKSUM_REQUIRED}" == "1" && "${missing_required}" -ne 0 ]]; then
    die "CHECKSUM_REQUIRED=1，但计划目标缺少官方 MD5，已写入差异报告：${DIFF_REPORT}"
  fi
  log "manifest 与差异报告已生成：${TARGET_MANIFEST} / ${UNVERIFIED_MANIFEST} / ${DIFF_REPORT}"
}

write_aria_input() {
  : > "${ARIA_INPUT}"
  local group relpath url local_dir out_name role local_file md5 count=0 skipped=0
  while IFS=$'\t' read -r group relpath url local_dir out_name role; do
    [[ "${group}" == "# group" ]] && continue
    mkdir -p "${local_dir}"
    local_file="${local_dir}/${out_name}"
    md5="$(lookup_md5 "${relpath}")"
    if [[ -z "${md5}" && "${CHECKSUM_REQUIRED}" == "1" ]] && ! weak_checksum_reason "${relpath}" >/dev/null; then
      die "CHECKSUM_REQUIRED=1，但计划目标缺少官方 MD5 且未声明 weak policy，拒绝写入 aria2 计划：${relpath}"
    fi
    if existing_file_is_complete "${relpath}" "${url}" "${local_file}" "${md5}"; then
      skipped=$((skipped + 1))
      continue
    fi
    printf '%s\n  dir=%s\n  out=%s\n' "${url}" "${local_dir}" "${out_name}" >> "${ARIA_INPUT}"
    if [[ -n "${md5}" ]]; then
      printf '  checksum=md5=%s\n' "${md5}" >> "${ARIA_INPUT}"
    fi
    count=$((count + 1))
  done < "${PLAN_FILE}"
  log "aria2 输入文件：${ARIA_INPUT}，需下载 ${count} 个，已跳过 ${skipped} 个。"
}

verify_after_download() {
  [[ "${VERIFY_AFTER_DOWNLOAD}" == "1" ]] || return 0
  local group relpath url local_dir out_name role local_file md5 weak_reason failed=0
  while IFS=$'\t' read -r group relpath url local_dir out_name role; do
    [[ "${group}" == "# group" ]] && continue
    local_file="${local_dir}/${out_name}"
    md5="$(lookup_md5 "${relpath}")"
    if [[ -n "${md5}" ]]; then
      if ! (cd "${LOCAL_ROOT}" && printf '%s  %s\n' "${md5}" "${relpath}" | md5sum --check --quiet); then
        errlog "MD5 校验失败：${relpath}"
        move_to_trash "${local_file}" "md5_verify_failed"
        failed=1
      fi
    elif weak_reason="$(weak_checksum_reason "${relpath}")"; then
      log "执行显式弱校验：${relpath}（${weak_reason}）"
      weak_verify_file "${local_file}" "${relpath}" || failed=1
    elif [[ "${CHECKSUM_REQUIRED}" == "1" ]]; then
      errlog "CHECKSUM_REQUIRED=1，但下载后缺少官方 MD5 且未声明 weak policy：${relpath}"
      failed=1
    else
      weak_verify_file "${local_file}" "${relpath}" || failed=1
    fi
  done < "${PLAN_FILE}"
  [[ "${failed}" -eq 0 ]] || die "至少一个文件校验失败。"
  log "下载后校验完成。"
}

main() {
  require_command curl
  require_command aria2c
  require_command awk
  require_command md5sum
  require_command gzip
  validate_config

  log "========== ${DB_NAME} ${RELEASE} 下载开始 =========="
  log "本地数据根目录：${LOCAL_ROOT}"
  log "运行日志目录：${RUN_ROOT}"
  log "版本锁定：${RELEASE}"
  log "冻结策略：${FREEZE_POLICY}"

  download_official_checksums
  download_remote_listings
  load_md5_map
  build_download_plan
  write_manifests_and_diff
  write_aria_input
  run_aria2_input "${DB_NAME}" "${ARIA_INPUT}"
  verify_after_download

  log "========== ${DB_NAME} ${RELEASE} 下载流程结束 =========="
  log "下载计划：${PLAN_FILE}"
  log "差异报告：${DIFF_REPORT}"
}

main "$@"
