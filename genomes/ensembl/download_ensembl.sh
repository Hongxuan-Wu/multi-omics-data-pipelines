#!/usr/bin/env bash
# =============================================================================
# Ensembl / Ensembl Genomes GTF downloader
#
# 目标：
#   1. 固定 Ensembl release 116 与 Ensembl Genomes release 63。
#   2. 只下载 GTF 注释与 species metadata，不重复下载 FASTA 序列。
#   3. 以 FTP/HTTPS 目录 listing 生成下载计划，报告 listing 与计划差异。
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/common.sh"
common_require_version "1.0"

DB_NAME="ensembl"
ENSEMBL_RELEASE="116"
ENSEMBL_GENOMES_RELEASE="63"
RELEASE="Ensembl_${ENSEMBL_RELEASE}_EnsemblGenomes_${ENSEMBL_GENOMES_RELEASE}"
LOCAL_ROOT="/data3/p252701008/genomes/ensembl"
RUN_ROOT="/data3/p252701008/genomes/ensembl_runlogs"
USE_PROXY=0

ARIA2_CONNECTIONS=4
ARIA2_MAX_CONCURRENT=8
ARIA2_SPLIT=4
ARIA2_MIN_SPLIT_SIZE="64M"
ARIA2_SUMMARY_INTERVAL=120
VERIFY_AFTER_DOWNLOAD=1
SKIP_VERIFIED_FILES=1
MIN_DISK_GB=200

