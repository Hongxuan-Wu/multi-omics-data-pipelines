#!/usr/bin/env bash
# =============================================================================
# NCBI RefSeq release downloader
#
# 目标：
#   1. 将 https://ftp.ncbi.nlm.nih.gov/refseq/release/ 的目标数据镜像到
#      /data3/p252701008/refseq_release，并保持远端目录结构。
#   2. 用 3 个 0/1 开关分别控制 complete、物种分类目录、辅助信息下载。
#   3. complete 与物种分类目录按远端目录 listing 全量下载，不按后缀过滤。
#   4. RefSeq-release*.catalog.gz 使用 aria2c 下载。
#   5. 官方 MD5 用于下载前跳过、aria2 单文件校验和下载后复核。
# =============================================================================
set -euo pipefail

# ==================== 用户配置 ====================
# RELEASE：目标 RefSeq release 编号。
RELEASE="235"
# BASE_URL：NCBI RefSeq release 远端根 URL；所有下载 URL 都由它拼接得到。
BASE_URL="https://ftp.ncbi.nlm.nih.gov/refseq/release"
# LOCAL_ROOT：本地镜像根目录，目录结构严格对应 BASE_URL 下的相对路径。
LOCAL_ROOT="/data3/p252701008/refseq_release"

# 三类下载开关：1=下载，0=不下载。
# DOWNLOAD_COMPLETE：是否下载 complete/ 目录。
DOWNLOAD_COMPLETE=1
# DOWNLOAD_TAXON_DIRS：是否下载 TAXON_DIRS 中列出的物种/分类目录。
DOWNLOAD_TAXON_DIRS=1
# DOWNLOAD_AUXILIARY：是否下载 README、release-catalog 核心文件和 release-statistics/。
DOWNLOAD_AUXILIARY=1

# aria2c 参数。最大并发连接数约等于 ARIA2_MAX_CONCURRENT * ARIA2_CONNECTIONS。
# ARIA2_CONNECTIONS：单个服务器最大连接数，对应 aria2c --max-connection-per-server。
ARIA2_CONNECTIONS=4
# ARIA2_MAX_CONCURRENT：同时下载的文件数，对应 aria2c --max-concurrent-downloads。
ARIA2_MAX_CONCURRENT=6
# ARIA2_SPLIT：单个文件最多切片数，对应 aria2c --split。
ARIA2_SPLIT=4
# ARIA2_MIN_SPLIT_SIZE：启用切片的最小文件大小，对应 aria2c --min-split-size。
ARIA2_MIN_SPLIT_SIZE="128M"
# ARIA2_SUMMARY_INTERVAL：aria2c 控制台进度汇总间隔，单位秒。
ARIA2_SUMMARY_INTERVAL=120

# 下载完成后是否立即做 MD5 校验：1=校验，0=只生成校验清单。
# VERIFY_MD5_AFTER_DOWNLOAD：是否在 aria2 全部完成后立刻执行官方 MD5 强校验。
VERIFY_MD5_AFTER_DOWNLOAD=1
# 对没有官方 MD5 的文件，下载完成后做弱校验：gzip 文件跑 gzip -t，非 gzip 文件检查非空。
# VERIFY_UNVERIFIED_AFTER_DOWNLOAD：是否对无官方 MD5 文件执行 gzip/非空弱校验。
VERIFY_UNVERIFIED_AFTER_DOWNLOAD=1
# 写 aria2 输入前检查本地已有文件；已通过完整性判断的文件不再交给 aria2。
# SKIP_VERIFIED_FILES：是否在生成 aria2 输入前跳过已校验完整的本地文件。
SKIP_VERIFIED_FILES=1

# 下载前磁盘保护阈值。
# MIN_DISK_GB：每次关键阶段前要求 LOCAL_ROOT 所在分区至少保留的 GB 数。
MIN_DISK_GB=2000

# 运行日志与清单不放入 LOCAL_ROOT，避免污染 RefSeq release 镜像目录。
# RUN_ROOT：运行日志、下载计划、manifest、临时文件的根目录。
RUN_ROOT="/data3/p252701008/refseq_release_runlogs"
# TRASH_DIR：异常本地文件的隔离目录；脚本不删除文件，只移动到这里。
TRASH_DIR="${RUN_ROOT}/垃圾箱"

# RefSeq release 物种/分类目录。complete 与辅助目录不在这里。
# TAXON_DIRS：需要递归镜像的 RefSeq 物种/分类目录列表。
TAXON_DIRS=(
  archaea
  bacteria
  fungi
  invertebrate
  mitochondrion
  other
  plant
  plasmid
  plastid
  protozoa
  vertebrate_mammalian
  vertebrate_other
  viral
)

# 辅助信息范围：
#   - release-catalog/RefSeq-release${RELEASE}.catalog.gz：accession catalog，aria2 下载。
#   - release-catalog/release${RELEASE}.files.installed：官方 MD5 清单，始终需要。
#   - release-catalog/README：catalog 字段说明。
#   - release-statistics/：完整递归下载，用于 release 统计核对。
#   - README 与 RELEASE_NUMBER：release 根目录说明文件。
# AUX_ROOT_FILES：release 根目录下要下载的辅助文件名。
AUX_ROOT_FILES=(
  README
  RELEASE_NUMBER
)
# AUX_RELEASE_CATALOG_FILES：release-catalog/ 下要下载的辅助文件名。
AUX_RELEASE_CATALOG_FILES=(
  README
  "RefSeq-release${RELEASE}.catalog.gz"
  "release${RELEASE}.files.installed"
)

