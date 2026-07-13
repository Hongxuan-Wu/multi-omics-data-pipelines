#!/usr/bin/env bash
# =============================================================================
# UniProt 2026_02 manifest-driven downloader
#
# The historical file name is retained for compatibility. With no arguments,
# the downloader selects UniRef50. Other approved datasets can be selected
# independently, combined, or downloaded together with --all.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SH="${SCRIPT_DIR}/../common/common.sh"
source "${COMMON_SH}"
common_require_version "1.0"

DB_NAME="uniprot"
RELEASE="${RELEASE:-2026_02}"
MANIFEST_FILE="${MANIFEST_FILE:-${SCRIPT_DIR}/download_file_manifest_${RELEASE}.tsv}"
APPROVED_MANIFEST_SHA256="1107165a1a1256314ec193202f127f40f8d64308a6c609d0fdf03b91728e5070"
DOWNLOAD_DATASETS="${DOWNLOAD_DATASETS:-uniref50}"
LOCAL_ROOT="${LOCAL_ROOT:-/data3/p252701008/genomes/uniprot_${RELEASE}}"
RUN_ROOT="${RUN_ROOT:-/data3/p252701008/genomes/uniprot_${RELEASE}_runlogs}"
USE_PROXY="${USE_PROXY:-0}"

ARIA2_CONNECTIONS="${ARIA2_CONNECTIONS:-4}"
ARIA2_MAX_CONCURRENT="${ARIA2_MAX_CONCURRENT:-4}"
ARIA2_SPLIT="${ARIA2_SPLIT:-4}"
ARIA2_MIN_SPLIT_SIZE="${ARIA2_MIN_SPLIT_SIZE:-128M}"
ARIA2_SUMMARY_INTERVAL="${ARIA2_SUMMARY_INTERVAL:-120}"
VERIFY_AFTER_DOWNLOAD="${VERIFY_AFTER_DOWNLOAD:-1}"
SKIP_VERIFIED_FILES="${SKIP_VERIFIED_FILES:-1}"
CHECK_REMOTE_RELEASE="${CHECK_REMOTE_RELEASE:-1}"
PLAN_ONLY="${PLAN_ONLY:-0}"
MIN_DISK_GB_WAS_SET="${MIN_DISK_GB+x}"
MIN_DISK_GB="${MIN_DISK_GB:-1}"

ALL_DATASETS=(
  uniprotkb_complete
  uniprotkb_accessions
  uniref50
  uniref90
  uniref100
  idmapping
  reference_proteomes
)

DATASET_ARG_SEEN=0
SELECT_ALL=0
LIST_DATASETS=0
CLI_DATASETS=""
RUN_ID=""
SELECTED_LABEL=""
TARGET_COUNT=0
TARGET_BYTES=0
DOWNLOAD_COUNT=0
DOWNLOAD_BYTES=0
SELECT_SWISSPROT=0
SELECT_TREMBL=0
SELECT_UNIPROTKB_METADATA=0

declare -A SELECTED_DATASETS=()
declare -a SELECTED_ORDER=()

usage() {
  cat <<'EOF'
Usage:
  download_uniprot_uniref50.sh [options]

Dataset selection:
  --dataset NAME[,NAME...]  Select one or more datasets; may be repeated
  --all                     Select all 25 approved files
  --list-datasets           List datasets and compressed sizes, then exit

Execution:
  --plan-only               Write and print the plan without network access
  --manifest PATH           Override the approved 2026_02 manifest path
  --local-root PATH         Override the data output root
  --run-root PATH           Override logs, plans, manifests and trash root
  -h, --help                Show this help

Datasets:
  swissprot                 Swiss-Prot FASTA, varsplic FASTA and DAT
  trembl                    TrEMBL FASTA and DAT
  uniprotkb_complete        Swiss-Prot/TrEMBL FASTA and DAT plus README/metalink
  uniprotkb_accessions      Secondary accession mapping plus metalink
  uniref50                  UniRef50 FASTA plus README/metalink (default)
  uniref90                  UniRef90 FASTA plus README/metalink
  uniref100                 UniRef100 FASTA plus README/metalink
  idmapping                 UniProt cross-reference mapping plus README/metalink
  reference_proteomes       Reference Proteomes archive plus README/STATS/metalink

Presets accepted by --dataset:
  uniprotkb                 uniprotkb_complete,uniprotkb_accessions
  uniref                    uniref50,uniref90,uniref100
  multiomics                accessions,idmapping,reference_proteomes
  all                       all datasets

Environment variables remain supported. Examples:
  DOWNLOAD_DATASETS=uniref50,uniref90 ./download_uniprot_uniref50.sh
  ./download_uniprot_uniref50.sh --dataset uniprotkb --plan-only
  ./download_uniprot_uniref50.sh --all
EOF
}

