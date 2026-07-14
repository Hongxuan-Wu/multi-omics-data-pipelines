#!/usr/bin/env bash
# =============================================================================
# RNAcentral Release 26 downloader
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
DB_NAME="rnacentral"
RELEASE="Release_26"
LOCAL_ROOT="${LOCAL_ROOT:-/data2/p252701008/genomes/rnacentral_release26}"
RUN_ROOT="${RUN_ROOT:-/data/p252701008/datasets/rnacentral_release26_runlogs}"
USE_PROXY="${USE_PROXY:-0}"

ARIA2_CONNECTIONS=4
ARIA2_MAX_CONCURRENT=6
ARIA2_SPLIT=4
ARIA2_MIN_SPLIT_SIZE="128M"
ARIA2_SUMMARY_INTERVAL=120
VERIFY_AFTER_DOWNLOAD=1
SKIP_VERIFIED_FILES=1
MIN_DISK_GB_WAS_SET="${MIN_DISK_GB+x}"
MIN_DISK_GB="${MIN_DISK_GB:-50}"
FULL_SEQUENCE_MIN_DISK_GB="${FULL_SEQUENCE_MIN_DISK_GB:-2500}"
DOWNLOAD_RNACENTRAL_SEQUENCES="${DOWNLOAD_RNACENTRAL_SEQUENCES:-0}"

# 官方 checksum 文件。留空表示该库未找到可直接用于目标文件的官方 MD5。
CHECKSUM_URLS=(

)
CHECKSUM_REQUIRED=0
EXPECTED_METALINK_VERSION=""
REMOTE_LISTING_URLS=(
  "https://ftp.ebi.ac.uk/pub/databases/RNAcentral/releases/26.0/"
  "https://ftp.ebi.ac.uk/pub/databases/RNAcentral/releases/26.0/sequences/"
  "https://ftp.ebi.ac.uk/pub/databases/RNAcentral/releases/26.0/id_mapping/"
  "https://ftp.ebi.ac.uk/pub/databases/RNAcentral/releases/26.0/md5/"
  "https://ftp.ebi.ac.uk/pub/databases/RNAcentral/releases/26.0/database_files/"
)

# group | relative_path | url | role
TARGET_RECORDS=(
  "sequence|sequences/rnacentral_active.fasta.gz|https://ftp.ebi.ac.uk/pub/databases/RNAcentral/releases/26.0/sequences/rnacentral_active.fasta.gz|active_ncrna_sequences"
  "sequence|sequences/rnacentral_species_specific_ids.fasta.gz|https://ftp.ebi.ac.uk/pub/databases/RNAcentral/releases/26.0/sequences/rnacentral_species_specific_ids.fasta.gz|species_specific_sequence_ids"
  "sequence|sequences/rnacentral_inactive.fasta.gz|https://ftp.ebi.ac.uk/pub/databases/RNAcentral/releases/26.0/sequences/rnacentral_inactive.fasta.gz|inactive_ncrna_sequences"
  "metadata|id_mapping/id_mapping.tsv.gz|https://ftp.ebi.ac.uk/pub/databases/RNAcentral/releases/26.0/id_mapping/id_mapping.tsv.gz|external_id_mapping"
  "metadata|md5/md5.tsv.gz|https://ftp.ebi.ac.uk/pub/databases/RNAcentral/releases/26.0/md5/md5.tsv.gz|sequence_md5_mapping_not_file_checksum"
  "metadata|database_files/toc.dat|https://ftp.ebi.ac.uk/pub/databases/RNAcentral/releases/26.0/database_files/toc.dat|postgres_dump_table_of_contents"
  "metadata|release_notes.txt|https://ftp.ebi.ac.uk/pub/databases/RNAcentral/releases/26.0/release_notes.txt|release_notes"
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
  if [[ -z "${MIN_DISK_GB_WAS_SET}" && "${DOWNLOAD_RNACENTRAL_SEQUENCES}" == "1" ]]; then
    MIN_DISK_GB="${FULL_SEQUENCE_MIN_DISK_GB}"
  fi
  common_validate_download_config
  validate_flag CHECKSUM_REQUIRED "${CHECKSUM_REQUIRED}"
  validate_flag DOWNLOAD_RNACENTRAL_SEQUENCES "${DOWNLOAD_RNACENTRAL_SEQUENCES}"
  [[ "${#TARGET_RECORDS[@]}" -gt 0 ]] || die "TARGET_RECORDS 为空。"
}

