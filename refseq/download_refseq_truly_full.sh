#!/usr/bin/env bash
# =============================================================================
# NCBI RefSeq release 下载脚本（目标集 manifest 版）
#
# 运行环境：Ubuntu/Linux 服务器，已安装 curl、aria2c、GNU awk/grep、md5sum
#
# 说明：
#   1. 下载 RefSeq release 下 13 个分类目录的主要序列/flatfile 文件。
#   2. complete/ 目录仅下载 bna 与 complete.wp_protein.*，避免重复拉取 complete
#      目录中已经在分类目录出现的 fasta/flatfile 导出。
#   3. 自动生成 logs/target_files.tsv，校验脚本只校验本次目标集。
#   4. RefSeq release FTP 不提供 genomic.gff3.gz；GFF3 需另走 assembly/genomes
#      或 NCBI Datasets 工作流。
# =============================================================================
set -euo pipefail

# ==================== 配置区 ====================
RELEASE="235"
BASE_URL="https://ftp.ncbi.nlm.nih.gov/refseq/release"
LOCAL_ROOT="/data/refseq_release"          # 改成 Ubuntu 服务器上的实际存储路径

LOG_DIR="${LOCAL_ROOT}/logs"
DL_LOG="${LOG_DIR}/download.log"
ERR_LOG="${LOG_DIR}/error.log"
STATE_FILE="${LOG_DIR}/state.txt"
MD5_FILE="${LOCAL_ROOT}/release${RELEASE}.files.installed"
TARGET_MANIFEST="${LOG_DIR}/target_files.tsv"
UNVERIFIED_MANIFEST="${LOG_DIR}/unverified_files.tsv"
TRASH_DIR="${LOCAL_ROOT}/垃圾箱"
STRICT_MD5="${STRICT_MD5:-0}"

# MD5 查找表：一次性加载，避免每个文件启动一次 awk。
declare -A MD5_MAP
MD5_MAP_LOADED=0
APPEND_UNVERIFIED_COUNT=0

TARGET_DIRS=(
  bacteria
  archaea
  fungi
  plant
  invertebrate
  protozoa
  vertebrate_mammalian
  vertebrate_other
  viral
  mitochondrion
  plasmid
  plastid
  other
)

# RefSeq release FTP 的官方序列/flatfile 导出格式；GFF3 不在该 release FTP 中。
TARGET_SUFFIXES=(
  "genomic.fna.gz"
  "genomic.gbff.gz"
  "protein.faa.gz"
  "protein.gpff.gz"
  "rna.fna.gz"
  "rna.gbff.gz"
)

# complete/ 目录仅取本脚本目标集中的特殊文件。
COMPLETE_EXCLUSIVE_PATTERNS=(
  ".bna.gz"
  "complete.wp_protein."
)

ARIA2_CONNECTIONS=4
ARIA2_MAX_CONCURRENT=8
ARIA2_SPLIT=4
MIN_DISK_GB=200

# ==================== 初始化 ====================
mkdir -p "${LOG_DIR}"
mkdir -p "${TRASH_DIR}"
mkdir -p "${LOCAL_ROOT}/complete"
for d in "${TARGET_DIRS[@]}"; do
  mkdir -p "${LOCAL_ROOT}/${d}"
done

