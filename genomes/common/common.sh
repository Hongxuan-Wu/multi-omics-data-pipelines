#!/usr/bin/env bash
# =============================================================================
# Common helpers for genome database downloaders
#
# 约束：
#   1. 只放跨数据库通用逻辑：日志、目录、校验、断点续传、异常文件隔离。
#   2. 不放任何数据库专属下载流程。
#   3. 不删除文件；异常文件只移动到 TRASH_DIR。
#   4. USE_PROXY 只作为开关占位。脚本不会自动设置代理变量。
# =============================================================================
set -euo pipefail

COMMON_VERSION="1.0"

common_require_version() {
  local required="$1"
  [[ "${COMMON_VERSION}" == "${required}" ]] || {
    printf '[ERROR] common.sh 版本不兼容：required=%s actual=%s\n' "${required}" "${COMMON_VERSION}" >&2
    exit 1
  }
}

common_init_dirs() {
  mkdir -p "${LOCAL_ROOT}" "${RUN_ROOT}" "${LOG_DIR}" "${PLAN_DIR}" "${MANIFEST_DIR}" "${TMP_DIR}" "${TRASH_DIR}"
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${DL_LOG}" >&2
}

errlog() {
  printf '[%s] [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${ERR_LOG}" >&2
}

die() {
  errlog "$*"
  exit 1
}

require_command() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "缺少命令：${cmd}。请先在 Linux 服务器安装后重跑脚本。"
}

validate_flag() {
  local name="$1"
  local value="$2"
  case "${value}" in
    0|1) ;;
    *) die "${name} 必须是 0 或 1，当前值为：${value}" ;;
  esac
}

validate_positive_int() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || die "${name} 必须是正整数，当前值为：${value}"
}

validate_size_value() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[1-9][0-9]*[KkMmGgTt]$ ]] || die "${name} 必须是正整数加单位，例如 64M 或 128M，当前值为：${value}"
}

common_validate_download_config() {
  validate_flag USE_PROXY "${USE_PROXY}"
  validate_positive_int ARIA2_CONNECTIONS "${ARIA2_CONNECTIONS}"
  validate_positive_int ARIA2_MAX_CONCURRENT "${ARIA2_MAX_CONCURRENT}"
  validate_positive_int ARIA2_SPLIT "${ARIA2_SPLIT}"
  validate_positive_int ARIA2_SUMMARY_INTERVAL "${ARIA2_SUMMARY_INTERVAL}"
  validate_size_value ARIA2_MIN_SPLIT_SIZE "${ARIA2_MIN_SPLIT_SIZE}"
  validate_flag VERIFY_AFTER_DOWNLOAD "${VERIFY_AFTER_DOWNLOAD}"
  validate_flag SKIP_VERIFIED_FILES "${SKIP_VERIFIED_FILES}"

  if [[ "${USE_PROXY}" == "1" ]]; then
    log "USE_PROXY=1。脚本不会自动设置代理；请在运行前自行 export http_proxy/https_proxy/all_proxy。"
  fi
}

safe_name() {
  printf '%s' "$1" | tr '/: ?&=' '_______'
}

move_to_trash() {
  local path="$1"
  local reason="$2"
  local rel_label
  local dest
  local suffix=1

  [[ -e "${path}" ]] || return 0
  rel_label="$(printf '%s' "${path#${LOCAL_ROOT}/}" | tr '/: ' '___')"
  dest="${TRASH_DIR}/${reason}.${RUN_ID}.${rel_label}"
  mkdir -p "${TRASH_DIR}"
  while [[ -e "${dest}" ]]; do
    dest="${TRASH_DIR}/${reason}.${RUN_ID}.${rel_label}.${suffix}"
    suffix=$((suffix + 1))
  done
  mv -- "${path}" "${dest}"
  log "已将异常本地文件移入 trash：${path} -> ${dest}"
}

fetch_to_stdout() {
  local url="$1"
  curl -fsSL --retry 5 --retry-delay 10 --retry-connrefused --retry-all-errors "${url}"
}

fetch_to_file() {
  local url="$1"
  local out="$2"
  local tmp_out="${out}.partial.${RUN_ID}"
  mkdir -p "$(dirname "${out}")"
  if ! curl -fsSL --retry 5 --retry-delay 10 --retry-connrefused --retry-all-errors -o "${tmp_out}" "${url}"; then
    move_to_trash "${tmp_out}" "failed_fetch"
    return 1
  fi
  if [[ ! -s "${tmp_out}" ]]; then
    move_to_trash "${tmp_out}" "empty_fetch"
    return 1
  fi
  mv -- "${tmp_out}" "${out}"
}

probe_remote_file() {
  local url="$1"
  curl -fsSI --retry 3 --retry-delay 5 --retry-connrefused --retry-all-errors "${url}" >/dev/null
}

remote_content_length() {
  local url="$1"
  curl -fsSI --retry 3 --retry-delay 5 --retry-connrefused --retry-all-errors "${url}" \
    | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {gsub("\r","",$2); len=$2} END{print len}'
}

check_disk_space() {
  local avail_gb
  avail_gb=$(df -BG "${LOCAL_ROOT}" | awk 'NR==2 {gsub("G","",$4); print $4}')
  [[ -n "${avail_gb}" ]] || die "无法读取磁盘剩余空间：${LOCAL_ROOT}"
  log "可用磁盘空间：${avail_gb} GB（阈值 ${MIN_DISK_GB} GB）"
  if [[ "${avail_gb}" -lt "${MIN_DISK_GB}" ]]; then
    die "磁盘空间不足：剩余 ${avail_gb} GB < 阈值 ${MIN_DISK_GB} GB。"
  fi
}

weak_verify_file() {
  local file="$1"
  local relpath="$2"
  if [[ ! -s "${file}" ]]; then
    errlog "弱校验失败：文件缺失或为空：${relpath}"
    move_to_trash "${file}" "weak_verify_empty"
    return 1
  fi
  case "${file}" in
    *.gz|*.tgz)
      if ! gzip -t "${file}"; then
        errlog "弱校验失败：gzip CRC 不通过：${relpath}"
        move_to_trash "${file}" "weak_verify_gzip_failed"
        return 1
      fi
      ;;
    *)
      [[ -s "${file}" ]] || {
        errlog "弱校验失败：非 gzip 文件为空：${relpath}"
        move_to_trash "${file}" "weak_verify_empty"
        return 1
      }
      ;;
  esac
  return 0
}