argument_error() {
  printf '[uniprot] ERROR: %s\n' "$*" >&2
  printf '[uniprot] Run with --help for usage.\n' >&2
  exit 2
}

require_argument() {
  local option="$1"
  local value="${2:-}"
  [[ -n "${value}" ]] || argument_error "${option} requires a value"
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --dataset)
        require_argument "$1" "${2:-}"
        if [[ "${DATASET_ARG_SEEN}" == "0" ]]; then
          CLI_DATASETS="$2"
        else
          CLI_DATASETS+=",$2"
        fi
        DATASET_ARG_SEEN=1
        shift 2
        ;;
      --dataset=*)
        require_argument "--dataset" "${1#*=}"
        if [[ "${DATASET_ARG_SEEN}" == "0" ]]; then
          CLI_DATASETS="${1#*=}"
        else
          CLI_DATASETS+=",${1#*=}"
        fi
        DATASET_ARG_SEEN=1
        shift
        ;;
      --all)
        SELECT_ALL=1
        shift
        ;;
      --plan-only)
        PLAN_ONLY=1
        shift
        ;;
      --list-datasets)
        LIST_DATASETS=1
        shift
        ;;
      --manifest)
        require_argument "$1" "${2:-}"
        MANIFEST_FILE="$2"
        shift 2
        ;;
      --manifest=*)
        require_argument "--manifest" "${1#*=}"
        MANIFEST_FILE="${1#*=}"
        shift
        ;;
      --local-root)
        require_argument "$1" "${2:-}"
        LOCAL_ROOT="$2"
        shift 2
        ;;
      --local-root=*)
        require_argument "--local-root" "${1#*=}"
        LOCAL_ROOT="${1#*=}"
        shift
        ;;
      --run-root)
        require_argument "$1" "${2:-}"
        RUN_ROOT="$2"
        shift 2
        ;;
      --run-root=*)
        require_argument "--run-root" "${1#*=}"
        RUN_ROOT="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        (( $# == 0 )) || argument_error "positional arguments are not supported"
        ;;
      -*)
        argument_error "unknown option: $1"
        ;;
      *)
        argument_error "positional arguments are not supported: $1"
        ;;
    esac
  done

  if [[ "${SELECT_ALL}" == "1" && "${DATASET_ARG_SEEN}" == "1" ]]; then
    argument_error "--all cannot be combined with --dataset"
  fi
  if [[ "${DATASET_ARG_SEEN}" == "1" ]]; then
    DOWNLOAD_DATASETS="${CLI_DATASETS}"
  elif [[ "${SELECT_ALL}" == "1" ]]; then
    DOWNLOAD_DATASETS="all"
  fi
}

init_runtime_paths() {
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
  MANIFEST_SNAPSHOT="${MANIFEST_DIR}/download_file_manifest_${RELEASE}_${RUN_ID}.tsv"
  VERIFY_REPORT="${MANIFEST_DIR}/verification_${RUN_ID}.tsv"
}