# ==================== 派生路径 ====================
# RUN_ID：本次运行唯一标识，用 UTC 时间和进程号区分日志/清单。
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ').$$"
# LOG_DIR：普通日志与错误日志目录。
LOG_DIR="${RUN_ROOT}/logs"
# PLAN_DIR：下载计划和 aria2 input 文件目录。
PLAN_DIR="${RUN_ROOT}/plans"
# MANIFEST_DIR：官方 MD5 manifest、无 MD5 manifest、md5sum 校验文件目录。
MANIFEST_DIR="${RUN_ROOT}/manifests"
# TMP_DIR：本次运行的远端目录 listing 临时缓存目录。
TMP_DIR="${RUN_ROOT}/tmp/${RUN_ID}"

# DL_LOG：主流程日志文件。
DL_LOG="${LOG_DIR}/download_${RUN_ID}.log"
# ERR_LOG：错误日志文件。
ERR_LOG="${LOG_DIR}/error_${RUN_ID}.log"
# STATE_FILE：三类下载任务的最终状态记录。
STATE_FILE="${RUN_ROOT}/state_${RUN_ID}.tsv"
# PLAN_FILE：完整下载计划，列出 group、relative_path、url、local_dir、out_name。
PLAN_FILE="${PLAN_DIR}/download_plan_${RUN_ID}.tsv"
# ARIA_INPUT_COMPLETE：complete 组的 aria2 input 文件。
ARIA_INPUT_COMPLETE="${PLAN_DIR}/aria_complete_${RUN_ID}.txt"
# ARIA_INPUT_TAXON：物种/分类目录组的 aria2 input 文件。
ARIA_INPUT_TAXON="${PLAN_DIR}/aria_taxon_${RUN_ID}.txt"
# ARIA_INPUT_AUXILIARY：辅助信息组的 aria2 input 文件。
ARIA_INPUT_AUXILIARY="${PLAN_DIR}/aria_auxiliary_${RUN_ID}.txt"
# TARGET_MANIFEST：有官方 MD5 的目标文件清单。
TARGET_MANIFEST="${MANIFEST_DIR}/target_files_${RUN_ID}.tsv"
# UNVERIFIED_MANIFEST：无官方 MD5 的目标文件清单。
UNVERIFIED_MANIFEST="${MANIFEST_DIR}/unverified_files_${RUN_ID}.tsv"
# MD5_CHECK_FILE：供 md5sum --check 使用的校验文件。
MD5_CHECK_FILE="${MANIFEST_DIR}/md5_check_${RUN_ID}.txt"
# MD5_FILE：本地保存的 NCBI 官方 release${RELEASE}.files.installed 文件。
MD5_FILE="${LOCAL_ROOT}/release-catalog/release${RELEASE}.files.installed"

# MD5_MAP：官方 MD5 映射表，key 通常是文件名，也兼容相对路径查询。
declare -A MD5_MAP

# ==================== 日志与基础工具 ====================
# 初始化本次运行需要的所有目录。
mkdir -p "${LOCAL_ROOT}" "${RUN_ROOT}" "${LOG_DIR}" "${PLAN_DIR}" "${MANIFEST_DIR}" "${TMP_DIR}" "${TRASH_DIR}"

# 记录普通日志，同时写入 stderr 和 DL_LOG。
log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${DL_LOG}" >&2
}

# 记录错误日志，同时写入 stderr 和 ERR_LOG。
errlog() {
  printf '[%s] [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${ERR_LOG}" >&2
}

# 输出错误并终止脚本。
die() {
  errlog "$*"
  exit 1
}

# 检查必需命令是否存在。
require_command() {
  # cmd：要检查的可执行命令名。
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "缺少命令：${cmd}。请先安装后重跑脚本。"
}

# 校验 0/1 开关变量。
validate_flag() {
  # name：变量名，用于错误提示。
  local name="$1"
  # value：变量当前值，必须为 0 或 1。
  local value="$2"
  case "${value}" in
    0|1) ;;
    *) die "${name} 必须是 0 或 1，当前值为：${value}" ;;
  esac
}

# 校验 aria2 文件大小参数，要求带 K/M/G/T 单位。
validate_size_value() {
  # name：变量名，用于错误提示。
  local name="$1"
  # value：变量当前值，例如 64M 或 128M。
  local value="$2"
  case "${value}" in
    *K|*M|*G|*T|*k|*m|*g|*t) ;;
    *) die "${name} 必须带单位，例如 64M 或 128M，当前值为：${value}" ;;
  esac
}

# 将相对路径转换为安全文件名片段，用于临时文件命名。
safe_name() {
  printf '%s' "$1" | tr '/: ' '___'
}

# 用 curl 读取远端内容并输出到 stdout。
fetch_to_stdout() {
  # url：要读取的远端 URL。
  local url="$1"
  curl -fsSL --retry 5 --retry-delay 10 --retry-connrefused --retry-all-errors "${url}"
}

# 用 curl 下载单个文件到指定路径。
fetch_to_file() {
  # url：要下载的远端 URL。
  local url="$1"
  # out：本地输出文件路径。
  local out="$2"
  mkdir -p "$(dirname "${out}")"
  curl -fsSL --retry 5 --retry-delay 10 --retry-connrefused --retry-all-errors -o "${out}" "${url}"
}