existing_file_is_complete() {
  local relpath="$1"
  local url="$2"
  local local_file="$3"
  local expected_md5="${4:-}"
  local actual_md5
  local local_size
  local remote_size

  [[ "${SKIP_VERIFIED_FILES}" == "1" ]] || return 1
  [[ -f "${local_file}" ]] || return 1
  [[ -f "${local_file}.aria2" ]] && return 1

  if [[ -n "${expected_md5}" ]]; then
    actual_md5="$(md5sum "${local_file}" | awk '{print $1}')"
    if [[ "${actual_md5}" == "${expected_md5}" ]]; then
      log "跳过已完成文件（官方 MD5 匹配）：${relpath}"
      return 0
    fi
    errlog "本地文件 MD5 不匹配，将重新下载：${relpath}，expected=${expected_md5}，actual=${actual_md5}"
    move_to_trash "${local_file}" "md5_mismatch"
    return 1
  fi

  local_size="$(stat -c '%s' "${local_file}")"
  remote_size="$(remote_content_length "${url}" || true)"
  if [[ -n "${remote_size}" && "${remote_size}" =~ ^[0-9]+$ && "${local_size}" -eq "${remote_size}" ]]; then
    if [[ "${relpath}" == *.gz || "${relpath}" == *.tgz ]]; then
      if gzip -t "${local_file}"; then
        log "跳过已完成文件（大小匹配 + gzip CRC 通过）：${relpath}"
        return 0
      fi
      move_to_trash "${local_file}" "gzip_crc_failed"
      return 1
    fi
    log "跳过已完成文件（大小匹配 + 非空）：${relpath}"
    return 0
  fi

  move_to_trash "${local_file}" "incomplete_or_unknown_size"
  return 1
}

run_aria2_input() {
  local group="$1"
  local input_file="$2"
  local log_file="${LOG_DIR}/aria2_${group}_${RUN_ID}.log"
  local file_count

  file_count=$(grep -Ec '^(https?|ftp|ftps)://' "${input_file}" || true)
  if [[ "${file_count}" -eq 0 ]]; then
    log "${group} 无下载目标，跳过 aria2。"
    return 0
  fi

  check_disk_space
  log "开始下载 ${group}：文件数 ${file_count}，aria2 并发=${ARIA2_MAX_CONCURRENT}，单服务器连接=${ARIA2_CONNECTIONS}，split=${ARIA2_SPLIT}"
  if aria2c \
      --input-file="${input_file}" \
      --continue=true \
      --auto-file-renaming=false \
      --allow-overwrite=true \
      --max-connection-per-server="${ARIA2_CONNECTIONS}" \
      --split="${ARIA2_SPLIT}" \
      --max-concurrent-downloads="${ARIA2_MAX_CONCURRENT}" \
      --min-split-size="${ARIA2_MIN_SPLIT_SIZE}" \
      --retry-wait=30 \
      --max-tries=10 \
      --timeout=600 \
      --connect-timeout=60 \
      --console-log-level=notice \
      --summary-interval="${ARIA2_SUMMARY_INTERVAL}" \
      --log="${log_file}" \
      --log-level=info; then
    log "${group} 下载完成。"
  else
    local exit_code=$?
    errlog "${group} 下载失败：aria2c exit=${exit_code}，日志：${log_file}"
    if [[ -f "${log_file}" ]]; then
      grep -iE 'error|failed|exception|abort|timeout|not complete|429|403|404|503' "${log_file}" | tail -30 | while IFS= read -r line; do
        errlog "  ${line}"
      done || true
    fi
    return "${exit_code}"
  fi
}