log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${DL_LOG}" >&2; }
errlog(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" | tee -a "${ERR_LOG}" >&2; }

move_to_trash() {
  local path="$1"
  local label="${2:-$(basename "${path}")}"
  [[ -e "${path}" ]] || return 0
  mkdir -p "${TRASH_DIR}"
  local stamp dest
  stamp=$(date -u '+%Y%m%dT%H%M%SZ')
  dest="${TRASH_DIR}/${label}.${stamp}.$$"
  mv -- "${path}" "${dest}"
  log "已将旧文件移入垃圾箱：${dest}"
}

fetch() {
  curl -fL --retry 5 --retry-delay 10 --retry-connrefused "$@"
}

check_disk_space() {
  local avail_gb
  avail_gb=$(df -BG "${LOCAL_ROOT}" | awk 'NR==2 {gsub("G","",$4); print $4}')
  log "可用磁盘空间：${avail_gb} GB（阈值 ${MIN_DISK_GB} GB）"
  if [[ "${avail_gb}" -lt "${MIN_DISK_GB}" ]]; then
    errlog "磁盘空间不足：剩余 ${avail_gb} GB < 阈值 ${MIN_DISK_GB} GB，终止下载"
    exit 1
  fi
}

prepare_state_file() {
  if [[ -e "${STATE_FILE}" ]]; then
    move_to_trash "${STATE_FILE}" "state.previous"
  fi
  : > "${STATE_FILE}"
}

# ==================== MD5 查找表 ====================
load_md5_map() {
  if [[ ${MD5_MAP_LOADED} -eq 1 ]]; then
    return 0
  fi
  if [[ ! -f "${MD5_FILE}" ]]; then
    errlog "MD5 文件不存在：${MD5_FILE}，无法生成 manifest"
    return 1
  fi
  local count=0
  while IFS=$'\t' read -r md5 filepath; do
    [[ -z "${filepath:-}" ]] && continue
    [[ "${md5}" == \#* ]] && continue
    MD5_MAP["${filepath}"]="${md5}"
    count=$((count + 1))
  done < "${MD5_FILE}"
  MD5_MAP_LOADED=1
  log "  MD5 查找表已加载：${count} 条记录"
}

# ==================== Manifest 写入 ====================
write_manifest_header() {
  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  {
    printf "# release\t%s\n" "${RELEASE}"
    printf "# download_started\t%s\n" "${timestamp}"
    printf "# base_url\t%s\n" "${BASE_URL}"
  } >> "${TARGET_MANIFEST}"
}

write_unverified_header() {
  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  {
    printf "# release\t%s\n" "${RELEASE}"
    printf "# download_started\t%s\n" "${timestamp}"
    printf "# base_url\t%s\n" "${BASE_URL}"
    printf "# columns\trelative_path\treason\n"
  } >> "${UNVERIFIED_MANIFEST}"
}

finalize_manifest() {
  local tmp="${TARGET_MANIFEST}.data.$$"
  local timestamp started_line
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  started_line=$(grep '^# download_started' "${TARGET_MANIFEST}" | head -1 || true)
  grep -v '^#' "${TARGET_MANIFEST}" > "${tmp}" 2>/dev/null || true
  {
    printf "# release\t%s\n" "${RELEASE}"
    if [[ -n "${started_line}" ]]; then
      printf "%s\n" "${started_line}"
    else
      printf "# download_started\tunknown\n"
    fi
    printf "# download_finished\t%s\n" "${timestamp}"
    printf "# base_url\t%s\n" "${BASE_URL}"
    sort -u "${tmp}"
  } > "${TARGET_MANIFEST}"
  move_to_trash "${tmp}" "target_files.data.tmp"
}

finalize_unverified_manifest() {
  local tmp="${UNVERIFIED_MANIFEST}.data.$$"
  local timestamp started_line
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  started_line=$(grep '^# download_started' "${UNVERIFIED_MANIFEST}" | head -1 || true)
  grep -v '^#' "${UNVERIFIED_MANIFEST}" > "${tmp}" 2>/dev/null || true
  {
    printf "# release\t%s\n" "${RELEASE}"
    if [[ -n "${started_line}" ]]; then
      printf "%s\n" "${started_line}"
    else
      printf "# download_started\tunknown\n"
    fi
    printf "# download_finished\t%s\n" "${timestamp}"
    printf "# base_url\t%s\n" "${BASE_URL}"
    printf "# columns\trelative_path\treason\n"
    sort -u "${tmp}"
  } > "${UNVERIFIED_MANIFEST}"
  move_to_trash "${tmp}" "unverified_files.data.tmp"
}

append_manifest_from_list() {
  local dir="$1"
  local list_file="$2"
  local fname relpath md5
  local missing=0
  local tmp_manifest="${LOG_DIR}/manifest_${dir}.tmp.$$"
  local tmp_unverified="${LOG_DIR}/unverified_${dir}.tmp.$$"
  APPEND_UNVERIFIED_COUNT=0
  : > "${tmp_manifest}"
  : > "${tmp_unverified}"

  while IFS= read -r fname; do
    [[ -z "${fname}" ]] && continue
    relpath="${dir}/${fname}"
    md5="${MD5_MAP[${relpath}]:-}"
    if [[ -z "${md5}" ]]; then
      errlog "MD5 catalog 中找不到目标文件：${relpath}"
      missing=$((missing + 1))
      printf "%s\t%s\n" "${relpath}" "NO_MD5_IN_CATALOG" >> "${tmp_unverified}"
      continue
    fi
    printf "%s\t%s\n" "${md5}" "${relpath}" >> "${tmp_manifest}"
  done < "${list_file}"

  if [[ ${missing} -gt 0 ]]; then
    errlog "${dir}：${missing} 个文件在 MD5 catalog 中未找到；继续下载，并写入 ${UNVERIFIED_MANIFEST}"
  fi

  cat "${tmp_manifest}" >> "${TARGET_MANIFEST}"
  cat "${tmp_unverified}" >> "${UNVERIFIED_MANIFEST}"
  move_to_trash "${tmp_manifest}" "manifest_${dir}.tmp"
  move_to_trash "${tmp_unverified}" "unverified_${dir}.tmp"
  APPEND_UNVERIFIED_COUNT="${missing}"
  return 0
}

generate_file_list() {
  local dir="$1"
  local list_file="${LOG_DIR}/filelist_${dir}.txt"
  local filtered="${LOG_DIR}/filelist_${dir}_filtered.txt"
  local url="${BASE_URL}/${dir}/"
  local suffix

  log "  正在生成 ${dir} 文件清单..."
  if ! fetch -s "${url}" \
      | grep -oP 'href="\K[^"]+\.gz' \
      | sort -u \
      > "${list_file}"; then
    errlog "拉取 ${dir} 目录列表失败或未解析到 .gz 文件"
    errlog "  URL: ${url}"
    errlog "  原因: 网络不可达、HTTP 错误或目录页面无 .gz 文件"
    return 1
  fi

  : > "${filtered}"
  for suffix in "${TARGET_SUFFIXES[@]}"; do
    awk -v s="${suffix}" 'length($0) >= length(s) && substr($0, length($0)-length(s)+1) == s' "${list_file}" >> "${filtered}"
  done
  sort -u -o "${filtered}" "${filtered}"

  log "    ${dir}：待下载 $(wc -l < "${filtered}") 个文件"
  echo "${filtered}"
}

generate_complete_list() {
  local list_file="${LOG_DIR}/filelist_complete.txt"
  local filtered="${LOG_DIR}/filelist_complete_filtered.txt"
  local url="${BASE_URL}/complete/"
  local pattern

  log "  正在生成 complete 目录文件清单（bna + complete.wp_protein）..."
  if ! fetch -s "${url}" \
      | grep -oP 'href="\K[^"]+\.gz' \
      | sort -u \
      > "${list_file}"; then
    errlog "拉取 complete 目录列表失败或未解析到 .gz 文件"
    errlog "  URL: ${url}"
    errlog "  原因: 网络不可达、HTTP 错误或目录页面无 .gz 文件"
    return 1
  fi

  : > "${filtered}"
  for pattern in "${COMPLETE_EXCLUSIVE_PATTERNS[@]}"; do
    grep -F "${pattern}" "${list_file}" >> "${filtered}" 2>/dev/null || true
  done
  sort -u -o "${filtered}" "${filtered}"

  log "    complete：待下载 $(wc -l < "${filtered}") 个文件"
  echo "${filtered}"
}

write_aria_input() {
  local dir="$1"
  local filtered="$2"
  local aria_input="$3"
  local fname

  : > "${aria_input}"
  while IFS= read -r fname; do
    [[ -z "${fname}" ]] && continue
    printf "%s\n  out=%s\n" "${BASE_URL}/${dir}/${fname}" "${fname}" >> "${aria_input}"
  done < "${filtered}"
}

run_aria2() {
  local aria_input="$1"
  local out_dir="$2"
  local log_name="$3"

  aria2c \
    --input-file="${aria_input}" \
    --dir="${out_dir}" \
    --continue=true \
    --auto-file-renaming=false \
    --max-connection-per-server="${ARIA2_CONNECTIONS}" \
    --split="${ARIA2_SPLIT}" \
    --max-concurrent-downloads="${ARIA2_MAX_CONCURRENT}" \
    --min-split-size=10M \
    --retry-wait=10 \
    --max-tries=5 \
    --timeout=300 \
    --connect-timeout=60 \
    --console-log-level=notice \
    --summary-interval=30 \
    --log="${LOG_DIR}/${log_name}" \
    --log-level=info
}

report_aria_failure() {
  local name="$1"
  local exit_code="$2"
  local log_file="$3"

  # aria2c 常见退出码映射
  local exit_meaning
  case "${exit_code}" in
    1)  exit_meaning="文件未找到（远程文件不存在或已被移除）";;
    2)  exit_meaning="超时（连接超时或响应超时）";;
    3)  exit_meaning="磁盘空间不足或写入权限问题";;
    4)  exit_meaning="网络异常（连接被重置、DNS 解析失败等）";;
    5)  exit_meaning="下载未完成（部分文件校验失败）";;
    6)  exit_meaning="远程文件已变更（ETag/大小不一致）";;
    7)  exit_meaning="aria2c 内部错误";;
    8)  exit_meaning="aria2c 内部错误";;
    9)  exit_meaning="aria2c 内部错误";;
    22)  exit_meaning="HTTP 错误（如 404/403/500）";;
    23)  exit_meaning="重定向次数过多";;
    *)  exit_meaning="未知错误";;
  esac

  errlog "${name} 下载异常（aria2c 退出码 ${exit_code}：${exit_meaning}）"
  errlog "  详细日志：${log_file}"
  if [[ -f "${log_file}" ]]; then
    local failed_in_aria
    failed_in_aria=$(grep -iE '(error|failed|abort|exception)' "${log_file}" | tail -20 || true)
    if [[ -n "${failed_in_aria}" ]]; then
      errlog "  aria2c 日志中的异常项（末尾 20 行）："
      while IFS= read -r line; do
        errlog "    ${line}"
      done <<< "${failed_in_aria}"
    fi
  fi
}