# 只探测远端文件是否可访问，不保存内容。
probe_remote_file() {
  # url：要探测的远端 URL。
  local url="$1"
  curl -fsSI --retry 5 --retry-delay 10 --retry-connrefused --retry-all-errors "${url}" >/dev/null
}

# 检查 LOCAL_ROOT 所在文件系统的可用空间是否达到阈值。
check_disk_space() {
  # avail_gb：LOCAL_ROOT 所在分区剩余空间，单位 GB。
  local avail_gb
  avail_gb=$(df -BG "${LOCAL_ROOT}" | awk 'NR==2 {gsub("G","",$4); print $4}')
  [[ -n "${avail_gb}" ]] || die "无法读取磁盘剩余空间：${LOCAL_ROOT}"
  log "可用磁盘空间：${avail_gb} GB（阈值 ${MIN_DISK_GB} GB）"
  if [[ "${avail_gb}" -lt "${MIN_DISK_GB}" ]]; then
    die "磁盘空间不足：剩余 ${avail_gb} GB < 阈值 ${MIN_DISK_GB} GB。请释放空间或调低 MIN_DISK_GB 后重跑。"
  fi
}

# 校验用户配置项，提前暴露错误参数。
validate_config() {
  validate_flag DOWNLOAD_COMPLETE "${DOWNLOAD_COMPLETE}"
  validate_flag DOWNLOAD_TAXON_DIRS "${DOWNLOAD_TAXON_DIRS}"
  validate_flag DOWNLOAD_AUXILIARY "${DOWNLOAD_AUXILIARY}"
  validate_flag VERIFY_MD5_AFTER_DOWNLOAD "${VERIFY_MD5_AFTER_DOWNLOAD}"
  validate_flag VERIFY_UNVERIFIED_AFTER_DOWNLOAD "${VERIFY_UNVERIFIED_AFTER_DOWNLOAD}"
  validate_flag SKIP_VERIFIED_FILES "${SKIP_VERIFIED_FILES}"
  validate_size_value ARIA2_MIN_SPLIT_SIZE "${ARIA2_MIN_SPLIT_SIZE}"

  if [[ "${DOWNLOAD_COMPLETE}" == "0" && "${DOWNLOAD_TAXON_DIRS}" == "0" && "${DOWNLOAD_AUXILIARY}" == "0" ]]; then
    die "三个下载开关都为 0，没有任何目标需要下载。"
  fi

  [[ "${ARIA2_CONNECTIONS}" =~ ^[0-9]+$ ]] || die "ARIA2_CONNECTIONS 必须是正整数，当前值为：${ARIA2_CONNECTIONS}"
  [[ "${ARIA2_MAX_CONCURRENT}" =~ ^[0-9]+$ ]] || die "ARIA2_MAX_CONCURRENT 必须是正整数，当前值为：${ARIA2_MAX_CONCURRENT}"
  [[ "${ARIA2_SPLIT}" =~ ^[0-9]+$ ]] || die "ARIA2_SPLIT 必须是正整数，当前值为：${ARIA2_SPLIT}"
  [[ "${ARIA2_SUMMARY_INTERVAL}" =~ ^[0-9]+$ ]] || die "ARIA2_SUMMARY_INTERVAL 必须是非负整数，当前值为：${ARIA2_SUMMARY_INTERVAL}"

  if [[ "${ARIA2_CONNECTIONS}" -lt 1 || "${ARIA2_MAX_CONCURRENT}" -lt 1 || "${ARIA2_SPLIT}" -lt 1 ]]; then
    die "ARIA2_CONNECTIONS、ARIA2_MAX_CONCURRENT、ARIA2_SPLIT 都必须大于 0。"
  fi
}

# 将校验失败或无法确认完整性的本地文件移入垃圾箱，避免覆盖前丢失原文件。
move_to_trash() {
  # path：需要隔离的本地文件路径。
  local path="$1"
  # reason：隔离原因，会作为垃圾箱文件名前缀。
  local reason="$2"
  # rel_label：由本地相对路径转换出的安全文件名片段。
  local rel_label
  # dest：垃圾箱中的最终目标路径。
  local dest

  [[ -e "${path}" ]] || return 0
  rel_label="$(printf '%s' "${path#${LOCAL_ROOT}/}" | tr '/: ' '___')"
  dest="${TRASH_DIR}/${reason}.${RUN_ID}.${rel_label}"
  mkdir -p "${TRASH_DIR}"
  mv -- "${path}" "${dest}"
  log "已将异常本地文件移入垃圾箱：${path} -> ${dest}"
}

# 读取远端文件的 Content-Length，用于无官方 MD5 文件的大小校验。
remote_content_length() {
  # url：要读取 HTTP header 的远端文件 URL。
  local url="$1"
  curl -fsSI --retry 5 --retry-delay 10 --retry-connrefused --retry-all-errors "${url}" \
    | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {gsub("\r","",$2); len=$2} END{print len}'
}

# ==================== 远端目录解析 ====================
# 从 NCBI HTML 目录 listing 中提取 href 值。
extract_hrefs() {
  awk '
    {
      # line：当前 HTML 行的剩余待解析片段。
      line = $0
      while (match(line, /href="[^"]+"/)) {
        # href：当前匹配到的链接目标。
        href = substr(line, RSTART + 6, RLENGTH - 7)
        print href
        line = substr(line, RSTART + RLENGTH)
      }
    }
  '
}

# 判断 href 是否应忽略，例如父目录、绝对 URL、锚点或查询链接。
is_skipped_href() {
  # href：目录 listing 中解析出的原始 href 字符串。
  local href="$1"
  case "${href}" in
    ""|"/"*|"http://"*|"https://"*|"?"*|"#"*) return 0 ;;
    "../") return 0 ;;
    *) return 1 ;;
  esac
}