print_dataset_catalog() {
  local dataset count bytes gib
  [[ -r "${MANIFEST_FILE}" ]] || {
    printf '[uniprot] ERROR: manifest is not readable: %s\n' "${MANIFEST_FILE}" >&2
    exit 1
  }

  printf 'dataset\tfiles\tbytes\tGiB\n'
  read -r count bytes < <(
    awk -F '\t' '
      !/^#/ && $1 != "scope" && $3 == "uniprotkb_complete" &&
      ($6 ~ /\/(README|RELEASE\.metalink)$/ || $6 ~ /\/uniprot_sprot[^/]*$/) {
        count++
        bytes += $7
      }
      END {printf "%d %.0f\n", count+0, bytes+0}
    ' "${MANIFEST_FILE}"
  )
  gib="$(awk -v bytes="${bytes}" 'BEGIN {printf "%.3f", bytes / 1073741824}')"
  printf 'swissprot\t%s\t%s\t%s\n' "${count}" "${bytes}" "${gib}"

  read -r count bytes < <(
    awk -F '\t' '
      !/^#/ && $1 != "scope" && $3 == "uniprotkb_complete" &&
      ($6 ~ /\/(README|RELEASE\.metalink)$/ || $6 ~ /\/uniprot_trembl[^/]*$/) {
        count++
        bytes += $7
      }
      END {printf "%d %.0f\n", count+0, bytes+0}
    ' "${MANIFEST_FILE}"
  )
  gib="$(awk -v bytes="${bytes}" 'BEGIN {printf "%.3f", bytes / 1073741824}')"
  printf 'trembl\t%s\t%s\t%s\n' "${count}" "${bytes}" "${gib}"

  for dataset in "${ALL_DATASETS[@]}"; do
    read -r count bytes < <(
      awk -F '\t' -v dataset="${dataset}" '
        !/^#/ && $1 != "scope" && $3 == dataset {
          count++
          bytes += $7
        }
        END {printf "%d %.0f\n", count+0, bytes+0}
      ' "${MANIFEST_FILE}"
    )
    gib="$(awk -v bytes="${bytes}" 'BEGIN {printf "%.3f", bytes / 1073741824}')"
    printf '%s\t%s\t%s\t%s\n' "${dataset}" "${count}" "${bytes}" "${gib}"
  done
}

validate_manifest() {
  local row_count byte_sum invalid_rows duplicate_paths duplicate_urls
  local unexpected_datasets manifest_digest

  [[ "${RELEASE}" == "2026_02" ]] || die "当前清单合同只支持 RELEASE=2026_02，当前值：${RELEASE}"
  [[ -r "${MANIFEST_FILE}" ]] || die "清单不可读：${MANIFEST_FILE}"

  invalid_rows="$(awk -F '\t' -v release="${RELEASE}" '
    !/^#/ && $1 != "scope" {
      invalid = NF != 10 || $1 != "required" || $4 != release ||
        $5 !~ /^https:\/\/ftp\.uniprot\.org\/pub\/databases\/uniprot\/current_release\// ||
        $5 != ("https://ftp.uniprot.org/pub/databases/uniprot/current_release/" $6) ||
        $6 ~ /^\// || $6 ~ /(^|\/)\.\.($|\/)/ || $7 !~ /^[1-9][0-9]*$/ ||
        ($9 == "static_file" && (length($8) != 32 || $8 !~ /^[0-9a-f]+$/)) ||
        ($9 == "release_manifest" && $8 != "") ||
        ($9 != "static_file" && $9 != "release_manifest")
      if (invalid) print NR
    }
  ' "${MANIFEST_FILE}")"
  [[ -z "${invalid_rows}" ]] || die "清单存在非法行：${invalid_rows}"

  duplicate_paths="$(awk -F '\t' '
    !/^#/ && $1 != "scope" {count[$6]++}
    END {for (path in count) if (count[path] > 1) print path}
  ' "${MANIFEST_FILE}")"
  [[ -z "${duplicate_paths}" ]] || die "清单存在重复相对路径：${duplicate_paths}"

  duplicate_urls="$(awk -F '\t' '
    !/^#/ && $1 != "scope" {count[$5]++}
    END {for (url in count) if (count[url] > 1) print url}
  ' "${MANIFEST_FILE}")"
  [[ -z "${duplicate_urls}" ]] || die "清单存在重复 URL：${duplicate_urls}"

  unexpected_datasets="$(awk -F '\t' '
    !/^#/ && $1 != "scope" &&
    $3 !~ /^(uniprotkb_complete|uniprotkb_accessions|uniref50|uniref90|uniref100|idmapping|reference_proteomes)$/ {
      print $3
    }
  ' "${MANIFEST_FILE}" | LC_ALL=C sort -u)"
  [[ -z "${unexpected_datasets}" ]] || die "清单包含未批准的数据集：${unexpected_datasets}"

  read -r row_count byte_sum < <(
    awk -F '\t' '
      !/^#/ && $1 != "scope" {count++; bytes += $7}
      END {printf "%d %.0f\n", count+0, bytes+0}
    ' "${MANIFEST_FILE}"
  )
  [[ "${row_count}" -eq 25 ]] || die "清单文件数应为 25，实际为 ${row_count}"
  [[ "${byte_sum}" == "618535806550" ]] || die "清单总字节数不匹配：expected=618535806550 actual=${byte_sum}"

  manifest_digest="$(awk '!/^#/' "${MANIFEST_FILE}" | sha256sum | awk '{print $1}')"
  [[ "${manifest_digest}" == "${APPROVED_MANIFEST_SHA256}" ]] || \
    die "清单内容不等于已批准的 25 文件合同：expected_sha256=${APPROVED_MANIFEST_SHA256} actual_sha256=${manifest_digest}"
}