download_dir() {
  local dir="$1"
  local filtered
  local aria_input="${LOG_DIR}/aria_input_${dir}.txt"

  if ! filtered=$(generate_file_list "${dir}"); then
    echo "${dir}:FAILED" >> "${STATE_FILE}"
    return 3
  fi
  if [[ ! -s "${filtered}" ]]; then
    log "  ${dir}：无匹配文件，跳过"
    echo "${dir}:SKIPPED" >> "${STATE_FILE}"
    return 0
  fi

  if ! append_manifest_from_list "${dir}" "${filtered}"; then
    echo "${dir}:FAILED" >> "${STATE_FILE}"
    return 3
  fi
  local unverified_count="${APPEND_UNVERIFIED_COUNT}"
  write_aria_input "${dir}" "${filtered}" "${aria_input}"

  log "  开始下载 ${dir}（aria2c 并行=${ARIA2_MAX_CONCURRENT}）..."
  if run_aria2 "${aria_input}" "${LOCAL_ROOT}/${dir}" "aria2_${dir}.log"; then
    log "  ${dir} 下载完成"
    if [[ "${unverified_count}" -gt 0 ]]; then
      echo "${dir}:DONE_WITH_UNVERIFIED:${unverified_count}" >> "${STATE_FILE}"
    else
      echo "${dir}:DONE" >> "${STATE_FILE}"
    fi
    return 0
  else
    local aria_exit_code=$?
    report_aria_failure "${dir}" "${aria_exit_code}" "${LOG_DIR}/aria2_${dir}.log"
    echo "${dir}:PARTIAL" >> "${STATE_FILE}"
    return 2
  fi
}