# 读取一个远端目录 listing，并解析为 file/dir 记录。
list_remote_dir() {
  # rel_dir：相对 BASE_URL 的目录路径；空字符串表示 release 根目录。
  local rel_dir="$1"
  # out_file：解析后的 TSV 输出文件。
  local out_file="$2"
  # url：当前目录的完整 URL。
  local url
  # index_file：当前目录 HTML listing 的本地临时缓存文件。
  local index_file
  # href：extract_hrefs 输出的原始链接。
  local href
  # name：去掉目录尾部斜杠后的文件名或目录名。
  local name
  # child_rel：当前条目相对 BASE_URL 的路径。
  local child_rel

  if [[ -z "${rel_dir}" ]]; then
    url="${BASE_URL}/"
  else
    url="${BASE_URL}/${rel_dir}/"
  fi

  index_file="${TMP_DIR}/index_$(safe_name "${rel_dir:-root}").html"
  log "读取远端目录：${url}"
  if ! fetch_to_stdout "${url}" > "${index_file}"; then
    die "无法读取远端目录 listing：${url}。请检查网络、代理或 NCBI 服务状态。"
  fi

  : > "${out_file}"
  while IFS= read -r href; do
    if is_skipped_href "${href}"; then
      continue
    fi

    if [[ "${href}" == */ ]]; then
      name="${href%/}"
      [[ -n "${name}" ]] || continue
      if [[ -z "${rel_dir}" ]]; then
        child_rel="${name}"
      else
        child_rel="${rel_dir}/${name}"
      fi
      printf 'dir\t%s\t%s\t%s\n' "${href}" "${name}" "${child_rel}" >> "${out_file}"
    else
      name="${href}"
      if [[ -z "${rel_dir}" ]]; then
        child_rel="${name}"
      else
        child_rel="${rel_dir}/${name}"
      fi
      printf 'file\t%s\t%s\t%s\n' "${href}" "${name}" "${child_rel}" >> "${out_file}"
    fi
  done < <(extract_hrefs < "${index_file}")

  if [[ ! -s "${out_file}" ]]; then
    die "远端目录 listing 为空或解析失败：${url}"
  fi
}

# 向 PLAN_FILE 追加一条下载任务记录。
append_plan_record() {
  # group：下载分组，取 complete、taxon 或 auxiliary。
  local group="$1"
  # relpath：目标文件相对 BASE_URL/LOCAL_ROOT 的路径。
  local relpath="$2"
  # url：目标文件完整下载 URL。
  local url="$3"
  # local_dir：目标文件应写入的本地目录。
  local local_dir
  # out_name：目标文件本地文件名。
  local out_name

  local_dir="${LOCAL_ROOT}/$(dirname "${relpath}")"
  if [[ "$(dirname "${relpath}")" == "." ]]; then
    local_dir="${LOCAL_ROOT}"
  fi
  out_name="$(basename "${relpath}")"

  printf '%s\t%s\t%s\t%s\t%s\n' "${group}" "${relpath}" "${url}" "${local_dir}" "${out_name}" >> "${PLAN_FILE}"
}

# 递归或非递归收集远端目录树下的所有文件，写入下载计划。
collect_remote_tree() {
  # group：下载分组，取 complete、taxon 或 auxiliary。
  local group="$1"
  # root_rel：要遍历的远端起始目录，相对 BASE_URL。
  local root_rel="$2"
  # recursive：是否递归子目录，1=递归，0=只收集当前层文件。
  local recursive="$3"
  # queue：待遍历目录队列。
  local -a queue
  # seen：已遍历目录集合，防止重复解析。
  local -A seen
  # current：当前正在解析的目录。
  local current
  # entries：当前目录解析后的 TSV 临时文件。
  local entries
  # kind：目录条目类型，file 或 dir。
  local kind
  # href：目录 listing 中的原始 href。
  local href
  # name：目录条目的文件名或目录名。
  local name
  # child_rel：目录条目相对 BASE_URL 的路径。
  local child_rel
  # i：queue 的当前读取下标。
  local i=0
  # files_added：本次目录树收集到的文件数量。
  local files_added=0

  queue=("${root_rel}")
  while (( i < ${#queue[@]} )); do
    current="${queue[$i]}"
    i=$((i + 1))

    if [[ -n "${seen[${current}]:-}" ]]; then
      continue
    fi
    seen["${current}"]=1

    entries="${TMP_DIR}/entries_$(safe_name "${current}").tsv"
    list_remote_dir "${current}" "${entries}"

    while IFS=$'\t' read -r kind href name child_rel; do
      case "${kind}" in
        file)
          append_plan_record "${group}" "${child_rel}" "${BASE_URL}/${child_rel}"
          files_added=$((files_added + 1))
          ;;
        dir)
          if [[ "${recursive}" == "1" ]]; then
            queue+=("${child_rel}")
          fi
          ;;
        *)
          die "目录 listing 解析出未知条目类型：${kind}，目录：${current}"
          ;;
      esac
    done < "${entries}"
  done

  log "${group}:${root_rel} 计划下载文件数：${files_added}"
}

