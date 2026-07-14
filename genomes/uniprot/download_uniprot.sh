#!/usr/bin/env bash
# =============================================================================
# UniProt 2026_02 manifest-driven downloader
#
# With no arguments, the downloader selects UniRef50. Other approved datasets
# can be selected independently, combined, or downloaded together with --all.
# =============================================================================
set -Eeuo pipefail

early_unhandled_error() {
  local exit_code="$1"
  local line="$2"
  local command="$3"
  trap - ERR
  printf '[uniprot] ERROR: initialization failed: exit=%s line=%s command=%q\n' \
    "${exit_code}" "${line}" "${command}" >&2
  exit "${exit_code}"
}

trap 'early_unhandled_error "$?" "${LINENO}" "${BASH_COMMAND}"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SH="${SCRIPT_DIR}/../common/common.sh"
source "${COMMON_SH}"
common_require_version "1.0"

DB_NAME="uniprot"
RELEASE="${RELEASE:-2026_02}"
MANIFEST_FILE="${MANIFEST_FILE:-${SCRIPT_DIR}/download_file_manifest_${RELEASE}.tsv}"
APPROVED_MANIFEST_SHA256="1107165a1a1256314ec193202f127f40f8d64308a6c609d0fdf03b91728e5070"
DOWNLOAD_DATASETS="${DOWNLOAD_DATASETS:-uniref50}"
LOCAL_ROOT="${LOCAL_ROOT:-/data2/p252701008/genomes/uniprot_${RELEASE}}"
RUN_ROOT="${RUN_ROOT:-/data/p252701008/datasets/uniprot_${RELEASE}_runlogs}"
USE_PROXY="${USE_PROXY:-0}"

ARIA2_CONNECTIONS="${ARIA2_CONNECTIONS:-4}"
ARIA2_MAX_CONCURRENT="${ARIA2_MAX_CONCURRENT:-4}"
ARIA2_SPLIT="${ARIA2_SPLIT:-4}"
ARIA2_MIN_SPLIT_SIZE="${ARIA2_MIN_SPLIT_SIZE:-128M}"
ARIA2_SUMMARY_INTERVAL="${ARIA2_SUMMARY_INTERVAL:-120}"
ARIA2_BIN="${ARIA2_BIN:-aria2c}"
ARIA2_MAX_TRIES="${ARIA2_MAX_TRIES:-10}"
ARIA2_RETRY_WAIT_SECONDS="${ARIA2_RETRY_WAIT_SECONDS:-30}"
DOWNLOAD_MAX_ATTEMPTS="${DOWNLOAD_MAX_ATTEMPTS:-3}"
DOWNLOAD_RETRY_WAIT_SECONDS="${DOWNLOAD_RETRY_WAIT_SECONDS:-60}"
PROGRESS_INTERVAL_SECONDS="${PROGRESS_INTERVAL_SECONDS:-120}"
LOCK_WAIT_SECONDS="${LOCK_WAIT_SECONDS:-0}"
VERIFY_AFTER_DOWNLOAD="${VERIFY_AFTER_DOWNLOAD:-1}"
SKIP_VERIFIED_FILES="${SKIP_VERIFIED_FILES:-1}"
CHECK_REMOTE_RELEASE="${CHECK_REMOTE_RELEASE:-1}"
PLAN_ONLY="${PLAN_ONLY:-0}"
VERIFY_ONLY="${VERIFY_ONLY:-0}"
STATUS_ONLY="${STATUS_ONLY:-0}"
SUMMARY_ONLY="${SUMMARY_ONLY:-0}"
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
RUNTIME_INITIALIZED=0
FINALIZED=0
HANDLING_FAILURE=0
LOCK_HELD=0
LOCK_FD=""
MONITOR_PID=""
ARIA_PID=""
CURRENT_STAGE="INITIALIZING"
CURRENT_STATE="INITIALIZING"
CURRENT_ATTEMPT=0
LAST_ERROR_CLASS="NONE"
LAST_MESSAGE=""
START_EPOCH=0
END_EPOCH=0
PROGRESS_BASE_BYTES=0
PROGRESS_BASE_EPOCH=0
PROGRESS_BASE_SET=0
VERIFY_PASS_COUNT=0
VERIFY_FAIL_COUNT=0
VERIFY_MISSING_COUNT=0
VERIFY_PARTIAL_COUNT=0
LAST_ATTEMPT_LOG=""
LAST_TRANSPORT_LOG=""
LAST_ATTEMPT_EVIDENCE=""
LAST_REPAIR_PLAN=""

declare -A SELECTED_DATASETS=()
declare -a SELECTED_ORDER=()
declare -A LAST_VALIDATION_STATUS_BY_PATH=()
declare -A LAST_VALIDATION_DETAIL_BY_PATH=()