# division | gtf_base_url | metadata_url
DIVISION_RECORDS=(
  "vertebrates|https://ftp.ensembl.org/pub/release-${ENSEMBL_RELEASE}/gtf|https://ftp.ensembl.org/pub/release-${ENSEMBL_RELEASE}/species_EnsemblVertebrates.txt"
  "plants|https://ftp.ebi.ac.uk/ensemblgenomes/pub/release-${ENSEMBL_GENOMES_RELEASE}/plants/gtf|https://ftp.ebi.ac.uk/ensemblgenomes/pub/release-${ENSEMBL_GENOMES_RELEASE}/plants/species_EnsemblPlants.txt"
  "fungi|https://ftp.ebi.ac.uk/ensemblgenomes/pub/release-${ENSEMBL_GENOMES_RELEASE}/fungi/gtf|https://ftp.ebi.ac.uk/ensemblgenomes/pub/release-${ENSEMBL_GENOMES_RELEASE}/fungi/species_EnsemblFungi.txt"
  "protists|https://ftp.ebi.ac.uk/ensemblgenomes/pub/release-${ENSEMBL_GENOMES_RELEASE}/protists/gtf|https://ftp.ebi.ac.uk/ensemblgenomes/pub/release-${ENSEMBL_GENOMES_RELEASE}/protists/species_EnsemblProtists.txt"
  "metazoa|https://ftp.ebi.ac.uk/ensemblgenomes/pub/release-${ENSEMBL_GENOMES_RELEASE}/metazoa/gtf|https://ftp.ebi.ac.uk/ensemblgenomes/pub/release-${ENSEMBL_GENOMES_RELEASE}/metazoa/species_EnsemblMetazoa.txt"
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
CHECKSUM_FILE="${MANIFEST_DIR}/official_checksums_${RUN_ID}.txt"
TARGET_MANIFEST="${MANIFEST_DIR}/target_files_${RUN_ID}.tsv"
UNVERIFIED_MANIFEST="${MANIFEST_DIR}/unverified_files_${RUN_ID}.tsv"
MD5_CHECK_FILE="${MANIFEST_DIR}/md5_check_${RUN_ID}.txt"

declare -A MD5_MAP

common_init_dirs

extract_hrefs() {
  awk '{line=$0; scan=tolower(line); while (match(scan, /href[[:space:]]*=[[:space:]]*"[^"]+"/)) {href=substr(line,RSTART,RLENGTH); sub(/^[^"]*"/,"",href); sub(/"$/,"",href); print href; line=substr(line,RSTART+RLENGTH); scan=substr(scan,RSTART+RLENGTH)}}'
}

append_plan_record() {
  local group="$1"
  local relpath="$2"
  local url="$3"
  local local_dir="${LOCAL_ROOT}/${relpath%/*}"
  local out_name="${relpath##*/}"
  printf '%s\t%s\t%s\t%s\t%s\n' "${group}" "${relpath}" "${url}" "${local_dir}" "${out_name}" >> "${PLAN_FILE}"
}

load_species_md5_map() {
  local checksum_path="$1"
  local species_rel="$2"
  local md5 file clean_file count=0

  while IFS=$'\t' read -r md5 file; do
    [[ -n "${md5:-}" && -n "${file:-}" ]] || continue
    [[ "${md5}" =~ ^[0-9a-fA-F]{32}$ ]] || continue
    clean_file="${file#\*}"
    clean_file="${clean_file#./}"
    MD5_MAP["${species_rel}/${clean_file}"]="${md5}"
    MD5_MAP["${species_rel}/${clean_file##*/}"]="${md5}"
    MD5_MAP["${clean_file##*/}"]="${md5}"
    count=$((count + 1))
  done < <(awk '
    {
      if (length($1) == 32 && $1 !~ /[^0-9a-fA-F]/ && NF >= 2) {
        file=$2
        sub(/^\*/, "", file)
        print $1 "\t" file
        next
      }
      line=$0
      if (line ~ /^MD5[[:space:]]*\(/) {
        file=line
        sub(/^MD5[[:space:]]*\(/, "", file)
        sub(/\).*/, "", file)
        md5=line
        sub(/^.*=[[:space:]]*/, "", md5)
        if (length(md5) == 32 && md5 !~ /[^0-9a-fA-F]/) {
          print md5 "\t" file
        }
      }
    }
  ' "${checksum_path}")

  [[ "${count}" -gt 0 ]] || printf 'checksum\tNO_MD5_RECORDS\t%s\n' "${species_rel}/CHECKSUMS" >> "${DIFF_REPORT}"
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

is_core_gtf_payload() {
  local relpath="$1"
  [[ "${relpath}" == *.gtf.gz ]]
}

collect_division_gtf() {
  local division="$1"
  local base_url="$2"
  local metadata_url="$3"
  local index_file species_href species species_url species_index href file_url relpath
  local checksum_url checksum_tmp species_rel checksum_seen
  index_file="${TMP_DIR}/index_${division}.html"
  if ! fetch_to_stdout "${base_url}/" > "${index_file}"; then
    printf 'listing\tREMOTE_DIVISION_DIR_UNREADABLE\t%s\n' "${base_url}/" >> "${DIFF_REPORT}"
    die "无法读取 Ensembl GTF listing：${base_url}/"
  fi
  append_plan_record "${division}_metadata" "${division}/metadata/${metadata_url##*/}" "${metadata_url}"

  while IFS= read -r species_href; do
    [[ "${species_href}" == ../* || "${species_href}" != */ ]] && continue
    species="${species_href%/}"
    species_url="${base_url}/${species}"
    species_index="${TMP_DIR}/index_${division}_${species}.html"
    if ! fetch_to_stdout "${species_url}/" > "${species_index}"; then
      printf 'listing\tREMOTE_SPECIES_DIR_UNREADABLE\t%s\n' "${species_url}" >> "${DIFF_REPORT}"
      continue
    fi

    species_rel="${division}/${species}"
    checksum_seen=0
    while IFS= read -r href; do
      [[ "${href}" == CHECKSUMS ]] || continue
      checksum_seen=1
      checksum_url="${species_url}/CHECKSUMS"
      checksum_tmp="${TMP_DIR}/checksum_${division}_${species}.txt"
      if fetch_to_file "${checksum_url}" "${checksum_tmp}"; then
        printf '# source\t%s\n' "${checksum_url}" >> "${CHECKSUM_FILE}"
        cat "${checksum_tmp}" >> "${CHECKSUM_FILE}"
        load_species_md5_map "${checksum_tmp}" "${species_rel}"
        append_plan_record "${division}" "${species_rel}/CHECKSUMS" "${checksum_url}"
      else
        printf 'checksum\tREMOTE_CHECKSUM_UNREADABLE\t%s\n' "${checksum_url}" >> "${DIFF_REPORT}"
      fi
    done < <(extract_hrefs < "${species_index}")
    [[ "${checksum_seen}" -eq 1 ]] || printf 'checksum\tREMOTE_CHECKSUM_MISSING\t%s\n' "${species_url}/CHECKSUMS" >> "${DIFF_REPORT}"

    while IFS= read -r href; do
      [[ "${href}" == *.gtf.gz ]] || continue
      file_url="${species_url}/${href}"
      relpath="${division}/${species}/${href}"
      append_plan_record "${division}" "${relpath}" "${file_url}"
    done < <(extract_hrefs < "${species_index}")
  done < <(extract_hrefs < "${index_file}")
}

build_download_plan() {
  : > "${PLAN_FILE}"
  : > "${DIFF_REPORT}"
  : > "${CHECKSUM_FILE}"
  printf '# group\trelative_path\turl\tlocal_dir\tout_name\n' >> "${PLAN_FILE}"
  printf '# check\tstatus\tdetail\n' >> "${DIFF_REPORT}"
  local rec division base_url metadata_url
  for rec in "${DIVISION_RECORDS[@]}"; do
    IFS='|' read -r division base_url metadata_url <<< "${rec}"
    collect_division_gtf "${division}" "${base_url}" "${metadata_url}"
  done
  write_manifests_and_diff
  local planned_count gtf_count
  planned_count=$(awk 'BEGIN{c=0} $0 !~ /^(#|[[:space:]]*$)/ {c++} END{print c}' "${PLAN_FILE}")
  gtf_count=$(awk -F'\t' 'BEGIN{c=0} $0 !~ /^#/ && $2 ~ /\.gtf\.gz$/ {c++} END{print c}' "${PLAN_FILE}")
  [[ "${planned_count}" -gt 0 ]] || die "下载计划为空。"
  if [[ "${gtf_count}" -eq 0 ]]; then
    printf 'plan\tZERO_GTF_PAYLOAD\t%s\n' "no *.gtf.gz records" >> "${DIFF_REPORT}"
    die "Ensembl 下载计划不包含任何 GTF payload。"
  fi
  log "下载计划生成完成：${PLAN_FILE}，文件数 ${planned_count}，GTF payload ${gtf_count} 个。"
}

write_manifests_and_diff() {
  : > "${TARGET_MANIFEST}"
  : > "${UNVERIFIED_MANIFEST}"
  : > "${MD5_CHECK_FILE}"
  printf '# md5\trelative_path\n' >> "${TARGET_MANIFEST}"
  printf '# relative_path\tchecksum_policy\treason\n' >> "${UNVERIFIED_MANIFEST}"

  local group relpath url local_dir out_name md5
  while IFS=$'\t' read -r group relpath url local_dir out_name; do
    [[ "${group}" == "# group" ]] && continue
    if is_core_gtf_payload "${relpath}"; then
      md5="$(lookup_md5 "${relpath}")"
      if [[ -n "${md5}" ]]; then
        printf '%s\t%s\n' "${md5}" "${relpath}" >> "${TARGET_MANIFEST}"
        printf '%s  %s\n' "${md5}" "${relpath}" >> "${MD5_CHECK_FILE}"
      else
        printf '%s\tno_official_md5\tweak_gzip_or_nonempty\n' "${relpath}" >> "${UNVERIFIED_MANIFEST}"
        printf 'plan_vs_checksum\tPLANNED_GTF_WITHOUT_OFFICIAL_MD5\t%s\n' "${relpath}" >> "${DIFF_REPORT}"
      fi
    else
      printf '%s\tweak_non_core\tweak_gzip_or_nonempty\n' "${relpath}" >> "${UNVERIFIED_MANIFEST}"
    fi
  done < "${PLAN_FILE}"
}

write_aria_input() {
  : > "${ARIA_INPUT}"
  local group relpath url local_dir out_name local_file md5 count=0 skipped=0
  while IFS=$'\t' read -r group relpath url local_dir out_name; do
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
  local group relpath url local_dir out_name local_file md5 failed=0
  while IFS=$'\t' read -r group relpath url local_dir out_name; do
    [[ "${group}" == "# group" ]] && continue
    local_file="${local_dir}/${out_name}"
    md5="$(lookup_md5 "${relpath}")"
    if is_core_gtf_payload "${relpath}"; then
      if [[ -n "${md5}" ]]; then
        if ! (cd "${LOCAL_ROOT}" && printf '%s  %s\n' "${md5}" "${relpath}" | md5sum --check --quiet); then
          errlog "MD5 校验失败：${relpath}"
          move_to_trash "${local_file}" "md5_verify_failed"
          failed=1
        fi
      elif ! weak_verify_file "${local_file}" "${relpath}"; then
        failed=1
      fi
    else
      weak_verify_file "${local_file}" "${relpath}" || failed=1
    fi
  done < "${PLAN_FILE}"
  [[ "${failed}" -eq 0 ]] || die "至少一个 Ensembl 文件校验失败。"
  log "Ensembl 下载后校验完成：GTF 有官方 MD5 时强校验；无官方 MD5 时使用 gzip/非空弱校验。metadata/CHECKSUMS 使用弱校验。"
}

main() {
  require_command curl
  require_command aria2c
  require_command awk
  require_command md5sum
  require_command gzip
  common_validate_download_config
  log "========== Ensembl 下载开始：${RELEASE} =========="
  build_download_plan
  write_aria_input
  run_aria2_input "${DB_NAME}" "${ARIA_INPUT}"
  verify_after_download
  log "========== Ensembl 下载流程结束 =========="
  log "下载计划：${PLAN_FILE}"
  log "差异报告：${DIFF_REPORT}"
}

main "$@"
