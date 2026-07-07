#!/usr/bin/env bash
# =============================================================================
# Ensembl / Ensembl Genomes GTF downloader
#
# 目标：
#   1. 固定 Ensembl release 116 与 Ensembl Genomes release 63。
#   2. 只下载 GTF 注释与 species metadata，不重复下载 FASTA 序列。
#   3. 以 FTP/HTTPS 目录 listing 生成下载计划，报告 listing 与计划差异。
# =============================================================================
set -euo pipefail

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

collect_division_gtf() {
  local division="$1"
  local base_url="$2"
  local metadata_url="$3"
  local index_file species_href species species_url species_index href file_url relpath
  index_file="${TMP_DIR}/index_${division}.html"
  fetch_to_stdout "${base_url}/" > "${index_file}" || die "无法读取 Ensembl GTF listing：${base_url}/"
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
    while IFS= read -r href; do
      [[ "${href}" == *.gtf.gz || "${href}" == CHECKSUMS ]] || continue
      file_url="${species_url}/${href}"
      relpath="${division}/${species}/${href}"
      append_plan_record "${division}" "${relpath}" "${file_url}"
    done < <(extract_hrefs < "${species_index}")
  done < <(extract_hrefs < "${index_file}")
}

build_download_plan() {
  : > "${PLAN_FILE}"
  : > "${DIFF_REPORT}"
  printf '# group\trelative_path\turl\tlocal_dir\tout_name\n' >> "${PLAN_FILE}"
  printf '# check\tstatus\tdetail\n' >> "${DIFF_REPORT}"
  local rec division base_url metadata_url
  for rec in "${DIVISION_RECORDS[@]}"; do
    IFS='|' read -r division base_url metadata_url <<< "${rec}"
    collect_division_gtf "${division}" "${base_url}" "${metadata_url}"
  done
  log "下载计划生成完成：${PLAN_FILE}，文件数 $(grep -Evc '^(#|[[:space:]]*$)' "${PLAN_FILE}")"
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
  local group relpath url local_dir out_name
  while IFS=$'\t' read -r group relpath url local_dir out_name; do
    [[ "${group}" == "# group" ]] && continue
    [[ "${out_name}" == CHECKSUMS ]] && continue
    weak_verify_file "${local_dir}/${out_name}" "${relpath}"
  done < "${PLAN_FILE}"
  log "Ensembl GTF 弱校验完成。CHECKSUMS 已同步保存供后续审计。"
}

main() {
  require_command curl
  require_command aria2c
  require_command awk
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