# 校验指定远端文件存在后，将其加入下载计划。
append_existing_remote_file() {
  # group：下载分组，通常为 auxiliary。
  local group="$1"
  # relpath：目标文件相对 BASE_URL 的路径。
  local relpath="$2"
  # url：目标文件完整下载 URL。
  local url="${BASE_URL}/${relpath}"

  if ! probe_remote_file "${url}"; then
    die "辅助文件不存在或不可访问：${url}"
  fi
  append_plan_record "${group}" "${relpath}" "${url}"
}

# 根据三类下载开关生成完整下载计划。
build_download_plan() {
  : > "${PLAN_FILE}"
  printf '# group\trelative_path\turl\tlocal_dir\tout_name\n' >> "${PLAN_FILE}"

  if [[ "${DOWNLOAD_COMPLETE}" == "1" ]]; then
    collect_remote_tree "complete" "complete" "1"
  else
    log "跳过 complete/：DOWNLOAD_COMPLETE=0"
  fi

  if [[ "${DOWNLOAD_TAXON_DIRS}" == "1" ]]; then
    # dir：当前要遍历的物种/分类目录名。
    local dir
    for dir in "${TAXON_DIRS[@]}"; do
      collect_remote_tree "taxon" "${dir}" "1"
    done
  else
    log "跳过物种分类目录：DOWNLOAD_TAXON_DIRS=0"
  fi

  if [[ "${DOWNLOAD_AUXILIARY}" == "1" ]]; then
    # root_file：release 根目录下的辅助文件名。
    local root_file
    # catalog_file：release-catalog/ 下的辅助文件名。
    local catalog_file
    for root_file in "${AUX_ROOT_FILES[@]}"; do
      append_existing_remote_file "auxiliary" "${root_file}"
    done
    for catalog_file in "${AUX_RELEASE_CATALOG_FILES[@]}"; do
      append_existing_remote_file "auxiliary" "release-catalog/${catalog_file}"
    done
    collect_remote_tree "auxiliary" "release-statistics" "1"
  else
    log "跳过辅助信息：DOWNLOAD_AUXILIARY=0"
  fi

  # planned_count：PLAN_FILE 中实际下载任务数量，不含注释和空行。
  local planned_count
  planned_count=$(grep -Evc '^(#|[[:space:]]*$)' "${PLAN_FILE}" || true)
  [[ "${planned_count}" -gt 0 ]] || die "下载计划为空。请检查三个下载开关和远端目录 listing。"
  log "下载计划生成完成：${PLAN_FILE}，文件数 ${planned_count}"
}

# ==================== MD5 清单与校验 ====================
# 下载 NCBI 官方 MD5 清单 release${RELEASE}.files.installed。
download_md5_file() {
  # md5_url：官方 MD5 清单的远端 URL。
  local md5_url="${BASE_URL}/release-catalog/release${RELEASE}.files.installed"
  log "下载官方 MD5 清单：${md5_url}"
  if ! fetch_to_file "${md5_url}" "${MD5_FILE}"; then
    die "官方 MD5 清单下载失败：${md5_url} -> ${MD5_FILE}。没有该文件无法建立可靠校验清单。"
  fi
  [[ -s "${MD5_FILE}" ]] || die "官方 MD5 清单为空：${MD5_FILE}"
  log "官方 MD5 清单已保存：${MD5_FILE}（$(wc -l < "${MD5_FILE}") 行）"
}