download_complete() {
  local filtered
  local aria_input="${LOG_DIR}/aria_input_complete.txt"

  if ! filtered=$(generate_complete_list); then
    echo "complete:FAILED" >> "${STATE_FILE}"
    return 3
  fi
  if [[ ! -s "${filtered}" ]]; then
    log "  complete：无目标文件，跳过"
    echo "complete:SKIPPED" >> "${STATE_FILE}"
    return 0
  fi

  if ! append_manifest_from_list "complete" "${filtered}"; then
    echo "complete:FAILED" >> "${STATE_FILE}"
    return 3
  fi
  local unverified_count="${APPEND_UNVERIFIED_COUNT}"
  write_aria_input "complete" "${filtered}" "${aria_input}"

  log "  开始下载 complete 目标文件（aria2c 并行=${ARIA2_MAX_CONCURRENT}）..."
  if run_aria2 "${aria_input}" "${LOCAL_ROOT}/complete" "aria2_complete.log"; then
    log "  complete 目标文件下载完成"
    if [[ "${unverified_count}" -gt 0 ]]; then
      echo "complete:DONE_WITH_UNVERIFIED:${unverified_count}" >> "${STATE_FILE}"
    else
      echo "complete:DONE" >> "${STATE_FILE}"
    fi
    return 0
  else
    local aria_exit_code=$?
    report_aria_failure "complete" "${aria_exit_code}" "${LOG_DIR}/aria2_complete.log"
    echo "complete:PARTIAL" >> "${STATE_FILE}"
    return 2
  fi
}