usage() {
  cat <<'EOF'
Usage:
  download_uniprot.sh [options]

Dataset selection:
  --dataset NAME[,NAME...]  Select one or more datasets; may be repeated
  --all                     Select all 25 approved files
  --list-datasets           List datasets and compressed sizes, then exit

Execution:
  --plan-only               Write and print the plan without network access
  --verify-only             Read-only validation; never move payload files
  --status                  Print the latest state and progress snapshots
  --summary                 Print the latest terminal summary
  --manifest PATH           Override the approved 2026_02 manifest path
  --local-root PATH         Override the data output root
  --run-root PATH           Override logs, plans, state, reports and trash root

Recovery and monitoring:
  --download-attempts N     Maximum outer transfer/repair rounds (default: 3)
  --retry-wait SECONDS      Delay between outer repair rounds (default: 60)
  --progress-interval SEC   Progress snapshot interval; 0 disables (default: 120)
  --lock-wait SECONDS       Exclusive-lock wait; 0 fails immediately (default: 0)

aria2 controls:
  --connections N           Connections per server (default: 4)
  --max-concurrent N        Concurrent files (default: 4)
  --split N                 Split count per file (default: 4)
  --min-split-size SIZE     aria2 split size from 1M through 1024M
  --aria-max-tries N        Retries inside each aria2 round (default: 10)
  --aria-retry-wait SEC     aria2 retry delay (default: 30)
  --summary-interval SEC    aria2 console summary interval (default: 120)
  --min-disk-gb N           Required free disk threshold in decimal GB
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
  DOWNLOAD_DATASETS=uniref50,uniref90 ./download_uniprot.sh
  ./download_uniprot.sh --dataset uniprotkb --plan-only
  ./download_uniprot.sh --verify-only --all
  ./download_uniprot.sh --status
  ./download_uniprot.sh --all

Exit status:
  0    COMPLETE, PLANNED, or a successful status/summary query
  2    Invalid command-line arguments
  20   NEEDS_REPAIR: required files remain missing, partial, or invalid
  30   BLOCKED: unsafe configuration, lock contention, or local preflight failure
  130  Interrupted by SIGINT
  143  Interrupted by SIGTERM
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

require_positive_cli_int() {
  local option="$1"
  local value="$2"
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || argument_error "${option} requires a positive integer"
}

require_nonnegative_cli_int() {
  local option="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || argument_error "${option} requires a non-negative integer"
}

require_cli_size() {
  local option="$1"
  local value="$2"
  [[ "${value}" =~ ^([1-9][0-9]*)[Mm]$ ]] || \
    argument_error "${option} requires an aria2 size from 1M through 1024M"
  (( 10#${BASH_REMATCH[1]} <= 1024 )) || \
    argument_error "${option} must not exceed 1024M"
}

parse_args() {
  local execution_mode_count mode_name mode_value
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
      --verify-only)
        VERIFY_ONLY=1
        shift
        ;;
      --status)
        STATUS_ONLY=1
        shift
        ;;
      --summary)
        SUMMARY_ONLY=1
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
      --download-attempts)
        require_argument "$1" "${2:-}"
        require_positive_cli_int "$1" "$2"
        DOWNLOAD_MAX_ATTEMPTS="$2"
        shift 2
        ;;
      --download-attempts=*)
        require_argument "--download-attempts" "${1#*=}"
        require_positive_cli_int "--download-attempts" "${1#*=}"
        DOWNLOAD_MAX_ATTEMPTS="${1#*=}"
        shift
        ;;
      --retry-wait)
        require_argument "$1" "${2:-}"
        require_nonnegative_cli_int "$1" "$2"
        DOWNLOAD_RETRY_WAIT_SECONDS="$2"
        shift 2
        ;;
      --retry-wait=*)
        require_argument "--retry-wait" "${1#*=}"
        require_nonnegative_cli_int "--retry-wait" "${1#*=}"
        DOWNLOAD_RETRY_WAIT_SECONDS="${1#*=}"
        shift
        ;;
      --progress-interval)
        require_argument "$1" "${2:-}"
        require_nonnegative_cli_int "$1" "$2"
        PROGRESS_INTERVAL_SECONDS="$2"
        shift 2
        ;;
      --progress-interval=*)
        require_argument "--progress-interval" "${1#*=}"
        require_nonnegative_cli_int "--progress-interval" "${1#*=}"
        PROGRESS_INTERVAL_SECONDS="${1#*=}"
        shift
        ;;
      --lock-wait)
        require_argument "$1" "${2:-}"
        require_nonnegative_cli_int "$1" "$2"
        LOCK_WAIT_SECONDS="$2"
        shift 2
        ;;
      --lock-wait=*)
        require_argument "--lock-wait" "${1#*=}"
        require_nonnegative_cli_int "--lock-wait" "${1#*=}"
        LOCK_WAIT_SECONDS="${1#*=}"
        shift
        ;;
      --connections)
        require_argument "$1" "${2:-}"
        require_positive_cli_int "$1" "$2"
        (( 10#$2 <= 16 )) || argument_error "$1 must not exceed aria2's limit of 16"
        ARIA2_CONNECTIONS="$2"
        shift 2
        ;;
      --connections=*)
        require_argument "--connections" "${1#*=}"
        require_positive_cli_int "--connections" "${1#*=}"
        (( 10#${1#*=} <= 16 )) || argument_error "--connections must not exceed aria2's limit of 16"
        ARIA2_CONNECTIONS="${1#*=}"
        shift
        ;;
      --max-concurrent)
        require_argument "$1" "${2:-}"
        require_positive_cli_int "$1" "$2"
        ARIA2_MAX_CONCURRENT="$2"
        shift 2
        ;;
      --max-concurrent=*)
        require_argument "--max-concurrent" "${1#*=}"
        require_positive_cli_int "--max-concurrent" "${1#*=}"
        ARIA2_MAX_CONCURRENT="${1#*=}"
        shift
        ;;
      --split)
        require_argument "$1" "${2:-}"
        require_positive_cli_int "$1" "$2"
        ARIA2_SPLIT="$2"
        shift 2
        ;;
      --split=*)
        require_argument "--split" "${1#*=}"
        require_positive_cli_int "--split" "${1#*=}"
        ARIA2_SPLIT="${1#*=}"
        shift
        ;;
      --min-split-size)
        require_argument "$1" "${2:-}"
        require_cli_size "$1" "$2"
        ARIA2_MIN_SPLIT_SIZE="$2"
        shift 2
        ;;
      --min-split-size=*)
        require_argument "--min-split-size" "${1#*=}"
        require_cli_size "--min-split-size" "${1#*=}"
        ARIA2_MIN_SPLIT_SIZE="${1#*=}"
        shift
        ;;
      --aria-max-tries)
        require_argument "$1" "${2:-}"
        require_positive_cli_int "$1" "$2"
        ARIA2_MAX_TRIES="$2"
        shift 2
        ;;
      --aria-max-tries=*)
        require_argument "--aria-max-tries" "${1#*=}"
        require_positive_cli_int "--aria-max-tries" "${1#*=}"
        ARIA2_MAX_TRIES="${1#*=}"
        shift
        ;;
      --aria-retry-wait)
        require_argument "$1" "${2:-}"
        require_nonnegative_cli_int "$1" "$2"
        ARIA2_RETRY_WAIT_SECONDS="$2"
        shift 2
        ;;
      --aria-retry-wait=*)
        require_argument "--aria-retry-wait" "${1#*=}"
        require_nonnegative_cli_int "--aria-retry-wait" "${1#*=}"
        ARIA2_RETRY_WAIT_SECONDS="${1#*=}"
        shift
        ;;
      --summary-interval)
        require_argument "$1" "${2:-}"
        require_positive_cli_int "$1" "$2"
        ARIA2_SUMMARY_INTERVAL="$2"
        shift 2
        ;;
      --summary-interval=*)
        require_argument "--summary-interval" "${1#*=}"
        require_positive_cli_int "--summary-interval" "${1#*=}"
        ARIA2_SUMMARY_INTERVAL="${1#*=}"
        shift
        ;;
      --min-disk-gb)
        require_argument "$1" "${2:-}"
        require_positive_cli_int "$1" "$2"
        MIN_DISK_GB="$2"
        MIN_DISK_GB_WAS_SET=1
        shift 2
        ;;
      --min-disk-gb=*)
        require_argument "--min-disk-gb" "${1#*=}"
        require_positive_cli_int "--min-disk-gb" "${1#*=}"
        MIN_DISK_GB="${1#*=}"
        MIN_DISK_GB_WAS_SET=1
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

  for mode_name in PLAN_ONLY VERIFY_ONLY STATUS_ONLY SUMMARY_ONLY; do
    mode_value="${!mode_name}"
    case "${mode_value}" in
      0|1) ;;
      *) die "${mode_name} 必须是 0 或 1，当前值为：${mode_value}" ;;
    esac
  done
  execution_mode_count=$((PLAN_ONLY + VERIFY_ONLY + STATUS_ONLY + SUMMARY_ONLY))
  (( execution_mode_count <= 1 )) || \
    argument_error "--plan-only, --verify-only, --status and --summary are mutually exclusive"
  if [[ "${LIST_DATASETS}" == "1" && "${execution_mode_count}" -gt 0 ]]; then
    argument_error "--list-datasets cannot be combined with an execution mode"
  fi
  if [[ "${LIST_DATASETS}" == "1" && \
        ("${SELECT_ALL}" == "1" || "${DATASET_ARG_SEEN}" == "1") ]]; then
    argument_error "--list-datasets does not accept dataset selectors"
  fi
  if [[ ("${STATUS_ONLY}" == "1" || "${SUMMARY_ONLY}" == "1") && \
        ("${SELECT_ALL}" == "1" || "${DATASET_ARG_SEEN}" == "1") ]]; then
    argument_error "--status and --summary do not accept dataset selectors"
  fi
  if [[ "${DATASET_ARG_SEEN}" == "1" ]]; then
    DOWNLOAD_DATASETS="${CLI_DATASETS}"
  elif [[ "${SELECT_ALL}" == "1" ]]; then
    DOWNLOAD_DATASETS="all"
  fi
}

