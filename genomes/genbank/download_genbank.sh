#!/usr/bin/env bash
# =============================================================================
# NCBI GenBank eukaryote incremental downloader
#
# 目标：
#   1. 以 assembly_summary_genbank.txt 为中心生成精准下载计划。
#   2. 排除已有 RefSeq 配对的 GenBank assembly，避免和 RefSeq 重复。
#   3. 默认只下载 metadata；开启开关后下载真核 genomic.fna.gz / genomic.gff.gz，病毒只取 genomic.fna.gz。
#   4. 同步下载 assembly_summary、README；开启 assembly 文件下载时同步每个 assembly 的 md5checksums.txt。
#   5. 对 manifest 记录但远端缺失的文件生成差异报告。
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/common.sh"
common_require_version "1.0"

# ==================== 用户配置 ====================
DB_NAME="genbank"
RELEASE="NCBI_GenBank_assembly_summary_freeze_2026-07-07"
BASE_URL="https://ftp.ncbi.nlm.nih.gov/genomes/genbank"
ASSEMBLY_SUMMARY_URL="${BASE_URL}/assembly_summary_genbank.txt"
ASSEMBLY_SUMMARY_README_URL="${BASE_URL}/README_assembly_summary.txt"
LOCAL_ROOT="${LOCAL_ROOT:-/data3/p252701008/genomes/genbank}"
RUN_ROOT="${RUN_ROOT:-/data3/p252701008/genomes/genbank_runlogs}"
USE_PROXY="${USE_PROXY:-0}"
REFRESH_MANIFEST=0

ARIA2_CONNECTIONS=4
ARIA2_MAX_CONCURRENT=8
ARIA2_SPLIT=4
ARIA2_MIN_SPLIT_SIZE="128M"
ARIA2_SUMMARY_INTERVAL=120
VERIFY_AFTER_DOWNLOAD=1
SKIP_VERIFIED_FILES=1
MIN_DISK_GB_WAS_SET="${MIN_DISK_GB+x}"
MIN_DISK_GB="${MIN_DISK_GB:-50}"
FULL_SEQUENCE_MIN_DISK_GB="${FULL_SEQUENCE_MIN_DISK_GB:-1000}"
DOWNLOAD_GENBANK_ASSEMBLY_FILES="${DOWNLOAD_GENBANK_ASSEMBLY_FILES:-0}"
PROBE_REMOTE_TARGETS=1
MAX_PER_SPECIES=3