add_dataset() {
  local dataset="$1"
  if [[ -z "${SELECTED_DATASETS[${dataset}]+x}" ]]; then
    SELECTED_DATASETS["${dataset}"]=1
    SELECTED_ORDER+=("${dataset}")
  fi
}

select_uniprotkb_complete() {
  add_dataset uniprotkb_complete
  SELECT_SWISSPROT=1
  SELECT_TREMBL=1
  SELECT_UNIPROTKB_METADATA=1
}

select_swissprot() {
  add_dataset uniprotkb_complete
  SELECT_SWISSPROT=1
  SELECT_UNIPROTKB_METADATA=1
}

select_trembl() {
  add_dataset uniprotkb_complete
  SELECT_TREMBL=1
  SELECT_UNIPROTKB_METADATA=1
}

expand_dataset_token() {
  local token="$1"
  local dataset
  case "${token}" in
    swissprot)
      select_swissprot
      ;;
    trembl)
      select_trembl
      ;;
    uniprotkb)
      select_uniprotkb_complete
      add_dataset uniprotkb_accessions
      ;;
    uniref)
      add_dataset uniref50
      add_dataset uniref90
      add_dataset uniref100
      ;;
    multiomics)
      add_dataset uniprotkb_accessions
      add_dataset idmapping
      add_dataset reference_proteomes
      ;;
    all)
      for dataset in "${ALL_DATASETS[@]}"; do
        if [[ "${dataset}" == "uniprotkb_complete" ]]; then
          select_uniprotkb_complete
        else
          add_dataset "${dataset}"
        fi
      done
      ;;
    uniprotkb_complete)
      select_uniprotkb_complete
      ;;
    uniprotkb_accessions|uniref50|uniref90|uniref100|idmapping|reference_proteomes)
      add_dataset "${token}"
      ;;
    "")
      die "DOWNLOAD_DATASETS 包含空数据集名称"
      ;;
    *)
      die "未知数据集：${token}。使用 --list-datasets 查看允许值。"
      ;;
  esac
}