# Runtime evidence lives under RUN_ROOT; payloads remain under LOCAL_ROOT.
init_runtime_paths() {
  RUN_ID="${RUN_ID:-$(date -u '+%Y%m%dT%H%M%SZ').$$}"
  LOG_DIR="${RUN_ROOT}/logs"
  PLAN_DIR="${RUN_ROOT}/plans"
  MANIFEST_DIR="${RUN_ROOT}/manifests"
  STATUS_DIR="${RUN_ROOT}/status"
  REPORT_DIR="${RUN_ROOT}/reports"
  LOCK_DIR="${RUN_ROOT}/locks"
  TMP_DIR="${RUN_ROOT}/tmp/${RUN_ID}"
  TRASH_DIR="${RUN_ROOT}/trash"

  DL_LOG="${LOG_DIR}/download_${RUN_ID}.log"
  ERR_LOG="${LOG_DIR}/error_${RUN_ID}.log"
  PLAN_FILE="${PLAN_DIR}/download_plan_${RUN_ID}.tsv"
  ARIA_INPUT="${PLAN_DIR}/aria_${DB_NAME}_${RUN_ID}.txt"
  MANIFEST_SNAPSHOT="${MANIFEST_DIR}/download_file_manifest_${RELEASE}_${RUN_ID}.tsv"
  VERIFY_REPORT="${MANIFEST_DIR}/verification_${RUN_ID}.tsv"
  STATE_FILE="${STATUS_DIR}/state_${RUN_ID}.tsv"
  PROGRESS_FILE="${STATUS_DIR}/progress_${RUN_ID}.tsv"
  LATEST_STATUS_FILE="${STATUS_DIR}/latest_status.tsv"
  LATEST_PROGRESS_FILE="${STATUS_DIR}/latest_progress.tsv"
  SUMMARY_REPORT="${REPORT_DIR}/summary_${RUN_ID}.md"
  LATEST_SUMMARY_REPORT="${REPORT_DIR}/latest_summary.md"
}

init_control_dirs() {
  mkdir -p "${RUN_ROOT}" "${LOG_DIR}" "${PLAN_DIR}" "${MANIFEST_DIR}" \
    "${STATUS_DIR}" "${REPORT_DIR}" "${LOCK_DIR}" "${TMP_DIR}" "${TRASH_DIR}"
}

# State/error messages are single-line and redact common credential assignments.
sanitize_message() {
  printf '%s' "$*" \
    | sed -E 's/((token|password|authorization|api[_-]?key)=)[^[:space:]]+/\1REDACTED/Ig' \
    | tr '\t\r\n' '   '
}

die() {
  local message
  message="$(sanitize_message "$*")"
  HANDLING_FAILURE=1
  if [[ "${message}" =~ 磁盘|disk|space ]]; then
    LAST_ERROR_CLASS="STORAGE_BLOCKED"
  elif [[ "${LAST_ERROR_CLASS}" == "NONE" ]]; then
    LAST_ERROR_CLASS="CONFIG_BLOCKED"
  fi
  if [[ "${RUNTIME_INITIALIZED}" == "1" ]]; then
    errlog "${message}"
    finish_run "BLOCKED" 30 "${message}"
  else
    printf '[uniprot] ERROR: %s\n' "${message}" >&2
  fi
  exit 30
}

path_parent_is_writable() {
  local path="$1"
  local parent="${path}"
  while [[ ! -e "${parent}" ]]; do
    parent="$(dirname "${parent}")"
  done
  [[ -d "${parent}" && -w "${parent}" ]]
}