# 将官方 MD5 清单读入 MD5_MAP，供跳过、aria2 checksum 和下载后校验使用。
load_md5_map() {
  # md5：当前行的 MD5 值。
  local md5
  # filepath：当前行记录的文件名或相对路径。
  local filepath
  # count：成功解析到 MD5_MAP 的条目数。
  local count=0

  while IFS=$'\t' read -r md5 filepath; do
    [[ -n "${md5:-}" && -n "${filepath:-}" ]] || continue
    [[ "${md5}" == \#* ]] && continue
    MD5_MAP["${filepath}"]="${md5}"
    count=$((count + 1))
  done < "${MD5_FILE}"

  [[ "${count}" -gt 0 ]] || die "官方 MD5 清单未解析到任何记录：${MD5_FILE}"
  log "MD5 映射加载完成：${count} 条。说明：该清单通常以文件名为 key，不以目录/文件名为 key。"
}

# 按相对路径优先、basename 兜底的方式查询官方 MD5。
lookup_md5() {
  # relpath：目标文件相对 BASE_URL 的路径。
  local relpath="$1"
  # basename_only：从 relpath 中取出的文件名，用于兼容官方清单的常见 key。
  local basename_only="${relpath##*/}"
  if [[ -n "${MD5_MAP[${relpath}]:-}" ]]; then
    printf '%s' "${MD5_MAP[${relpath}]}"
  elif [[ -n "${MD5_MAP[${basename_only}]:-}" ]]; then
    printf '%s' "${MD5_MAP[${basename_only}]}"
  fi
  return 0
}

# 根据 PLAN_FILE 输出有官方 MD5 和无官方 MD5 的两类 manifest。
write_manifests() {
  # group：PLAN_FILE 中的下载分组。
  local group
  # relpath：PLAN_FILE 中的相对路径。
  local relpath
  # url：PLAN_FILE 中的远端下载 URL。
  local url
  # local_dir：PLAN_FILE 中的本地目标目录。
  local local_dir
  # out_name：PLAN_FILE 中的本地输出文件名。
  local out_name
  # md5：lookup_md5 返回的官方 MD5 值。
  local md5
  # with_md5：有官方 MD5 的计划文件数量。
  local with_md5=0
  # without_md5：无官方 MD5 的计划文件数量。
  local without_md5=0

  {
    printf '# release\t%s\n' "${RELEASE}"
    printf '# base_url\t%s\n' "${BASE_URL}"
    printf '# local_root\t%s\n' "${LOCAL_ROOT}"
    printf '# run_id\t%s\n' "${RUN_ID}"
    printf '# columns\tmd5\trelative_path\n'
  } > "${TARGET_MANIFEST}"

  {
    printf '# release\t%s\n' "${RELEASE}"
    printf '# base_url\t%s\n' "${BASE_URL}"
    printf '# local_root\t%s\n' "${LOCAL_ROOT}"
    printf '# run_id\t%s\n' "${RUN_ID}"
    printf '# columns\trelative_path\treason\n'
  } > "${UNVERIFIED_MANIFEST}"

  : > "${MD5_CHECK_FILE}"

  while IFS=$'\t' read -r group relpath url local_dir out_name; do
    [[ "${group}" == "# group" ]] && continue
    [[ -n "${relpath:-}" ]] || continue
    md5="$(lookup_md5 "${relpath}")"
    if [[ -n "${md5}" ]]; then
      printf '%s\t%s\n' "${md5}" "${relpath}" >> "${TARGET_MANIFEST}"
      printf '%s  %s\n' "${md5}" "${relpath}" >> "${MD5_CHECK_FILE}"
      with_md5=$((with_md5 + 1))
    else
      printf '%s\t%s\n' "${relpath}" "NO_OFFICIAL_MD5_IN_release${RELEASE}.files.installed" >> "${UNVERIFIED_MANIFEST}"
      without_md5=$((without_md5 + 1))
    fi
  done < "${PLAN_FILE}"

  log "MD5 manifest 已生成：${TARGET_MANIFEST}（有官方 MD5：${with_md5}）"
  log "未收录官方 MD5 清单：${UNVERIFIED_MANIFEST}（无官方 MD5：${without_md5}）"
  if [[ "${without_md5}" -gt 0 ]]; then
    log "说明：无官方 MD5 的文件仍会下载；它们不能用 release${RELEASE}.files.installed 做强校验。"
  fi
}

# 对有官方 MD5 的文件执行下载后强校验。
verify_md5_if_enabled() {
  if [[ "${VERIFY_MD5_AFTER_DOWNLOAD}" == "0" ]]; then
    log "跳过即时 MD5 校验：VERIFY_MD5_AFTER_DOWNLOAD=0"
    log "后续可在 ${LOCAL_ROOT} 下使用该清单校验：${MD5_CHECK_FILE}"
    return 0
  fi

  if [[ ! -s "${MD5_CHECK_FILE}" ]]; then
    log "无可校验 MD5 条目，跳过 MD5 校验。"
    return 0
  fi

  log "开始 MD5 校验：${MD5_CHECK_FILE}"
  if (cd "${LOCAL_ROOT}" && md5sum --check --quiet "${MD5_CHECK_FILE}"); then
    log "MD5 校验通过：所有官方 MD5 条目均匹配。"
  else
    die "MD5 校验失败。请查看 ${MD5_CHECK_FILE} 中的相对路径，并检查对应文件是否下载完整。"
  fi
}

# 判断本地已有文件是否完整；完整则跳过，异常则移入垃圾箱并允许重下。
existing_file_is_complete() {
  # relpath：目标文件相对 BASE_URL 的路径。
  local relpath="$1"
  # url：目标文件完整下载 URL。
  local url="$2"
  # local_file：目标文件本地绝对路径。
  local local_file="$3"
  # md5：官方 MD5；为空表示该文件没有官方 MD5 记录。
  local md5
  # actual_md5：本地文件计算得到的 MD5。
  local actual_md5
  # local_size：本地文件字节数。
  local local_size
  # remote_size：远端 Content-Length 字节数。
  local remote_size

  [[ "${SKIP_VERIFIED_FILES}" == "1" ]] || return 1
  [[ -f "${local_file}" ]] || return 1

  if [[ -f "${local_file}.aria2" ]]; then
    log "检测到 aria2 续传状态，继续下载未完成文件：${relpath}"
    return 1
  fi

  md5="$(lookup_md5 "${relpath}")"
  if [[ -n "${md5}" ]]; then
    actual_md5="$(md5sum "${local_file}" | awk '{print $1}')"
    if [[ "${actual_md5}" == "${md5}" ]]; then
      log "跳过已完成文件（官方 MD5 匹配）：${relpath}"
      return 0
    fi
    errlog "本地文件 MD5 不匹配，将重新下载：${relpath}，expected=${md5}，actual=${actual_md5}"
    move_to_trash "${local_file}" "md5_mismatch"
    return 1
  fi

  local_size="$(stat -c '%s' "${local_file}")"
  remote_size="$(remote_content_length "${url}" || true)"
  if [[ -z "${remote_size}" || ! "${remote_size}" =~ ^[0-9]+$ ]]; then
    errlog "无法获取远端 Content-Length，不能确认已有文件完整性，将重新下载：${relpath}"
    move_to_trash "${local_file}" "unknown_remote_size"
    return 1
  fi

  if [[ "${local_size}" -ne "${remote_size}" ]]; then
    errlog "本地文件大小不匹配，将重新下载：${relpath}，remote=${remote_size}，local=${local_size}"
    move_to_trash "${local_file}" "size_mismatch"
    return 1
  fi

  if [[ "${relpath}" == *.gz ]]; then
    if gzip -t "${local_file}"; then
      log "跳过已完成文件（大小匹配 + gzip CRC 通过）：${relpath}"
      return 0
    fi
    errlog "本地 gzip CRC 校验失败，将重新下载：${relpath}"
    move_to_trash "${local_file}" "gzip_crc_failed"
    return 1
  fi

  if [[ "${local_size}" -gt 0 ]]; then
    log "跳过已完成文件（无官方 MD5，远端大小匹配且本地非空）：${relpath}"
    return 0
  fi

  errlog "本地文件为空，将重新下载：${relpath}"
  move_to_trash "${local_file}" "empty_file"
  return 1
}

# 对无官方 MD5 的文件执行下载后弱校验。
verify_unverified_if_enabled() {
  # group：PLAN_FILE 中的下载分组。
  local group
  # relpath：PLAN_FILE 中的相对路径。
  local relpath
  # url：PLAN_FILE 中的远端下载 URL。
  local url
  # local_dir：PLAN_FILE 中的本地目标目录。
  local local_dir
  # out_name：PLAN_FILE 中的本地输出文件名。
  local out_name
  # local_file：目标文件本地绝对路径。
  local local_file
  # md5：lookup_md5 返回的官方 MD5；非空则跳过弱校验。
  local md5
  # failed：弱校验失败标记，1 表示至少一个文件失败。
  local failed=0
  # checked：执行弱校验的文件数量。
  local checked=0

  if [[ "${VERIFY_UNVERIFIED_AFTER_DOWNLOAD}" == "0" ]]; then
    log "跳过无官方 MD5 文件的弱校验：VERIFY_UNVERIFIED_AFTER_DOWNLOAD=0"
    return 0
  fi

  while IFS=$'\t' read -r group relpath url local_dir out_name; do
    [[ "${group}" == "# group" ]] && continue
    [[ -n "${relpath:-}" ]] || continue
    md5="$(lookup_md5 "${relpath}")"
    [[ -z "${md5}" ]] || continue

    local_file="${local_dir}/${out_name}"
    checked=$((checked + 1))
    if [[ ! -f "${local_file}" ]]; then
      errlog "无官方 MD5 文件缺失：${relpath}，路径：${local_file}"
      failed=1
      continue
    fi

    if [[ "${relpath}" == *.gz ]]; then
      if ! gzip -t "${local_file}"; then
        errlog "无官方 MD5 gzip 文件 CRC 校验失败：${relpath}"
        failed=1
      fi
    elif [[ ! -s "${local_file}" ]]; then
      errlog "无官方 MD5 非 gzip 文件为空：${relpath}"
      failed=1
    fi
  done < "${PLAN_FILE}"

  if [[ "${failed}" -ne 0 ]]; then
    die "无官方 MD5 文件弱校验失败。请查看错误日志：${ERR_LOG}"
  fi
  log "无官方 MD5 文件弱校验通过：${checked} 个文件。"
}

# ==================== aria2 下载 ====================
# 生成某个分组的 aria2 input 文件，并跳过已通过完整性判断的本地文件。
write_aria_input_for_group() {
  # group_filter：要生成 aria2 input 的分组名。
  local group_filter="$1"
  # out_file：aria2 input 输出文件。
  local out_file="$2"
  # group：PLAN_FILE 中的下载分组。
  local group
  # relpath：PLAN_FILE 中的相对路径。
  local relpath
  # url：PLAN_FILE 中的远端下载 URL。
  local url
  # local_dir：PLAN_FILE 中的本地目标目录。
  local local_dir
  # out_name：PLAN_FILE 中的本地输出文件名。
  local out_name
  # local_file：目标文件本地绝对路径。
  local local_file
  # md5：lookup_md5 返回的官方 MD5；存在时写入 aria2 checksum。
  local md5
  # count：需要交给 aria2 下载的文件数量。
  local count=0
  # skipped：已通过完整性判断并跳过的文件数量。
  local skipped=0

  : > "${out_file}"
  while IFS=$'\t' read -r group relpath url local_dir out_name; do
    [[ "${group}" == "# group" ]] && continue
    [[ "${group}" == "${group_filter}" ]] || continue
    mkdir -p "${local_dir}"
    local_file="${local_dir}/${out_name}"
    if existing_file_is_complete "${relpath}" "${url}" "${local_file}"; then
      skipped=$((skipped + 1))
      continue
    fi
    printf '%s\n  dir=%s\n  out=%s\n' "${url}" "${local_dir}" "${out_name}" >> "${out_file}"
    md5="$(lookup_md5 "${relpath}")"
    if [[ -n "${md5}" ]]; then
      printf '  checksum=md5=%s\n' "${md5}" >> "${out_file}"
    fi
    count=$((count + 1))
  done < "${PLAN_FILE}"

  log "${group_filter} aria2 输入文件：${out_file}，需下载 ${count} 个，已校验跳过 ${skipped} 个"
}

# 将 aria2 退出码翻译成可读错误，并摘录 aria2 日志中的异常行。
report_aria_failure() {
  # group：下载分组名。
  local group="$1"
  # exit_code：aria2c 退出码。
  local exit_code="$2"
  # log_file：aria2c 详细日志路径。
  local log_file="$3"
  # meaning：脚本内维护的退出码含义。
  local meaning

  case "${exit_code}" in
    1) meaning="未知错误或多个错误叠加" ;;
    2) meaning="超时" ;;
    3) meaning="资源未找到" ;;
    4) meaning="aria2 看到指定数量的 404/410 后终止" ;;
    5) meaning="下载速度过低或网络不稳定" ;;
    6) meaning="网络问题" ;;
    7) meaning="未完成下载过多" ;;
    8) meaning="远端不支持断点续传或续传失败" ;;
    9) meaning="磁盘空间不足" ;;
    22) meaning="HTTP 响应错误，例如 403/404/429/5xx" ;;
    23) meaning="写文件失败" ;;
    24) meaning="文件重命名失败" ;;
    25) meaning="已存在同名文件且不允许覆盖" ;;
    28) meaning="参数或环境变量解析失败" ;;
    *) meaning="未在脚本中映射的 aria2 退出码" ;;
  esac

  errlog "${group} 下载失败：aria2c 退出码 ${exit_code}，含义：${meaning}"
  errlog "${group} aria2 日志：${log_file}"
  if [[ -f "${log_file}" ]]; then
    errlog "${group} aria2 异常摘录（最多 30 行）："
    grep -iE 'error|failed|exception|abort|timeout|not complete|429|403|404|503' "${log_file}" | tail -30 | while IFS= read -r line; do
      errlog "  ${line}"
    done || true
  fi
}