should_include_target_record() {
  local group="$1"
  local relpath="$2"
  local role="$3"
  case "${group}|${relpath}|${role}" in
    sequence\|*|*rnacentral_active.fasta.gz*|*rnacentral_inactive.fasta.gz*|*species_specific_sequence_ids*)
      [[ "${DOWNLOAD_RNACENTRAL_SEQUENCES}" == "1" ]]
      return
      ;;
  esac
  return 0
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
    should_include_target_record "${group}" "${relpath}" "${role}" || continue
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

  # 兼容 UniProt RELEASE.metalink：同一 <file name="..."> 块内包含 <hash type="md5">。
  while IFS=$'\t' read -r md5 path; do
    [[ -n "${md5:-}" && -n "${path:-}" ]] || continue
    MD5_MAP["${path}"]="${md5}"
    MD5_MAP["${path##*/}"]="${md5}"
    count=$((count + 1))
  done < <(awk '
    /<file name="/ {
      line=$0
      sub(/^.*<file name="/, "", line)
      sub(/".*$/, "", line)
      name=line
    }
    /<hash type="md5">/ && name != "" {
      line=$0
      sub(/^.*<hash type="md5">/, "", line)
      sub(/<\/hash>.*$/, "", line)
      if (length(line) == 32 && line ~ /^[0-9a-fA-F]+$/) {
        print line "\t" name
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

write_manifests_and_diff() {
  : > "${TARGET_MANIFEST}"
  : > "${UNVERIFIED_MANIFEST}"
  : > "${DIFF_REPORT}"
  : > "${MD5_CHECK_FILE}"
  printf '# md5\trelative_path\n' >> "${TARGET_MANIFEST}"
  printf '# relative_path\treason\n' >> "${UNVERIFIED_MANIFEST}"
  printf '# check\tstatus\tdetail\n' >> "${DIFF_REPORT}"
  [[ -s "${REMOTE_LISTING_ISSUES}" ]] && cat "${REMOTE_LISTING_ISSUES}" >> "${DIFF_REPORT}"

  local group relpath url local_dir out_name role md5
  while IFS=$'\t' read -r group relpath url local_dir out_name role; do
    [[ "${group}" == "# group" ]] && continue
    md5="$(lookup_md5 "${relpath}")"
    if [[ -n "${md5}" ]]; then
      printf '%s\t%s\n' "${md5}" "${relpath}" >> "${TARGET_MANIFEST}"
      printf '%s  %s\n' "${md5}" "${relpath}" >> "${MD5_CHECK_FILE}"
    else
      printf '%s\tNO_OFFICIAL_MD5_MATCHED\n' "${relpath}" >> "${UNVERIFIED_MANIFEST}"
      printf 'plan_vs_checksum\tPLANNED_WITHOUT_MD5\t%s\n' "${relpath}" >> "${DIFF_REPORT}"
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

    # 兼容 UniProt RELEASE.metalink：报告 metalink 中有 checksum 但脚本未纳入计划的文件。
    while IFS= read -r path; do
      [[ -n "${path:-}" ]] || continue
      if ! awk -F'\t' -v p="${path}" -v b="${path##*/}" '($2==p || $5==b){found=1} END{exit found?0:1}' "${PLAN_FILE}"; then
        printf 'metalink_vs_plan\tCHECKSUM_NOT_PLANNED\t%s\n' "${path}" >> "${DIFF_REPORT}"
      fi
    done < <(awk '
      /<file name="/ {
        line=$0
        sub(/^.*<file name="/, "", line)
        sub(/".*$/, "", line)
        if (line != "") print line
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
  local group relpath url local_dir out_name role local_file md5 failed=0
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