download_metadata() {
  log "下载 MD5 校验文件..."
  local md5_url="${BASE_URL}/release-catalog/release${RELEASE}.files.installed"
  if ! fetch -s -o "${MD5_FILE}" "${md5_url}"; then
    errlog "MD5 catalog 下载失败"
    errlog "  URL: ${md5_url}"
    errlog "  目标路径: ${MD5_FILE}"
    errlog "  原因: 网络不可达、HTTP 错误或磁盘写入失败"
    errlog "  影响: 无法生成 manifest，后续校验无法执行"
    exit 1
  fi
  log "MD5 校验文件：${MD5_FILE}（$(wc -l < "${MD5_FILE}") 条记录）"

  log "下载 release catalog（约 3.3 GB，可用于后续物种/accession 索引）..."
  local catalog_url="${BASE_URL}/release-catalog/RefSeq-release${RELEASE}.catalog.gz"
  if ! fetch -o "${LOCAL_ROOT}/RefSeq-release${RELEASE}.catalog.gz" "${catalog_url}"; then
    log "  [WARN] release catalog 下载失败"
    log "        URL: ${catalog_url}"
    log "        不影响序列文件下载，可后续单独下载"
  fi

  log "下载 release statistics..."
  local stats_url="${BASE_URL}/release-statistics/"
  fetch -s "${stats_url}" \
    | grep -oP 'href="\K[^"]+\.txt' \
    | head -5 \
    | while read -r statfile; do
        fetch -s -o "${LOCAL_ROOT}/${statfile}" "${BASE_URL}/release-statistics/${statfile}"
      done || {
        log "  [WARN] statistics 下载不完整"
        log "        URL: ${stats_url}"
        log "        不影响主流程"
      }
}