# group 与最大 assembly 数。group 名必须匹配 assembly_summary_genbank.txt 的 group 字段。
TARGET_GROUP_LIMITS=(
  "fungi|3000"
  "plant|1000"
  "vertebrate_mammalian|200"
  "vertebrate_other|500"
  "invertebrate|1500"
  "protozoa|500"
  "viral|10000"
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
DIFF_REPORT="${MANIFEST_DIR}/diff_report_${RUN_ID}.tsv"
SELECTED_ASSEMBLIES="${MANIFEST_DIR}/selected_assemblies_${RUN_ID}.tsv"
ASSEMBLY_PARSE_REPORT="${MANIFEST_DIR}/assembly_parse_report_${RUN_ID}.tsv"
ASSEMBLY_SUMMARY_DIGEST="${MANIFEST_DIR}/assembly_summary_genbank_digest_${RUN_ID}.txt"
ASSEMBLY_SUMMARY="${RUN_ROOT}/metadata/assembly_summary_genbank.txt"
ASSEMBLY_README="${RUN_ROOT}/metadata/README_assembly_summary.txt"

common_init_dirs
mkdir -p "${RUN_ROOT}/metadata"

validate_config() {
  if [[ -z "${MIN_DISK_GB_WAS_SET}" && "${DOWNLOAD_GENBANK_ASSEMBLY_FILES}" == "1" ]]; then
    MIN_DISK_GB="${FULL_SEQUENCE_MIN_DISK_GB}"
  fi
  common_validate_download_config
  validate_flag PROBE_REMOTE_TARGETS "${PROBE_REMOTE_TARGETS}"
  validate_flag REFRESH_MANIFEST "${REFRESH_MANIFEST}"
  validate_flag DOWNLOAD_GENBANK_ASSEMBLY_FILES "${DOWNLOAD_GENBANK_ASSEMBLY_FILES}"
  validate_positive_int MAX_PER_SPECIES "${MAX_PER_SPECIES}"
}

normalise_ncbi_url() {
  local ftp_path="$1"
  ftp_path="${ftp_path/ftp:\/\/ftp.ncbi.nlm.nih.gov/https:\/\/ftp.ncbi.nlm.nih.gov}"
  printf '%s' "${ftp_path}"
}

download_metadata() {
  if [[ -s "${ASSEMBLY_SUMMARY}" && "${REFRESH_MANIFEST}" == "0" ]]; then
    log "复用已冻结 GenBank assembly manifest：${ASSEMBLY_SUMMARY}"
  else
    log "下载 GenBank assembly manifest 并冻结到本地：${ASSEMBLY_SUMMARY_URL}"
    fetch_to_file "${ASSEMBLY_SUMMARY_URL}" "${ASSEMBLY_SUMMARY}" || die "assembly_summary_genbank.txt 下载失败。"
  fi
  if [[ -s "${ASSEMBLY_README}" && "${REFRESH_MANIFEST}" == "0" ]]; then
    log "复用已冻结 README_assembly_summary.txt：${ASSEMBLY_README}"
  else
    fetch_to_file "${ASSEMBLY_SUMMARY_README_URL}" "${ASSEMBLY_README}" || errlog "README_assembly_summary.txt 下载失败，继续执行。"
  fi
  {
    printf '# source\tpath\tmd5\tsha256\n'
    printf '%s\t%s\t%s\t%s\n' "${ASSEMBLY_SUMMARY_URL}" "${ASSEMBLY_SUMMARY}" "$(md5sum "${ASSEMBLY_SUMMARY}" | awk '{print $1}')" "$(sha256sum "${ASSEMBLY_SUMMARY}" | awk '{print $1}')"
  } > "${ASSEMBLY_SUMMARY_DIGEST}"
  log "GenBank manifest digest 已记录：${ASSEMBLY_SUMMARY_DIGEST}"
}

select_assemblies() {
  local groups_csv limits_tsv candidates selected_count
  groups_csv="$(printf '%s\n' "${TARGET_GROUP_LIMITS[@]}" | awk -F'|' '{print $1}' | paste -sd, -)"
  limits_tsv="${TMP_DIR}/group_limits.tsv"
  printf '%s\n' "${TARGET_GROUP_LIMITS[@]}" | tr '|' '\t' > "${limits_tsv}"
  candidates="${TMP_DIR}/candidate_assemblies.tsv"
  : > "${ASSEMBLY_PARSE_REPORT}"
  printf '# check\tstatus\tdetail\n' >> "${ASSEMBLY_PARSE_REPORT}"

  awk -F'\t' -v groups_csv="${groups_csv}" -v parse_report="${ASSEMBLY_PARSE_REPORT}" '
    BEGIN {
      split(groups_csv, g, ",")
      for (i in g) want[g[i]]=1
      pr["Complete Genome"]=1
      pr["Chromosome"]=2
      pr["Scaffold"]=3
      pr["Contig"]=4
    }
    NR==1 {
      for (i=1; i<=NF; i++) {
        key=$i
        sub(/^# /, "", key)
        h[key]=i
      }
      next
    }
    {
      ftp_i=h["ftp_path"]
      ftp=$(ftp_i)
      if (!(ftp ~ /^(ftp:\/\/ftp\.ncbi\.nlm\.nih\.gov\/genomes\/all\/|na$)/)) {
        recovered=0
        for (i=1; i<=NF; i++) {
          if ($i ~ /^(ftp:\/\/ftp\.ncbi\.nlm\.nih\.gov\/genomes\/all\/|na$)/) {
            ftp_i=i
            ftp=$i
            recovered=1
            break
          }
        }
        if (recovered) {
          printf "assembly_summary_parse\tFTP_PATH_RECOVERED\t%s\tline=%s\n", $1, NR >> parse_report
        } else {
          printf "assembly_summary_parse\tFTP_PATH_UNRECOVERABLE\t%s\tline=%s\n", $1, NR >> parse_report
          next
        }
      }
      group=$(ftp_i + 5)
      if (!(group in want)) next
      if ($(ftp_i - 9) != "latest") next
      if ($(ftp_i - 6) != "Full") next
      if ($(ftp_i - 2) != "na") next
      if (ftp == "na" || ftp == "") next
      level=$(ftp_i - 8)
      priority=(level in pr ? pr[level] : 9)
      print group "\t" $(h["species_taxid"]) "\t" priority "\t" $(h["assembly_accession"]) "\t" ftp "\t" level
    }
  ' "${ASSEMBLY_SUMMARY}" | sort -t $'\t' -k1,1 -k2,2 -k3,3n > "${candidates}"

  : > "${SELECTED_ASSEMBLIES}"
  printf '# group\tspecies_taxid\tassembly_accession\tassembly_level\tftp_path\n' >> "${SELECTED_ASSEMBLIES}"

  awk -F'\t' -v limits="${limits_tsv}" -v max_per_species="${MAX_PER_SPECIES}" '
    BEGIN {
      while ((getline < limits) > 0) {
        limit[$1]=$2
      }
    }
    {
      group=$1
      species=$2
      key=group "|" species
      if (group_count[group] >= limit[group]) next
      if (species_count[key] >= max_per_species) next
      group_count[group]++
      species_count[key]++
      print group "\t" species "\t" $4 "\t" $6 "\t" $5
    }
  ' "${candidates}" >> "${SELECTED_ASSEMBLIES}"

  selected_count="$(awk 'BEGIN{n=0} !/^(#|[[:space:]]*$)/{n++} END{print n}' "${SELECTED_ASSEMBLIES}")"
  (( selected_count > 0 )) || die "GenBank selected assemblies 为 0；请检查 assembly_summary 字段、TARGET_GROUP_LIMITS 或筛选条件。"
  log "GenBank assembly 筛选完成：${SELECTED_ASSEMBLIES}，数量 ${selected_count}"
}

append_plan_record() {
  local group="$1"
  local relpath="$2"
  local url="$3"
  local local_dir="${LOCAL_ROOT}/${relpath%/*}"
  local out_name="${relpath##*/}"
  printf '%s\t%s\t%s\t%s\t%s\n' "${group}" "${relpath}" "${url}" "${local_dir}" "${out_name}" >> "${PLAN_FILE}"
}

build_download_plan() {
  : > "${PLAN_FILE}"
  printf '# group\trelative_path\turl\tlocal_dir\tout_name\n' >> "${PLAN_FILE}"

  append_plan_record "metadata" "metadata/assembly_summary_genbank.txt" "${ASSEMBLY_SUMMARY_URL}"
  append_plan_record "metadata" "metadata/README_assembly_summary.txt" "${ASSEMBLY_SUMMARY_README_URL}"

  if [[ "${DOWNLOAD_GENBANK_ASSEMBLY_FILES}" != "1" ]]; then
    log "DOWNLOAD_GENBANK_ASSEMBLY_FILES=0，metadata-only 模式跳过 assembly 文件计划。"
    local metadata_only_count
    metadata_only_count="$(awk 'BEGIN{n=0} !/^(#|[[:space:]]*$)/{n++} END{print n}' "${PLAN_FILE}")"
    (( metadata_only_count > 0 )) || die "GenBank metadata-only 下载计划为空。"
    log "下载计划生成完成：${PLAN_FILE}，文件数 ${metadata_only_count}，metadata-only"
    return 0
  fi

  local group species acc level ftp_path base_url base_name rel_prefix suffix file_url relpath
  while IFS=$'\t' read -r group species acc level ftp_path; do
    [[ -z "${group}" || "${group}" == \#* ]] && continue
    base_url="$(normalise_ncbi_url "${ftp_path}")"
    base_name="${base_url##*/}"
    rel_prefix="${group}/${acc}_${base_name}"
    append_plan_record "${group}" "${rel_prefix}/md5checksums.txt" "${base_url}/md5checksums.txt"
    if [[ "${group}" == "viral" ]]; then
      suffixes=("_genomic.fna.gz")
    else
      suffixes=("_genomic.fna.gz" "_genomic.gff.gz")
    fi
    for suffix in "${suffixes[@]}"; do
      file_url="${base_url}/${base_name}${suffix}"
      relpath="${rel_prefix}/${base_name}${suffix}"
      append_plan_record "${group}" "${relpath}" "${file_url}"
    done
  done < "${SELECTED_ASSEMBLIES}"

  local planned_count genome_payload_count
  planned_count="$(awk 'BEGIN{n=0} !/^(#|[[:space:]]*$)/{n++} END{print n}' "${PLAN_FILE}")"
  genome_payload_count="$(awk -F'\t' 'BEGIN{n=0} !/^(#|[[:space:]]*$)/ && $1 != "metadata" && $2 !~ /\/md5checksums\.txt$/ {n++} END{print n}' "${PLAN_FILE}")"
  (( planned_count > 0 )) || die "GenBank 下载计划为空。"
  (( genome_payload_count > 0 )) || die "GenBank 非 metadata genome payload 下载计划为 0；拒绝只下载 metadata/md5checksums。"
  log "下载计划生成完成：${PLAN_FILE}，文件数 ${planned_count}，genome payload 数 ${genome_payload_count}"
}

probe_and_write_diff() {
  : > "${DIFF_REPORT}"
  printf '# check\tstatus\tdetail\n' >> "${DIFF_REPORT}"
  [[ -s "${ASSEMBLY_PARSE_REPORT}" ]] && cat "${ASSEMBLY_PARSE_REPORT}" >> "${DIFF_REPORT}"
  [[ "${PROBE_REMOTE_TARGETS}" == "1" ]] || {
    printf 'manifest_vs_remote\tSKIPPED\tPROBE_REMOTE_TARGETS=0\n' >> "${DIFF_REPORT}"
    return 0
  }
  local group relpath url local_dir out_name
  while IFS=$'\t' read -r group relpath url local_dir out_name; do
    [[ "${group}" == "# group" ]] && continue
    if ! probe_remote_file "${url}"; then
      printf 'manifest_vs_remote\tREMOTE_MISSING\t%s\t%s\n' "${relpath}" "${url}" >> "${DIFF_REPORT}"
    fi
  done < "${PLAN_FILE}"
  log "远端差异探测完成：${DIFF_REPORT}"
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

verify_ncbi_md5checksums() {
  [[ "${VERIFY_AFTER_DOWNLOAD}" == "1" ]] || return 0
  if [[ "${DOWNLOAD_GENBANK_ASSEMBLY_FILES}" != "1" ]]; then
    log "DOWNLOAD_GENBANK_ASSEMBLY_FILES=0，metadata-only 模式跳过 assembly MD5 校验。"
    return 0
  fi
  local group relpath url local_dir out_name local_file checksum_file expected_md5
  local failed=0 checked=0 checksum_files_seen=0
  while IFS=$'\t' read -r group relpath url local_dir out_name; do
    [[ -z "${group}" || "${group}" == \#* ]] && continue
    [[ "${group}" == "metadata" ]] && continue
    [[ "${relpath}" == */md5checksums.txt ]] && continue

    local_file="${local_dir}/${out_name}"
    checksum_file="${local_dir}/md5checksums.txt"
    if [[ ! -s "${checksum_file}" ]]; then
      errlog "缺少或为空的 GenBank md5checksums.txt：${checksum_file}，计划文件 ${relpath} 无法强校验。"
      move_to_trash "${checksum_file}" "missing_or_empty_md5checksums"
      move_to_trash "${local_file}" "missing_md5checksums"
      move_to_trash "${local_file}.aria2" "missing_md5checksums"
      failed=1
      continue
    fi
    checksum_files_seen=1

    if ! expected_md5="$(awk -v target="${out_name}" '
      length($1) == 32 && $1 ~ /^[0-9a-fA-F]+$/ {
        path=$2
        sub(/^\*/, "", path)
        sub(/^\.\//, "", path)
        if (path == target) {
          print $1
          found=1
          exit
        }
      }
      END { if (!found) exit 1 }
    ' "${checksum_file}")"; then
      errlog "GenBank md5checksums.txt 中缺少计划文件：${relpath}"
      move_to_trash "${local_file}" "md5_entry_missing"
      move_to_trash "${local_file}.aria2" "md5_entry_missing"
      failed=1
      continue
    fi

    if [[ ! -s "${local_file}" ]]; then
      errlog "计划文件缺失或为空，无法执行 MD5 强校验：${relpath}"
      move_to_trash "${local_file}" "missing_payload"
      move_to_trash "${local_file}.aria2" "missing_payload"
      failed=1
      continue
    fi

    if ! (cd "${local_dir}" && printf '%s  %s\n' "${expected_md5}" "${out_name}" | md5sum --check --quiet); then
      errlog "GenBank 计划文件 MD5 校验失败：${relpath}"
      move_to_trash "${local_file}" "md5_verify_failed"
      move_to_trash "${local_file}.aria2" "md5_verify_failed"
      failed=1
      continue
    fi
    checked=$((checked + 1))
  done < "${PLAN_FILE}"

  (( checksum_files_seen > 0 )) || die "没有任何可用的 GenBank md5checksums.txt；拒绝跳过官方 MD5 强校验。"
  (( checked > 0 )) || die "未校验任何 GenBank genome payload；拒绝静默成功。"
  [[ "${failed}" -eq 0 ]] || die "至少一个 GenBank assembly MD5 校验失败。"
  log "GenBank 计划内 genome payload MD5 强校验完成，文件数 ${checked}。"
}

main() {
  require_command curl
  require_command aria2c
  require_command awk
  require_command sort
  require_command md5sum
  require_command sha256sum
  require_command gzip
  validate_config
  log "========== GenBank 下载开始：${RELEASE} =========="
  download_metadata
  if [[ "${DOWNLOAD_GENBANK_ASSEMBLY_FILES}" == "1" ]]; then
    select_assemblies
  fi
  build_download_plan
  probe_and_write_diff
  write_aria_input
  run_aria2_input "${DB_NAME}" "${ARIA_INPUT}"
  verify_ncbi_md5checksums
  log "========== GenBank 下载流程结束 =========="
  log "下载计划：${PLAN_FILE}"
  log "差异报告：${DIFF_REPORT}"
}

main "$@"