# 执行某个分组的 aria2 下载任务。
run_aria2_group() {
  # group：下载分组名。
  local group="$1"
  # input_file：该分组的 aria2 input 文件。
  local input_file="$2"
  # log_file：该分组 aria2 运行日志。
  local log_file="${LOG_DIR}/aria2_${group}_${RUN_ID}.log"
  # file_count：input_file 中实际 URL 数量。
  local file_count

  file_count=$(grep -Ec '^https?://' "${input_file}" || true)
  if [[ "${file_count}" -eq 0 ]]; then
    log "${group} 无下载目标，跳过 aria2。"
    printf '%s\t%s\t%s\n' "${group}" "SKIPPED" "NO_TARGET" >> "${STATE_FILE}"
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
    printf '%s\t%s\t%s\n' "${group}" "DONE" "${file_count}" >> "${STATE_FILE}"
  else
    # exit_code：失败时捕获的 aria2c 退出码。
    local exit_code=$?
    report_aria_failure "${group}" "${exit_code}" "${log_file}"
    printf '%s\t%s\t%s\n' "${group}" "FAILED" "${exit_code}" >> "${STATE_FILE}"
    return "${exit_code}"
  fi
}

# ==================== 主流程 ====================
# 串联配置校验、远端目录枚举、下载、完整性校验和状态输出。
main() {
  require_command curl
  require_command aria2c
  require_command awk
  require_command sort
  require_command md5sum
  validate_config

  : > "${STATE_FILE}"

  log "========== RefSeq release${RELEASE} 下载开始 =========="
  log "远端根目录：${BASE_URL}"
  log "本地数据根目录：${LOCAL_ROOT}"
  log "运行日志目录：${RUN_ROOT}"
  log "下载开关：complete=${DOWNLOAD_COMPLETE}, taxon=${DOWNLOAD_TAXON_DIRS}, auxiliary=${DOWNLOAD_AUXILIARY}"
  log "aria2 参数：connections=${ARIA2_CONNECTIONS}, max_concurrent=${ARIA2_MAX_CONCURRENT}, split=${ARIA2_SPLIT}, min_split_size=${ARIA2_MIN_SPLIT_SIZE}, summary_interval=${ARIA2_SUMMARY_INTERVAL}"
  log "MD5 说明：下载目标由远端目录 listing 决定；官方 MD5 用于下载前跳过、aria2 单文件校验和下载后复核。"

  check_disk_space
  download_md5_file
  load_md5_map
  build_download_plan
  write_manifests

  write_aria_input_for_group "complete" "${ARIA_INPUT_COMPLETE}"
  write_aria_input_for_group "taxon" "${ARIA_INPUT_TAXON}"
  write_aria_input_for_group "auxiliary" "${ARIA_INPUT_AUXILIARY}"

  # failed：三个下载分组的失败标记，1 表示至少一个分组失败。
  local failed=0

  if [[ "${DOWNLOAD_COMPLETE}" == "1" ]]; then
    run_aria2_group "complete" "${ARIA_INPUT_COMPLETE}" || failed=1
  fi

  if [[ "${DOWNLOAD_TAXON_DIRS}" == "1" ]]; then
    run_aria2_group "taxon" "${ARIA_INPUT_TAXON}" || failed=1
  fi

  if [[ "${DOWNLOAD_AUXILIARY}" == "1" ]]; then
    run_aria2_group "auxiliary" "${ARIA_INPUT_AUXILIARY}" || failed=1
  fi

  if [[ "${failed}" -ne 0 ]]; then
    errlog "至少一类数据下载失败或部分完成。重跑本脚本会利用 aria2 断点续传。状态文件：${STATE_FILE}"
    exit 1
  fi

  verify_md5_if_enabled
  verify_unverified_if_enabled

  log "========== RefSeq release${RELEASE} 下载流程结束 =========="
  log "下载计划：${PLAN_FILE}"
  log "官方 MD5 manifest：${TARGET_MANIFEST}"
  log "无官方 MD5 manifest：${UNVERIFIED_MANIFEST}"
  log "状态文件：${STATE_FILE}"
}

main "$@"