resolve_datasets() {
  local token
  local -a tokens=()
  local -a requested_order=()
  local -A requested_seen=()
  IFS=',' read -r -a tokens <<< "${DOWNLOAD_DATASETS}"
  for token in "${tokens[@]}"; do
    token="${token//[[:space:]]/}"
    expand_dataset_token "${token}"
    if [[ -z "${requested_seen[${token}]+x}" ]]; then
      requested_seen["${token}"]=1
      requested_order+=("${token}")
    fi
  done
  (( ${#SELECTED_ORDER[@]} > 0 )) || die "未选择任何数据集"

  local IFS=,
  SELECTED_LABEL="${requested_order[*]}"
}

validate_config() {
  common_validate_download_config
  validate_flag CHECK_REMOTE_RELEASE "${CHECK_REMOTE_RELEASE}"
  validate_flag PLAN_ONLY "${PLAN_ONLY}"
  validate_positive_int MIN_DISK_GB "${MIN_DISK_GB}"
  [[ "${CHECK_REMOTE_RELEASE}" == "1" ]] || die "CHECK_REMOTE_RELEASE 是强制安全门，不能设为 0"
  [[ "${VERIFY_AFTER_DOWNLOAD}" == "1" ]] || die "VERIFY_AFTER_DOWNLOAD 是强制安全门，不能设为 0"
  validate_manifest
}

manifest_records() {
  awk -F '\t' '
    BEGIN {OFS="\034"}
    !/^#/ && $1 != "scope" {
      print $1, $2, $3, $4, $5, $6, $7, $8, $9, $10
    }
  ' "${MANIFEST_FILE}"
}

plan_records() {
  awk -F '\t' '
    BEGIN {OFS="\034"}
    !/^#/ && $1 != "dataset" {
      print $1, $2, $3, $4, $5, $6, $7, $8
    }
  ' "${PLAN_FILE}"
}

manifest_record_is_selected() {
  local dataset="$1"
  local relpath="$2"
  [[ -n "${SELECTED_DATASETS[${dataset}]+x}" ]] || return 1
  [[ "${dataset}" == "uniprotkb_complete" ]] || return 0

  case "${relpath##*/}" in
    README|RELEASE.metalink)
      [[ "${SELECT_UNIPROTKB_METADATA}" == "1" ]]
      ;;
    uniprot_sprot*)
      [[ "${SELECT_SWISSPROT}" == "1" ]]
      ;;
    uniprot_trembl*)
      [[ "${SELECT_TREMBL}" == "1" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

build_download_plan() {
  local rows_file="${TMP_DIR}/selected_manifest_rows.tsv"
  local scope tier dataset release remote_url relpath bytes md5 source_kind notes
  local local_file planned_dataset human_gib
  local -A planned_counts=()

  : > "${rows_file}"
  TARGET_COUNT=0
  TARGET_BYTES=0

  while IFS=$'\034' read -r scope tier dataset release remote_url relpath bytes md5 source_kind notes; do
    manifest_record_is_selected "${dataset}" "${relpath}" || continue

    local_file="${LOCAL_ROOT}/${relpath}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${dataset}" "${relpath}" "${remote_url}" "${local_file}" "${bytes}" "${md5}" "${source_kind}" "${notes}" >> "${rows_file}"
    TARGET_COUNT=$((TARGET_COUNT + 1))
    TARGET_BYTES=$((TARGET_BYTES + bytes))
    planned_counts["${dataset}"]=$((${planned_counts[${dataset}]:-0} + 1))
  done < <(manifest_records)

  for planned_dataset in "${SELECTED_ORDER[@]}"; do
    (( ${planned_counts[${planned_dataset}]:-0} > 0 )) || die "所选数据集在清单中没有文件：${planned_dataset}"
  done
  (( TARGET_COUNT > 0 )) || die "下载计划为空"

  {
    printf '# release\t%s\n' "${RELEASE}"
    printf '# datasets\t%s\n' "${SELECTED_LABEL}"
    printf '# total_files\t%s\n' "${TARGET_COUNT}"
    printf '# total_bytes\t%s\n' "${TARGET_BYTES}"
    printf 'dataset\trelative_path\turl\tlocal_file\tbytes\tmd5\tsource_kind\tnotes\n'
    cat "${rows_file}"
  } > "${PLAN_FILE}"
  install -m 0644 "${MANIFEST_FILE}" "${MANIFEST_SNAPSHOT}"

  human_gib="$(awk -v bytes="${TARGET_BYTES}" 'BEGIN {printf "%.3f", bytes / 1073741824}')"
  log "下载计划已生成：${PLAN_FILE}"
  log "选择：${SELECTED_LABEL}；文件数：${TARGET_COUNT}；压缩体积：${TARGET_BYTES} bytes (${human_gib} GiB)"
  log "清单快照：${MANIFEST_SNAPSHOT}"
}

verify_remote_release() {
  local dataset relpath url local_file bytes md5 source_kind notes
  local probe actual_bytes count=0

  while IFS=$'\034' read -r dataset relpath url local_file bytes md5 source_kind notes; do
    [[ "${source_kind}" == "release_manifest" ]] || continue

    probe="${TMP_DIR}/remote_release_$(safe_name "${relpath}")"
    log "检查远端版本：${url}"
    fetch_to_file "${url}" "${probe}" || die "无法读取远端 release manifest：${url}"
    actual_bytes="$(stat -c '%s' "${probe}")"
    if [[ "${actual_bytes}" != "${bytes}" ]]; then
      move_to_trash "${probe}" "remote_manifest_size_mismatch"
      die "远端 release manifest 大小已漂移：${relpath}，expected=${bytes} actual=${actual_bytes}"
    fi
    if ! grep -Fq "<version>${RELEASE}</version>" "${probe}"; then
      move_to_trash "${probe}" "remote_release_mismatch"
      die "远端版本已不再是 ${RELEASE}：${url}。请先重新生成并审核清单。"
    fi
    count=$((count + 1))
  done < <(plan_records)

  [[ "${count}" -eq "${#SELECTED_ORDER[@]}" ]] || die "远端版本检查数量异常：expected=${#SELECTED_ORDER[@]} actual=${count}"
  log "远端版本检查通过：${count} 个 RELEASE.metalink 均为 ${RELEASE}"
}

write_aria_input() {
  local dataset relpath url local_file bytes md5 source_kind notes
  local local_dir out_name human_gib

  : > "${ARIA_INPUT}"
  DOWNLOAD_COUNT=0
  DOWNLOAD_BYTES=0

  while IFS=$'\034' read -r dataset relpath url local_file bytes md5 source_kind notes; do
    local_dir="$(dirname "${local_file}")"
    out_name="${local_file##*/}"
    mkdir -p "${local_dir}"

    if existing_file_is_complete "${relpath}" "${url}" "${local_file}" "${md5}" "${bytes}"; then
      continue
    fi

    printf '%s\n  dir=%s\n  out=%s\n' "${url}" "${local_dir}" "${out_name}" >> "${ARIA_INPUT}"
    if [[ -n "${md5}" ]]; then
      printf '  checksum=md5=%s\n' "${md5}" >> "${ARIA_INPUT}"
    fi
    DOWNLOAD_COUNT=$((DOWNLOAD_COUNT + 1))
    DOWNLOAD_BYTES=$((DOWNLOAD_BYTES + bytes))
  done < <(plan_records)

  if [[ -z "${MIN_DISK_GB_WAS_SET}" && "${DOWNLOAD_BYTES}" -gt 0 ]]; then
    MIN_DISK_GB="$(awk -v bytes="${DOWNLOAD_BYTES}" 'BEGIN {required = bytes / 1000000000 * 1.05; printf "%d", int(required) + 1}')"
  fi

  human_gib="$(awk -v bytes="${DOWNLOAD_BYTES}" 'BEGIN {printf "%.3f", bytes / 1073741824}')"
  log "aria2 输入：${ARIA_INPUT}"
  log "待下载：${DOWNLOAD_COUNT} 个，${DOWNLOAD_BYTES} bytes (${human_gib} GiB)；磁盘阈值：${MIN_DISK_GB} GB"
}

quarantine_invalid_completed_files() {
  local dataset relpath url local_file bytes md5 source_kind notes
  local actual_bytes actual_md5 reason
  local quarantined=0 retained_partial=0 valid=0

  while IFS=$'\034' read -r dataset relpath url local_file bytes md5 source_kind notes; do
    [[ -f "${local_file}" ]] || continue
    if [[ -f "${local_file}.aria2" ]]; then
      retained_partial=$((retained_partial + 1))
      continue
    fi

    reason=""
    actual_bytes="$(stat -c '%s' "${local_file}")"
    if [[ "${actual_bytes}" != "${bytes}" ]]; then
      reason="size expected=${bytes} actual=${actual_bytes}"
    elif [[ -n "${md5}" ]]; then
      actual_md5="$(md5sum "${local_file}" | awk '{print $1}')"
      if [[ "${actual_md5}" != "${md5}" ]]; then
        reason="md5 expected=${md5} actual=${actual_md5}"
      fi
    elif [[ "${source_kind}" == "release_manifest" ]]; then
      if ! grep -Fq "<version>${RELEASE}</version>" "${local_file}"; then
        reason="release_version expected=${RELEASE}"
      fi
    else
      reason="missing_verification_rule"
    fi

    if [[ -n "${reason}" ]]; then
      errlog "aria2 失败后隔离无 sidecar 的无效文件：${relpath}，${reason}"
      move_to_trash "${local_file}" "aria_failed_invalid_file"
      quarantined=$((quarantined + 1))
    else
      valid=$((valid + 1))
    fi
  done < <(plan_records)

  log "aria2 失败清理：有效完整文件 ${valid} 个，保留可续传 partial ${retained_partial} 个，移入 trash ${quarantined} 个"
}

verify_after_download() {
  local dataset relpath url local_file bytes md5 source_kind notes
  local actual_bytes actual_md5 failed=0
  : > "${VERIFY_REPORT}"
  printf '# relative_path\tstatus\tdetail\n' >> "${VERIFY_REPORT}"

  while IFS=$'\034' read -r dataset relpath url local_file bytes md5 source_kind notes; do

    if [[ ! -f "${local_file}" ]]; then
      printf '%s\tFAIL\tmissing\n' "${relpath}" >> "${VERIFY_REPORT}"
      errlog "下载后校验失败，文件缺失：${relpath}"
      failed=1
      continue
    fi

    actual_bytes="$(stat -c '%s' "${local_file}")"
    if [[ "${actual_bytes}" != "${bytes}" ]]; then
      printf '%s\tFAIL\tsize expected=%s actual=%s\n' "${relpath}" "${bytes}" "${actual_bytes}" >> "${VERIFY_REPORT}"
      errlog "下载后校验失败，大小不匹配：${relpath}"
      move_to_trash "${local_file}" "size_verify_failed"
      failed=1
      continue
    fi

    if [[ -n "${md5}" ]]; then
      actual_md5="$(md5sum "${local_file}" | awk '{print $1}')"
      if [[ "${actual_md5}" != "${md5}" ]]; then
        printf '%s\tFAIL\tmd5 expected=%s actual=%s\n' "${relpath}" "${md5}" "${actual_md5}" >> "${VERIFY_REPORT}"
        errlog "下载后校验失败，MD5 不匹配：${relpath}"
        move_to_trash "${local_file}" "md5_verify_failed"
        failed=1
        continue
      fi
      printf '%s\tPASS\tsize+md5\n' "${relpath}" >> "${VERIFY_REPORT}"
    elif [[ "${source_kind}" == "release_manifest" ]]; then
      if ! grep -Fq "<version>${RELEASE}</version>" "${local_file}"; then
        printf '%s\tFAIL\trelease_version\n' "${relpath}" >> "${VERIFY_REPORT}"
        errlog "下载后校验失败，release 版本不匹配：${relpath}"
        move_to_trash "${local_file}" "release_verify_failed"
        failed=1
        continue
      fi
      printf '%s\tPASS\tsize+release_version\n' "${relpath}" >> "${VERIFY_REPORT}"
    else
      printf '%s\tFAIL\tmissing_verification_rule\n' "${relpath}" >> "${VERIFY_REPORT}"
      errlog "下载后校验失败，无校验规则：${relpath}"
      move_to_trash "${local_file}" "verification_rule_missing"
      failed=1
    fi
  done < <(plan_records)

  [[ "${failed}" -eq 0 ]] || die "至少一个文件校验失败；报告：${VERIFY_REPORT}"
  log "下载后校验通过：${VERIFY_REPORT}"
}

main() {
  local aria_status
  parse_args "$@"

  if [[ "${LIST_DATASETS}" == "1" ]]; then
    print_dataset_catalog
    return 0
  fi

  init_runtime_paths
  common_init_dirs
  require_command awk
  require_command install
  require_command md5sum
  require_command sha256sum
  require_command stat
  validate_config
  resolve_datasets
  build_download_plan

  log "========== UniProt ${RELEASE} =========="
  log "数据根目录：${LOCAL_ROOT}"
  log "运行目录：${RUN_ROOT}"

  if [[ "${PLAN_ONLY}" == "1" ]]; then
    log "PLAN_ONLY=1：未访问网络，未启动下载"
    cat "${PLAN_FILE}"
    return 0
  fi

  require_command curl
  require_command aria2c
  verify_remote_release
  write_aria_input
  if run_aria2_input "${DB_NAME}_${SELECTED_LABEL//,/+}" "${ARIA_INPUT}"; then
    :
  else
    aria_status=$?
    quarantine_invalid_completed_files
    die "aria2 未完成，exit=${aria_status}；带 .aria2 的 partial 已保留供断点续传"
  fi
  verify_after_download

  log "========== UniProt ${RELEASE} 下载完成 =========="
  log "下载计划：${PLAN_FILE}"
  log "校验报告：${VERIFY_REPORT}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