main() {
  log "========== RefSeq release${RELEASE} 目标集下载 =========="
  log "本地根目录：${LOCAL_ROOT}"
  log "目标目录：${TARGET_DIRS[*]} + complete（bna + complete.wp_protein）"
  log "目标后缀：${TARGET_SUFFIXES[*]}"
  log "注意：RefSeq release FTP 不提供 genomic.gff3.gz；GFF3 需另走 assembly/genomes 或 NCBI Datasets。"
  log ""

  log "文件类型说明："
  log "  genomic.fna.gz  — 基因组 FASTA（D1 Track 1 核苷酸 MLM）"
  log "  genomic.gbff.gz — GenBank 注释（D4 CDS-蛋白对提取 + 密码子 Track 2）"
  log "  protein.faa.gz  — 蛋白质 FASTA（D4 蛋白序列补充）"
  log "  protein.gpff.gz — GenBank 蛋白质格式（注释补充）"
  log "  rna.fna.gz      — RNA FASTA（D3 RNA 补充）"
  log "  rna.gbff.gz     — GenBank RNA 格式（注释补充）"
  log "  bna.gz          — 二进制 ASN.1 注释（complete 目录）"
  log ""

  check_disk_space
  download_metadata
  load_md5_map

  if [[ -e "${TARGET_MANIFEST}" ]]; then
    move_to_trash "${TARGET_MANIFEST}" "target_files.previous"
  fi
  if [[ -e "${UNVERIFIED_MANIFEST}" ]]; then
    move_to_trash "${UNVERIFIED_MANIFEST}" "unverified_files.previous"
  fi
  : > "${TARGET_MANIFEST}"
  : > "${UNVERIFIED_MANIFEST}"
  write_manifest_header
  write_unverified_header
  prepare_state_file

  local total_dirs=${#TARGET_DIRS[@]}
  local done_count=0
  local partial_count=0
  local skipped_count=0
  local unverified_dirs=()
  local failed_dirs=()

  for dir in "${TARGET_DIRS[@]}"; do
    check_disk_space
    if download_dir "${dir}"; then
      if grep -Fxq "${dir}:SKIPPED" "${STATE_FILE}"; then
        skipped_count=$((skipped_count + 1))
      else
        done_count=$((done_count + 1))
        if grep -Eq "^${dir}:DONE_WITH_UNVERIFIED:" "${STATE_FILE}"; then
          unverified_dirs+=("${dir}")
        fi
      fi
    else
      local status=$?
      if [[ ${status} -eq 2 ]]; then
        partial_count=$((partial_count + 1))
      else
        failed_dirs+=("${dir}")
      fi
    fi
  done

  local complete_status="DONE"
  check_disk_space
  if download_complete; then
    if grep -Fxq "complete:SKIPPED" "${STATE_FILE}"; then
      complete_status="SKIPPED"
    elif grep -Eq "^complete:DONE_WITH_UNVERIFIED:" "${STATE_FILE}"; then
      complete_status="DONE_WITH_UNVERIFIED"
    fi
  else
    local status=$?
    if [[ ${status} -eq 2 ]]; then
      complete_status="PARTIAL"
    else
      complete_status="FAILED"
    fi
  fi

  finalize_manifest
  finalize_unverified_manifest

  local unverified_count
  unverified_count=$(grep -Evc '^(#|[[:space:]]*$)' "${UNVERIFIED_MANIFEST}" 2>/dev/null || true)

  log ""
  log "========== 下载总结 =========="
  log "  分类目录：${total_dirs} 个"
  log "  完成：${done_count} 个"
  log "  跳过：${skipped_count} 个"
  log "  部分完成（PARTIAL）：${partial_count} 个"
  log "  含未 MD5 校验文件的分类目录：${#unverified_dirs[@]} 个"
  log "  未 MD5 校验文件：${unverified_count} 个"
  log "  complete 状态：${complete_status}"
  if [[ ${#failed_dirs[@]} -gt 0 ]]; then
    errlog "  失败目录：${failed_dirs[*]}"
  fi
  log "  目标 manifest：${TARGET_MANIFEST}"
  log "  未 MD5 校验清单：${UNVERIFIED_MANIFEST}"
  log "  状态文件：${STATE_FILE}"
  log ""

  if [[ ${partial_count} -gt 0 || ${#failed_dirs[@]} -gt 0 || "${complete_status}" == "PARTIAL" || "${complete_status}" == "FAILED" ]]; then
    log "  ⚠ 有目录未完全下载。可重跑本脚本续传（aria2c --continue=true 自动跳过已完成文件）。"
    log "  下一步：先重跑下载脚本；补齐后再运行 bash verify_refseq_truly_full.sh ${LOCAL_ROOT}"
    exit 1
  fi

  if [[ "${STRICT_MD5}" == "1" && "${unverified_count}" -gt 0 ]]; then
    errlog "STRICT_MD5=1 且存在 ${unverified_count} 个无 MD5 文件，本轮按失败处理"
    exit 1
  fi

  if [[ "${unverified_count}" -gt 0 ]]; then
    log "  ⚠ 存在无 MD5 catalog 条目的文件；这些文件已下载，但需在验证阶段做 gzip CRC/解析检查。"
  fi

  log "  全部目标目录下载完成。"
  log "  下一步：bash verify_refseq_truly_full.sh ${LOCAL_ROOT}"
}

main "$@"