# Reject ambiguous or dangerous roots before creating any directory.
validate_safe_roots() {
  local candidate
  for candidate in "${LOCAL_ROOT}" "${RUN_ROOT}"; do
    [[ -n "${candidate}" ]] || die "数据目录和运行目录不能为空"
    [[ "${candidate}" == /* ]] || die "目录必须是绝对路径：${candidate}"
    [[ "${candidate}" != *$'\n'* && "${candidate}" != *$'\r'* && "${candidate}" != *$'\t'* ]] || \
      die "目录包含控制字符"
  done

  LOCAL_ROOT="$(readlink -m -- "${LOCAL_ROOT}")"
  RUN_ROOT="$(readlink -m -- "${RUN_ROOT}")"
  [[ "${LOCAL_ROOT}" != "/" ]] || die "LOCAL_ROOT 不能是根目录 /"
  [[ "${RUN_ROOT}" != "/" ]] || die "RUN_ROOT 不能是根目录 /"
  [[ "${LOCAL_ROOT}" != "${RUN_ROOT}" ]] || die "LOCAL_ROOT 与 RUN_ROOT 不能相同"

  case "${LOCAL_ROOT}/" in
    "${RUN_ROOT}/"*) die "LOCAL_ROOT 不能位于 RUN_ROOT 内：${LOCAL_ROOT}" ;;
  esac
  case "${RUN_ROOT}/" in
    "${LOCAL_ROOT}/"*) die "RUN_ROOT 不能位于 LOCAL_ROOT 内：${RUN_ROOT}" ;;
  esac

  path_parent_is_writable "${LOCAL_ROOT}" || die "LOCAL_ROOT 的现有父目录不可写：${LOCAL_ROOT}"
  path_parent_is_writable "${RUN_ROOT}" || die "RUN_ROOT 的现有父目录不可写：${RUN_ROOT}"
}

validate_safe_run_root() {
  [[ -n "${RUN_ROOT}" ]] || die "RUN_ROOT 不能为空"
  [[ "${RUN_ROOT}" == /* ]] || die "RUN_ROOT 必须是绝对路径：${RUN_ROOT}"
  [[ "${RUN_ROOT}" != *$'\n'* && "${RUN_ROOT}" != *$'\r'* && "${RUN_ROOT}" != *$'\t'* ]] || \
    die "RUN_ROOT 包含控制字符"
  RUN_ROOT="$(readlink -m -- "${RUN_ROOT}")"
  [[ "${RUN_ROOT}" != "/" ]] || die "RUN_ROOT 不能是根目录 /"
}

atomic_publish() {
  local source_file="$1"
  local destination="$2"
  local temp_file="${destination}.tmp.${RUN_ID}.$$"
  cp -- "${source_file}" "${temp_file}"
  mv -f -- "${temp_file}" "${destination}"
}

write_state() {
  local state="$1"
  local exit_code="${2:-0}"
  local message="${3:-}"
  local timestamp
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  message="$(sanitize_message "${message}")"
  CURRENT_STATE="${state}"
  LAST_MESSAGE="${message}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${timestamp}" "${RUN_ID}" "${state}" "${exit_code}" "${CURRENT_STAGE}" \
    "${CURRENT_ATTEMPT}" "${LAST_ERROR_CLASS}" "${message}" >> "${STATE_FILE}"
  atomic_publish "${STATE_FILE}" "${LATEST_STATUS_FILE}"
}

write_summary_report() {
  local now_epoch duration temp_report
  now_epoch="$(date +%s)"
  if (( START_EPOCH > 0 )); then
    duration=$((now_epoch - START_EPOCH))
  else
    duration=0
  fi
  temp_report="${SUMMARY_REPORT}.tmp.$$"
  {
    printf '# UniProt download run summary\n\n'
    printf -- '- Run ID: `%s`\n' "${RUN_ID}"
    printf -- '- Release: `%s`\n' "${RELEASE}"
    printf -- '- Datasets: `%s`\n' "${SELECTED_LABEL:-not-resolved}"
    printf -- '- State: `%s`\n' "${CURRENT_STATE}"
    printf -- '- Stage: `%s`\n' "${CURRENT_STAGE}"
    printf -- '- Exit code: `%s`\n' "${1:-0}"
    printf -- '- Attempt: `%s/%s`\n' "${CURRENT_ATTEMPT}" "${DOWNLOAD_MAX_ATTEMPTS}"
    printf -- '- Last error class: `%s`\n' "${LAST_ERROR_CLASS}"
    printf -- '- Duration seconds: `%s`\n' "${duration}"
    printf -- '- Planned files: `%s`\n' "${TARGET_COUNT}"
    printf -- '- Planned bytes: `%s`\n' "${TARGET_BYTES}"
    printf -- '- Verification passed: `%s`\n' "${VERIFY_PASS_COUNT}"
    printf -- '- Verification failed: `%s`\n' "${VERIFY_FAIL_COUNT}"
    printf -- '- Verification missing: `%s`\n' "${VERIFY_MISSING_COUNT}"
    printf -- '- Verification partial: `%s`\n' "${VERIFY_PARTIAL_COUNT}"
    printf -- '- Message: %s\n\n' "${LAST_MESSAGE:-none}"
    printf '## Evidence\n\n'
    printf -- '- Plan: `%s`\n' "${PLAN_FILE:-not-created}"
    printf -- '- State history: `%s`\n' "${STATE_FILE}"
    printf -- '- Progress history: `%s`\n' "${PROGRESS_FILE}"
    printf -- '- Verification report: `%s`\n' "${VERIFY_REPORT:-not-created}"
    printf -- '- Download log: `%s`\n' "${DL_LOG}"
    printf -- '- Error log: `%s`\n' "${ERR_LOG}"
  } > "${temp_report}"
  mv -f -- "${temp_report}" "${SUMMARY_REPORT}"
  atomic_publish "${SUMMARY_REPORT}" "${LATEST_SUMMARY_REPORT}"
}

finish_run() {
  local state="$1"
  local exit_code="$2"
  local message="$3"
  [[ "${FINALIZED}" == "0" ]] || return 0
  END_EPOCH="$(date +%s)"
  write_state "${state}" "${exit_code}" "${message}"
  if [[ -n "${PLAN_FILE:-}" && -r "${PLAN_FILE}" ]]; then
    write_progress_snapshot "${CURRENT_ATTEMPT}" "${LAST_ERROR_CLASS}"
  fi
  write_summary_report "${exit_code}"
  FINALIZED=1
}

exit_with_state() {
  local state="$1"
  local exit_code="$2"
  local message="$3"
  finish_run "${state}" "${exit_code}" "${message}"
  exit "${exit_code}"
}

stop_progress_monitor() {
  if [[ -n "${MONITOR_PID}" ]] && kill -0 "${MONITOR_PID}" 2>/dev/null; then
    kill "${MONITOR_PID}" 2>/dev/null || true
    wait "${MONITOR_PID}" 2>/dev/null || true
  fi
  MONITOR_PID=""
}

stop_active_transfer() {
  if [[ -n "${ARIA_PID}" ]] && kill -0 "${ARIA_PID}" 2>/dev/null; then
    kill -TERM "${ARIA_PID}" 2>/dev/null || true
    wait "${ARIA_PID}" 2>/dev/null || true
  fi
  ARIA_PID=""
}

release_run_lock() {
  if [[ "${LOCK_HELD}" == "1" && -n "${LOCK_FD}" ]]; then
    flock -u "${LOCK_FD}" 2>/dev/null || true
    exec {LOCK_FD}>&-
    LOCK_FD=""
    LOCK_HELD=0
  fi
}

on_exit() {
  stop_progress_monitor
  stop_active_transfer
  release_run_lock
}

on_signal() {
  local signal_name="$1"
  local exit_code=143
  [[ "${signal_name}" == "INT" ]] && exit_code=130
  trap - ERR INT TERM
  HANDLING_FAILURE=1
  LAST_ERROR_CLASS="INTERRUPTED"
  CURRENT_STAGE="INTERRUPTED"
  stop_progress_monitor
  stop_active_transfer
  if [[ "${RUNTIME_INITIALIZED}" == "1" ]]; then
    warnlog "收到 SIG${signal_name}，保留现有文件和 .aria2 sidecar"
    finish_run "INTERRUPTED" "${exit_code}" "received SIG${signal_name}; resumable artifacts retained"
  fi
  exit "${exit_code}"
}

on_unhandled_error() {
  local exit_code="$1"
  local line="$2"
  local command="$3"
  local message
  [[ "${FINALIZED}" == "0" ]] || exit "${exit_code}"
  [[ "${HANDLING_FAILURE}" == "0" ]] || exit 30
  HANDLING_FAILURE=1
  trap - ERR
  LAST_ERROR_CLASS="INTERNAL_INVARIANT"
  CURRENT_STAGE="UNHANDLED_ERROR"
  message="unhandled error: original_exit=${exit_code} line=${line} command=$(sanitize_message "${command}")"
  if [[ "${RUNTIME_INITIALIZED}" == "1" ]]; then
    errlog "${message}"
    finish_run "BLOCKED" 30 "${message}"
  else
    printf '[uniprot] ERROR: %s\n' "${message}" >&2
  fi
  exit 30
}

init_runtime_state() {
  mkdir -p "${STATUS_DIR}" "${REPORT_DIR}" "${LOCK_DIR}"
  START_EPOCH="$(date +%s)"
  PROGRESS_BASE_EPOCH="${START_EPOCH}"
  printf 'timestamp\trun_id\tstate\texit_code\tstage\tattempt\terror_class\tmessage\n' > "${STATE_FILE}"
  printf 'timestamp\tepoch\trun_id\tattempt\ttarget_files\tcomplete_files\tpartial_files\ttarget_bytes\tpresent_bytes\telapsed_seconds\tspeed_10m_Bps\tspeed_30m_Bps\tspeed_60m_Bps\teta_seconds\tlast_error_class\n' > "${PROGRESS_FILE}"
  RUNTIME_INITIALIZED=1
  trap 'on_unhandled_error "$?" "${LINENO}" "${BASH_COMMAND}"' ERR
  trap 'on_signal INT' INT
  trap 'on_signal TERM' TERM
  trap 'on_exit' EXIT
  write_state "INITIALIZED" 0 "runtime paths initialized"
}

# The lock is derived from LOCAL_ROOT, so a different RUN_ROOT cannot bypass it.
acquire_run_lock() {
  local lock_digest
  require_command flock
  lock_digest="$(printf '%s' "${LOCAL_ROOT}" | sha256sum | awk '{print substr($1, 1, 16)}')"
  LOCK_FILE="$(dirname "${LOCAL_ROOT}")/.uniprot_download_${lock_digest}.lock"
  exec {LOCK_FD}>>"${LOCK_FILE}"
  if ! flock -w "${LOCK_WAIT_SECONDS}" "${LOCK_FD}"; then
    die "已有下载进程持有数据目录锁：${LOCK_FILE}"
  fi
  LOCK_HELD=1
  printf 'run_id=%s\npid=%s\nlocal_root=%s\nstarted_utc=%s\n' \
    "${RUN_ID}" "$$" "${LOCAL_ROOT}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "${LOCK_FILE}"
  printf 'lock_file\t%s\nlocal_root\t%s\nrun_id\t%s\n' \
    "${LOCK_FILE}" "${LOCAL_ROOT}" "${RUN_ID}" > "${LOCK_DIR}/lock_${lock_digest}.${RUN_ID}.tsv"
  write_state "LOCKED" 0 "exclusive lock acquired"
}

show_latest_status() {
  local status_file="${RUN_ROOT}/status/latest_status.tsv"
  local progress_file="${RUN_ROOT}/status/latest_progress.tsv"
  if [[ ! -r "${status_file}" ]]; then
    printf '[uniprot] No status snapshot: %s\n' "${status_file}" >&2
    exit 20
  fi
  cat "${status_file}"
  if [[ -r "${progress_file}" ]]; then
    printf '\n'
    cat "${progress_file}"
  fi
}

show_latest_summary() {
  local summary_file="${RUN_ROOT}/reports/latest_summary.md"
  if [[ ! -r "${summary_file}" ]]; then
    printf '[uniprot] No summary report: %s\n' "${summary_file}" >&2
    exit 20
  fi
  cat "${summary_file}"
}

print_dataset_catalog() {
  local dataset count bytes gib
  [[ -r "${MANIFEST_FILE}" ]] || die "manifest is not readable: ${MANIFEST_FILE}"

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

validate_nonnegative_int() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} 必须是非负整数，当前值为：${value}"
}

validate_aria_limits() {
  [[ "${ARIA2_CONNECTIONS}" -le 16 ]] || die "ARIA2_CONNECTIONS 不能超过 aria2 上限 16"
  [[ "${ARIA2_MIN_SPLIT_SIZE}" =~ ^([1-9][0-9]*)[Mm]$ ]] || \
    die "ARIA2_MIN_SPLIT_SIZE 必须位于 1M 到 1024M"
  (( 10#${BASH_REMATCH[1]} <= 1024 )) || die "ARIA2_MIN_SPLIT_SIZE 不能超过 1024M"
}

validate_config() {
  common_validate_download_config
  validate_aria_limits
  validate_flag CHECK_REMOTE_RELEASE "${CHECK_REMOTE_RELEASE}"
  validate_flag PLAN_ONLY "${PLAN_ONLY}"
  validate_flag VERIFY_ONLY "${VERIFY_ONLY}"
  validate_flag STATUS_ONLY "${STATUS_ONLY}"
  validate_flag SUMMARY_ONLY "${SUMMARY_ONLY}"
  validate_positive_int MIN_DISK_GB "${MIN_DISK_GB}"
  validate_positive_int DOWNLOAD_MAX_ATTEMPTS "${DOWNLOAD_MAX_ATTEMPTS}"
  validate_positive_int ARIA2_MAX_TRIES "${ARIA2_MAX_TRIES}"
  validate_nonnegative_int DOWNLOAD_RETRY_WAIT_SECONDS "${DOWNLOAD_RETRY_WAIT_SECONDS}"
  validate_nonnegative_int ARIA2_RETRY_WAIT_SECONDS "${ARIA2_RETRY_WAIT_SECONDS}"
  validate_nonnegative_int PROGRESS_INTERVAL_SECONDS "${PROGRESS_INTERVAL_SECONDS}"
  validate_nonnegative_int LOCK_WAIT_SECONDS "${LOCK_WAIT_SECONDS}"
  [[ "${CHECK_REMOTE_RELEASE}" == "1" ]] || die "CHECK_REMOTE_RELEASE 是强制安全门，不能设为 0"
  [[ "${VERIFY_AFTER_DOWNLOAD}" == "1" ]] || die "VERIFY_AFTER_DOWNLOAD 是强制安全门，不能设为 0"
  [[ "${SKIP_VERIFIED_FILES}" == "1" ]] || die "SKIP_VERIFIED_FILES 是幂等安全门，不能设为 0"
  [[ -n "${ARIA2_BIN}" ]] || die "ARIA2_BIN 不能为空"
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

# Progress snapshots use size only; repeated whole-file MD5 scans are reserved
# for verification boundaries because the selected payload may exceed 600 GB.
calculate_plan_progress() {
  local dataset relpath url local_file bytes md5 source_kind notes
  local actual_bytes capped_bytes
  PROGRESS_COMPLETE_FILES=0
  PROGRESS_PARTIAL_FILES=0
  PROGRESS_PRESENT_BYTES=0

  while IFS=$'\034' read -r dataset relpath url local_file bytes md5 source_kind notes; do
    [[ -f "${local_file}" ]] || continue
    actual_bytes="$(stat -c '%s' "${local_file}")"
    capped_bytes="${actual_bytes}"
    (( capped_bytes > bytes )) && capped_bytes="${bytes}"
    PROGRESS_PRESENT_BYTES=$((PROGRESS_PRESENT_BYTES + capped_bytes))
    if [[ ! -f "${local_file}.aria2" && "${actual_bytes}" == "${bytes}" ]]; then
      PROGRESS_COMPLETE_FILES=$((PROGRESS_COMPLETE_FILES + 1))
    else
      PROGRESS_PARTIAL_FILES=$((PROGRESS_PARTIAL_FILES + 1))
    fi
  done < <(plan_records)
}

progress_speed_for_window() {
  local now_epoch="$1"
  local present_bytes="$2"
  local window_seconds="$3"
  local cutoff prior_epoch prior_bytes elapsed delta
  cutoff=$((now_epoch - window_seconds))
  read -r prior_epoch prior_bytes < <(
    awk -F '\t' -v cutoff="${cutoff}" '
      NR > 1 && $2 <= cutoff {epoch=$2; bytes=$9}
      END {if (epoch != "") print epoch, bytes}
    ' "${PROGRESS_FILE}"
  ) || true
  prior_epoch="${prior_epoch:-${PROGRESS_BASE_EPOCH}}"
  prior_bytes="${prior_bytes:-${PROGRESS_BASE_BYTES}}"
  elapsed=$((now_epoch - prior_epoch))
  delta=$((present_bytes - prior_bytes))
  (( delta < 0 )) && delta=0
  if (( elapsed <= 0 )); then
    printf '0'
  else
    awk -v bytes="${delta}" -v seconds="${elapsed}" 'BEGIN {printf "%.3f", bytes / seconds}'
  fi
}

write_progress_snapshot() {
  local attempt="${1:-${CURRENT_ATTEMPT}}"
  local error_class="${2:-${LAST_ERROR_CLASS}}"
  local now_epoch timestamp elapsed speed_10m speed_30m speed_60m eta speed_for_eta remaining
  local temp_latest
  [[ -r "${PLAN_FILE}" ]] || return 0
  calculate_plan_progress
  now_epoch="$(date +%s)"
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  if [[ "${PROGRESS_BASE_SET}" == "0" ]]; then
    PROGRESS_BASE_BYTES="${PROGRESS_PRESENT_BYTES}"
    PROGRESS_BASE_EPOCH="${now_epoch}"
    PROGRESS_BASE_SET=1
  fi
  elapsed=$((now_epoch - START_EPOCH))
  speed_10m="$(progress_speed_for_window "${now_epoch}" "${PROGRESS_PRESENT_BYTES}" 600)"
  speed_30m="$(progress_speed_for_window "${now_epoch}" "${PROGRESS_PRESENT_BYTES}" 1800)"
  speed_60m="$(progress_speed_for_window "${now_epoch}" "${PROGRESS_PRESENT_BYTES}" 3600)"
  speed_for_eta="${speed_10m}"
  awk -v speed="${speed_for_eta}" 'BEGIN {exit !(speed <= 0)}' && speed_for_eta="${speed_30m}"
  remaining=$((TARGET_BYTES - PROGRESS_PRESENT_BYTES))
  (( remaining < 0 )) && remaining=0
  if (( remaining == 0 )); then
    eta=0
  elif awk -v speed="${speed_for_eta}" 'BEGIN {exit !(speed > 0)}'; then
    eta="$(awk -v bytes="${remaining}" -v speed="${speed_for_eta}" 'BEGIN {printf "%d", (bytes / speed) + 0.999}')"
  else
    eta=-1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${timestamp}" "${now_epoch}" "${RUN_ID}" "${attempt}" "${TARGET_COUNT}" \
    "${PROGRESS_COMPLETE_FILES}" "${PROGRESS_PARTIAL_FILES}" "${TARGET_BYTES}" \
    "${PROGRESS_PRESENT_BYTES}" "${elapsed}" "${speed_10m}" "${speed_30m}" \
    "${speed_60m}" "${eta}" "${error_class}" >> "${PROGRESS_FILE}"

  temp_latest="${LATEST_PROGRESS_FILE}.tmp.${RUN_ID}.$$"
  {
    sed -n '1p' "${PROGRESS_FILE}"
    tail -n 1 "${PROGRESS_FILE}"
  } > "${temp_latest}"
  mv -f -- "${temp_latest}" "${LATEST_PROGRESS_FILE}"
}

monitor_transfer_progress() {
  local attempt="$1"
  local parent_pid="$2"
  trap - ERR INT TERM EXIT
  (( PROGRESS_INTERVAL_SECONDS > 0 )) || return 0
  while kill -0 "${parent_pid}" 2>/dev/null; do
    write_progress_snapshot "${attempt}" "${LAST_ERROR_CLASS}"
    sleep "${PROGRESS_INTERVAL_SECONDS}"
  done
}

classify_transfer_failure() {
  local evidence_file="$1"
  [[ -r "${evidence_file}" ]] || {
    printf 'INTERNAL_INVARIANT'
    return 0
  }
  if grep -Eqi 'no space left|disk quota|read-only file system|input/output error' "${evidence_file}"; then
    printf 'STORAGE_BLOCKED'
  elif grep -Eqi 'checksum|hash mismatch|digest mismatch|integrity check|range not satisfiable|(^|[^0-9])416([^0-9]|$)' "${evidence_file}"; then
    printf 'VALIDATION_FAILED'
  elif grep -Eqi '(^|[^0-9])(401|403)([^0-9]|$)|unauthorized|forbidden|permission denied' "${evidence_file}"; then
    printf 'AUTH_CONFIG'
  elif grep -Eqi '(^|[^0-9])429([^0-9]|$)|too many requests|retry-after' "${evidence_file}"; then
    printf 'RATE_LIMITED'
  elif grep -Eqi '(^|[^0-9])(404|410)([^0-9]|$)|not found|gone' "${evidence_file}"; then
    printf 'REMOTE_PERMANENT'
  elif grep -Eqi '(^|[^0-9])(408|5[0-9][0-9])([^0-9]|$)|timeout|timed out|temporary failure|could not resolve|name resolution|tls|ssl|connection reset|connection refused|got eof|network is unreachable' "${evidence_file}"; then
    printf 'TRANSIENT_NETWORK'
  else
    printf 'INTERNAL_INVARIANT'
  fi
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
    if ! fetch_to_file "${url}" "${probe}"; then
      LAST_ERROR_CLASS="TRANSIENT_NETWORK"
      die "无法读取远端 release manifest：${url}"
    fi
    actual_bytes="$(stat -c '%s' "${probe}")"
    if [[ "${actual_bytes}" != "${bytes}" ]]; then
      move_to_trash "${probe}" "remote_manifest_size_mismatch"
      LAST_ERROR_CLASS="REMOTE_PERMANENT"
      die "远端 release manifest 大小已漂移：${relpath}，expected=${bytes} actual=${actual_bytes}"
    fi
    if ! grep -Fq "<version>${RELEASE}</version>" "${probe}"; then
      move_to_trash "${probe}" "remote_release_mismatch"
      LAST_ERROR_CLASS="REMOTE_PERMANENT"
      die "远端版本已不再是 ${RELEASE}：${url}。请先重新生成并审核清单。"
    fi
    count=$((count + 1))
  done < <(plan_records)

  if [[ "${count}" -ne "${#SELECTED_ORDER[@]}" ]]; then
    LAST_ERROR_CLASS="INTERNAL_INVARIANT"
    die "远端版本检查数量异常：expected=${#SELECTED_ORDER[@]} actual=${count}"
  fi
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

# This helper never mutates payloads. Callers decide whether invalid complete
# files should be quarantined or only reported.
file_is_valid_readonly() {
  local relpath="$1"
  local local_file="$2"
  local bytes="$3"
  local md5="$4"
  local source_kind="$5"
  local actual_bytes actual_md5
  VALIDATION_STATUS="FAIL"
  VALIDATION_DETAIL="unknown"

  if [[ ! -f "${local_file}" ]]; then
    VALIDATION_STATUS="MISSING"
    VALIDATION_DETAIL="missing"
    return 1
  fi
  if [[ -f "${local_file}.aria2" ]]; then
    VALIDATION_STATUS="PARTIAL"
    VALIDATION_DETAIL="aria2_sidecar_present"
    return 1
  fi

  actual_bytes="$(stat -c '%s' "${local_file}")"
  if [[ "${actual_bytes}" != "${bytes}" ]]; then
    VALIDATION_DETAIL="size expected=${bytes} actual=${actual_bytes}"
    return 1
  fi
  if [[ -n "${md5}" ]]; then
    actual_md5="$(md5sum "${local_file}" | awk '{print $1}')"
    if [[ "${actual_md5}" != "${md5}" ]]; then
      VALIDATION_DETAIL="md5 expected=${md5} actual=${actual_md5}"
      return 1
    fi
    VALIDATION_STATUS="PASS"
    VALIDATION_DETAIL="size+md5"
    return 0
  fi
  if [[ "${source_kind}" == "release_manifest" ]]; then
    if ! grep -Fq "<version>${RELEASE}</version>" "${local_file}"; then
      VALIDATION_DETAIL="release_version expected=${RELEASE}"
      return 1
    fi
    VALIDATION_STATUS="PASS"
    VALIDATION_DETAIL="size+release_version"
    return 0
  fi

  VALIDATION_DETAIL="missing_verification_rule relpath=${relpath}"
  return 1
}

verify_selected_files() {
  local quarantine_invalid="${1:-0}"
  local dataset relpath url local_file bytes md5 source_kind notes
  local total_failed=0
  VERIFY_PASS_COUNT=0
  VERIFY_FAIL_COUNT=0
  VERIFY_MISSING_COUNT=0
  VERIFY_PARTIAL_COUNT=0
  LAST_VALIDATION_STATUS_BY_PATH=()
  LAST_VALIDATION_DETAIL_BY_PATH=()
  : > "${VERIFY_REPORT}"
  printf 'relative_path\tstatus\tdetail\n' >> "${VERIFY_REPORT}"

  while IFS=$'\034' read -r dataset relpath url local_file bytes md5 source_kind notes; do
    if file_is_valid_readonly "${relpath}" "${local_file}" "${bytes}" "${md5}" "${source_kind}"; then
      VERIFY_PASS_COUNT=$((VERIFY_PASS_COUNT + 1))
      LAST_VALIDATION_STATUS_BY_PATH["${relpath}"]="PASS"
      LAST_VALIDATION_DETAIL_BY_PATH["${relpath}"]="${VALIDATION_DETAIL}"
      printf '%s\tPASS\t%s\n' "${relpath}" "${VALIDATION_DETAIL}" >> "${VERIFY_REPORT}"
      continue
    fi

    total_failed=$((total_failed + 1))
    LAST_VALIDATION_STATUS_BY_PATH["${relpath}"]="${VALIDATION_STATUS}"
    LAST_VALIDATION_DETAIL_BY_PATH["${relpath}"]="${VALIDATION_DETAIL}"
    case "${VALIDATION_STATUS}" in
      MISSING)
        VERIFY_MISSING_COUNT=$((VERIFY_MISSING_COUNT + 1))
        ;;
      PARTIAL)
        VERIFY_PARTIAL_COUNT=$((VERIFY_PARTIAL_COUNT + 1))
        ;;
      *)
        VERIFY_FAIL_COUNT=$((VERIFY_FAIL_COUNT + 1))
        if [[ "${quarantine_invalid}" == "1" && -f "${local_file}" && ! -f "${local_file}.aria2" ]]; then
          move_to_trash "${local_file}" "verification_failed"
        fi
        ;;
    esac
    printf '%s\t%s\t%s\n' "${relpath}" "${VALIDATION_STATUS}" "${VALIDATION_DETAIL}" >> "${VERIFY_REPORT}"
  done < <(plan_records)

  if (( total_failed > 0 )); then
    warnlog "校验未通过：pass=${VERIFY_PASS_COUNT} missing=${VERIFY_MISSING_COUNT} partial=${VERIFY_PARTIAL_COUNT} invalid=${VERIFY_FAIL_COUNT}；报告：${VERIFY_REPORT}"
    return 1
  fi
  log "校验通过：${VERIFY_PASS_COUNT} 个文件；报告：${VERIFY_REPORT}"
  return 0
}

build_repair_plan() {
  local round="$1"
  local dataset relpath url local_file bytes md5 source_kind notes
  local repair_status repair_detail
  local repair_count=0
  LAST_REPAIR_PLAN="${PLAN_DIR}/repair_plan_${RUN_ID}.attempt${round}.tsv"
  printf 'dataset\trelative_path\turl\tlocal_file\tbytes\tmd5\tsource_kind\tstatus\tdetail\n' > "${LAST_REPAIR_PLAN}"
  while IFS=$'\034' read -r dataset relpath url local_file bytes md5 source_kind notes; do
    if [[ -n "${LAST_VALIDATION_STATUS_BY_PATH[${relpath}]+x}" ]]; then
      repair_status="${LAST_VALIDATION_STATUS_BY_PATH[${relpath}]}"
      repair_detail="${LAST_VALIDATION_DETAIL_BY_PATH[${relpath}]}"
    elif file_is_valid_readonly "${relpath}" "${local_file}" "${bytes}" "${md5}" "${source_kind}"; then
      repair_status="PASS"
      repair_detail="${VALIDATION_DETAIL}"
    else
      repair_status="${VALIDATION_STATUS}"
      repair_detail="${VALIDATION_DETAIL}"
    fi
    if [[ "${repair_status}" == "PASS" ]]; then
      continue
    fi
    repair_count=$((repair_count + 1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${dataset}" "${relpath}" "${url}" "${local_file}" "${bytes}" "${md5}" \
      "${source_kind}" "${repair_status}" "${repair_detail}" >> "${LAST_REPAIR_PLAN}"
  done < <(plan_records)
  log "修复计划已生成：${LAST_REPAIR_PLAN}；待修复 ${repair_count} 个文件"
}

# One outer round gets independent console, transport, and failure-evidence logs.
run_aria2_attempt() {
  local attempt="$1"
  local aria_status=0 parent_pid
  LAST_ATTEMPT_LOG="${LOG_DIR}/aria2_console_${RUN_ID}.attempt${attempt}.log"
  LAST_TRANSPORT_LOG="${LOG_DIR}/aria2_transport_${RUN_ID}.attempt${attempt}.log"
  LAST_ATTEMPT_EVIDENCE="${LOG_DIR}/aria2_failure_${RUN_ID}.attempt${attempt}.log"
  : > "${LAST_ATTEMPT_LOG}"
  : > "${LAST_ATTEMPT_EVIDENCE}"

  check_disk_space
  log "启动 aria2 round ${attempt}/${DOWNLOAD_MAX_ATTEMPTS}：files=${DOWNLOAD_COUNT} max_concurrent=${ARIA2_MAX_CONCURRENT} connections=${ARIA2_CONNECTIONS} split=${ARIA2_SPLIT} aria_max_tries=${ARIA2_MAX_TRIES} aria_retry_wait=${ARIA2_RETRY_WAIT_SECONDS}s"

  parent_pid="${BASHPID}"
  if (( PROGRESS_INTERVAL_SECONDS > 0 )); then
    monitor_transfer_progress "${attempt}" "${parent_pid}" &
    MONITOR_PID=$!
  fi

  "${ARIA2_BIN}" \
    --input-file="${ARIA_INPUT}" \
    --continue=true \
    --auto-file-renaming=false \
    --allow-overwrite=true \
    --check-integrity=true \
    --max-connection-per-server="${ARIA2_CONNECTIONS}" \
    --split="${ARIA2_SPLIT}" \
    --max-concurrent-downloads="${ARIA2_MAX_CONCURRENT}" \
    --min-split-size="${ARIA2_MIN_SPLIT_SIZE}" \
    --retry-wait="${ARIA2_RETRY_WAIT_SECONDS}" \
    --max-tries="${ARIA2_MAX_TRIES}" \
    --timeout=600 \
    --connect-timeout=60 \
    --console-log-level=notice \
    --summary-interval="${ARIA2_SUMMARY_INTERVAL}" \
    --log="${LAST_TRANSPORT_LOG}" \
    --log-level=info > "${LAST_ATTEMPT_LOG}" 2>&1 &
  ARIA_PID=$!
  if wait "${ARIA_PID}"; then
    aria_status=0
  else
    aria_status=$?
  fi
  ARIA_PID=""
  stop_progress_monitor
  write_progress_snapshot "${attempt}" "${LAST_ERROR_CLASS}"

  {
    printf '# console log\n'
    cat "${LAST_ATTEMPT_LOG}"
    if [[ -r "${LAST_TRANSPORT_LOG}" ]]; then
      printf '\n# transport log\n'
      cat "${LAST_TRANSPORT_LOG}"
    fi
  } > "${LAST_ATTEMPT_EVIDENCE}"

  if [[ "${aria_status}" -ne 0 ]]; then
    errlog "aria2 round ${attempt} 失败：exit=${aria_status}；证据：${LAST_ATTEMPT_EVIDENCE}"
    tail -n 30 "${LAST_ATTEMPT_EVIDENCE}" | while IFS= read -r line; do
      [[ -n "${line}" ]] && errlog "  ${line}"
    done || true
    return "${aria_status}"
  fi
  log "aria2 round ${attempt} 进程正常结束；进入强校验"
  return 0
}

# Reconcile actual files after every aria2 exit. A nonzero transport exit is
# accepted when all targets nevertheless pass the frozen size/checksum contract.
run_download_with_recovery() {
  local attempt aria_status
  CURRENT_STAGE="TRANSFER_PREP"
  for ((attempt = 1; attempt <= DOWNLOAD_MAX_ATTEMPTS; attempt++)); do
    CURRENT_ATTEMPT="${attempt}"
    write_aria_input
    write_progress_snapshot "${attempt}" "${LAST_ERROR_CLASS}"

    if (( DOWNLOAD_COUNT == 0 )); then
      CURRENT_STAGE="VERIFYING"
      if verify_selected_files 1; then
        LAST_ERROR_CLASS="NONE"
        finish_run "COMPLETE" 0 "all selected files were already complete and verified"
        return 0
      fi
      LAST_ERROR_CLASS="VALIDATION_FAILED"
      build_repair_plan "${attempt}"
    else
      CURRENT_STAGE="TRANSFERRING"
      write_state "TRANSFERRING" 0 "aria2 round ${attempt} started"
      if run_aria2_attempt "${attempt}"; then
        aria_status=0
        LAST_ERROR_CLASS="NONE"
      else
        aria_status=$?
        LAST_ERROR_CLASS="$(classify_transfer_failure "${LAST_ATTEMPT_EVIDENCE}")"
        quarantine_invalid_completed_files
      fi

      CURRENT_STAGE="VERIFYING"
      write_state "VERIFYING" "${aria_status}" "strong verification after aria2 round ${attempt}"
      if verify_selected_files 1; then
        LAST_ERROR_CLASS="NONE"
        finish_run "COMPLETE" 0 "all selected files passed size and checksum/release validation"
        return 0
      fi
      [[ "${LAST_ERROR_CLASS}" != "NONE" ]] || LAST_ERROR_CLASS="VALIDATION_FAILED"
      build_repair_plan "${attempt}"
    fi

    case "${LAST_ERROR_CLASS}" in
      STORAGE_BLOCKED|AUTH_CONFIG|INTERNAL_INVARIANT)
        CURRENT_STAGE="RECOVERY_BLOCKED"
        exit_with_state "BLOCKED" 30 "recovery blocked by ${LAST_ERROR_CLASS}; repair plan: ${LAST_REPAIR_PLAN}"
        ;;
      REMOTE_PERMANENT)
        CURRENT_STAGE="RECOVERY_EXHAUSTED"
        exit_with_state "NEEDS_REPAIR" 20 "remote target is permanently unavailable; repair plan: ${LAST_REPAIR_PLAN}"
        ;;
    esac

    if (( attempt >= DOWNLOAD_MAX_ATTEMPTS )); then
      CURRENT_STAGE="RECOVERY_EXHAUSTED"
      exit_with_state "NEEDS_REPAIR" 20 "retry budget exhausted; repair plan: ${LAST_REPAIR_PLAN}"
    fi
    CURRENT_STAGE="RECOVERING"
    write_state "RECOVERING" 0 "${LAST_ERROR_CLASS}; next round in ${DOWNLOAD_RETRY_WAIT_SECONDS}s"
    if (( DOWNLOAD_RETRY_WAIT_SECONDS > 0 )); then
      sleep "${DOWNLOAD_RETRY_WAIT_SECONDS}"
    fi
  done
}

main() {
  parse_args "$@"

  if [[ "${LIST_DATASETS}" == "1" ]]; then
    require_command awk
    require_command sha256sum
    validate_manifest
    print_dataset_catalog
    return 0
  fi

  if [[ "${STATUS_ONLY}" == "1" ]]; then
    command -v readlink >/dev/null 2>&1 || die "缺少命令：readlink"
    validate_safe_run_root
    show_latest_status
    return 0
  fi
  if [[ "${SUMMARY_ONLY}" == "1" ]]; then
    command -v readlink >/dev/null 2>&1 || die "缺少命令：readlink"
    validate_safe_run_root
    show_latest_summary
    return 0
  fi

  command -v readlink >/dev/null 2>&1 || die "缺少命令：readlink"
  validate_safe_roots

  init_runtime_paths
  init_control_dirs
  init_runtime_state
  require_command awk
  require_command install
  require_command md5sum
  require_command readlink
  require_command sed
  require_command sha256sum
  require_command stat
  validate_config
  resolve_datasets
  build_download_plan

  log "========== UniProt ${RELEASE} =========="
  log "数据根目录：${LOCAL_ROOT}"
  log "运行目录：${RUN_ROOT}"

  if [[ "${PLAN_ONLY}" == "1" ]]; then
    CURRENT_STAGE="PLANNED"
    log "PLAN_ONLY=1：未访问网络，未启动下载"
    cat "${PLAN_FILE}"
    finish_run "PLANNED" 0 "network-free plan generated"
    return 0
  fi

  if [[ "${VERIFY_ONLY}" == "1" ]]; then
    CURRENT_STAGE="VERIFYING"
    if verify_selected_files 0; then
      finish_run "COMPLETE" 0 "read-only verification passed"
      return 0
    fi
    LAST_ERROR_CLASS="VALIDATION_FAILED"
    build_repair_plan 0
    exit_with_state "NEEDS_REPAIR" 20 "read-only verification found incomplete targets; repair plan: ${LAST_REPAIR_PLAN}"
  fi

  require_command curl
  require_command "${ARIA2_BIN}"
  acquire_run_lock
  CURRENT_STAGE="REMOTE_PREFLIGHT"
  write_state "PREFLIGHT" 0 "checking frozen release manifests"
  verify_remote_release
  run_download_with_recovery

  log "========== UniProt ${RELEASE} 下载完成 =========="
  log "下载计划：${PLAN_FILE}"
  log "校验报告：${VERIFY_REPORT}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
