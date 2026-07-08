#!/usr/bin/env bash
# =============================================================================
# NCBI RefSeq genomes downloader by NCBI Datasets CLI
#
# 目标：
#   1. 使用 assembly_summary_refseq.txt 作为唯一 accession 清单来源，避免递归扫描 FTP 目录。
#   2. 使用 ncbi/datasets 推荐的大规模流程：
#        manifest/shard -> 下载 dehydrated 数据包 -> 解包 -> 汇总 fetch.txt -> 统一 rehydrate -> 校验。
#   3. 默认使用 --include all，下载 genome/protein/cds/gff3/gtf/gbff/rna/seq-report。
#   4. 每个阶段可独立重复执行，便于断点续跑、错误定位和人工检查。
#   5. 脚本不删除下载产物；可复用旧产物会尽量移动到 TRASH_DIR，运行状态表会按阶段重写。
#   6. datasets download / rehydrate 阶段带自动重试；有官方 MD5 时执行强完整性检查。
# =============================================================================
set -Eeuo pipefail
export LC_ALL=C

early_unhandled_error() {
  local exit_code="$1"
  local line_no="$2"
  local command_text="$3"
  local error_line
  error_line="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] 初始化阶段命令失败；退出码：${exit_code}；line=${line_no};command=${command_text}"
  if [[ -n "${ERR_LOG:-}" ]]; then
    mkdir -p "$(dirname "${ERR_LOG}")" 2>/dev/null || true
    printf '%s\n' "${error_line}" >> "${ERR_LOG}" 2>/dev/null || true
  fi
  if [[ -n "${STATE_FILE:-}" ]]; then
    mkdir -p "$(dirname "${STATE_FILE}")" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "init" "FAILED_EXIT_${exit_code}" "line=${line_no};command=${command_text}" >> "${STATE_FILE}" 2>/dev/null || true
  fi
  printf '%s\n' "${error_line}" >&2
  exit "${exit_code}"
}

trap 'early_unhandled_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

# ==================== 用户配置 ====================
# ASSEMBLY_SUMMARY_FILE：RefSeq assembly_summary 标准信息表。
#   默认使用研究工作区根目录下的相对路径；在其他目录运行时请改成可读的绝对路径。
#   脚本只从这个表读取 accession、ftp_path 和过滤字段，不再递归扫描 NCBI FTP 目录。
ASSEMBLY_SUMMARY_FILE="/data/p252701008/projects/multi-omics-data-pipelines/refseq/resources/assembly_summary_refseq.txt"
# ASSEMBLY_SUMMARY_SOURCE_URL：该本地表的官方来源记录；脚本不自动下载，只用于可追溯性。
ASSEMBLY_SUMMARY_SOURCE_URL="https://ftp.ncbi.nlm.nih.gov/genomes/refseq/assembly_summary_refseq.txt"
# RESOLVED_ASSEMBLY_SUMMARY_FILE：运行时解析后的实际路径。
#   例如把 Windows 路径 C:\Users\... 转成 WSL 可读的 /mnt/c/Users/...；用户一般不需要手动改。
RESOLVED_ASSEMBLY_SUMMARY_FILE=""
# REQUIRE_RESOLVED_CONTEXT_TOKEN：1=所有阶段都要求当前 assembly_summary 能计算内容指纹。
#   如果必须复用旧 context 且来源表暂时不可读，请显式设置 PIPELINE_CONTEXT_OVERRIDE。
REQUIRE_RESOLVED_CONTEXT_TOKEN=1

# STORAGE_DISK_CANDIDATES：真实数据存储盘候选列表，按顺序选择；默认首选 /data1。
STORAGE_DISK_CANDIDATES=(/data1 /data2 /data4 /data5 /data3)
# STORAGE_OWNER_DIR：每个候选盘下的数据归属目录；不存在时脚本会尝试创建。
STORAGE_OWNER_DIR="p252701008"
# STORAGE_DATA_SUBDIR：每个候选盘下的 RefSeq genomes 数据目录名。
STORAGE_DATA_SUBDIR="refseq_genomes"
# STORAGE_RUNLOG_SUBDIR：固定放在 /data1/p252701008 下的运行日志目录名。
STORAGE_RUNLOG_SUBDIR="refseq_genomes_runlogs"
# STORAGE_MIN_FREE_GB：rehydrate 运行盘最低剩余空间；低于该值时切换到下一个候选盘。
STORAGE_MIN_FREE_GB=200

# DATA_ROOT：默认数据根目录，派生自首个候选盘 /data1。
DATA_ROOT="${STORAGE_DISK_CANDIDATES[0]}/${STORAGE_OWNER_DIR}/${STORAGE_DATA_SUBDIR}"

# RUN_ROOT：运行日志、manifest、shard、状态表目录，固定放在 /data1/p252701008 下。
#   这个目录保存可重复运行所需的过程文件，删除或移动后会影响断点续跑。
RUN_ROOT="/data1/${STORAGE_OWNER_DIR}/${STORAGE_RUNLOG_SUBDIR}"

# TRASH_DIR：异常 zip、异常解包目录、可复用旧产物的隔离目录。
#   FORCE_*、校验跳过或重建触发覆盖时，相关旧产物会尽量移动到这里；运行状态表会按阶段重写。
TRASH_DIR="${RUN_ROOT}/trash"

# PIPELINE_CONTEXT_OVERRIDE：手动指定既有 context 名称，用于源表路径变化后复用旧运行上下文。
#   默认留空，脚本按来源表指纹和过滤参数自动生成 context；设置后必须确认该 context 属于当前任务。
PIPELINE_CONTEXT_OVERRIDE=""

# datasets / unzip 命令名。若服务器上安装在非 PATH 位置，可改成绝对路径。
# DATASETS_BIN：NCBI Datasets CLI 可执行文件；例如 /path/to/datasets。
DATASETS_BIN="datasets"
# UNZIP_BIN：解包 dehydrated zip 的 unzip 可执行文件；例如 /usr/bin/unzip。
UNZIP_BIN="unzip"

# NCBI API key。留空则不使用；非空时不会把 key 打进日志。
#   推荐通过环境变量 NCBI_API_KEY 传入，不建议把真实 key 写进脚本。
NCBI_API_KEY="${NCBI_API_KEY:-}"

# 下载内容。all 等价于 genome,protein,cds,gff3,gtf,gbff,rna,seq-report。
# INCLUDE_FILES：传给 datasets download 的 --include 参数。
INCLUDE_FILES="all"
# ASSEMBLY_SOURCE：传给 datasets download 的 --assembly-source 参数；这里固定使用 RefSeq/GCF。
ASSEMBLY_SOURCE="RefSeq"

# 下载范围。默认是 assembly_summary_refseq.txt 中 latest GCF 且 ftp_path 非 na 的记录。
# FILTER_LATEST_ONLY=1 会要求 version_status=latest；当前 assembly_summary_refseq 通常本身就是 current 表。
# FILTER_LATEST_ONLY：1=只保留 latest；0=允许非 latest。RefSeq current 表通常全是 latest。
FILTER_LATEST_ONLY=1
# FILTER_GENOME_REP：assembly_summary 的 genome_rep 过滤；all=不限制，Full=只保留完整 genome_rep。
FILTER_GENOME_REP="all"             # all 或 Full
# FILTER_EXCLUDED_FROM_REFSEQ：all=不限制；clean=只保留 excluded_from_refseq 为 na 的记录。
FILTER_EXCLUDED_FROM_REFSEQ="all"   # all 或 clean；clean 表示 excluded_from_refseq 必须为 na
# FILTER_ASSEMBLY_LEVELS：assembly_level 过滤；all=不限制，逗号分隔时只保留指定层级。
FILTER_ASSEMBLY_LEVELS="all"        # all 或逗号分隔：Complete Genome,Chromosome,Scaffold,Contig
# FILTER_GROUPS：assembly_summary 的 group 过滤；all=不限制，逗号分隔时只保留指定类群。
FILTER_GROUPS="all"                 # all 或逗号分隔：archaea,bacteria,viral,...
# MIN_GENOME_SIZE：按 genome_size 最小值过滤；0=不限制。
MIN_GENOME_SIZE=0                   # 0 表示不限制
# MAX_ACCESSIONS：最多保留多少个 accession；0=不限制，试跑时可设小值。
MAX_ACCESSIONS=0                    # 0 表示不限制；试跑可设为 1000

# Shard 是工程容错层，不是生物学筛选。全量下载建议保留。
# SHARD_SIZE：每个 dehydrated zip 对应的 accession 数；越小越容易重试，越大过程文件越少。
SHARD_SIZE=1000
# FORCE_SINGLE_PACKAGE：1=把所有 accession 放进单个输入文件；全量下载不推荐。
FORCE_SINGLE_PACKAGE=0              # 1=不分片；只建议小规模试跑

# 多阶段解耦开关。默认完整执行。
# 也可用第一个命令行参数覆盖：manifest / download-links / unpack-links / merge-fetch / rehydrate / verify / summary / all
# RUN_BUILD_MANIFEST：1=解析 assembly_summary 并生成 accession/shard 清单。
RUN_BUILD_MANIFEST=1
# RUN_DOWNLOAD_LINKS：1=运行 datasets download --dehydrated，下载轻量链接包。
RUN_DOWNLOAD_LINKS=1
# RUN_UNPACK_LINKS：1=解包 dehydrated zip，提取每个 shard 内的 fetch.txt。
RUN_UNPACK_LINKS=1
# RUN_MERGE_FETCH：1=汇总所有 shard 的 fetch.txt，形成统一 rehydrate 入口。
RUN_MERGE_FETCH=1
# RUN_REHYDRATE：1=运行 datasets rehydrate，统一下载真实数据文件。
RUN_REHYDRATE=1
# RUN_VERIFY：1=执行 accession 覆盖、目标文件存在性和可选 MD5 校验。
RUN_VERIFY=1

# 断点与覆盖策略。默认尽量复用已有结果。
# FORCE_REBUILD_MANIFEST：1=强制重建 manifest/shard，并尽量把主要旧产物移入 TRASH_DIR。
FORCE_REBUILD_MANIFEST=0
# FORCE_DOWNLOAD_LINKS：1=重新下载 dehydrated zip，并把旧 zip 移入 TRASH_DIR。
FORCE_DOWNLOAD_LINKS=0
# FORCE_UNPACK_LINKS：1=重新解包 dehydrated zip，并把旧解包目录移入 TRASH_DIR。
FORCE_UNPACK_LINKS=0
# FORCE_MERGE_FETCH：1=重新汇总 fetch.txt，并把旧汇总文件移入 TRASH_DIR。
FORCE_MERGE_FETCH=0

# 下载链接阶段：0=某些 shard 失败后继续其他 shard，最后汇总失败；1=遇到失败立即停止。
# STOP_ON_LINK_DOWNLOAD_ERROR：控制 dehydrated 包下载失败时是否立刻停止。
STOP_ON_LINK_DOWNLOAD_ERROR=0
# DOWNLOAD_LINK_MAX_RETRIES：单个 dehydrated zip 下载失败后的自动重试次数。
DOWNLOAD_LINK_MAX_RETRIES=3
# REHYDRATE_MAX_RETRIES：datasets rehydrate 失败后的自动重试次数。
REHYDRATE_MAX_RETRIES=3
# RETRY_SLEEP_SECONDS：自动重试前等待秒数。
RETRY_SLEEP_SECONDS=30

# rehydrate 并发 worker，datasets 官方允许 1-30。
# REHYDRATE_MAX_WORKERS：真实数据下载并发数；过高可能触发网络或 NCBI 限流。
REHYDRATE_MAX_WORKERS=30
# REHYDRATE_LIST_BEFORE_DOWNLOAD：1=下载前先执行 datasets rehydrate --list 做预检。
REHYDRATE_LIST_BEFORE_DOWNLOAD=1
# REHYDRATE_GZIP：1=执行 datasets rehydrate --gzip，下载落盘为 gzip 压缩文件。
REHYDRATE_GZIP=1
# REHYDRATE_PROGRESS_INTERVAL_SECONDS：rehydrate 下载中每隔多少秒向主日志输出一次文件数和目录大小；0=关闭。
REHYDRATE_PROGRESS_INTERVAL_SECONDS=60

# 校验策略。STRICT_INTEGRITY=1 表示默认启用目标存在性、类别和可用 MD5 验证。
# STRICT_INTEGRITY：1=严格完整性模式；若关闭，需要人工接受只做存在性/格式校验的风险。
STRICT_INTEGRITY=1
# VERIFY_FETCH_TARGETS_AFTER_REHYDRATE：1=检查 fetch.txt 中每个目标文件是否存在且非空。
VERIFY_FETCH_TARGETS_AFTER_REHYDRATE=1
# VERIFY_FETCH_MD5：1=使用 fetch.txt 第二列中可用的 MD5 校验；第二列为 0 时表示官方未提供 MD5。
VERIFY_FETCH_MD5=1
# VERIFY_FETCH_CHECKSUM_FORMAT：1=即使不计算 MD5，也检查 fetch.txt 第二列是否为 32 位 MD5 或 0 占位值。
VERIFY_FETCH_CHECKSUM_FORMAT=1
# VERIFY_FETCH_FILE_PROFILE：1=按 accession 检查 fetch.txt 是否至少包含关键文件类别。
VERIFY_FETCH_FILE_PROFILE=1
# REQUIRED_FETCH_TARGET_CLASSES：逗号分隔的关键文件类别；空字符串表示不做类别要求。
#   可选类别：genome,protein,cds,gff3,gtf,gbff,rna,seq-report。
REQUIRED_FETCH_TARGET_CLASSES="genome,seq-report"
# MIN_FETCH_TARGETS_PER_ACCESSION：每个 accession 至少需要的 fetch 目标行数；0=不限制。
MIN_FETCH_TARGETS_PER_ACCESSION=2
# MAX_VERIFY_MISSING_PREVIEW：目标文件缺失时最多在错误日志中预览多少条，完整列表写入 TSV。
MAX_VERIFY_MISSING_PREVIEW=50

# 磁盘保护阈值，单位 GB。每个关键下载阶段都会检查。
# MIN_DISK_GB：目标分区剩余空间低于该值时停止，防止写满数据盘。
MIN_DISK_GB=200

# ==================== 派生路径 ====================
# RUN_ID：本次运行唯一标识，用 UTC 时间和进程号区分日志/状态文件。
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ').$$"
# DATA_ROOT_CANDIDATES：按候选盘派生出的完整数据根目录列表。
DATA_ROOT_CANDIDATES=()
for storage_disk in "${STORAGE_DISK_CANDIDATES[@]}"; do
  DATA_ROOT_CANDIDATES+=("${storage_disk}/${STORAGE_OWNER_DIR}/${STORAGE_DATA_SUBDIR}")
done
DATA_ROOT="${DATA_ROOT_CANDIDATES[0]}"
# REHYDRATE_FORMAT_TAG：进入 context 名称，避免 gzip 与未压缩数据混写。
REHYDRATE_FORMAT_TAG="plain"
if [[ "${REHYDRATE_GZIP}" == "1" ]]; then
  REHYDRATE_FORMAT_TAG="gzip"
fi
# SHARD_SET_NAME：当前 shard 集合名称；由 SHARD_SIZE 或 FORCE_SINGLE_PACKAGE 决定。
SHARD_SET_NAME="refseq_shards_size_${SHARD_SIZE}"
if [[ "${FORCE_SINGLE_PACKAGE}" == "1" ]]; then
  SHARD_SET_NAME="refseq_single_package"
fi
# ASSEMBLY_SUMMARY_CONTEXT_TOKEN：assembly_summary 文件内容指纹，防止同路径文件更新后复用旧 context。
ASSEMBLY_SUMMARY_CONTEXT_TOKEN="unresolved"
if [[ -f "${ASSEMBLY_SUMMARY_FILE}" ]]; then
  ASSEMBLY_SUMMARY_CONTEXT_TOKEN="$(cksum "${ASSEMBLY_SUMMARY_FILE}" | awk '{print $1 "_" $2}')"
elif [[ "${ASSEMBLY_SUMMARY_FILE}" =~ ^([A-Za-z]):\\(.*)$ ]]; then
  context_drive="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
  context_rest="${BASH_REMATCH[2]//\\//}"
  for context_candidate in "/mnt/${context_drive}/${context_rest}" "/${context_drive}/${context_rest}"; do
    if [[ -f "${context_candidate}" ]]; then
      ASSEMBLY_SUMMARY_CONTEXT_TOKEN="$(cksum "${context_candidate}" | awk '{print $1 "_" $2}')"
      break
    fi
  done
  unset context_drive context_rest context_candidate
fi
# PIPELINE_CONTEXT_ID：由来源、过滤条件、include 和 shard 参数生成的配置指纹。
#   该指纹会进入过程目录，避免试跑、改过滤条件或改 shard 后复用旧 zip/fetch。
PIPELINE_CONTEXT_ID="$(
  printf '%s\n' \
    "ASSEMBLY_SUMMARY_FILE=${ASSEMBLY_SUMMARY_FILE}" \
    "ASSEMBLY_SUMMARY_SOURCE_URL=${ASSEMBLY_SUMMARY_SOURCE_URL}" \
    "ASSEMBLY_SUMMARY_CONTEXT_TOKEN=${ASSEMBLY_SUMMARY_CONTEXT_TOKEN}" \
    "INCLUDE_FILES=${INCLUDE_FILES}" \
    "ASSEMBLY_SOURCE=${ASSEMBLY_SOURCE}" \
    "FILTER_LATEST_ONLY=${FILTER_LATEST_ONLY}" \
    "FILTER_GENOME_REP=${FILTER_GENOME_REP}" \
    "FILTER_EXCLUDED_FROM_REFSEQ=${FILTER_EXCLUDED_FROM_REFSEQ}" \
    "FILTER_ASSEMBLY_LEVELS=${FILTER_ASSEMBLY_LEVELS}" \
    "FILTER_GROUPS=${FILTER_GROUPS}" \
    "MIN_GENOME_SIZE=${MIN_GENOME_SIZE}" \
    "MAX_ACCESSIONS=${MAX_ACCESSIONS}" \
    "SHARD_SIZE=${SHARD_SIZE}" \
    "FORCE_SINGLE_PACKAGE=${FORCE_SINGLE_PACKAGE}" \
    "REHYDRATE_GZIP=${REHYDRATE_GZIP}" |
  cksum | awk '{print $1}'
)"
# PIPELINE_CONTEXT_COMPUTED_NAME：由当前配置自动生成的 context 名称。
PIPELINE_CONTEXT_COMPUTED_NAME="refseq_${ASSEMBLY_SOURCE}_include_${INCLUDE_FILES}_${REHYDRATE_FORMAT_TAG}_${SHARD_SET_NAME}_${PIPELINE_CONTEXT_ID}"
if [[ -n "${PIPELINE_CONTEXT_OVERRIDE}" && ! "${PIPELINE_CONTEXT_OVERRIDE}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  printf '[FATAL] PIPELINE_CONTEXT_OVERRIDE 只能包含字母、数字、下划线、点号和短横线。\n' >&2
  exit 1
fi
# PIPELINE_CONTEXT_NAME：最终使用的 context 名称；PIPELINE_CONTEXT_OVERRIDE 非空时优先使用用户指定值。
PIPELINE_CONTEXT_NAME="${PIPELINE_CONTEXT_OVERRIDE:-${PIPELINE_CONTEXT_COMPUTED_NAME}}"

# LOG_DIR：普通日志和错误日志目录。
LOG_DIR="${RUN_ROOT}/logs/${PIPELINE_CONTEXT_NAME}"
# MANIFEST_DIR：manifest、accession 清单、过滤配置记录目录。
MANIFEST_DIR="${RUN_ROOT}/manifests/${PIPELINE_CONTEXT_NAME}"
# SHARD_ROOT：所有 shard 输入文件集合的父目录。
SHARD_ROOT="${RUN_ROOT}/shards/${PIPELINE_CONTEXT_NAME}"
# STATUS_DIR：各阶段状态表、缺失清单、summary 报告目录。
STATUS_DIR="${RUN_ROOT}/status/${PIPELINE_CONTEXT_NAME}"

# LINK_ROOT：dehydrated 链接包相关文件根目录。
LINK_ROOT="${DATA_ROOT}/contexts/${PIPELINE_CONTEXT_NAME}/dehydrated_links"
# ZIP_DIR：datasets download --dehydrated 生成的 zip 包目录。
ZIP_DIR="${LINK_ROOT}/zips"
# UNPACK_DIR：每个 dehydrated zip 解包后的独立目录。
UNPACK_DIR="${LINK_ROOT}/unzipped"
# MERGED_PACKAGE_DIR：汇总后的统一 dehydrated package 目录，保留总 fetch.txt 并用于 rehydrate --list 预检。
MERGED_PACKAGE_DIR="${DATA_ROOT}/contexts/${PIPELINE_CONTEXT_NAME}/merged_refseq_dataset"
# REHYDRATE_PACKAGE_NAME：各候选盘上真正承载 rehydrate 数据的 package 目录名。
REHYDRATE_PACKAGE_NAME="rehydrate_refseq_dataset"

# DL_LOG：本次运行主日志。
DL_LOG="${LOG_DIR}/download_${RUN_ID}.log"
# ERR_LOG：本次运行错误日志。
ERR_LOG="${LOG_DIR}/error_${RUN_ID}.log"
# STATE_FILE：本次运行各阶段状态流水表。
STATE_FILE="${STATUS_DIR}/state_${RUN_ID}.tsv"
# SUMMARY_REPORT：本次运行的 Markdown 汇总报告。
SUMMARY_REPORT="${STATUS_DIR}/summary_${RUN_ID}.md"

# MANIFEST_FILE：过滤后的下载主表，包含 accession、group、assembly_level、ftp_path 等字段。
MANIFEST_FILE="${MANIFEST_DIR}/download_manifest.tsv"
# MANIFEST_SUMMARY_FILE：manifest 构建阶段的统计表，记录保留/跳过数量。
MANIFEST_SUMMARY_FILE="${MANIFEST_DIR}/download_manifest_summary.tsv"
# ACCESSION_FILE：传给 datasets --inputfile 的 accession 清单，保持 manifest 顺序。
ACCESSION_FILE="${MANIFEST_DIR}/accessions.txt"
# ACCESSION_SORTED_FILE：排序去重后的 accession 清单，用于 comm 覆盖校验。
ACCESSION_SORTED_FILE="${MANIFEST_DIR}/accessions.sorted.txt"
# MANIFEST_CONFIG_FILE：记录本次 manifest 的来源、配置和上下文快照，便于后续单独阶段追溯。
MANIFEST_CONFIG_FILE="${MANIFEST_DIR}/manifest_config.txt"

# SHARD_DIR：当前 shard 集合实际目录。
SHARD_DIR="${SHARD_ROOT}/${SHARD_SET_NAME}"
# SHARD_LIST_FILE：所有 shard 文件路径列表，供下载阶段顺序读取。
SHARD_LIST_FILE="${SHARD_DIR}/shard_list.txt"

# PACKAGE_STATUS_FILE：dehydrated zip 下载阶段状态表。
PACKAGE_STATUS_FILE="${STATUS_DIR}/package_status.tsv"
# UNPACK_STATUS_FILE：dehydrated zip 解包阶段状态表。
UNPACK_STATUS_FILE="${STATUS_DIR}/unpack_status.tsv"
# FETCH_SOURCE_LIST：参与汇总的各 shard fetch.txt 来源清单。
FETCH_SOURCE_LIST="${STATUS_DIR}/fetch_sources.tsv"
# MERGED_FETCH_FILE：统一 rehydrate 使用的总 fetch.txt。
MERGED_FETCH_FILE="${MERGED_PACKAGE_DIR}/ncbi_dataset/fetch.txt"
# MERGED_FETCH_ACCESSIONS_FILE：从 MERGED_FETCH_FILE 中提取出的 accession 集合。
MERGED_FETCH_ACCESSIONS_FILE="${STATUS_DIR}/fetch_accessions.sorted.txt"
# MISSING_FETCH_ACCESSIONS_FILE：manifest 有但 fetch.txt 未覆盖的 accession 清单。
MISSING_FETCH_ACCESSIONS_FILE="${STATUS_DIR}/missing_accessions_in_fetch.tsv"
# EXTRA_FETCH_ACCESSIONS_FILE：fetch.txt 有但 manifest 没有的 accession 清单，防止旧 fetch 混入。
EXTRA_FETCH_ACCESSIONS_FILE="${STATUS_DIR}/extra_accessions_in_fetch.tsv"
# FETCH_TARGETS_FILE：fetch.txt 第三列目标路径清单。
FETCH_TARGETS_FILE="${STATUS_DIR}/fetch_targets.tsv"
# INVALID_FETCH_TARGETS_FILE：fetch.txt 中不安全或无法解析的目标路径清单。
INVALID_FETCH_TARGETS_FILE="${STATUS_DIR}/invalid_fetch_targets.tsv"
# INVALID_FETCH_ROWS_FILE：fetch.txt 中 checksum 或 target 格式异常的原始行清单。
INVALID_FETCH_ROWS_FILE="${STATUS_DIR}/invalid_fetch_rows.tsv"
# FETCH_PROFILE_FILE：按 accession 汇总的 fetch 目标类别和数量。
FETCH_PROFILE_FILE="${STATUS_DIR}/fetch_target_profile.tsv"
# MISSING_FETCH_CLASSES_FILE：缺少关键 fetch 文件类别或目标数不足的 accession 清单。
MISSING_FETCH_CLASSES_FILE="${STATUS_DIR}/missing_fetch_target_classes.tsv"
# MISSING_TARGETS_FILE：rehydrate 后仍缺失或为空的目标文件清单。
MISSING_TARGETS_FILE="${STATUS_DIR}/missing_download_targets.tsv"
# GZIP_STATUS_FILE：gzip 模式下每个 rehydrate 目标文件的压缩完整性校验结果。
GZIP_STATUS_FILE="${STATUS_DIR}/fetch_gzip_status.tsv"
# MD5_STATUS_FILE：可选 MD5 校验结果表。
MD5_STATUS_FILE="${STATUS_DIR}/fetch_md5_status.tsv"

REQUESTED_ACTION="${1:-all}"
case "${REQUESTED_ACTION}" in
  all|manifest|download-links|unpack-links|merge-fetch|rehydrate|verify|summary) ;;
  *)
    printf '[FATAL] 未知 action：%s。可选：all / manifest / download-links / unpack-links / merge-fetch / rehydrate / verify / summary\n' "${REQUESTED_ACTION}" >&2
    exit 1
    ;;
esac

if [[ "${#DATA_ROOT_CANDIDATES[@]}" -eq 0 ]]; then
  printf '[FATAL] STORAGE_DISK_CANDIDATES 不能为空。\n' >&2
  exit 1
fi

for data_root_candidate in "${DATA_ROOT_CANDIDATES[@]}"; do
  if [[ -z "${data_root_candidate}" || "${data_root_candidate}" != /* ]]; then
    printf '[FATAL] 候选 DATA_ROOT 必须是非空 Linux 绝对路径，当前值为：%s\n' "${data_root_candidate}" >&2
    exit 1
  fi
done

for root_var in DATA_ROOT RUN_ROOT TRASH_DIR; do
  root_value="${!root_var}"
  if [[ -z "${root_value}" || "${root_value}" != /* ]]; then
    printf '[FATAL] %s 必须是非空 Linux 绝对路径，当前值为：%s\n' "${root_var}" "${root_value}" >&2
    exit 1
  fi
done

if ! mkdir -p \
  "${DATA_ROOT_CANDIDATES[@]}" \
  "${DATA_ROOT}" \
  "${RUN_ROOT}" \
  "${LOG_DIR}" \
  "${MANIFEST_DIR}" \
  "${SHARD_ROOT}" \
  "${STATUS_DIR}" \
  "${LINK_ROOT}" \
  "${ZIP_DIR}" \
  "${UNPACK_DIR}" \
  "${MERGED_PACKAGE_DIR}/ncbi_dataset" \
  "${TRASH_DIR}"; then
  printf '[FATAL] 无法创建运行目录；请检查 DATA_ROOT/RUN_ROOT/TRASH_DIR 权限。\n' >&2
  exit 1
fi

# ==================== 日志与基础工具 ====================
# log：写入普通运行日志，并同步输出到 stderr。
# 参数：
#   $*：需要记录的日志正文。
# 输出：
#   1. 标准错误流，方便在终端实时观察。
#   2. DL_LOG，保留完整运行记录。
# 失败行为：
#   tee 写日志失败时会触发 set -e，使脚本停止。
log() {
  printf '[%s] [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${DL_LOG}" >&2
}

# errlog：写入错误日志，并同步输出到 stderr。
# 参数：
#   $*：错误正文。
# 输出：
#   1. 标准错误流。
#   2. ERR_LOG，供失败后定位。
# 失败行为：
#   tee 写日志失败时会触发 set -e，使脚本停止。
errlog() {
  printf '[%s] [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${ERR_LOG}" >&2
}

# warnlog：写入警告日志，并同步输出到 stderr。
# 参数：
#   $*：警告正文。
# 输出：
#   1. 标准错误流。
#   2. ERR_LOG，便于和错误一起排查。
warnlog() {
  printf '[%s] [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${ERR_LOG}" >&2
}

# die：记录错误并立即终止脚本。
# 参数：
#   $*：终止原因，必须写清楚用户需要检查的对象或下一步动作。
# 输出：
#   写入 ERR_LOG。
# 返回：
#   固定 exit 1。
die() {
  errlog "$*"
  if [[ -n "${STATE_FILE:-}" && -f "${STATE_FILE}" ]]; then
    printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "fatal" "FAILED" "$(redact_sensitive_text "$*")" >> "${STATE_FILE}"
  fi
  exit 1
}

# redact_sensitive_text：从外部命令日志中隐藏敏感字符串。
# 参数：
#   $1：待输出文本行。
# 输出：
#   隐藏 NCBI_API_KEY 后的文本。
redact_sensitive_text() {
  local text="$1"
  if [[ -n "${NCBI_API_KEY}" ]]; then
    text="${text//${NCBI_API_KEY}/<hidden>}"
  fi
  printf '%s' "${text}"
}

# require_command：检查必需命令是否存在。
# 参数：
#   $1 / cmd：命令名或可执行文件路径。
# 返回：
#   命令存在时返回 0；不存在时调用 die 终止。
require_command() {
  # cmd：待检查的命令名，例如 awk、datasets、unzip。
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "缺少命令：${cmd}。请先安装后重跑脚本。"
}

# validate_flag：校验 0/1 配置开关。
# 参数：
#   $1 / name：配置变量名，用于错误信息。
#   $2 / value：配置变量值，必须为 0 或 1。
# 返回：
#   合法时返回 0；非法时调用 die 终止。
validate_flag() {
  # name：被校验的变量名。
  local name="$1"
  # value：被校验的变量值。
  local value="$2"
  case "${value}" in
    0|1) ;;
    *) die "${name} 必须是 0 或 1，当前值为：${value}" ;;
  esac
}

# validate_csv_enum：校验 all 或逗号分隔枚举值。
# 参数：
#   $1 / name：配置变量名。
#   $2 / value：配置变量值。
#   $3 / allowed_csv：允许值，逗号分隔；all 总是允许。
# 返回：
#   合法时返回 0；非法时调用 die。
validate_csv_enum() {
  local name="$1"
  local value="$2"
  local allowed_csv="$3"
  local old_ifs="${IFS}"
  local item

  [[ "${value}" != "" ]] || die "${name} 不能为空。"
  [[ "${value}" == "all" ]] && return 0
  [[ "${value}" != ","* && "${value}" != *"," && "${value}" != *",,"* ]] || die "${name} 包含空枚举项：${value}"

  IFS=','
  for item in ${value}; do
    IFS="${old_ifs}"
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "${item}" ]] || die "${name} 包含空白枚举项：${value}"
    case ",${allowed_csv}," in
      *,"${item}",*) ;;
      *) die "${name} 包含不支持的值：${item}。允许值：all 或 ${allowed_csv}" ;;
    esac
    IFS=','
  done
  IFS="${old_ifs}"
}

# safe_name：把路径或标识符转换为可用于文件名的安全字符串。
# 参数：
#   $1：任意路径或字符串。
# 输出：
#   将 / : 空格 反斜杠 点号替换成下划线后的字符串。
# 用途：
#   给 trash 文件名或临时标识生成稳定标签。
safe_name() {
  printf '%s' "$1" | tr '/: \\.' '_____'
}

# move_to_trash：隔离异常文件或旧文件，不做删除。
# 参数：
#   $1 / path：需要隔离的文件或目录。
#   $2 / reason：隔离原因，会写入目标文件名。
# 输出：
#   将 path 移动到 TRASH_DIR，并在 DL_LOG 记录来源和去向。
# 返回：
#   path 不存在时直接返回 0；移动失败时由 set -e 终止。
move_to_trash() {
  # path：待移动的文件或目录，可以是普通文件、目录或 partial 文件。
  local path="$1"
  # reason：移动原因，例如 old_zip、bad_zip、empty_manifest。
  local reason="$2"
  # rel_label：由原始路径转换成的安全文件名片段。
  local rel_label
  # dest：TRASH_DIR 内最终目标路径。
  local dest
  # suffix：当目标路径已存在时追加的递增后缀。
  local suffix=1

  [[ -e "${path}" ]] || return 0
  rel_label="$(printf '%s' "${path}" | tr '/: \\.' '_____')"
  dest="${TRASH_DIR}/${reason}.${RUN_ID}.${rel_label}"
  mkdir -p "${TRASH_DIR}"
  while [[ -e "${dest}" ]]; do
    dest="${TRASH_DIR}/${reason}.${RUN_ID}.${rel_label}.${suffix}"
    suffix=$((suffix + 1))
  done
  mv -- "${path}" "${dest}"
  log "已将异常或旧文件移入 trash：${path} -> ${dest}"
}

# finalize_partial_file：把 partial 文件移动到最终路径，并显式记录落盘失败。
# 参数：
#   $1 / partial_file：待落盘的临时文件。
#   $2 / final_file：最终文件路径。
#   $3 / stage：失败时写入 STATE_FILE 的阶段名。
# 返回：
#   mv 成功返回 0；失败时写入 FAILED_FINALIZE_EXIT_* 并返回 mv 退出码。
finalize_partial_file() {
  # partial_file：待移动的临时文件路径。
  local partial_file="$1"
  # final_file：目标文件路径。
  local final_file="$2"
  # stage：状态表阶段名。
  local stage="$3"
  # exit_code：mv 失败时的退出码。
  local exit_code

  if mv -- "${partial_file}" "${final_file}"; then
    return 0
  else
    exit_code=$?
    errlog "partial 文件移动到最终路径失败：${stage}；退出码：${exit_code}；临时文件：${partial_file}；目标文件：${final_file}"
    write_state "${stage}" "FAILED_FINALIZE_EXIT_${exit_code}" "${partial_file}->${final_file}"
    return "${exit_code}"
  fi
}

# tail_error_log：把外部命令日志尾部摘录到 ERR_LOG。
# 参数：
#   $1 / log_file：需要摘录的日志文件。
#   $2 / max_lines：最多摘录行数，默认 30。
# 返回：
#   日志文件不存在时返回 0；日志文件存在时逐行写入 errlog。
tail_error_log() {
  # log_file：外部命令 stdout/stderr 日志路径。
  local log_file="$1"
  # max_lines：错误摘录最大行数。
  local max_lines="${2:-30}"
  # safe_line：脱敏后的日志行。
  local safe_line
  [[ -f "${log_file}" ]] || return 0
  tail -n "${max_lines}" "${log_file}" | while IFS= read -r line; do
    safe_line="$(redact_sensitive_text "${line}")"
    errlog "  ${safe_line}"
  done
}

# run_logged_command_with_retries：带日志、脱敏和自动重试地执行外部命令。
# 参数：
#   $1 / stage：阶段名，用于错误日志，例如 datasets_download:refseq_000001。
#   $2 / max_retries：最大尝试次数，必须为正整数。
#   $3 / sleep_seconds：失败后等待秒数，必须为非负整数。
#   $4 / log_file：最终日志路径；多次尝试时同时保留 .attemptN 日志。
#   $5...：需要执行的命令及其参数。
# 输出：
#   log_file 记录最后一次尝试的完整输出，attempt 日志保留每次尝试。
# 失败行为：
#   所有尝试失败时返回最后一次命令退出码，由调用方写阶段状态。
run_logged_command_with_retries() {
  local stage="$1"
  local max_retries="$2"
  local sleep_seconds="$3"
  local log_file="$4"
  shift 4
  local attempt=1
  local exit_code=0
  local attempt_log

  while [[ "${attempt}" -le "${max_retries}" ]]; do
    attempt_log="${log_file}"
    if [[ "${max_retries}" -gt 1 ]]; then
      attempt_log="${log_file}.attempt${attempt}"
    fi
    log "${stage}：第 ${attempt}/${max_retries} 次尝试。日志：${attempt_log}"
    if "$@" > "${attempt_log}" 2>&1; then
      redact_log_file "${attempt_log}"
      if [[ "${attempt_log}" != "${log_file}" ]]; then
        cat "${attempt_log}" > "${log_file}"
      fi
      return 0
    else
      exit_code=$?
    fi
    redact_log_file "${attempt_log}"
    errlog "${stage} 失败：第 ${attempt}/${max_retries} 次；退出码：${exit_code}；日志：${attempt_log}"
    tail_error_log "${attempt_log}" 30
    if [[ "${attempt}" -lt "${max_retries}" ]]; then
      log "${stage} 将在 ${sleep_seconds} 秒后重试。"
      sleep "${sleep_seconds}"
    fi
    attempt=$((attempt + 1))
  done

  if [[ "${attempt_log}" != "${log_file}" && -f "${attempt_log}" ]]; then
    cat "${attempt_log}" > "${log_file}" || true
  fi
  return "${exit_code}"
}

# run_rehydrate_list_precheck_with_retries：执行 datasets rehydrate --list，但不保存完整 stdout 清单。
# 参数：
#   $1 / stage：阶段名。
#   $2 / max_retries：最大尝试次数。
#   $3 / sleep_seconds：失败后等待秒数。
#   $4 / log_file：摘要日志路径。
#   $5 / count_file：stdout 行数输出路径。
#   $6...：需要执行的 rehydrate --list 命令及其参数。
# 输出：
#   log_file 只记录命令摘要、stdout 行数和 stderr 日志路径；stdout 明细流式计数后丢弃。
# 说明：
#   rehydrate --list 对全量 RefSeq 会输出数百万行目标文件清单，不能走通用完整日志脱敏流程。
run_rehydrate_list_precheck_with_retries() {
  local stage="$1"
  local max_retries="$2"
  local sleep_seconds="$3"
  local log_file="$4"
  local count_file="$5"
  shift 5
  local attempt=1
  local exit_code=0
  local attempt_log
  local stderr_log
  local line_count
  local stderr_lines
  local stderr_bytes
  local command_text

  command_text="$(printf '%q ' "$@")"
  command_text="$(redact_sensitive_text "${command_text}")"

  while [[ "${attempt}" -le "${max_retries}" ]]; do
    attempt_log="${log_file}"
    if [[ "${max_retries}" -gt 1 ]]; then
      attempt_log="${log_file}.attempt${attempt}"
    fi
    stderr_log="${attempt_log}.stderr"
    log "${stage}：第 ${attempt}/${max_retries} 次尝试。摘要日志：${attempt_log}；stderr：${stderr_log}"

    line_count=""
    if line_count="$("$@" 2> "${stderr_log}" | wc -l | awk '{print $1}')"; then
      redact_log_file "${stderr_log}"
      stderr_lines="$(count_lines "${stderr_log}")"
      stderr_bytes="$(wc -c < "${stderr_log}" | awk '{print $1}')"
      {
        printf 'stage=%s\n' "${stage}"
        printf 'attempt=%s/%s\n' "${attempt}" "${max_retries}"
        printf 'command=%s\n' "${command_text}"
        printf 'status=DONE\n'
        printf 'exit_code=0\n'
        printf 'stdout=discarded_after_line_count\n'
        printf 'stdout_lines=%s\n' "${line_count}"
        printf 'stderr_log=%s\n' "${stderr_log}"
        printf 'stderr_lines=%s\n' "${stderr_lines}"
        printf 'stderr_bytes=%s\n' "${stderr_bytes}"
      } > "${attempt_log}"
      printf '%s\n' "${line_count}" > "${count_file}"
      if [[ "${attempt_log}" != "${log_file}" ]]; then
        cat "${attempt_log}" > "${log_file}"
      fi
      return 0
    else
      exit_code=$?
    fi

    redact_log_file "${stderr_log}"
    stderr_lines="$(count_lines "${stderr_log}")"
    stderr_bytes="$(wc -c < "${stderr_log}" | awk '{print $1}')"
    {
      printf 'stage=%s\n' "${stage}"
      printf 'attempt=%s/%s\n' "${attempt}" "${max_retries}"
      printf 'command=%s\n' "${command_text}"
      printf 'status=FAILED\n'
      printf 'exit_code=%s\n' "${exit_code}"
      printf 'stdout=discarded_after_line_count\n'
      printf 'stdout_lines_partial=%s\n' "${line_count:-unknown}"
      printf 'stderr_log=%s\n' "${stderr_log}"
      printf 'stderr_lines=%s\n' "${stderr_lines}"
      printf 'stderr_bytes=%s\n' "${stderr_bytes}"
    } > "${attempt_log}"
    errlog "${stage} 失败：第 ${attempt}/${max_retries} 次；退出码：${exit_code}；摘要日志：${attempt_log}；stderr：${stderr_log}"
    tail_error_log "${stderr_log}" 30
    if [[ "${attempt}" -lt "${max_retries}" ]]; then
      log "${stage} 将在 ${sleep_seconds} 秒后重试。"
      sleep "${sleep_seconds}"
    fi
    attempt=$((attempt + 1))
  done

  if [[ "${attempt_log}" != "${log_file}" && -f "${attempt_log}" ]]; then
    cat "${attempt_log}" > "${log_file}" || true
  fi
  return "${exit_code}"
}

# log_rehydrate_progress_snapshot：输出一次 rehydrate 下载进度快照。
# 参数：
#   $1 / target_count：fetch target 总数。
#   $2 / data_dir：ncbi_dataset/data 目录。
# 输出：
#   主日志中写入当前文件数、accession 目录数和数据目录大小。
log_rehydrate_progress_snapshot() {
  local target_count="$1"
  local data_dir="$2"
  local downloaded_count=0
  local accession_count=0
  local data_size="0"
  local percent="n/a"

  if [[ -d "${data_dir}" ]]; then
    downloaded_count="$(find "${data_dir}" -type f 2>/dev/null | wc -l | awk '{print $1}')" || downloaded_count=0
    accession_count="$(find "${data_dir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | awk '{print $1}')" || accession_count=0
    data_size="$(du -sh "${data_dir}" 2>/dev/null | awk '{print $1}')" || data_size="unknown"
  fi

  if [[ "${target_count}" =~ ^[0-9]+$ && "${target_count}" -gt 0 ]]; then
    percent="$(awk -v done="${downloaded_count}" -v total="${target_count}" 'BEGIN {printf "%.4f", (done * 100) / total}')"
  fi
  log "rehydrate progress: files=${downloaded_count}/${target_count} (${percent}%), accession_dirs=${accession_count}, data_size=${data_size}, data_dir=${data_dir}"
}

# monitor_rehydrate_progress：在 datasets rehydrate 运行时周期性记录进度。
# 参数：
#   $1 / watched_pid：datasets rehydrate 进程 PID。
#   $2 / interval_seconds：进度输出间隔；0 表示关闭。
#   $3 / target_count：fetch target 总数。
#   $4 / data_dir：ncbi_dataset/data 目录。
#   $5 / min_free_gb：当前数据盘最小剩余空间；0 表示不做空间中止。
monitor_rehydrate_progress() {
  local watched_pid="$1"
  local interval_seconds="$2"
  local target_count="$3"
  local data_dir="$4"
  local min_free_gb="${5:-0}"
  local avail_gb

  [[ "${interval_seconds}" -gt 0 || "${min_free_gb}" -gt 0 ]] || return 0
  if [[ "${interval_seconds}" -le 0 ]]; then
    interval_seconds=60
  fi
  while kill -0 "${watched_pid}" 2>/dev/null; do
    log_rehydrate_progress_snapshot "${target_count}" "${data_dir}" || true
    if [[ "${min_free_gb}" -gt 0 ]]; then
      if avail_gb="$(storage_free_gb "${data_dir}")"; then
        if [[ "${avail_gb}" -lt "${min_free_gb}" ]]; then
          warnlog "当前 rehydrate 数据盘剩余空间 ${avail_gb} GB < ${min_free_gb} GB，停止当前 datasets rehydrate，后续尝试将切换候选盘：${data_dir}"
          kill -TERM "${watched_pid}" 2>/dev/null || true
          return 0
        fi
      fi
    fi
    sleep "${interval_seconds}" || return 0
  done
}

# stop_progress_monitor：停止后台进度监控进程。
# 参数：
#   $1 / monitor_pid：monitor_rehydrate_progress 的 PID；空值时无动作。
stop_progress_monitor() {
  local monitor_pid="$1"

  [[ -n "${monitor_pid}" ]] || return 0
  if kill -0 "${monitor_pid}" 2>/dev/null; then
    kill -TERM "${monitor_pid}" 2>/dev/null || true
    wait "${monitor_pid}" 2>/dev/null || true
  fi
}

# run_logged_command_with_retries_and_progress：带日志、脱敏、重试和 rehydrate 进度监控地执行命令。
# 参数：
#   $1 / stage：阶段名。
#   $2 / max_retries：最大尝试次数。
#   $3 / sleep_seconds：失败后等待秒数。
#   $4 / log_file：最终日志路径。
#   $5 / progress_interval_seconds：进度输出间隔；0 表示关闭。
#   $6 / progress_target_count：fetch target 总数。
#   $7 / progress_data_dir：ncbi_dataset/data 目录。
#   $8 / min_free_gb：当前数据盘最小剩余空间；0 表示不做空间中止。
#   $9...：需要执行的命令及其参数。
run_logged_command_with_retries_and_progress() {
  local stage="$1"
  local max_retries="$2"
  local sleep_seconds="$3"
  local log_file="$4"
  local progress_interval_seconds="$5"
  local progress_target_count="$6"
  local progress_data_dir="$7"
  local min_free_gb="$8"
  shift 8
  local attempt=1
  local exit_code=0
  local attempt_log
  local cmd_pid
  local monitor_pid

  while [[ "${attempt}" -le "${max_retries}" ]]; do
    attempt_log="${log_file}"
    if [[ "${max_retries}" -gt 1 ]]; then
      attempt_log="${log_file}.attempt${attempt}"
    fi
    log "${stage}：第 ${attempt}/${max_retries} 次尝试。日志：${attempt_log}"
    "$@" > "${attempt_log}" 2>&1 &
    cmd_pid=$!
    monitor_pid=""
    if [[ "${progress_interval_seconds}" -gt 0 || "${min_free_gb}" -gt 0 ]]; then
      monitor_rehydrate_progress "${cmd_pid}" "${progress_interval_seconds}" "${progress_target_count}" "${progress_data_dir}" "${min_free_gb}" &
      monitor_pid=$!
    fi
    if wait "${cmd_pid}"; then
      stop_progress_monitor "${monitor_pid}"
      log_rehydrate_progress_snapshot "${progress_target_count}" "${progress_data_dir}" || true
      redact_log_file "${attempt_log}"
      if [[ "${attempt_log}" != "${log_file}" ]]; then
        cat "${attempt_log}" > "${log_file}"
      fi
      return 0
    else
      exit_code=$?
      stop_progress_monitor "${monitor_pid}"
      log_rehydrate_progress_snapshot "${progress_target_count}" "${progress_data_dir}" || true
    fi
    redact_log_file "${attempt_log}"
    errlog "${stage} 失败：第 ${attempt}/${max_retries} 次；退出码：${exit_code}；日志：${attempt_log}"
    tail_error_log "${attempt_log}" 30
    if [[ "${attempt}" -lt "${max_retries}" ]]; then
      log "${stage} 将在 ${sleep_seconds} 秒后重试。"
      sleep "${sleep_seconds}"
    fi
    attempt=$((attempt + 1))
  done

  if [[ "${attempt_log}" != "${log_file}" && -f "${attempt_log}" ]]; then
    cat "${attempt_log}" > "${log_file}" || true
  fi
  return "${exit_code}"
}

# redact_log_file：把外部命令完整日志中的敏感字符串原地脱敏。
# 参数：
#   $1 / log_file：需要脱敏的日志文件。
# 输出：
#   如果 NCBI_API_KEY 非空，则重写 log_file，把 key 替换为 <hidden>。
redact_log_file() {
  # log_file：需要脱敏的日志文件。
  local log_file="$1"
  # tmp_file：脱敏过程的临时文件。
  local tmp_file="${log_file}.redacted.${RUN_ID}"
  # safe_line：脱敏后的单行文本。
  local safe_line

  [[ -n "${NCBI_API_KEY}" && -f "${log_file}" ]] || return 0
  : > "${tmp_file}"
  while IFS= read -r line; do
    safe_line="$(redact_sensitive_text "${line}")"
    printf '%s\n' "${safe_line}" >> "${tmp_file}"
  done < "${log_file}"
  mv -- "${tmp_file}" "${log_file}"
}

# check_disk_space：检查目标目录所在分区剩余空间。
# 参数：
#   $1 / target_dir：用于 df 检查的目录；不存在时会先创建。
# 依赖：
#   MIN_DISK_GB 配置。
# 返回：
#   剩余空间足够时返回 0；不足或无法读取时调用 die。
check_disk_space() {
  # target_dir：需要保证可用空间的目录。
  local target_dir="$1"
  # avail_gb：df 读取到的剩余空间，单位 GB，已去掉 G 后缀。
  local avail_gb

  mkdir -p "${target_dir}"
  avail_gb=$(df -BG "${target_dir}" | awk 'NR==2 {gsub("G","",$4); print $4}')
  [[ -n "${avail_gb}" ]] || die "无法读取磁盘剩余空间：${target_dir}"
  log "可用磁盘空间：${avail_gb} GB；阈值：${MIN_DISK_GB} GB；路径：${target_dir}"
  if [[ "${avail_gb}" -lt "${MIN_DISK_GB}" ]]; then
    die "磁盘空间不足：剩余 ${avail_gb} GB < 阈值 ${MIN_DISK_GB} GB。请释放空间或调低 MIN_DISK_GB 后重跑。"
  fi
}

# storage_free_gb：读取指定路径所在分区剩余空间，单位 GB。
# 参数：
#   $1 / target_dir：需要检查的目录；不存在时会先创建。
# 输出：
#   剩余空间 GB；读取失败时返回非 0。
storage_free_gb() {
  local target_dir="$1"
  local avail_gb

  mkdir -p "${target_dir}"
  avail_gb="$(df -BG "${target_dir}" | awk 'NR==2 {gsub("G","",$4); print $4}')"
  [[ -n "${avail_gb}" ]] || return 1
  printf '%s' "${avail_gb}" 2>/dev/null || return 1
}

# rehydrate_package_dir_for_root：返回某个数据根目录下的 rehydrate package 目录。
rehydrate_package_dir_for_root() {
  local data_root="$1"
  printf '%s/contexts/%s/%s' "${data_root}" "${PIPELINE_CONTEXT_NAME}" "${REHYDRATE_PACKAGE_NAME}"
}

# rehydrate_data_dir_for_root：返回某个数据根目录下的真实 rehydrate 数据目录。
rehydrate_data_dir_for_root() {
  local data_root="$1"
  printf '%s/ncbi_dataset/data' "$(rehydrate_package_dir_for_root "${data_root}")"
}

# expected_rehydrate_target：把 fetch target 转换为 rehydrate 后实际落盘 target。
expected_rehydrate_target() {
  local target="$1"
  if [[ "${REHYDRATE_GZIP}" == "1" && ! "${target}" =~ \.gz$ ]]; then
    printf '%s.gz' "${target}"
  else
    printf '%s' "${target}"
  fi
}

# select_rehydrate_data_root：按候选顺序选择剩余空间不低于 STORAGE_MIN_FREE_GB 的数据根目录。
select_rehydrate_data_root() {
  local data_root_candidate
  local avail_gb

  for data_root_candidate in "${DATA_ROOT_CANDIDATES[@]}"; do
    if avail_gb="$(storage_free_gb "${data_root_candidate}")"; then
      if [[ "${avail_gb}" -ge "${STORAGE_MIN_FREE_GB}" ]]; then
        printf '%s' "${data_root_candidate}"
        return 0
      fi
    fi
  done
  return 1
}

# collect_existing_rehydrate_targets：收集所有候选盘中已存在的 rehydrate 目标相对路径。
# 参数：
#   $1 / out_file：输出路径，内容形如 data/GCF_xxx/file.fna.gz。
collect_existing_rehydrate_targets() {
  local out_file="$1"
  local data_root_candidate
  local data_dir
  local legacy_data_dir="${MERGED_PACKAGE_DIR}/ncbi_dataset/data"

  : > "${out_file}.partial.${RUN_ID}"
  for data_root_candidate in "${DATA_ROOT_CANDIDATES[@]}"; do
    data_dir="$(rehydrate_data_dir_for_root "${data_root_candidate}")"
    if [[ -d "${data_dir}" ]]; then
      find "${data_dir}" -type f -printf 'data/%P\n' >> "${out_file}.partial.${RUN_ID}"
    fi
  done
  if [[ -d "${legacy_data_dir}" ]]; then
    find "${legacy_data_dir}" -type f -printf 'data/%P\n' >> "${out_file}.partial.${RUN_ID}"
  fi
  sort -u "${out_file}.partial.${RUN_ID}" > "${out_file}"
}

# build_remaining_fetch_for_root：为指定候选盘生成仅包含未完成目标的 fetch.txt。
# 参数：
#   $1 / data_root：当前要写入的候选数据根目录。
#   $2 / count_file：输出剩余 fetch 行数。
build_remaining_fetch_for_root() {
  local data_root="$1"
  local count_file="$2"
  local package_dir
  local package_ncbi_dir
  local dest_fetch
  local existing_targets_file="${STATUS_DIR}/existing_rehydrate_targets_${RUN_ID}.tsv"
  local remaining_count

  package_dir="$(rehydrate_package_dir_for_root "${data_root}")"
  package_ncbi_dir="${package_dir}/ncbi_dataset"
  dest_fetch="${package_ncbi_dir}/fetch.txt"
  mkdir -p "${package_ncbi_dir}"

  collect_existing_rehydrate_targets "${existing_targets_file}"
  awk -F '\t' -v gzip_mode="${REHYDRATE_GZIP}" -v existing_file="${existing_targets_file}" '
    BEGIN {
      while ((getline line < existing_file) > 0) {
        existing[line] = 1
      }
      close(existing_file)
    }
    NF >= 3 {
      target = $3
      sub(/\r$/, "", target)
      expected = target
      if (gzip_mode == "1" && expected !~ /\.gz$/) {
        expected = expected ".gz"
      }
      if (!(expected in existing)) {
        print $0
      }
    }
  ' "${MERGED_FETCH_FILE}" > "${dest_fetch}.partial.${RUN_ID}"

  mv -- "${dest_fetch}.partial.${RUN_ID}" "${dest_fetch}"
  remaining_count="$(count_lines "${dest_fetch}")"
  printf '%s\n' "${remaining_count}" > "${count_file}"

  if [[ -s "${MERGED_PACKAGE_DIR}/ncbi_dataset/assembly_data_report.jsonl" ]]; then
    cp -- "${MERGED_PACKAGE_DIR}/ncbi_dataset/assembly_data_report.jsonl" "${package_ncbi_dir}/assembly_data_report.jsonl"
  fi
}

# find_rehydrate_target_file：在所有候选盘里查找某个 fetch target 的实际本地文件。
# 参数：
#   $1 / target：fetch.txt 第三列目标路径。
# 输出：
#   找到时输出绝对路径；找不到时返回非 0。
find_rehydrate_target_file() {
  local target="$1"
  local expected_target
  local data_root_candidate
  local candidate_file

  expected_target="$(expected_rehydrate_target "${target}")"
  for data_root_candidate in "${DATA_ROOT_CANDIDATES[@]}"; do
    candidate_file="$(rehydrate_package_dir_for_root "${data_root_candidate}")/ncbi_dataset/${expected_target}"
    if [[ -s "${candidate_file}" ]]; then
      printf '%s' "${candidate_file}"
      return 0
    fi
  done
  candidate_file="${MERGED_PACKAGE_DIR}/ncbi_dataset/${expected_target}"
  if [[ -s "${candidate_file}" ]]; then
    printf '%s' "${candidate_file}"
    return 0
  fi
  return 1
}

# resolve_assembly_summary_path：解析 assembly_summary 文件的真实路径。
# 参数：
#   $1 / raw：用户配置的 ASSEMBLY_SUMMARY_FILE，可能是 Windows 路径或 Linux 路径。
# 输出：
#   可读文件的实际路径。
# 兼容：
#   1. 原路径已经存在。
#   2. Windows C:\... 转成 WSL /mnt/c/...。
#   3. Windows C:\... 转成 Git Bash 风格 /c/...。
# 失败行为：
#   找不到文件时调用 die。
resolve_assembly_summary_path() {
  # raw：原始路径字符串。
  local raw="$1"
  # drive：Windows 盘符，统一转小写。
  local drive
  # rest：去掉盘符后的 Windows 路径主体，并把反斜杠转成斜杠。
  local rest
  # candidate：逐个尝试的 Linux/Git Bash 兼容路径。
  local candidate

  if [[ -f "${raw}" ]]; then
    printf '%s' "${raw}"
    return 0
  fi

  if [[ "${raw}" =~ ^([A-Za-z]):\\(.*)$ ]]; then
    drive="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
    rest="${BASH_REMATCH[2]//\\//}"
    for candidate in "/mnt/${drive}/${rest}" "/${drive}/${rest}"; do
      if [[ -f "${candidate}" ]]; then
        printf '%s' "${candidate}"
        return 0
      fi
    done
  fi

  die "找不到 assembly_summary_refseq.txt：${raw}。如果在 Linux 服务器运行，请先复制该文件，并设置 ASSEMBLY_SUMMARY_FILE 为服务器上的实际路径。"
}

# write_state：向本次运行状态表追加一条阶段记录。
# 参数：
#   $1 / stage：阶段名，例如 download_links、rehydrate、verify_targets。
#   $2 / status：状态，例如 DONE、FAILED、FAILED_MISSING_ACCESSIONS。
#   $3 / detail：状态细节，通常是日志文件或状态表路径。
# 输出：
#   追加写入 STATE_FILE，四列：时间、阶段、状态、细节。
write_state() {
  # stage：阶段名。
  local stage="$1"
  # status：阶段状态。
  local status="$2"
  # detail：日志路径、状态表路径或数量等补充信息。
  local detail="$3"
  printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${stage}" "${status}" "${detail}" >> "${STATE_FILE}"
}

# on_unhandled_error：收口未被显式 if/die 捕获的 Bash 错误。
# 参数：
#   $1 / exit_code：失败命令退出码。
#   $2 / line_no：失败发生的脚本行号。
#   $3 / command_text：Bash 提供的失败命令文本。
# 输出：
#   写入 ERR_LOG 和 STATE_FILE；如果日志本身不可写，至少向 stderr 输出。
on_unhandled_error() {
  # exit_code：失败命令退出码。
  local exit_code="$1"
  # line_no：失败命令所在行号。
  local line_no="$2"
  # command_text：失败命令文本，写日志前需要脱敏。
  local command_text="$3"
  # detail：状态表中的失败详情。
  local detail
  # error_line：写入日志和 stderr 的完整错误行。
  local error_line

  trap - ERR
  detail="line=${line_no};command=$(redact_sensitive_text "${command_text}")"
  error_line="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] 未处理命令失败；退出码：${exit_code}；${detail}"
  if printf '%s\n' "${error_line}" >> "${ERR_LOG}" 2>/dev/null; then
    printf '%s\n' "${error_line}" >&2
  else
    printf '[ERROR] 未处理命令失败；退出码：%s；%s\n' "${exit_code}" "${detail}" >&2
  fi
  if [[ -f "${STATE_FILE}" ]]; then
    write_state "unhandled" "FAILED_EXIT_${exit_code}" "${detail}"
  fi
  exit "${exit_code}"
}

trap 'on_unhandled_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

# init_run_state：初始化本次运行状态表。
# 参数：
#   无。
# 输出：
#   STATE_FILE，包含表头。
init_run_state() {
  printf 'time\tstage\tstatus\tdetail\n' > "${STATE_FILE}"
}

# init_package_status：初始化 dehydrated zip 下载状态表。
# 参数：
#   无。
# 输出：
#   PACKAGE_STATUS_FILE，包含表头。
init_package_status() {
  printf 'shard_id\tstatus\tdetail\n' > "${PACKAGE_STATUS_FILE}"
}

# init_unpack_status：初始化 dehydrated zip 解包状态表。
# 参数：
#   无。
# 输出：
#   UNPACK_STATUS_FILE，包含表头。
init_unpack_status() {
  printf 'shard_id\tstatus\tdetail\n' > "${UNPACK_STATUS_FILE}"
}

# count_lines：安全统计文件行数。
# 参数：
#   $1 / file：待统计文件。
# 输出：
#   文件存在时输出行数；不存在时输出 0。
# 用途：
#   统一用于日志、summary 和状态统计，避免 wc 对不存在文件报错。
count_lines() {
  # file：待统计的文件路径。
  local file="$1"
  if [[ -f "${file}" ]]; then
    wc -l < "${file}" | awk '{print $1}'
  else
    printf '0'
  fi
}

# count_current_zip_files：统计当前 shard list 对应的 dehydrated zip 数量。
# 参数：
#   无。
# 输出：
#   当前 shard list 中已存在 zip 的数量。
count_current_zip_files() {
  local count=0
  local shard_file
  local shard_id

  if [[ ! -s "${SHARD_LIST_FILE}" ]]; then
    printf '0'
    return 0
  fi
  while IFS= read -r shard_file; do
    [[ -n "${shard_file}" ]] || continue
    shard_id="$(basename "${shard_file}" .txt)"
    [[ -s "${ZIP_DIR}/${shard_id}.zip" ]] && count=$((count + 1))
  done < "${SHARD_LIST_FILE}"
  printf '%s' "${count}"
}

# count_current_unpacked_fetch_files：统计当前 shard list 对应的已解包 fetch.txt 数量。
# 参数：
#   无。
# 输出：
#   当前 shard list 中已存在 fetch.txt 的数量。
count_current_unpacked_fetch_files() {
  local count=0
  local shard_file
  local shard_id

  if [[ ! -s "${SHARD_LIST_FILE}" ]]; then
    printf '0'
    return 0
  fi
  while IFS= read -r shard_file; do
    [[ -n "${shard_file}" ]] || continue
    shard_id="$(basename "${shard_file}" .txt)"
    [[ -s "${UNPACK_DIR}/${shard_id}/ncbi_dataset/fetch.txt" ]] && count=$((count + 1))
  done < "${SHARD_LIST_FILE}"
  printf '%s' "${count}"
}

# configure_action：根据命令行 action 覆盖阶段开关。
# 参数：
#   $1 / action：all、manifest、download-links、unpack-links、merge-fetch、rehydrate、verify、summary。
# 修改的全局变量：
#   RUN_BUILD_MANIFEST、RUN_DOWNLOAD_LINKS、RUN_UNPACK_LINKS、RUN_MERGE_FETCH、RUN_REHYDRATE、RUN_VERIFY。
# 失败行为：
#   action 不在白名单内时调用 die。
configure_action() {
  # action：用户请求执行的阶段组合；为空时默认为 all。
  local action="${1:-all}"

  case "${action}" in
    all)
      # all：完整流水线，依次执行 manifest、链接包下载、解包、fetch 汇总、rehydrate 和校验。
      RUN_BUILD_MANIFEST=1
      RUN_DOWNLOAD_LINKS=1
      RUN_UNPACK_LINKS=1
      RUN_MERGE_FETCH=1
      RUN_REHYDRATE=1
      RUN_VERIFY=1
      ;;
    manifest)
      # manifest：只解析 assembly_summary 并生成 accession/shard 清单，不访问 NCBI Datasets API。
      RUN_BUILD_MANIFEST=1
      RUN_DOWNLOAD_LINKS=0
      RUN_UNPACK_LINKS=0
      RUN_MERGE_FETCH=0
      RUN_REHYDRATE=0
      RUN_VERIFY=0
      ;;
    download-links)
      # download-links：保证 manifest/shard 存在，然后只下载 dehydrated 链接包。
      RUN_BUILD_MANIFEST=1
      RUN_DOWNLOAD_LINKS=1
      RUN_UNPACK_LINKS=0
      RUN_MERGE_FETCH=0
      RUN_REHYDRATE=0
      RUN_VERIFY=0
      ;;
    unpack-links)
      # unpack-links：只解包已下载的 dehydrated zip，提取每个 shard 的 fetch.txt。
      RUN_BUILD_MANIFEST=0
      RUN_DOWNLOAD_LINKS=0
      RUN_UNPACK_LINKS=1
      RUN_MERGE_FETCH=0
      RUN_REHYDRATE=0
      RUN_VERIFY=0
      ;;
    merge-fetch)
      # merge-fetch：只汇总 fetch.txt，不检查真实数据文件是否已经 rehydrate。
      RUN_BUILD_MANIFEST=0
      RUN_DOWNLOAD_LINKS=0
      RUN_UNPACK_LINKS=0
      RUN_MERGE_FETCH=1
      RUN_REHYDRATE=0
      RUN_VERIFY=0
      ;;
    rehydrate)
      # rehydrate：只执行统一下载真实数据，并在完成后做校验。
      RUN_BUILD_MANIFEST=0
      RUN_DOWNLOAD_LINKS=0
      RUN_UNPACK_LINKS=0
      RUN_MERGE_FETCH=0
      RUN_REHYDRATE=1
      RUN_VERIFY=1
      ;;
    verify)
      # verify：不下载，只重复执行 accession 覆盖、目标文件存在性和可选 MD5 校验。
      RUN_BUILD_MANIFEST=0
      RUN_DOWNLOAD_LINKS=0
      RUN_UNPACK_LINKS=0
      RUN_MERGE_FETCH=0
      RUN_REHYDRATE=0
      RUN_VERIFY=1
      ;;
    summary)
      # summary：不重跑任何阶段，只基于当前 context 已有状态文件重新生成汇总报告。
      RUN_BUILD_MANIFEST=0
      RUN_DOWNLOAD_LINKS=0
      RUN_UNPACK_LINKS=0
      RUN_MERGE_FETCH=0
      RUN_REHYDRATE=0
      RUN_VERIFY=0
      ;;
    *)
      die "未知 action：${action}。可选：all / manifest / download-links / unpack-links / merge-fetch / rehydrate / verify / summary"
      ;;
  esac
}

# normalize_force_flags：把上游 FORCE 操作自动传递给依赖它的下游阶段。
# 参数：
#   无。
# 修改的全局变量：
#   FORCE_UNPACK_LINKS、FORCE_MERGE_FETCH。
# 用途：
#   防止 FORCE_DOWNLOAD_LINKS=1 后继续复用旧 unpack/fetch，或 FORCE_UNPACK_LINKS=1 后继续复用旧 merged fetch。
normalize_force_flags() {
  if [[ "${FORCE_DOWNLOAD_LINKS}" == "1" ]]; then
    if [[ "${FORCE_UNPACK_LINKS}" == "0" ]]; then
      FORCE_UNPACK_LINKS=1
      warnlog "FORCE_DOWNLOAD_LINKS=1，自动设置 FORCE_UNPACK_LINKS=1，避免新 zip 复用旧解包结果。"
    fi
    if [[ "${FORCE_MERGE_FETCH}" == "0" ]]; then
      FORCE_MERGE_FETCH=1
      warnlog "FORCE_DOWNLOAD_LINKS=1，自动设置 FORCE_MERGE_FETCH=1，避免新 zip 复用旧 fetch 汇总。"
    fi
  fi

  if [[ "${FORCE_UNPACK_LINKS}" == "1" && "${FORCE_MERGE_FETCH}" == "0" ]]; then
    FORCE_MERGE_FETCH=1
    warnlog "FORCE_UNPACK_LINKS=1，自动设置 FORCE_MERGE_FETCH=1，避免新解包结果复用旧 fetch 汇总。"
  fi
}

# require_action_commands：按当前 RUN_* 阶段检查真正需要的外部命令。
# 参数：
#   无。
# 行为：
#   本地阶段不强制要求 datasets/unzip；下载或 rehydrate 阶段才检查 datasets。
# 失败行为：
#   缺少任一必要命令时调用 die，避免执行到长流程中段才失败。
require_action_commands() {
  require_command awk
  require_command basename
  require_command cat
  require_command cksum
  require_command date
  require_command find
  require_command mv
  require_command sort
  require_command sleep
  require_command tail
  require_command tee
  require_command tr
  require_command wc

  if [[ "${RUN_BUILD_MANIFEST}" == "1" ]]; then
    require_command cp
    require_command split
  fi
  if [[ "${RUN_DOWNLOAD_LINKS}" == "1" ]]; then
    require_command "${DATASETS_BIN}"
    require_command "${UNZIP_BIN}"
    require_command df
  fi
  if [[ "${RUN_UNPACK_LINKS}" == "1" ]]; then
    require_command "${UNZIP_BIN}"
  fi
  if [[ "${RUN_MERGE_FETCH}" == "1" || "${RUN_REHYDRATE}" == "1" || "${RUN_VERIFY}" == "1" ]]; then
    require_command comm
  fi
  if [[ "${RUN_REHYDRATE}" == "1" ]]; then
    require_command cp
    require_command "${DATASETS_BIN}"
    require_command df
    if [[ "${REHYDRATE_PROGRESS_INTERVAL_SECONDS}" != "0" ]]; then
      require_command du
    fi
  fi
  if [[ "${RUN_VERIFY}" == "1" && "${REHYDRATE_GZIP}" == "1" ]]; then
    require_command gzip
  fi
  if [[ "${RUN_VERIFY}" == "1" && "${VERIFY_FETCH_MD5}" == "1" ]]; then
    require_command md5sum
  fi
}

# validate_config：集中校验所有用户可调整参数。
# 参数：
#   无。
# 检查内容：
#   1. 0/1 开关是否只使用 0 或 1。
#   2. 数值参数是否为非负整数或正整数。
#   3. datasets rehydrate worker 是否在官方允许的 1-30 范围内。
#   4. 固定枚举参数和逗号列表过滤项是否在脚本支持范围内。
# 失败行为：
#   任一配置非法时调用 die，避免进入长时间下载后才暴露配置错误。
validate_config() {
  validate_flag FILTER_LATEST_ONLY "${FILTER_LATEST_ONLY}"
  validate_flag FORCE_SINGLE_PACKAGE "${FORCE_SINGLE_PACKAGE}"
  validate_flag RUN_BUILD_MANIFEST "${RUN_BUILD_MANIFEST}"
  validate_flag RUN_DOWNLOAD_LINKS "${RUN_DOWNLOAD_LINKS}"
  validate_flag RUN_UNPACK_LINKS "${RUN_UNPACK_LINKS}"
  validate_flag RUN_MERGE_FETCH "${RUN_MERGE_FETCH}"
  validate_flag RUN_REHYDRATE "${RUN_REHYDRATE}"
  validate_flag RUN_VERIFY "${RUN_VERIFY}"
  validate_flag FORCE_REBUILD_MANIFEST "${FORCE_REBUILD_MANIFEST}"
  validate_flag FORCE_DOWNLOAD_LINKS "${FORCE_DOWNLOAD_LINKS}"
  validate_flag FORCE_UNPACK_LINKS "${FORCE_UNPACK_LINKS}"
  validate_flag FORCE_MERGE_FETCH "${FORCE_MERGE_FETCH}"
  validate_flag STOP_ON_LINK_DOWNLOAD_ERROR "${STOP_ON_LINK_DOWNLOAD_ERROR}"
  validate_flag REHYDRATE_LIST_BEFORE_DOWNLOAD "${REHYDRATE_LIST_BEFORE_DOWNLOAD}"
  validate_flag REHYDRATE_GZIP "${REHYDRATE_GZIP}"
  validate_flag VERIFY_FETCH_TARGETS_AFTER_REHYDRATE "${VERIFY_FETCH_TARGETS_AFTER_REHYDRATE}"
  validate_flag STRICT_INTEGRITY "${STRICT_INTEGRITY}"
  validate_flag VERIFY_FETCH_MD5 "${VERIFY_FETCH_MD5}"
  validate_flag VERIFY_FETCH_CHECKSUM_FORMAT "${VERIFY_FETCH_CHECKSUM_FORMAT}"
  validate_flag VERIFY_FETCH_FILE_PROFILE "${VERIFY_FETCH_FILE_PROFILE}"
  validate_flag REQUIRE_RESOLVED_CONTEXT_TOKEN "${REQUIRE_RESOLVED_CONTEXT_TOKEN}"

  [[ "${SHARD_SIZE}" =~ ^[1-9][0-9]*$ ]] || die "SHARD_SIZE 必须是正整数，当前值为：${SHARD_SIZE}"
  [[ "${DOWNLOAD_LINK_MAX_RETRIES}" =~ ^[1-9][0-9]*$ ]] || die "DOWNLOAD_LINK_MAX_RETRIES 必须是正整数，当前值为：${DOWNLOAD_LINK_MAX_RETRIES}"
  [[ "${REHYDRATE_MAX_RETRIES}" =~ ^[1-9][0-9]*$ ]] || die "REHYDRATE_MAX_RETRIES 必须是正整数，当前值为：${REHYDRATE_MAX_RETRIES}"
  [[ "${RETRY_SLEEP_SECONDS}" =~ ^[0-9]+$ ]] || die "RETRY_SLEEP_SECONDS 必须是非负整数，当前值为：${RETRY_SLEEP_SECONDS}"
  [[ "${REHYDRATE_MAX_WORKERS}" =~ ^[1-9][0-9]*$ ]] || die "REHYDRATE_MAX_WORKERS 必须是正整数，当前值为：${REHYDRATE_MAX_WORKERS}"
  [[ "${REHYDRATE_MAX_WORKERS}" -le 30 ]] || die "REHYDRATE_MAX_WORKERS 不能超过 30，当前值为：${REHYDRATE_MAX_WORKERS}"
  [[ "${REHYDRATE_PROGRESS_INTERVAL_SECONDS}" =~ ^[0-9]+$ ]] || die "REHYDRATE_PROGRESS_INTERVAL_SECONDS 必须是非负整数，当前值为：${REHYDRATE_PROGRESS_INTERVAL_SECONDS}"
  [[ "${STORAGE_MIN_FREE_GB}" =~ ^[0-9]+$ ]] || die "STORAGE_MIN_FREE_GB 必须是非负整数，当前值为：${STORAGE_MIN_FREE_GB}"
  [[ "${MIN_DISK_GB}" =~ ^[0-9]+$ ]] || die "MIN_DISK_GB 必须是非负整数，当前值为：${MIN_DISK_GB}"
  [[ "${MIN_GENOME_SIZE}" =~ ^[0-9]+$ ]] || die "MIN_GENOME_SIZE 必须是非负整数，当前值为：${MIN_GENOME_SIZE}"
  [[ "${MAX_ACCESSIONS}" =~ ^[0-9]+$ ]] || die "MAX_ACCESSIONS 必须是非负整数，当前值为：${MAX_ACCESSIONS}"
  [[ "${MIN_FETCH_TARGETS_PER_ACCESSION}" =~ ^[0-9]+$ ]] || die "MIN_FETCH_TARGETS_PER_ACCESSION 必须是非负整数，当前值为：${MIN_FETCH_TARGETS_PER_ACCESSION}"
  [[ "${MAX_VERIFY_MISSING_PREVIEW}" =~ ^[0-9]+$ ]] || die "MAX_VERIFY_MISSING_PREVIEW 必须是非负整数，当前值为：${MAX_VERIFY_MISSING_PREVIEW}"
  [[ "${ASSEMBLY_SOURCE}" == "RefSeq" ]] || die "ASSEMBLY_SOURCE 固定为 RefSeq，当前值为：${ASSEMBLY_SOURCE}"

  [[ "${STRICT_INTEGRITY}" == "0" || "${VERIFY_FETCH_MD5}" == "1" ]] || die "STRICT_INTEGRITY=1 时必须设置 VERIFY_FETCH_MD5=1；若要跳过 MD5，请先显式设置 STRICT_INTEGRITY=0。"
  validate_csv_enum INCLUDE_FILES "${INCLUDE_FILES}" "genome,protein,cds,gff3,gtf,gbff,rna,seq-report"
  validate_csv_enum FILTER_ASSEMBLY_LEVELS "${FILTER_ASSEMBLY_LEVELS}" "Complete Genome,Chromosome,Scaffold,Contig"
  validate_csv_enum FILTER_GROUPS "${FILTER_GROUPS}" "archaea,bacteria,viral,fungi,plant,protozoa,invertebrate,vertebrate_mammalian,vertebrate_other"

  case "${FILTER_GENOME_REP}" in
    all|Full) ;;
    *) die "FILTER_GENOME_REP 只能是 all 或 Full，当前值为：${FILTER_GENOME_REP}" ;;
  esac
  case "${FILTER_EXCLUDED_FROM_REFSEQ}" in
    all|clean) ;;
    *) die "FILTER_EXCLUDED_FROM_REFSEQ 只能是 all 或 clean，当前值为：${FILTER_EXCLUDED_FROM_REFSEQ}" ;;
  esac

  if [[ -n "${REQUIRED_FETCH_TARGET_CLASSES}" ]]; then
    # class_name：用户要求的 fetch 目标类别。
    local class_name
    # old_ifs：临时修改 IFS 前的原值。
    local old_ifs="${IFS}"
    IFS=','
    for class_name in ${REQUIRED_FETCH_TARGET_CLASSES}; do
      IFS="${old_ifs}"
      class_name="${class_name//[[:space:]]/}"
      case "${class_name}" in
        genome|protein|cds|gff3|gtf|gbff|rna|seq-report) ;;
        *) die "REQUIRED_FETCH_TARGET_CLASSES 包含不支持的类别：${class_name}" ;;
      esac
      IFS=','
    done
    IFS="${old_ifs}"
  fi
}

# write_manifest_config：保存 manifest 构建时使用的关键配置。
# 参数：
#   无。
# 输出：
#   MANIFEST_CONFIG_FILE，key=value 格式。
# 用途：
#   后续单独运行 unpack-links、merge-fetch、rehydrate、verify 时可追溯来源表和过滤配置上下文。
# 失败行为：
#   partial 文件写入或 mv 失败时由 set -e 终止。
write_manifest_config() {
  # 下面 here-doc 中的同名条目是写入 MANIFEST_CONFIG_FILE 的配置快照；
  # 它们不是重新定义运行时变量，而是为后续单阶段复跑保留上下文。
  cat > "${MANIFEST_CONFIG_FILE}.partial.${RUN_ID}" <<EOF
ASSEMBLY_SUMMARY_FILE=${RESOLVED_ASSEMBLY_SUMMARY_FILE}
ASSEMBLY_SUMMARY_SOURCE_URL=${ASSEMBLY_SUMMARY_SOURCE_URL}
ASSEMBLY_SUMMARY_CONTEXT_TOKEN=${ASSEMBLY_SUMMARY_CONTEXT_TOKEN}
INCLUDE_FILES=${INCLUDE_FILES}
ASSEMBLY_SOURCE=${ASSEMBLY_SOURCE}
PIPELINE_CONTEXT_ID=${PIPELINE_CONTEXT_ID}
PIPELINE_CONTEXT_COMPUTED_NAME=${PIPELINE_CONTEXT_COMPUTED_NAME}
PIPELINE_CONTEXT_NAME=${PIPELINE_CONTEXT_NAME}
PIPELINE_CONTEXT_OVERRIDE=${PIPELINE_CONTEXT_OVERRIDE}
STORAGE_DISK_CANDIDATES=${STORAGE_DISK_CANDIDATES[*]}
STORAGE_OWNER_DIR=${STORAGE_OWNER_DIR}
STORAGE_DATA_SUBDIR=${STORAGE_DATA_SUBDIR}
STORAGE_RUNLOG_SUBDIR=${STORAGE_RUNLOG_SUBDIR}
STORAGE_MIN_FREE_GB=${STORAGE_MIN_FREE_GB}
RUN_ROOT=${RUN_ROOT}
FILTER_LATEST_ONLY=${FILTER_LATEST_ONLY}
FILTER_GENOME_REP=${FILTER_GENOME_REP}
FILTER_EXCLUDED_FROM_REFSEQ=${FILTER_EXCLUDED_FROM_REFSEQ}
FILTER_ASSEMBLY_LEVELS=${FILTER_ASSEMBLY_LEVELS}
FILTER_GROUPS=${FILTER_GROUPS}
MIN_GENOME_SIZE=${MIN_GENOME_SIZE}
MAX_ACCESSIONS=${MAX_ACCESSIONS}
SHARD_SIZE=${SHARD_SIZE}
FORCE_SINGLE_PACKAGE=${FORCE_SINGLE_PACKAGE}
DOWNLOAD_LINK_MAX_RETRIES=${DOWNLOAD_LINK_MAX_RETRIES}
REHYDRATE_MAX_RETRIES=${REHYDRATE_MAX_RETRIES}
RETRY_SLEEP_SECONDS=${RETRY_SLEEP_SECONDS}
REHYDRATE_GZIP=${REHYDRATE_GZIP}
REHYDRATE_PROGRESS_INTERVAL_SECONDS=${REHYDRATE_PROGRESS_INTERVAL_SECONDS}
STRICT_INTEGRITY=${STRICT_INTEGRITY}
VERIFY_FETCH_MD5=${VERIFY_FETCH_MD5}
VERIFY_FETCH_CHECKSUM_FORMAT=${VERIFY_FETCH_CHECKSUM_FORMAT}
VERIFY_FETCH_FILE_PROFILE=${VERIFY_FETCH_FILE_PROFILE}
REQUIRED_FETCH_TARGET_CLASSES=${REQUIRED_FETCH_TARGET_CLASSES}
MIN_FETCH_TARGETS_PER_ACCESSION=${MIN_FETCH_TARGETS_PER_ACCESSION}
REQUIRE_RESOLVED_CONTEXT_TOKEN=${REQUIRE_RESOLVED_CONTEXT_TOKEN}
EOF
  mv -- "${MANIFEST_CONFIG_FILE}.partial.${RUN_ID}" "${MANIFEST_CONFIG_FILE}"
}

# ==================== 阶段 1：manifest 与 shard ====================
# build_manifest：解析 assembly_summary_refseq.txt，生成下载主表和 accession 清单。
# 参数：
#   $1 / input_file：已解析为本机可读路径的 assembly_summary_refseq.txt。
# 输入：
#   assembly_summary 标准表；脚本会按 ftp_path 字段动态定位，容忍少数 free-text stray tab 行。
# 输出：
#   1. MANIFEST_FILE：过滤后的 accession 主表。
#   2. MANIFEST_SUMMARY_FILE：过滤统计和 group/assembly_level 分布。
#   3. ACCESSION_FILE：datasets --inputfile 使用的 accession 清单。
#   4. ACCESSION_SORTED_FILE：覆盖校验使用的排序去重 accession 清单。
#   5. MANIFEST_CONFIG_FILE：本次过滤配置记录。
# 失败行为：
#   过滤结果为空时把 partial 文件移入 TRASH_DIR 并终止。
build_manifest() {
  # input_file：assembly_summary_refseq.txt 的实际可读路径。
  local input_file="$1"
  # manifest_tmp：MANIFEST_FILE 的临时写入路径，成功后原子移动。
  local manifest_tmp="${MANIFEST_FILE}.partial.${RUN_ID}"
  # summary_tmp：MANIFEST_SUMMARY_FILE 的临时写入路径。
  local summary_tmp="${MANIFEST_SUMMARY_FILE}.partial.${RUN_ID}"
  # accession_tmp：ACCESSION_FILE 的临时写入路径。
  local accession_tmp="${ACCESSION_FILE}.partial.${RUN_ID}"
  # manifest_log：manifest 阶段本地命令 stderr 日志。
  local manifest_log="${LOG_DIR}/manifest_${RUN_ID}.log"

  if [[ -s "${MANIFEST_FILE}" && -s "${ACCESSION_FILE}" && -s "${ACCESSION_SORTED_FILE}" && -s "${MANIFEST_CONFIG_FILE}" && "${FORCE_REBUILD_MANIFEST}" == "0" ]]; then
    log "已存在 manifest，跳过重建：${MANIFEST_FILE}"
    return 0
  fi

  if [[ "${FORCE_REBUILD_MANIFEST}" == "1" ]]; then
    move_to_trash "${MANIFEST_FILE}" "old_manifest"
    move_to_trash "${MANIFEST_SUMMARY_FILE}" "old_manifest_summary"
    move_to_trash "${ACCESSION_FILE}" "old_accessions"
    move_to_trash "${ACCESSION_SORTED_FILE}" "old_accessions_sorted"
    move_to_trash "${SHARD_DIR}" "old_shards"
    move_to_trash "${ZIP_DIR}" "old_context_zips"
    move_to_trash "${UNPACK_DIR}" "old_context_unpacked"
    move_to_trash "${MERGED_FETCH_FILE}" "old_merged_fetch"
    move_to_trash "${MERGED_FETCH_ACCESSIONS_FILE}" "old_fetch_accessions"
    move_to_trash "${MISSING_FETCH_ACCESSIONS_FILE}" "old_missing_fetch_accessions"
    move_to_trash "${EXTRA_FETCH_ACCESSIONS_FILE}" "old_extra_fetch_accessions"
    move_to_trash "${FETCH_TARGETS_FILE}" "old_fetch_targets"
    move_to_trash "${INVALID_FETCH_TARGETS_FILE}" "old_invalid_fetch_targets"
    move_to_trash "${INVALID_FETCH_ROWS_FILE}" "old_invalid_fetch_rows"
    move_to_trash "${FETCH_PROFILE_FILE}" "old_fetch_profile"
    move_to_trash "${MISSING_FETCH_CLASSES_FILE}" "old_missing_fetch_classes"
    move_to_trash "${MISSING_TARGETS_FILE}" "old_missing_targets"
    move_to_trash "${GZIP_STATUS_FILE}" "old_gzip_status"
    move_to_trash "${MD5_STATUS_FILE}" "old_md5_status"
    mkdir -p "${ZIP_DIR}" "${UNPACK_DIR}" "${MERGED_PACKAGE_DIR}/ncbi_dataset"
  fi

  log "开始解析 assembly summary：${input_file}"
  if awk \
    -v latest_only="${FILTER_LATEST_ONLY}" \
    -v genome_rep_filter="${FILTER_GENOME_REP}" \
    -v excluded_filter="${FILTER_EXCLUDED_FROM_REFSEQ}" \
    -v assembly_levels_filter="${FILTER_ASSEMBLY_LEVELS}" \
    -v groups_filter="${FILTER_GROUPS}" \
    -v min_genome_size="${MIN_GENOME_SIZE}" \
    -v max_accessions="${MAX_ACCESSIONS}" \
    -v manifest_out="${manifest_tmp}" \
    -v summary_out="${summary_tmp}" \
    -v accession_out="${accession_tmp}" '
    BEGIN {
      FS = OFS = "\t"
      print "# assembly_accession", "group", "assembly_level", "genome_rep", "version_status", "excluded_from_refseq", "genome_size", "ftp_path" > manifest_out
      total = gcf = selected = malformed = no_ftp = skip_non_gcf = skip_latest = skip_rep = skip_excluded = skip_level = skip_group = skip_size = 0
      split(assembly_levels_filter, level_arr, ",")
      for (i in level_arr) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", level_arr[i])
        if (level_arr[i] != "" && assembly_levels_filter != "all") allow_level[level_arr[i]] = 1
      }
      split(groups_filter, group_arr, ",")
      for (i in group_arr) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", group_arr[i])
        if (group_arr[i] != "" && groups_filter != "all") allow_group[group_arr[i]] = 1
      }
    }
    /^#/ || NF == 0 { next }
    {
      total++
      accession = $1
      if (accession !~ /^GCF_[0-9]+\.[0-9]+$/) {
        skip_non_gcf++
        next
      }
      gcf++
      if (NF != 38) {
        malformed++
      }

      version_status = $11
      assembly_level = $12
      genome_rep = $14
      ftp_idx = 0
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^https:\/\/ftp\.ncbi\.nlm\.nih\.gov\/genomes\//) {
          ftp_idx = i
          break
        }
      }
      if (ftp_idx == 0) {
        no_ftp++
        next
      }

      ftp_path = $ftp_idx
      excluded_from_refseq = (ftp_idx + 1 <= NF ? $(ftp_idx + 1) : "")
      group_name = (ftp_idx + 5 <= NF ? $(ftp_idx + 5) : "")
      genome_size = (ftp_idx + 6 <= NF ? $(ftp_idx + 6) : 0)
      if (ftp_path == "" || ftp_path == "na") {
        no_ftp++
        next
      }
      if (latest_only == "1" && version_status != "latest") {
        skip_latest++
        next
      }
      if (genome_rep_filter != "all" && genome_rep != genome_rep_filter) {
        skip_rep++
        next
      }
      if (excluded_filter == "clean" && excluded_from_refseq != "na") {
        skip_excluded++
        next
      }
      if (assembly_levels_filter != "all" && !(assembly_level in allow_level)) {
        skip_level++
        next
      }
      if (groups_filter != "all" && !(group_name in allow_group)) {
        skip_group++
        next
      }
      if (min_genome_size > 0 && genome_size + 0 < min_genome_size) {
        skip_size++
        next
      }

      print accession, group_name, assembly_level, genome_rep, version_status, excluded_from_refseq, genome_size, ftp_path >> manifest_out
      print accession >> accession_out
      selected++
      group_count[group_name]++
      level_count[assembly_level]++

      if (max_accessions > 0 && selected >= max_accessions) {
        exit
      }
    }
    END {
      print "metric", "value" > summary_out
      print "total_rows", total >> summary_out
      print "gcf_rows", gcf >> summary_out
      print "skip_non_gcf", skip_non_gcf >> summary_out
      print "selected", selected >> summary_out
      print "malformed_field_count_rows", malformed >> summary_out
      print "no_ftp_path", no_ftp >> summary_out
      print "skip_latest", skip_latest >> summary_out
      print "skip_genome_rep", skip_rep >> summary_out
      print "skip_excluded_from_refseq", skip_excluded >> summary_out
      print "skip_assembly_level", skip_level >> summary_out
      print "skip_group", skip_group >> summary_out
      print "skip_genome_size", skip_size >> summary_out
      for (g in group_count) {
        print "group:" g, group_count[g] >> summary_out
      }
      for (l in level_count) {
        print "assembly_level:" l, level_count[l] >> summary_out
      }
    }
  ' "${input_file}" 2> "${manifest_log}"; then
    :
  else
    local exit_code=$?
    tail_error_log "${manifest_log}" 40
    move_to_trash "${manifest_tmp}" "failed_manifest"
    move_to_trash "${summary_tmp}" "failed_manifest_summary"
    move_to_trash "${accession_tmp}" "failed_accessions"
    write_state "manifest" "FAILED_EXIT_${exit_code}" "${manifest_log}"
    die "解析 assembly_summary_refseq.txt 失败；退出码：${exit_code}；输入：${input_file}；日志：${manifest_log}"
  fi

  if [[ ! -s "${accession_tmp}" ]]; then
    move_to_trash "${manifest_tmp}" "empty_manifest"
    move_to_trash "${summary_tmp}" "empty_manifest_summary"
    move_to_trash "${accession_tmp}" "empty_accessions"
    die "manifest 为空。请检查过滤条件和 assembly_summary_refseq.txt。"
  fi

  if sort -u "${accession_tmp}" > "${ACCESSION_SORTED_FILE}.partial.${RUN_ID}" 2>> "${manifest_log}"; then
    :
  else
    local exit_code=$?
    tail_error_log "${manifest_log}" 40
    move_to_trash "${ACCESSION_SORTED_FILE}.partial.${RUN_ID}" "failed_accessions_sorted"
    write_state "manifest" "FAILED_EXIT_${exit_code}" "${manifest_log}"
    die "生成 accession 排序清单失败；退出码：${exit_code}；输入：${accession_tmp}；日志：${manifest_log}"
  fi
  mv -- "${manifest_tmp}" "${MANIFEST_FILE}"
  mv -- "${summary_tmp}" "${MANIFEST_SUMMARY_FILE}"
  mv -- "${accession_tmp}" "${ACCESSION_FILE}"
  mv -- "${ACCESSION_SORTED_FILE}.partial.${RUN_ID}" "${ACCESSION_SORTED_FILE}"
  write_manifest_config

  log "manifest 已生成：${MANIFEST_FILE}"
  log "accession 清单：${ACCESSION_FILE}；数量：$(count_lines "${ACCESSION_FILE}")"
  log "manifest 统计：${MANIFEST_SUMMARY_FILE}"
}

# build_shards：把 accession 清单拆分成多个 datasets 输入文件。
# 参数：
#   无。
# 输入：
#   ACCESSION_FILE。
# 输出：
#   1. SHARD_DIR/refseq_*.txt：每个 shard 的 accession 列表。
#   2. SHARD_LIST_FILE：所有 shard 文件路径，供 download-links 阶段读取。
# 行为：
#   FORCE_SINGLE_PACKAGE=1 时只生成一个 shard；否则按 SHARD_SIZE 分片。
# 失败行为：
#   ACCESSION_FILE 缺失时调用 die。
build_shards() {
  # accession_count：ACCESSION_FILE 中 accession 总数，用于日志。
  local accession_count
  # shard_log：本地分片、复制、排序命令的 stderr 日志。
  local shard_log="${LOG_DIR}/shards_${RUN_ID}.log"

  [[ -s "${ACCESSION_FILE}" ]] || die "缺少 accession 清单：${ACCESSION_FILE}。请先运行 manifest 阶段。"
  if [[ -s "${SHARD_LIST_FILE}" && "${FORCE_REBUILD_MANIFEST}" == "0" ]]; then
    log "已存在 shard 列表，跳过重建：${SHARD_LIST_FILE}"
    return 0
  fi

  if [[ -e "${SHARD_DIR}" ]]; then
    move_to_trash "${SHARD_DIR}" "old_shards_before_rebuild"
  fi
  mkdir -p "${SHARD_DIR}"
  accession_count="$(count_lines "${ACCESSION_FILE}")"
  if [[ "${FORCE_SINGLE_PACKAGE}" == "1" ]]; then
    if cp -- "${ACCESSION_FILE}" "${SHARD_DIR}/refseq_000000.txt" 2> "${shard_log}"; then
      :
    else
      local exit_code=$?
      tail_error_log "${shard_log}" 30
      write_state "shards" "FAILED_EXIT_${exit_code}" "${shard_log}"
      die "生成单包 shard 失败；退出码：${exit_code}；输入：${ACCESSION_FILE}；输出目录：${SHARD_DIR}；日志：${shard_log}"
    fi
  else
    if split -l "${SHARD_SIZE}" -d -a 6 --additional-suffix=.txt "${ACCESSION_FILE}" "${SHARD_DIR}/refseq_" 2> "${shard_log}"; then
      :
    else
      local exit_code=$?
      tail_error_log "${shard_log}" 30
      write_state "shards" "FAILED_EXIT_${exit_code}" "${shard_log}"
      die "生成 shard 失败；退出码：${exit_code}；输入：${ACCESSION_FILE}；输出目录：${SHARD_DIR}；日志：${shard_log}"
    fi
  fi

  if find "${SHARD_DIR}" -maxdepth 1 -type f -name 'refseq_*.txt' 2>> "${shard_log}" | sort 2>> "${shard_log}" > "${SHARD_LIST_FILE}.partial.${RUN_ID}"; then
    :
  else
    local exit_code=$?
    tail_error_log "${shard_log}" 30
    write_state "shards" "FAILED_EXIT_${exit_code}" "${shard_log}"
    die "生成 shard 列表失败；退出码：${exit_code}；目录：${SHARD_DIR}；日志：${shard_log}"
  fi
  mv -- "${SHARD_LIST_FILE}.partial.${RUN_ID}" "${SHARD_LIST_FILE}"

  log "shard 已生成：${SHARD_DIR}"
  log "accession 总数：${accession_count}；shard 数量：$(count_lines "${SHARD_LIST_FILE}")"
  write_state "shards" "DONE" "${SHARD_LIST_FILE}"
}

# ==================== 阶段 2：下载 dehydrated 链接包 ====================
# datasets_download_command_text：生成脱敏后的 datasets download 命令文本。
# 参数：
#   $1 / shard_file：当前 shard accession 文件。
#   $2 / out_file：当前 shard dehydrated zip 输出路径。
# 输出：
#   可写入日志的命令字符串；如果使用 NCBI_API_KEY，只显示 <hidden>。
# 注意：
#   该函数只生成日志文本，不执行命令。
datasets_download_command_text() {
  # shard_file：传给 --inputfile 的 accession shard 路径。
  local shard_file="$1"
  # out_file：传给 --filename 的 zip 输出路径。
  local out_file="$2"
  # api_text：脱敏后的 API key 传递方式；无 key 时为空。
  local api_text=""

  if [[ -n "${NCBI_API_KEY}" ]]; then
    api_text=" [NCBI_API_KEY exported]"
  fi
  printf '%s download genome accession --inputfile %s --dehydrated --include %s --assembly-source %s --filename %s --no-progressbar%s' \
    "${DATASETS_BIN}" "${shard_file}" "${INCLUDE_FILES}" "${ASSEMBLY_SOURCE}" "${out_file}" "${api_text}"
}

# download_one_dehydrated_package：下载单个 shard 的 dehydrated zip。
# 参数：
#   $1 / shard_file：一个 accession shard 文件。
# 输入：
#   shard_file 内每行一个 GCF accession。
# 输出：
#   1. ZIP_DIR/refseq_*.zip。
#   2. LOG_DIR/datasets_download_* 日志。
#   3. PACKAGE_STATUS_FILE 追加一条状态记录。
# 行为：
#   已存在且 unzip -t 通过的 zip 会跳过；坏 zip 或旧 zip 会移入 TRASH_DIR。
# 失败行为：
#   datasets download 失败、zip 为空、unzip -t 失败时返回非 0，不直接终止总流程。
download_one_dehydrated_package() {
  # shard_file：当前待下载的 accession shard 文件。
  local shard_file="$1"
  # shard_id：由 shard 文件名去掉 .txt 得到，用于 zip 和日志命名。
  local shard_id
  # zip_file：当前 shard 的最终 dehydrated zip 路径。
  local zip_file
  # tmp_zip：当前 shard 的临时 zip 路径，下载成功并校验后再移动为 zip_file。
  local tmp_zip
  # log_file：当前 datasets download 的 stdout/stderr 日志。
  local log_file
  # cmd：实际执行的 datasets download 命令数组，避免 shell 字符串拼接。
  local cmd=()
  # attempt：当前下载尝试次数。
  local attempt=1
  # attempt_log：当前尝试的 datasets download 日志。
  local attempt_log
  # exit_code：datasets download 的原始退出码，用于状态表和错误日志。
  local exit_code=0
  # verify_exit_code：unzip -t 的原始退出码。
  local verify_exit_code=0

  shard_id="$(basename "${shard_file}" .txt)"
  zip_file="${ZIP_DIR}/${shard_id}.zip"
  tmp_zip="${zip_file}.partial.${RUN_ID}"
  log_file="${LOG_DIR}/datasets_download_${shard_id}_${RUN_ID}.log"

  if [[ -s "${zip_file}" && "${FORCE_DOWNLOAD_LINKS}" == "0" ]]; then
    if "${UNZIP_BIN}" -t "${zip_file}" > "${log_file}.verify" 2>&1; then
      log "dehydrated zip 已存在且校验通过，跳过：${zip_file}"
      printf '%s\t%s\t%s\n' "${shard_id}" "SKIPPED_EXISTING" "${zip_file}" >> "${PACKAGE_STATUS_FILE}"
      return 0
    else
      verify_exit_code=$?
    fi
    errlog "已存在 zip 但 unzip -t 失败；退出码：${verify_exit_code}；将移入 trash 后重新下载：${zip_file}"
    tail_error_log "${log_file}.verify" 20
    move_to_trash "${zip_file}" "bad_zip"
  elif [[ -e "${zip_file}" && "${FORCE_DOWNLOAD_LINKS}" == "1" ]]; then
    move_to_trash "${zip_file}" "old_zip"
  fi

  move_to_trash "${tmp_zip}" "old_partial_zip"
  check_disk_space "${ZIP_DIR}"
  log "开始下载 dehydrated 链接包：${shard_id}；accession 数：$(count_lines "${shard_file}")"
  log "命令：$(datasets_download_command_text "${shard_file}" "${tmp_zip}")"

  cmd=(
    "${DATASETS_BIN}" download genome accession
    --inputfile "${shard_file}"
    --dehydrated
    --include "${INCLUDE_FILES}"
    --assembly-source "${ASSEMBLY_SOURCE}"
    --filename "${tmp_zip}"
    --no-progressbar
  )
  while [[ "${attempt}" -le "${DOWNLOAD_LINK_MAX_RETRIES}" ]]; do
    attempt_log="${log_file}"
    if [[ "${DOWNLOAD_LINK_MAX_RETRIES}" -gt 1 ]]; then
      attempt_log="${log_file}.attempt${attempt}"
    fi
    move_to_trash "${tmp_zip}" "retry_partial_zip"
    log "datasets download ${shard_id}：第 ${attempt}/${DOWNLOAD_LINK_MAX_RETRIES} 次尝试。日志：${attempt_log}"
    if "${cmd[@]}" > "${attempt_log}" 2>&1; then
      :
    else
      exit_code=$?
      redact_log_file "${attempt_log}"
      errlog "datasets download 失败：${shard_id}；第 ${attempt}/${DOWNLOAD_LINK_MAX_RETRIES} 次；退出码：${exit_code}；日志：${attempt_log}"
      tail_error_log "${attempt_log}" 30
      move_to_trash "${tmp_zip}" "failed_partial_zip"
      if [[ "${attempt}" -lt "${DOWNLOAD_LINK_MAX_RETRIES}" ]]; then
        log "datasets download ${shard_id} 将在 ${RETRY_SLEEP_SECONDS} 秒后重试。"
        sleep "${RETRY_SLEEP_SECONDS}"
        attempt=$((attempt + 1))
        continue
      fi
      if [[ "${attempt_log}" != "${log_file}" && -f "${attempt_log}" ]]; then
        cat "${attempt_log}" > "${log_file}" || true
      fi
      printf '%s\t%s\t%s\n' "${shard_id}" "FAILED_EXIT_${exit_code}" "${log_file}" >> "${PACKAGE_STATUS_FILE}"
      return "${exit_code}"
    fi

    redact_log_file "${attempt_log}"
    if [[ "${attempt_log}" != "${log_file}" ]]; then
      cat "${attempt_log}" > "${log_file}"
    fi
    if [[ ! -s "${tmp_zip}" ]]; then
      move_to_trash "${tmp_zip}" "empty_zip"
      errlog "datasets download 成功退出但 zip 为空：${shard_id}；第 ${attempt}/${DOWNLOAD_LINK_MAX_RETRIES} 次；日志：${attempt_log}"
      tail_error_log "${log_file}" 30
      if [[ "${attempt}" -lt "${DOWNLOAD_LINK_MAX_RETRIES}" ]]; then
        log "datasets download ${shard_id} 将在 ${RETRY_SLEEP_SECONDS} 秒后重试。"
        sleep "${RETRY_SLEEP_SECONDS}"
        attempt=$((attempt + 1))
        continue
      fi
      printf '%s\t%s\t%s\n' "${shard_id}" "FAILED_EMPTY_ZIP" "${log_file}" >> "${PACKAGE_STATUS_FILE}"
      return 1
    fi
    if "${UNZIP_BIN}" -t "${tmp_zip}" > "${log_file}.verify" 2>&1; then
      :
    else
      verify_exit_code=$?
      errlog "新下载 zip 的 unzip -t 校验失败：${shard_id}；第 ${attempt}/${DOWNLOAD_LINK_MAX_RETRIES} 次；退出码：${verify_exit_code}；日志：${log_file}.verify"
      tail_error_log "${log_file}.verify" 20
      move_to_trash "${tmp_zip}" "bad_zip_after_download"
      if [[ "${attempt}" -lt "${DOWNLOAD_LINK_MAX_RETRIES}" ]]; then
        log "datasets download ${shard_id} 将在 ${RETRY_SLEEP_SECONDS} 秒后重试。"
        sleep "${RETRY_SLEEP_SECONDS}"
        attempt=$((attempt + 1))
        continue
      fi
      printf '%s\t%s\t%s\n' "${shard_id}" "FAILED_ZIP_VERIFY_EXIT_${verify_exit_code}" "${log_file}.verify" >> "${PACKAGE_STATUS_FILE}"
      return 1
    fi
    if mv -- "${tmp_zip}" "${zip_file}"; then
      log "dehydrated 链接包下载完成：${zip_file}"
      printf '%s\t%s\t%s\n' "${shard_id}" "DONE" "${zip_file}" >> "${PACKAGE_STATUS_FILE}"
      return 0
    else
      exit_code=$?
      errlog "dehydrated zip 移动到最终路径失败：${shard_id}；退出码：${exit_code}；临时文件：${tmp_zip}；目标文件：${zip_file}"
      printf '%s\t%s\t%s\n' "${shard_id}" "FAILED_FINALIZE_EXIT_${exit_code}" "${tmp_zip}->${zip_file}" >> "${PACKAGE_STATUS_FILE}"
      return "${exit_code}"
    fi
  done

  printf '%s\t%s\t%s\n' "${shard_id}" "FAILED_RETRY_EXHAUSTED" "${log_file}" >> "${PACKAGE_STATUS_FILE}"
  return 1
}

# download_dehydrated_packages：按 SHARD_LIST_FILE 批量下载所有 dehydrated zip。
# 参数：
#   无。
# 输入：
#   SHARD_LIST_FILE，每行一个 shard_file 路径。
# 输出：
#   PACKAGE_STATUS_FILE，记录每个 shard 的 DONE/SKIPPED/FAILED 状态。
# 行为：
#   STOP_ON_LINK_DOWNLOAD_ERROR=0 时会尽量跑完所有 shard 后统一报错；
#   STOP_ON_LINK_DOWNLOAD_ERROR=1 时第一个失败 shard 会立即终止。
# 失败行为：
#   任何 shard 失败都会最终调用 die，提示用户重跑 download-links 阶段。
download_dehydrated_packages() {
  # failed：批量下载失败标志；0=全部成功或跳过，1=至少一个 shard 失败。
  local failed=0
  # shard_file：循环读取的单个 shard 文件路径。
  local shard_file

  [[ -s "${SHARD_LIST_FILE}" ]] || die "缺少 shard 列表：${SHARD_LIST_FILE}。请先运行 manifest 阶段。"
  init_package_status

  while IFS= read -r shard_file; do
    [[ -n "${shard_file}" ]] || continue
    if ! download_one_dehydrated_package "${shard_file}"; then
      failed=1
      if [[ "${STOP_ON_LINK_DOWNLOAD_ERROR}" == "1" ]]; then
        write_state "download_links" "FAILED" "${PACKAGE_STATUS_FILE}"
        die "dehydrated 链接包下载失败，已按 STOP_ON_LINK_DOWNLOAD_ERROR=1 停止。失败 shard：${shard_file}；状态表：${PACKAGE_STATUS_FILE}；错误日志：${ERR_LOG}"
      fi
    fi
  done < "${SHARD_LIST_FILE}"

  if [[ "${failed}" -ne 0 ]]; then
    write_state "download_links" "FAILED" "${PACKAGE_STATUS_FILE}"
    die "至少一个 dehydrated 链接包下载失败。可重跑 download-links 阶段；成功 zip 会自动跳过。状态表：${PACKAGE_STATUS_FILE}；错误日志：${ERR_LOG}"
  fi

  write_state "download_links" "DONE" "${PACKAGE_STATUS_FILE}"
  log "所有 dehydrated 链接包下载完成。状态表：${PACKAGE_STATUS_FILE}"
}

# ==================== 阶段 3：解包 dehydrated 链接包 ====================
# unpack_one_dehydrated_package：解包单个 dehydrated zip 并检查 fetch.txt。
# 参数：
#   $1 / zip_file：需要解包的 dehydrated zip 路径。
# 输出：
#   1. UNPACK_DIR/refseq_xxxxxx/ncbi_dataset/fetch.txt。
#   2. LOG_DIR/unzip_* 日志。
#   3. UNPACK_STATUS_FILE 追加一条状态记录。
# 行为：
#   已存在 fetch.txt 且 FORCE_UNPACK_LINKS=0 时跳过；旧解包目录会移入 TRASH_DIR。
# 失败行为：
#   unzip 失败或 fetch.txt 缺失时返回非 0。
unpack_one_dehydrated_package() {
  # zip_file：当前待解包的 dehydrated zip 文件。
  local zip_file="$1"
  # shard_id：由 zip 文件名去掉 .zip 得到，用于输出目录和日志命名。
  local shard_id
  # out_dir：当前 zip 的解包输出目录。
  local out_dir
  # log_file：当前 unzip 的 stdout/stderr 日志。
  local log_file

  shard_id="$(basename "${zip_file}" .zip)"
  out_dir="${UNPACK_DIR}/${shard_id}"
  log_file="${LOG_DIR}/unzip_${shard_id}_${RUN_ID}.log"

  if [[ -s "${out_dir}/ncbi_dataset/fetch.txt" && "${FORCE_UNPACK_LINKS}" == "0" ]]; then
    log "已存在解包目录和 fetch.txt，跳过：${out_dir}"
    printf '%s\t%s\t%s\n' "${shard_id}" "SKIPPED_EXISTING" "${out_dir}" >> "${UNPACK_STATUS_FILE}"
    return 0
  fi

  if [[ -e "${out_dir}" ]]; then
    move_to_trash "${out_dir}" "old_unpacked_package"
  fi

  mkdir -p "${out_dir}"
  log "开始解包 dehydrated 链接包：${zip_file} -> ${out_dir}"
  if "${UNZIP_BIN}" -q -n "${zip_file}" -d "${out_dir}" > "${log_file}" 2>&1; then
    if [[ ! -s "${out_dir}/ncbi_dataset/fetch.txt" ]]; then
      errlog "解包完成但缺少 fetch.txt：${out_dir}/ncbi_dataset/fetch.txt"
      move_to_trash "${out_dir}" "unpacked_without_fetch"
      printf '%s\t%s\t%s\n' "${shard_id}" "FAILED_NO_FETCH" "${out_dir}" >> "${UNPACK_STATUS_FILE}"
      return 1
    fi
    printf '%s\t%s\t%s\n' "${shard_id}" "DONE" "${out_dir}" >> "${UNPACK_STATUS_FILE}"
    return 0
  else
    # exit_code：unzip 的原始退出码，用于状态表和错误日志。
    local exit_code=$?
    errlog "unzip 失败：${zip_file}；退出码：${exit_code}；日志：${log_file}"
    tail_error_log "${log_file}" 30
    move_to_trash "${out_dir}" "failed_unpacked_package"
    printf '%s\t%s\t%s\n' "${shard_id}" "FAILED_EXIT_${exit_code}" "${log_file}" >> "${UNPACK_STATUS_FILE}"
    return "${exit_code}"
  fi
}

# unpack_dehydrated_packages：按当前 SHARD_LIST_FILE 批量解包对应 dehydrated zip。
# 参数：
#   无。
# 输入：
#   SHARD_LIST_FILE 和 ZIP_DIR/refseq_*.zip。
# 输出：
#   UNPACK_STATUS_FILE，记录每个 zip 的 DONE/SKIPPED/FAILED 状态。
# 失败行为：
#   未发现 zip 或任一 zip 解包失败时调用 die。
unpack_dehydrated_packages() {
  # failed：批量解包失败标志；0=全部成功或跳过，1=至少一个 zip 失败。
  local failed=0
  # shard_file：循环读取的单个 shard accession 文件路径。
  local shard_file
  # shard_id：由 shard_file basename 推导出的 shard 标识。
  local shard_id
  # zip_file：当前 shard 对应的 dehydrated zip 路径。
  local zip_file
  # expected_count：当前 shard 列表中期望解包的 zip 数量。
  local expected_count

  [[ -s "${SHARD_LIST_FILE}" ]] || die "缺少 shard 列表：${SHARD_LIST_FILE}。请先运行 manifest 阶段。"
  expected_count="$(count_lines "${SHARD_LIST_FILE}")"
  [[ "${expected_count}" -gt 0 ]] || die "shard 列表为空：${SHARD_LIST_FILE}"
  init_unpack_status

  while IFS= read -r shard_file; do
    [[ -n "${shard_file}" ]] || continue
    shard_id="$(basename "${shard_file}" .txt)"
    zip_file="${ZIP_DIR}/${shard_id}.zip"
    if [[ ! -s "${zip_file}" ]]; then
      errlog "缺少当前 shard 对应的 dehydrated zip：${zip_file}"
      printf '%s\t%s\t%s\n' "${shard_id}" "FAILED_MISSING_ZIP" "${zip_file}" >> "${UNPACK_STATUS_FILE}"
      failed=1
      continue
    fi
    if ! unpack_one_dehydrated_package "${zip_file}"; then
      failed=1
    fi
  done < "${SHARD_LIST_FILE}"

  if [[ "${failed}" -ne 0 ]]; then
    write_state "unpack_links" "FAILED" "${UNPACK_STATUS_FILE}"
    die "至少一个 dehydrated 链接包解包失败。可重跑 unpack-links 阶段。状态表：${UNPACK_STATUS_FILE}；错误日志：${ERR_LOG}"
  fi

  write_state "unpack_links" "DONE" "${UNPACK_STATUS_FILE}"
  log "所有 dehydrated 链接包解包完成。状态表：${UNPACK_STATUS_FILE}"
}

# refresh_merged_fetch_accessions：从 MERGED_FETCH_FILE 第三列 data/<accession>/ 重新提取 accession 集合。
# 参数：
#   无。
# 输入：
#   MERGED_FETCH_FILE。
# 输出：
#   MERGED_FETCH_ACCESSIONS_FILE，排序去重后的 GCA/GCF accession。
# 失败行为：
#   MERGED_FETCH_FILE 缺失或无法提取 accession 时调用 die。
refresh_merged_fetch_accessions() {
  # accession_log：提取和排序 accession 的 stderr 日志。
  local accession_log="${LOG_DIR}/fetch_accessions_${RUN_ID}.log"
  # exit_code：提取或排序命令失败时的退出码。
  local exit_code

  [[ -s "${MERGED_FETCH_FILE}" ]] || die "缺少汇总 fetch.txt：${MERGED_FETCH_FILE}"
  if awk -F '\t' '
    NF >= 3 && $3 ~ /^data\/GC[AF]_[0-9]+\.[0-9]+\// {
      split($3, target_parts, "/")
      print target_parts[2]
    }
  ' "${MERGED_FETCH_FILE}" 2> "${accession_log}" | sort -u 2>> "${accession_log}" > "${MERGED_FETCH_ACCESSIONS_FILE}.partial.${RUN_ID}"; then
    :
  else
    exit_code=$?
    tail_error_log "${accession_log}" 30
    move_to_trash "${MERGED_FETCH_ACCESSIONS_FILE}.partial.${RUN_ID}" "failed_fetch_accessions"
    write_state "fetch_accessions" "FAILED_EXIT_${exit_code}" "${accession_log}"
    die "从汇总 fetch.txt 提取 accession 失败；退出码：${exit_code}；日志：${accession_log}"
  fi
  mv -- "${MERGED_FETCH_ACCESSIONS_FILE}.partial.${RUN_ID}" "${MERGED_FETCH_ACCESSIONS_FILE}"
  [[ -s "${MERGED_FETCH_ACCESSIONS_FILE}" ]] || die "无法从汇总 fetch.txt 提取任何 GCA/GCF accession：${MERGED_FETCH_FILE}"
}

# check_fetch_accession_set：检查 fetch.txt accession 集合与 manifest 是否一致。
# 参数：
#   $1 / stage：写入 STATE_FILE 的阶段名。
# 输入：
#   ACCESSION_SORTED_FILE、MERGED_FETCH_FILE。
# 输出：
#   MISSING_FETCH_ACCESSIONS_FILE、EXTRA_FETCH_ACCESSIONS_FILE。
# 行为：
#   1. manifest 有但 fetch.txt 没有的 accession 默认硬失败。
#   2. fetch.txt 有但 manifest 没有的 accession 一律硬失败，防止旧 fetch 混入。
check_fetch_accession_set() {
  local stage="$1"
  # missing_count：manifest 中有但 fetch.txt 中没有的 accession 数。
  local missing_count
  # extra_count：fetch.txt 中有但 manifest 中没有的 accession 数。
  local extra_count
  # compare_log：comm 比较阶段的 stderr 日志。
  local compare_log="${LOG_DIR}/fetch_accession_compare_${RUN_ID}.log"
  # exit_code：comm 比较失败时的退出码。
  local exit_code

  [[ -s "${ACCESSION_SORTED_FILE}" ]] || die "缺少 accession 排序清单：${ACCESSION_SORTED_FILE}。请先运行 manifest 阶段。"
  refresh_merged_fetch_accessions

  if comm -23 "${ACCESSION_SORTED_FILE}" "${MERGED_FETCH_ACCESSIONS_FILE}" > "${MISSING_FETCH_ACCESSIONS_FILE}.partial.${RUN_ID}" 2> "${compare_log}"; then
    :
  else
    exit_code=$?
    tail_error_log "${compare_log}" 30
    move_to_trash "${MISSING_FETCH_ACCESSIONS_FILE}.partial.${RUN_ID}" "failed_missing_fetch_accessions"
    write_state "${stage}" "FAILED_EXIT_${exit_code}" "${compare_log}"
    die "比较 manifest 与 fetch accession 集合失败；退出码：${exit_code}；日志：${compare_log}"
  fi
  mv -- "${MISSING_FETCH_ACCESSIONS_FILE}.partial.${RUN_ID}" "${MISSING_FETCH_ACCESSIONS_FILE}"
  if comm -13 "${ACCESSION_SORTED_FILE}" "${MERGED_FETCH_ACCESSIONS_FILE}" > "${EXTRA_FETCH_ACCESSIONS_FILE}.partial.${RUN_ID}" 2>> "${compare_log}"; then
    :
  else
    exit_code=$?
    tail_error_log "${compare_log}" 30
    move_to_trash "${EXTRA_FETCH_ACCESSIONS_FILE}.partial.${RUN_ID}" "failed_extra_fetch_accessions"
    write_state "${stage}" "FAILED_EXIT_${exit_code}" "${compare_log}"
    die "比较 fetch 额外 accession 失败；退出码：${exit_code}；日志：${compare_log}"
  fi
  mv -- "${EXTRA_FETCH_ACCESSIONS_FILE}.partial.${RUN_ID}" "${EXTRA_FETCH_ACCESSIONS_FILE}"

  missing_count="$(count_lines "${MISSING_FETCH_ACCESSIONS_FILE}")"
  extra_count="$(count_lines "${EXTRA_FETCH_ACCESSIONS_FILE}")"

  if [[ "${extra_count}" -gt 0 ]]; then
    write_state "${stage}" "FAILED_EXTRA_ACCESSIONS" "${EXTRA_FETCH_ACCESSIONS_FILE}"
    errlog "fetch.txt 包含 manifest 外 accession：${extra_count} 个；详情：${EXTRA_FETCH_ACCESSIONS_FILE}"
    die "fetch accession 集合超出当前 manifest，疑似旧 fetch 混入。请检查配置指纹目录或设置 FORCE_MERGE_FETCH=1 后重跑。"
  fi

  if [[ "${missing_count}" -gt 0 ]]; then
    write_state "${stage}" "FAILED_MISSING_ACCESSIONS" "${MISSING_FETCH_ACCESSIONS_FILE}"
    errlog "fetch.txt 未覆盖全部 manifest accession：${missing_count} 个；详情：${MISSING_FETCH_ACCESSIONS_FILE}"
    die "fetch accession 覆盖校验失败。当前 manifest accession 必须全部进入 fetch.txt；请重跑 merge-fetch 或检查 dehydrated 包。"
  else
    write_state "${stage}" "DONE" "$(count_lines "${ACCESSION_SORTED_FILE}")"
    log "fetch accession 集合校验通过：manifest accession 全部覆盖，且无额外 accession。"
  fi
}

# ==================== 阶段 4：汇总 fetch.txt ====================
# merge_fetch_files：汇总各 shard 解包目录中的 fetch.txt。
# 参数：
#   无。
# 输入：
#   SHARD_LIST_FILE，以及每个当前 shard 对应的 UNPACK_DIR/<shard_id>/ncbi_dataset/fetch.txt。
# 输出：
#   1. MERGED_FETCH_FILE：去重后的统一 fetch.txt。
#   2. FETCH_SOURCE_LIST：参与汇总的 fetch.txt 来源列表。
#   3. MERGED_FETCH_ACCESSIONS_FILE：从总 fetch.txt 提取的 accession 集合。
#   4. MISSING_FETCH_ACCESSIONS_FILE：manifest 有但 fetch.txt 没覆盖的 accession。
#   5. EXTRA_FETCH_ACCESSIONS_FILE：fetch 有但 manifest 没有的 accession。
#   6. FETCH_TARGETS_FILE / FETCH_PROFILE_FILE：fetch 目标路径和按 accession 汇总的文件类别。
#   7. 合并后的 assembly_data_report.jsonl（如果 shard 包内存在）。
# 行为：
#   merge-fetch 单独运行会汇总链接并校验 fetch 行格式、路径安全和关键目标类别，不检查真实文件是否已经下载。
# 失败行为：
#   找不到当前 shard 对应的 fetch.txt、汇总结果为空或 accession 集合不一致时调用 die。
merge_fetch_files() {
  # fetch_tmp：MERGED_FETCH_FILE 的临时写入路径。
  local fetch_tmp="${MERGED_FETCH_FILE}.partial.${RUN_ID}"
  # report_tmp：合并 assembly_data_report.jsonl 的临时写入路径。
  local report_tmp="${MERGED_PACKAGE_DIR}/ncbi_dataset/assembly_data_report.jsonl.partial.${RUN_ID}"
  # fetch_file：循环读取的单个 shard fetch.txt。
  local fetch_file
  # report_file：循环读取的单个 shard assembly_data_report.jsonl。
  local report_file
  # fetch_count：汇总去重后的 fetch 目标行数。
  local fetch_count=0
  # source_count：参与汇总的 fetch.txt 文件数量。
  local source_count=0
  # missing_source：当前 shard 缺少 fetch.txt 的数量。
  local missing_source=0
  # shard_file：循环读取的当前 shard accession 文件。
  local shard_file
  # shard_id：由 shard 文件名推导出的 shard 标识。
  local shard_id
  # unpack_root：当前 shard 的解包目录。
  local unpack_root

  if [[ -s "${MERGED_FETCH_FILE}" && "${FORCE_MERGE_FETCH}" == "0" ]]; then
    log "已存在汇总 fetch.txt，跳过重建：${MERGED_FETCH_FILE}"
    check_fetch_accession_set "merge_fetch_accessions"
    write_fetch_targets
    write_state "merge_fetch" "DONE_REUSED" "${MERGED_FETCH_FILE}"
    return 0
  fi

  move_to_trash "${MERGED_FETCH_FILE}" "old_merged_fetch"
  move_to_trash "${MERGED_FETCH_ACCESSIONS_FILE}" "old_fetch_accessions"
  move_to_trash "${MISSING_FETCH_ACCESSIONS_FILE}" "old_missing_fetch_accessions"
  move_to_trash "${EXTRA_FETCH_ACCESSIONS_FILE}" "old_extra_fetch_accessions"
  move_to_trash "${FETCH_TARGETS_FILE}" "old_fetch_targets"
  move_to_trash "${INVALID_FETCH_TARGETS_FILE}" "old_invalid_fetch_targets"
  move_to_trash "${INVALID_FETCH_ROWS_FILE}" "old_invalid_fetch_rows"
  move_to_trash "${FETCH_PROFILE_FILE}" "old_fetch_profile"
  move_to_trash "${MISSING_FETCH_CLASSES_FILE}" "old_missing_fetch_classes"
  move_to_trash "${MISSING_TARGETS_FILE}" "old_missing_targets"
  move_to_trash "${MD5_STATUS_FILE}" "old_md5_status"
  move_to_trash "${MERGED_PACKAGE_DIR}/ncbi_dataset/assembly_data_report.jsonl" "old_merged_report"
  mkdir -p "${MERGED_PACKAGE_DIR}/ncbi_dataset"
  : > "${fetch_tmp}"
  : > "${report_tmp}"
  printf 'index\tshard_id\tfetch_file\n' > "${FETCH_SOURCE_LIST}"

  [[ -s "${SHARD_LIST_FILE}" ]] || die "缺少 shard 列表：${SHARD_LIST_FILE}。请先运行 manifest 阶段。"
  log "开始汇总当前 shard 的 fetch.txt。来源目录：${UNPACK_DIR}"
  while IFS= read -r shard_file; do
    [[ -n "${shard_file}" ]] || continue
    shard_id="$(basename "${shard_file}" .txt)"
    unpack_root="${UNPACK_DIR}/${shard_id}"
    fetch_file="${unpack_root}/ncbi_dataset/fetch.txt"
    if [[ ! -s "${fetch_file}" ]]; then
      errlog "缺少当前 shard 对应的 fetch.txt：${fetch_file}"
      missing_source=$((missing_source + 1))
      continue
    fi
    source_count=$((source_count + 1))
    printf '%s\t%s\t%s\n' "${source_count}" "${shard_id}" "${fetch_file}" >> "${FETCH_SOURCE_LIST}"
    awk -F '\t' 'NF > 0 && $1 !~ /^#/ { print }' "${fetch_file}" >> "${fetch_tmp}"
    while IFS= read -r report_file; do
      [[ -n "${report_file}" ]] || continue
      cat "${report_file}" >> "${report_tmp}"
    done < <(find "${unpack_root}" -name 'assembly_data_report.jsonl' -type f | sort)
  done < "${SHARD_LIST_FILE}"

  [[ "${source_count}" -gt 0 ]] || die "未找到任何 fetch.txt。请先运行 unpack-links 阶段。"
  if [[ "${missing_source}" -gt 0 ]]; then
    write_state "merge_fetch" "FAILED_MISSING_FETCH_SOURCE" "${FETCH_SOURCE_LIST}"
    die "当前 shard 有 ${missing_source} 个缺少 fetch.txt。请先重跑 unpack-links 阶段；详情见错误日志：${ERR_LOG}"
  fi

  awk -F '\t' '!seen[$0]++ { print }' "${fetch_tmp}" > "${fetch_tmp}.dedup"
  mv -- "${fetch_tmp}.dedup" "${fetch_tmp}"
  fetch_count="$(count_lines "${fetch_tmp}")"
  [[ "${fetch_count}" -gt 0 ]] || die "汇总后的 fetch.txt 为空。请检查 dehydrated 包内容。"

  mv -- "${fetch_tmp}" "${MERGED_FETCH_FILE}"
  if [[ -s "${report_tmp}" ]]; then
    mv -- "${report_tmp}" "${MERGED_PACKAGE_DIR}/ncbi_dataset/assembly_data_report.jsonl"
  else
    move_to_trash "${report_tmp}" "empty_merged_report"
  fi

  check_fetch_accession_set "merge_fetch_accessions"
  write_fetch_targets

  write_state "merge_fetch" "DONE" "${MERGED_FETCH_FILE}"
  log "fetch.txt 汇总完成：${MERGED_FETCH_FILE}"
  log "fetch 来源数：${source_count}；fetch 目标行数：${fetch_count}；fetch 中 accession 数：$(count_lines "${MERGED_FETCH_ACCESSIONS_FILE}")"
}

# ==================== 阶段 5：统一 rehydrate ====================
# rehydrate_merged_package：对统一 package 执行 datasets rehydrate。
# 参数：
#   无。
# 输入：
#   MERGED_PACKAGE_DIR/ncbi_dataset/fetch.txt。
# 输出：
#   MERGED_PACKAGE_DIR/ncbi_dataset/data/ 下的真实数据文件。
# 行为：
#   REHYDRATE_LIST_BEFORE_DOWNLOAD=1 时先运行 datasets rehydrate --list 预检。
# 失败行为：
#   --list 失败或 rehydrate 失败时返回非 0，并写入 STATE_FILE。
rehydrate_merged_package() {
  # log_file：datasets rehydrate 正式下载日志。
  local log_file="${LOG_DIR}/datasets_rehydrate_${RUN_ID}.log"
  # list_log：datasets rehydrate --list 预检日志。
  local list_log="${LOG_DIR}/datasets_rehydrate_list_${RUN_ID}.log"
  # list_count_file：datasets rehydrate --list stdout 行数记录。
  local list_count_file="${LOG_DIR}/datasets_rehydrate_list_${RUN_ID}.stdout_lines"
  # cmd：正式 rehydrate 命令数组。
  local cmd=()
  # list_cmd：rehydrate --list 预检命令数组。
  local list_cmd=()
  # list_count：rehydrate --list 输出行数，仅用于状态记录。
  local list_count=0
  # target_count：fetch target 总数，用于 rehydrate 进度日志。
  local target_count=0
  # attempt：rehydrate 当前尝试次数。
  local attempt=1
  # selected_data_root：当前尝试使用的数据根目录。
  local selected_data_root
  # selected_package_dir：当前尝试使用的 rehydrate package 目录。
  local selected_package_dir
  # selected_data_dir：当前尝试使用的真实数据目录。
  local selected_data_dir
  # remaining_count_file：当前尝试剩余 fetch 行数记录。
  local remaining_count_file
  # remaining_count：当前尝试仍需下载的 fetch 行数。
  local remaining_count=0
  # rehydrate_log：当前尝试的 datasets rehydrate 日志。
  local rehydrate_log
  # selected_avail_gb：当前候选盘剩余空间。
  local selected_avail_gb
  # exit_code：datasets rehydrate 失败退出码。
  local exit_code

  [[ -s "${MERGED_FETCH_FILE}" ]] || die "缺少汇总 fetch.txt：${MERGED_FETCH_FILE}。请先运行 merge-fetch 阶段。"
  check_fetch_accession_set "rehydrate_precheck_accessions"
  write_fetch_targets
  target_count="$(count_lines "${FETCH_TARGETS_FILE}")"

  if [[ "${REHYDRATE_LIST_BEFORE_DOWNLOAD}" == "1" ]]; then
    list_cmd=("${DATASETS_BIN}" rehydrate --directory "${MERGED_PACKAGE_DIR}" --list)
    log "执行 rehydrate --list 预检：${DATASETS_BIN} rehydrate --directory ${MERGED_PACKAGE_DIR} --list"
    if run_rehydrate_list_precheck_with_retries "datasets rehydrate --list" "${REHYDRATE_MAX_RETRIES}" "${RETRY_SLEEP_SECONDS}" "${list_log}" "${list_count_file}" "${list_cmd[@]}"; then
      list_count="$(awk 'NR == 1 {print $1}' "${list_count_file}")"
      write_state "rehydrate_list" "DONE" "lines=${list_count};log=${list_log}"
      log "rehydrate --list 预检通过：stdout 行数 ${list_count}；摘要日志：${list_log}"
    else
      local exit_code=$?
      errlog "datasets rehydrate --list 失败；退出码：${exit_code}；摘要日志：${list_log}"
      tail_error_log "${list_log}" 30
      write_state "rehydrate_list" "FAILED_EXIT_${exit_code}" "${list_log}"
      return 1
    fi
  fi

  log "rehydrate 候选数据根目录：${DATA_ROOT_CANDIDATES[*]}"
  log "rehydrate gzip=${REHYDRATE_GZIP}; min_free_gb=${STORAGE_MIN_FREE_GB}"
  if [[ "${REHYDRATE_PROGRESS_INTERVAL_SECONDS}" -gt 0 ]]; then
    log "rehydrate 进度日志已启用：每 ${REHYDRATE_PROGRESS_INTERVAL_SECONDS} 秒输出一次；目标文件数：${target_count}"
  else
    log "rehydrate 进度日志已关闭；磁盘保护仍会按 ${STORAGE_MIN_FREE_GB} GB 阈值运行。"
  fi

  while [[ "${attempt}" -le "${REHYDRATE_MAX_RETRIES}" ]]; do
    if ! selected_data_root="$(select_rehydrate_data_root)"; then
      write_state "rehydrate" "FAILED_NO_STORAGE" "min_free_gb=${STORAGE_MIN_FREE_GB};candidates=${DATA_ROOT_CANDIDATES[*]}"
      die "所有候选数据盘剩余空间均低于 ${STORAGE_MIN_FREE_GB} GB，无法继续 rehydrate。候选：${DATA_ROOT_CANDIDATES[*]}"
    fi
    selected_avail_gb="$(storage_free_gb "${selected_data_root}")"
    selected_package_dir="$(rehydrate_package_dir_for_root "${selected_data_root}")"
    selected_data_dir="${selected_package_dir}/ncbi_dataset/data"
    remaining_count_file="${STATUS_DIR}/rehydrate_remaining_${RUN_ID}.attempt${attempt}.count"
    build_remaining_fetch_for_root "${selected_data_root}" "${remaining_count_file}"
    remaining_count="$(awk 'NR == 1 {print $1}' "${remaining_count_file}")"

    if [[ "${remaining_count}" -eq 0 ]]; then
      write_state "rehydrate" "DONE" "all_targets_present;candidates=${DATA_ROOT_CANDIDATES[*]}"
      log "所有 rehydrate 目标文件已在候选盘中存在，跳过 datasets rehydrate。"
      return 0
    fi

    cmd=(
      "${DATASETS_BIN}" rehydrate
      --directory "${selected_package_dir}"
      --max-workers "${REHYDRATE_MAX_WORKERS}"
      --no-progressbar
    )
    if [[ "${REHYDRATE_GZIP}" == "1" ]]; then
      cmd+=(--gzip)
    fi
    rehydrate_log="${log_file}.attempt${attempt}"
    log "开始 rehydrate：attempt=${attempt}/${REHYDRATE_MAX_RETRIES}; data_root=${selected_data_root}; avail_gb=${selected_avail_gb}; remaining_targets=${remaining_count}; package=${selected_package_dir}"
    log "命令：${DATASETS_BIN} rehydrate --directory ${selected_package_dir} --max-workers ${REHYDRATE_MAX_WORKERS} --no-progressbar$([[ "${REHYDRATE_GZIP}" == "1" ]] && printf ' --gzip' || true)"
    if run_logged_command_with_retries_and_progress "datasets rehydrate" 1 "${RETRY_SLEEP_SECONDS}" "${rehydrate_log}" "${REHYDRATE_PROGRESS_INTERVAL_SECONDS}" "${remaining_count}" "${selected_data_dir}" "${STORAGE_MIN_FREE_GB}" "${cmd[@]}"; then
      cat "${rehydrate_log}" > "${log_file}" || true
      write_state "rehydrate" "DONE" "log=${log_file};data_root=${selected_data_root};gzip=${REHYDRATE_GZIP}"
      log "统一 rehydrate 完成。日志：${log_file}；最终数据根目录之一：${selected_data_root}"
      return 0
    else
      exit_code=$?
    fi

    tail_error_log "${rehydrate_log}" 40
    selected_avail_gb="$(storage_free_gb "${selected_data_root}")"
    if [[ "${attempt}" -lt "${REHYDRATE_MAX_RETRIES}" ]]; then
      if [[ "${selected_avail_gb}" -lt "${STORAGE_MIN_FREE_GB}" ]]; then
        warnlog "当前数据盘剩余 ${selected_avail_gb} GB < ${STORAGE_MIN_FREE_GB} GB，下次尝试将选择下一个可用候选盘。"
      else
        warnlog "datasets rehydrate 失败；退出码：${exit_code}；当前数据盘仍有 ${selected_avail_gb} GB，${RETRY_SLEEP_SECONDS} 秒后重试。"
      fi
      sleep "${RETRY_SLEEP_SECONDS}"
    fi
    attempt=$((attempt + 1))
  done

  errlog "datasets rehydrate 失败；已尝试 ${REHYDRATE_MAX_RETRIES} 次；最后退出码：${exit_code}；日志：${log_file}"
  write_state "rehydrate" "FAILED_EXIT_${exit_code}" "${log_file}"
  return "${exit_code}"
}

# ==================== 阶段 6：校验 ====================
# write_fetch_targets：从总 fetch.txt 提取目标文件相对路径。
# 参数：
#   无。
# 输入：
#   MERGED_FETCH_FILE，第三列为 rehydrate 后的相对目标路径。
# 输出：
#   FETCH_TARGETS_FILE、INVALID_FETCH_TARGETS_FILE、INVALID_FETCH_ROWS_FILE、FETCH_PROFILE_FILE。
# 失败行为：
#   MERGED_FETCH_FILE 缺失、目标路径不安全、checksum/target 格式异常、目标清单为空、
#   或关键 fetch 目标类别缺失时调用 die。
write_fetch_targets() {
  # invalid_count：不安全目标路径数量。
  local invalid_count
  # invalid_row_count：checksum 或 target 格式异常的原始行数量。
  local invalid_row_count
  # target_count：合法 fetch target 数量。
  local target_count
  # target_log：fetch target 解析阶段的 stderr 日志。
  local target_log="${LOG_DIR}/fetch_targets_${RUN_ID}.log"
  # exit_code：awk 解析失败时的退出码。
  local exit_code

  [[ -s "${MERGED_FETCH_FILE}" ]] || die "缺少汇总 fetch.txt：${MERGED_FETCH_FILE}"
  move_to_trash "${FETCH_TARGETS_FILE}" "old_fetch_targets_before_rebuild"
  move_to_trash "${INVALID_FETCH_TARGETS_FILE}" "old_invalid_fetch_targets_before_rebuild"
  move_to_trash "${INVALID_FETCH_ROWS_FILE}" "old_invalid_fetch_rows_before_rebuild"
  : > "${INVALID_FETCH_TARGETS_FILE}.partial.${RUN_ID}"
  : > "${INVALID_FETCH_ROWS_FILE}.partial.${RUN_ID}"
  if awk -F '\t' \
    -v invalid_target_out="${INVALID_FETCH_TARGETS_FILE}.partial.${RUN_ID}" \
    -v invalid_row_out="${INVALID_FETCH_ROWS_FILE}.partial.${RUN_ID}" \
    -v check_checksum="${VERIFY_FETCH_CHECKSUM_FORMAT}" '
    NF < 3 {
      print $0 > invalid_row_out
      next
    }
    {
      checksum = $2
      target = $3
      sub(/\r$/, "", checksum)
      sub(/\r$/, "", target)
      if (target == "") {
        print $0 > invalid_row_out
      } else if (target ~ /^\// || target ~ /(^|\/)\.\.(\/|$)/) {
        print target > invalid_target_out
        print $0 > invalid_row_out
      } else if (check_checksum == "1" && checksum != "0" && checksum !~ /^[0-9a-fA-F]{32}$/) {
        print $0 > invalid_row_out
      } else {
        print target
      }
    }
  ' "${MERGED_FETCH_FILE}" > "${FETCH_TARGETS_FILE}.partial.${RUN_ID}" 2> "${target_log}"; then
    :
  else
    exit_code=$?
    tail_error_log "${target_log}" 30
    move_to_trash "${FETCH_TARGETS_FILE}.partial.${RUN_ID}" "failed_fetch_targets"
    move_to_trash "${INVALID_FETCH_TARGETS_FILE}.partial.${RUN_ID}" "failed_invalid_fetch_targets"
    move_to_trash "${INVALID_FETCH_ROWS_FILE}.partial.${RUN_ID}" "failed_invalid_fetch_rows"
    write_state "fetch_targets" "FAILED_EXIT_${exit_code}" "${target_log}"
    die "解析 fetch target 失败；退出码：${exit_code}；输入：${MERGED_FETCH_FILE}；日志：${target_log}。请检查 fetch 来源后重跑 merge-fetch/verify。"
  fi
  finalize_partial_file "${FETCH_TARGETS_FILE}.partial.${RUN_ID}" "${FETCH_TARGETS_FILE}" "fetch_targets" ||
    die "fetch target 清单落盘失败：${FETCH_TARGETS_FILE}"
  finalize_partial_file "${INVALID_FETCH_TARGETS_FILE}.partial.${RUN_ID}" "${INVALID_FETCH_TARGETS_FILE}" "fetch_targets" ||
    die "invalid fetch target 清单落盘失败：${INVALID_FETCH_TARGETS_FILE}"
  finalize_partial_file "${INVALID_FETCH_ROWS_FILE}.partial.${RUN_ID}" "${INVALID_FETCH_ROWS_FILE}" "fetch_targets" ||
    die "invalid fetch row 清单落盘失败：${INVALID_FETCH_ROWS_FILE}"

  invalid_count="$(count_lines "${INVALID_FETCH_TARGETS_FILE}")"
  invalid_row_count="$(count_lines "${INVALID_FETCH_ROWS_FILE}")"
  target_count="$(count_lines "${FETCH_TARGETS_FILE}")"
  if [[ "${invalid_count}" -gt 0 ]]; then
    write_state "fetch_targets" "FAILED_INVALID_PATH" "${INVALID_FETCH_TARGETS_FILE}"
    die "fetch.txt 中发现不安全目标路径：${invalid_count} 条；详情：${INVALID_FETCH_TARGETS_FILE}。请检查 fetch 来源后重跑 merge-fetch/verify。"
  fi
  if [[ "${invalid_row_count}" -gt 0 ]]; then
    write_state "fetch_targets" "FAILED_INVALID_FETCH_ROW" "${INVALID_FETCH_ROWS_FILE}"
    die "fetch.txt 中发现 checksum 或 target 格式异常：${invalid_row_count} 条；详情：${INVALID_FETCH_ROWS_FILE}。请检查 fetch 来源后重跑 merge-fetch/verify。"
  fi
  [[ "${target_count}" -gt 0 ]] || {
    write_state "fetch_targets" "FAILED_EMPTY" "${FETCH_TARGETS_FILE}"
    die "fetch target 清单为空。请检查汇总 fetch.txt 格式：${MERGED_FETCH_FILE}；修复后重跑 merge-fetch/verify。"
  }

  log "fetch target 清单已生成：${FETCH_TARGETS_FILE}；数量：${target_count}"
  verify_fetch_target_profile
}

# verify_fetch_target_profile：按 accession 校验 fetch 目标类别和目标行数。
# 参数：
#   无。
# 输入：
#   ACCESSION_SORTED_FILE、FETCH_TARGETS_FILE。
# 输出：
#   1. FETCH_PROFILE_FILE：每个 accession 的 fetch target 数量和类别。
#   2. MISSING_FETCH_CLASSES_FILE：缺少关键类别或目标行数不足的 accession。
# 行为：
#   VERIFY_FETCH_FILE_PROFILE=0 时跳过，并把旧 profile 文件移入 TRASH_DIR。
# 失败行为：
#   任一 accession 缺少 REQUIRED_FETCH_TARGET_CLASSES 或低于 MIN_FETCH_TARGETS_PER_ACCESSION 时调用 die。
verify_fetch_target_profile() {
  # profile_log：profile 生成阶段的 stderr 日志。
  local profile_log="${LOG_DIR}/fetch_target_profile_${RUN_ID}.log"
  # issue_count：缺少关键类别或目标数不足的问题条数。
  local issue_count
  # exit_code：awk/sort 本地命令失败时的退出码。
  local exit_code

  if [[ "${VERIFY_FETCH_FILE_PROFILE}" == "0" ]]; then
    move_to_trash "${FETCH_PROFILE_FILE}" "old_fetch_profile_skipped"
    move_to_trash "${MISSING_FETCH_CLASSES_FILE}" "old_missing_fetch_classes_skipped"
    write_state "fetch_profile" "SKIPPED" "VERIFY_FETCH_FILE_PROFILE=0"
    log "VERIFY_FETCH_FILE_PROFILE=0，跳过 fetch 文件类别完整性校验。"
    return 0
  fi

  [[ -s "${ACCESSION_SORTED_FILE}" ]] || die "缺少 accession 排序清单，无法校验 fetch 文件类别：${ACCESSION_SORTED_FILE}"
  [[ -s "${FETCH_TARGETS_FILE}" ]] || die "缺少 fetch target 清单，无法校验 fetch 文件类别：${FETCH_TARGETS_FILE}"
  move_to_trash "${FETCH_PROFILE_FILE}" "old_fetch_profile_before_rebuild"
  move_to_trash "${MISSING_FETCH_CLASSES_FILE}" "old_missing_fetch_classes_before_rebuild"

  if awk -v profile_out="${FETCH_PROFILE_FILE}.partial.${RUN_ID}" \
    -v missing_out="${MISSING_FETCH_CLASSES_FILE}.partial.${RUN_ID}" \
    -v required_classes="${REQUIRED_FETCH_TARGET_CLASSES}" \
    -v min_targets="${MIN_FETCH_TARGETS_PER_ACCESSION}" '
    BEGIN {
      FS = OFS = "\t"
      req_count = split(required_classes, req, ",")
      print "accession", "target_count", "classes" > profile_out
    }
    FNR == NR {
      if ($1 != "") {
        expected[++expected_count] = $1
      }
      next
    }
    {
      target = $0
      acc = ""
      if (match(target, /GC[AF]_[0-9]+\.[0-9]+/)) {
        acc = substr(target, RSTART, RLENGTH)
      }
      if (acc == "") next
      count[acc]++
      cls = target_class(target)
      if (cls != "other") {
        have[acc SUBSEP cls] = 1
        if (class_seen[acc] == "") {
          class_seen[acc] = cls
        } else if (class_seen[acc] !~ "(^|,)" cls "(,|$)") {
          class_seen[acc] = class_seen[acc] "," cls
        }
      }
    }
    END {
      for (i = 1; i <= expected_count; i++) {
        acc = expected[i]
        print acc, count[acc] + 0, class_seen[acc] >> profile_out
        if (min_targets + 0 > 0 && count[acc] + 0 < min_targets + 0) {
          print acc, "too_few_targets", min_targets, count[acc] + 0 > missing_out
        }
        for (j = 1; j <= req_count; j++) {
          cls = req[j]
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", cls)
          if (cls == "") continue
          if (!((acc SUBSEP cls) in have)) {
            print acc, "missing_class", cls, count[acc] + 0 > missing_out
          }
        }
      }
    }
    function target_class(t, name) {
      name = t
      sub(/^.*\//, "", name)
      sub(/\r$/, "", name)
      if (name ~ /(^|_)cds_from_genomic\.fna(\.gz)?$/) return "cds"
      if (name ~ /(^|_)rna_from_genomic\.fna(\.gz)?$/ || name ~ /^rna\.fna(\.gz)?$/) return "rna"
      if (name ~ /(^|_)genomic\.fna(\.gz)?$/) return "genome"
      if (name ~ /(^|_)protein\.faa(\.gz)?$/) return "protein"
      if (name ~ /(^|_)genomic\.gff(\.gz)?$/) return "gff3"
      if (name ~ /(^|_)genomic\.gtf(\.gz)?$/) return "gtf"
      if (name ~ /(^|_)genomic\.gbff(\.gz)?$/) return "gbff"
      if (name ~ /(^|_)sequence_report\.jsonl(\.gz)?$/) return "seq-report"
      return "other"
    }
  ' "${ACCESSION_SORTED_FILE}" "${FETCH_TARGETS_FILE}" 2> "${profile_log}"; then
    :
  else
    exit_code=$?
    tail_error_log "${profile_log}" 30
    move_to_trash "${FETCH_PROFILE_FILE}.partial.${RUN_ID}" "failed_fetch_profile"
    move_to_trash "${MISSING_FETCH_CLASSES_FILE}.partial.${RUN_ID}" "failed_missing_fetch_classes"
    write_state "fetch_profile" "FAILED_EXIT_${exit_code}" "${profile_log}"
    die "生成 fetch 文件类别 profile 失败；退出码：${exit_code}；日志：${profile_log}"
  fi
  mv -- "${FETCH_PROFILE_FILE}.partial.${RUN_ID}" "${FETCH_PROFILE_FILE}"
  if [[ -f "${MISSING_FETCH_CLASSES_FILE}.partial.${RUN_ID}" ]]; then
    mv -- "${MISSING_FETCH_CLASSES_FILE}.partial.${RUN_ID}" "${MISSING_FETCH_CLASSES_FILE}"
  else
    : > "${MISSING_FETCH_CLASSES_FILE}"
  fi

  issue_count="$(count_lines "${MISSING_FETCH_CLASSES_FILE}")"
  if [[ "${issue_count}" -gt 0 ]]; then
    write_state "fetch_profile" "FAILED_MISSING_CLASSES" "${MISSING_FETCH_CLASSES_FILE}"
    die "fetch 文件类别完整性校验失败：${issue_count} 条问题；详情：${MISSING_FETCH_CLASSES_FILE}。可调整 REQUIRED_FETCH_TARGET_CLASSES 或 MIN_FETCH_TARGETS_PER_ACCESSION 后重跑 merge-fetch/verify。"
  fi

  write_state "fetch_profile" "DONE" "${FETCH_PROFILE_FILE}"
  log "fetch 文件类别完整性校验通过：${FETCH_PROFILE_FILE}"
}

# verify_fetch_targets：校验 fetch.txt 中的目标文件是否已经下载到本地。
# 参数：
#   无。
# 输入：
#   FETCH_TARGETS_FILE；每次运行会先调用 write_fetch_targets 重建并校验 fetch 行格式。
# 输出：
#   MISSING_TARGETS_FILE，记录缺失或空文件。
# 行为：
#   VERIFY_FETCH_TARGETS_AFTER_REHYDRATE=0 时只跳过本地文件存在性检查，不跳过 fetch 行格式/类别检查。
# 失败行为：
#   任一目标文件不存在或为空时调用 die。
verify_fetch_targets() {
  # missing：缺失或空文件数量。
  local missing=0
  # checked：已经检查的目标文件数量。
  local checked=0
  # target：fetch.txt 第三列中的相对目标路径。
  local target
  # local_file：target 映射到 MERGED_PACKAGE_DIR 下的本地绝对路径。
  local local_file

  write_fetch_targets

  [[ "${VERIFY_FETCH_TARGETS_AFTER_REHYDRATE}" == "1" ]] || {
    move_to_trash "${MISSING_TARGETS_FILE}" "old_missing_targets_skipped"
    write_state "verify_targets" "SKIPPED" "VERIFY_FETCH_TARGETS_AFTER_REHYDRATE=0"
    log "VERIFY_FETCH_TARGETS_AFTER_REHYDRATE=0，已完成 fetch 行格式/类别检查，跳过本地目标文件存在性校验。"
    return 0
  }

  move_to_trash "${MISSING_TARGETS_FILE}" "old_missing_targets_before_rebuild"
  : > "${MISSING_TARGETS_FILE}"
  while IFS= read -r target; do
    [[ -n "${target}" ]] || continue
    checked=$((checked + 1))
    if local_file="$(find_rehydrate_target_file "${target}")"; then
      :
    else
      local_file="NOT_FOUND:$(expected_rehydrate_target "${target}")"
    fi
    if [[ ! -s "${local_file}" ]]; then
      printf '%s\t%s\n' "${target}" "${local_file}" >> "${MISSING_TARGETS_FILE}"
      missing=$((missing + 1))
      if [[ "${missing}" -le "${MAX_VERIFY_MISSING_PREVIEW}" ]]; then
        errlog "缺失或空文件：${local_file}"
      fi
    fi
  done < "${FETCH_TARGETS_FILE}"

  if [[ "${checked}" -eq 0 ]]; then
    write_state "verify_targets" "FAILED_EMPTY" "${FETCH_TARGETS_FILE}"
    die "fetch 目标文件校验没有检查到任何目标。请检查 fetch.txt 第三列格式：${MERGED_FETCH_FILE}"
  fi

  if [[ "${missing}" -gt 0 ]]; then
    write_state "verify_targets" "FAILED" "${MISSING_TARGETS_FILE}"
    die "fetch 目标文件校验失败：检查 ${checked} 个目标，缺失/空文件 ${missing} 个。详情：${MISSING_TARGETS_FILE}。请重跑 rehydrate；若仍缺失，再重跑 download-links/unpack-links/merge-fetch。"
  fi

  write_state "verify_targets" "DONE" "${checked}"
  log "fetch 目标文件校验通过：${checked} 个文件均存在且非空。"
}

# verify_gzip_integrity：gzip 模式下对所有 rehydrate 目标执行 gzip -t。
# 参数：
#   无。
# 输入：
#   FETCH_TARGETS_FILE；每个 target 通过 find_rehydrate_target_file 映射到实际 .gz 文件。
# 输出：
#   GZIP_STATUS_FILE，记录 OK/MISSING/NOT_GZIP/FAILED 状态。
# 行为：
#   REHYDRATE_GZIP=0 时跳过，并把旧状态文件移入 TRASH_DIR。
# 失败行为：
#   任一 gzip 文件缺失、不是 .gz 后缀或 gzip -t 失败时调用 die。
verify_gzip_integrity() {
  local target
  local local_file
  local checked=0
  local failed=0
  local gzip_log="${LOG_DIR}/gzip_integrity_${RUN_ID}.log"

  if [[ "${REHYDRATE_GZIP}" != "1" ]]; then
    move_to_trash "${GZIP_STATUS_FILE}" "old_gzip_status_skipped"
    write_state "verify_gzip" "SKIPPED" "REHYDRATE_GZIP=0"
    return 0
  fi

  require_command gzip
  [[ -s "${FETCH_TARGETS_FILE}" ]] || die "缺少 fetch target 清单，无法执行 gzip 完整性校验：${FETCH_TARGETS_FILE}"
  move_to_trash "${GZIP_STATUS_FILE}" "old_gzip_status_before_rebuild"
  : > "${gzip_log}"
  printf 'target\tstatus\tlocal_file_or_reason\n' > "${GZIP_STATUS_FILE}"

  while IFS= read -r target; do
    [[ -n "${target}" ]] || continue
    if local_file="$(find_rehydrate_target_file "${target}")"; then
      :
    else
      printf '%s\t%s\t%s\n' "${target}" "MISSING" "$(expected_rehydrate_target "${target}")" >> "${GZIP_STATUS_FILE}"
      failed=$((failed + 1))
      continue
    fi
    if [[ "${local_file}" != *.gz ]]; then
      printf '%s\t%s\t%s\n' "${target}" "NOT_GZIP" "${local_file}" >> "${GZIP_STATUS_FILE}"
      failed=$((failed + 1))
      continue
    fi
    if gzip -t "${local_file}" >> "${gzip_log}" 2>&1; then
      printf '%s\t%s\t%s\n' "${target}" "OK" "${local_file}" >> "${GZIP_STATUS_FILE}"
      checked=$((checked + 1))
    else
      printf '%s\t%s\t%s\n' "${target}" "FAILED" "${local_file}" >> "${GZIP_STATUS_FILE}"
      failed=$((failed + 1))
      if [[ "${failed}" -le "${MAX_VERIFY_MISSING_PREVIEW}" ]]; then
        errlog "gzip 完整性校验失败：${local_file}"
      fi
    fi
  done < "${FETCH_TARGETS_FILE}"

  if [[ "${checked}" -eq 0 && "${failed}" -eq 0 ]]; then
    write_state "verify_gzip" "FAILED_EMPTY" "${FETCH_TARGETS_FILE}"
    die "gzip 完整性校验没有检查到任何目标。请检查 fetch target 清单：${FETCH_TARGETS_FILE}"
  fi

  if [[ "${failed}" -gt 0 ]]; then
    write_state "verify_gzip" "FAILED" "${GZIP_STATUS_FILE}"
    die "gzip 完整性校验失败：通过 ${checked} 个，失败/缺失 ${failed} 个。详情：${GZIP_STATUS_FILE}；gzip stderr：${gzip_log}。请重跑 rehydrate。"
  fi

  write_state "verify_gzip" "DONE" "${checked}"
  log "gzip 完整性校验通过：${checked} 个 gzip 文件。"
}

# verify_fetch_md5：按 fetch.txt 第二列执行可选 MD5 校验。
# 参数：
#   无。
# 输入：
#   MERGED_FETCH_FILE，第二列为期望 MD5 或 0 占位值，第三列为本地目标路径。
# 输出：
#   MD5_STATUS_FILE，每个被校验文件的 OK/MISSING/FAILED 状态。
# 行为：
#   VERIFY_FETCH_MD5=0 时跳过；VERIFY_FETCH_MD5=1 且第二列为 32 位 MD5 时逐文件计算 md5sum，耗时很长。
# 失败行为：
#   任一有官方 MD5 的文件缺失或 MD5 不一致时调用 die；checksum=0 的行记录为跳过。
verify_fetch_md5() {
  # url：fetch.txt 第一列，远程文件 URL；当前函数只读取但不用于下载。
  local url
  # checksum：fetch.txt 第二列，期望 MD5；0 表示官方未提供 MD5。
  local checksum
  # target：fetch.txt 第三列，本地相对目标路径。
  local target
  # local_file：target 映射到 MERGED_PACKAGE_DIR 下的本地绝对路径。
  local local_file
  # actual：本地文件实际 md5sum。
  local actual
  # checked：完成 MD5 计算的文件数量。
  local checked=0
  # failed：MD5 校验失败或文件缺失的数量。
  local failed=0
  # invalid：checksum 或目标路径格式异常的数量。
  local invalid=0
  # skipped_no_md5：fetch.txt 第二列为 0、无法执行强 MD5 校验的文件数量。
  local skipped_no_md5=0

  [[ "${VERIFY_FETCH_MD5}" == "1" ]] || {
    move_to_trash "${MD5_STATUS_FILE}" "old_md5_status_skipped"
    write_state "verify_md5" "SKIPPED" "VERIFY_FETCH_MD5=0"
    log "VERIFY_FETCH_MD5=0，跳过全量 md5 校验。"
    return 0
  }

  if [[ "${REHYDRATE_GZIP}" == "1" ]]; then
    move_to_trash "${MD5_STATUS_FILE}" "old_md5_status_gzip_skipped"
    write_state "verify_md5" "SKIPPED_GZIP" "REHYDRATE_GZIP=1"
    log "REHYDRATE_GZIP=1，fetch.txt 中官方 MD5 若存在通常对应未压缩目标，跳过直接 md5sum；已保留目标存在性和类别校验。"
    return 0
  fi

  require_command md5sum
  move_to_trash "${MD5_STATUS_FILE}" "old_md5_status_before_rebuild"
  printf 'target\tstatus\texpected_md5\tactual_md5_or_reason\n' > "${MD5_STATUS_FILE}"
  while IFS=$'\t' read -r url checksum target _rest; do
    checksum="${checksum%$'\r'}"
    target="${target%$'\r'}"
    [[ -n "${target}" ]] || continue
    if [[ "${target}" =~ ^/ || "${target}" =~ (^|/)\.\.(/|$) ]]; then
      printf '%s\t%s\t%s\t%s\n' "${target}" "INVALID_TARGET_PATH" "${checksum}" "target must be relative and must not contain .." >> "${MD5_STATUS_FILE}"
      invalid=$((invalid + 1))
      failed=$((failed + 1))
      continue
    fi
    if [[ "${checksum}" == "0" ]]; then
      printf '%s\t%s\t%s\t%s\n' "${target}" "SKIPPED_NO_OFFICIAL_MD5" "${checksum}" "fetch checksum placeholder 0" >> "${MD5_STATUS_FILE}"
      skipped_no_md5=$((skipped_no_md5 + 1))
      continue
    fi
    if [[ ! "${checksum}" =~ ^[0-9a-fA-F]{32}$ ]]; then
      printf '%s\t%s\t%s\t%s\n' "${target}" "INVALID_CHECKSUM" "${checksum}" "expected 32 hex chars" >> "${MD5_STATUS_FILE}"
      invalid=$((invalid + 1))
      failed=$((failed + 1))
      continue
    fi
    if local_file="$(find_rehydrate_target_file "${target}")"; then
      :
    else
      local_file=""
    fi
    if [[ -z "${local_file}" || ! -s "${local_file}" ]]; then
      printf '%s\t%s\t%s\t%s\n' "${target}" "MISSING" "${checksum}" "missing_or_empty_file" >> "${MD5_STATUS_FILE}"
      failed=$((failed + 1))
      continue
    fi
    if actual="$(md5sum "${local_file}" 2>/dev/null | awk '{print $1}')"; then
      :
    else
      printf '%s\t%s\t%s\t%s\n' "${target}" "FAILED_READ" "${checksum}" "md5sum_failed" >> "${MD5_STATUS_FILE}"
      failed=$((failed + 1))
      continue
    fi
    if [[ -z "${actual}" ]]; then
      printf '%s\t%s\t%s\t%s\n' "${target}" "FAILED_READ" "${checksum}" "empty_md5sum_output" >> "${MD5_STATUS_FILE}"
      failed=$((failed + 1))
      continue
    fi
    checked=$((checked + 1))
    if [[ "${actual}" == "${checksum}" ]]; then
      printf '%s\t%s\t%s\t%s\n' "${target}" "OK" "${checksum}" "${actual}" >> "${MD5_STATUS_FILE}"
    else
      printf '%s\t%s\t%s\t%s\n' "${target}" "FAILED" "${checksum}" "${actual}" >> "${MD5_STATUS_FILE}"
      failed=$((failed + 1))
    fi
  done < "${MERGED_FETCH_FILE}"

  if [[ "${failed}" -gt 0 ]]; then
    write_state "verify_md5" "FAILED" "${MD5_STATUS_FILE}"
    die "fetch md5 校验失败：失败 ${failed} 个，其中格式异常 ${invalid} 个，官方未提供 MD5 跳过 ${skipped_no_md5} 个；详情：${MD5_STATUS_FILE}。请重跑 rehydrate/verify；若 checksum 格式异常，请先重跑 merge-fetch。"
  fi

  if [[ "${checked}" -eq 0 ]]; then
    if [[ "${skipped_no_md5}" -gt 0 ]]; then
      write_state "verify_md5" "DONE_NO_OFFICIAL_MD5" "${MD5_STATUS_FILE}"
      log "fetch.txt 第二列均为 0 或无可用 MD5，已跳过官方 MD5 校验：${skipped_no_md5} 个文件。"
      return 0
    fi
    write_state "verify_md5" "FAILED_EMPTY" "${MD5_STATUS_FILE}"
    die "fetch md5 校验没有检查到任何文件。请检查 fetch.txt 第二列是否包含 MD5 或 0 占位值；修复后重跑 merge-fetch/verify。"
  fi

  write_state "verify_md5" "DONE" "${checked}"
  log "fetch md5 校验通过：${checked} 个文件；官方未提供 MD5 跳过：${skipped_no_md5} 个文件。"
}

# find_latest_previous_state_file：查找当前 context 下最近一次旧状态表。
# 参数：
#   无。
# 输出：
#   除本次 STATE_FILE 之外最新的 state_*.tsv；不存在时输出空字符串。
find_latest_previous_state_file() {
  local latest=""

  [[ -d "${STATUS_DIR}" ]] || {
    printf '%s' "${latest}"
    return 0
  }
  if latest="$(
    find "${STATUS_DIR}" -maxdepth 1 -type f -name 'state_*.tsv' ! -path "${STATE_FILE}" -printf '%T@\t%p\n' 2>/dev/null |
      sort -n |
      awk -F '\t' 'NF >= 2 {path=$2} END {print path}'
  )"; then
    :
  else
    latest=""
  fi
  printf '%s' "${latest}"
}

# last_state_status：读取指定阶段在状态表中最后一次记录的状态。
# 参数：
#   $1 / stage：阶段名。
# 输出：
#   最近状态；如果不存在则输出 not_run。
last_state_status() {
  local stage="$1"
  local state_source="${STATE_FILE}"
  local status

  if [[ "${REQUESTED_ACTION}" == "summary" ]]; then
    state_source="$(find_latest_previous_state_file)"
  fi
  status=""
  if [[ -f "${state_source}" ]]; then
    status="$(awk -F '\t' -v stage="${stage}" '$2 == stage {status=$3} END {print status}' "${state_source}")"
  fi
  [[ -n "${status}" ]] && printf '%s' "${status}" || printf 'not_run'
}

# verify_fetch_accession_coverage：校验 manifest accession 是否都进入 fetch.txt。
# 参数：
#   无。
# 输入：
#   ACCESSION_SORTED_FILE 和 MERGED_FETCH_ACCESSIONS_FILE。
# 输出：
#   MISSING_FETCH_ACCESSIONS_FILE。
# 行为：
#   缺少 ACCESSION_SORTED_FILE 时直接失败，因为 verify 需要 manifest 作为完整性基准。
# 失败行为：
#   发现缺失或额外 accession 时按 check_fetch_accession_set 的规则处理。
verify_fetch_accession_coverage() {
  check_fetch_accession_set "verify_fetch_accessions"
}

# write_summary_report：写出本次运行的 Markdown 汇总报告。
# 参数：
#   无。
# 输入：
#   各阶段生成的 manifest、shard、zip、fetch、校验清单。
# 输出：
#   SUMMARY_REPORT。
# 用途：
#   让用户快速看到本次运行数量、关键路径和错误清单位置。
write_summary_report() {
  # manifest_count：ACCESSION_FILE 行数。
  local manifest_count
  # shard_count：SHARD_LIST_FILE 行数。
  local shard_count
  # zip_count：ZIP_DIR 中 dehydrated zip 数量。
  local zip_count
  # unpack_count：UNPACK_DIR 中 fetch.txt 来源数量。
  local unpack_count
  # fetch_count：MERGED_FETCH_FILE 行数。
  local fetch_count
  # target_count：FETCH_TARGETS_FILE 行数。
  local target_count
  # missing_target_count：MISSING_TARGETS_FILE 行数。
  local missing_target_count
  # missing_fetch_accession_count：manifest 中未被 fetch 覆盖的 accession 数。
  local missing_fetch_accession_count
  # extra_fetch_accession_count：fetch 中不属于当前 manifest 的 accession 数。
  local extra_fetch_accession_count
  # invalid_target_count：fetch.txt 中不安全目标路径数量。
  local invalid_target_count
  # invalid_fetch_row_count：fetch.txt 中 checksum 或 target 格式异常的原始行数量。
  local invalid_fetch_row_count
  # missing_fetch_class_count：fetch 文件类别完整性问题数量。
  local missing_fetch_class_count
  # md5_status_count：MD5 状态表行数，扣除表头后表示实际记录数。
  local md5_status_count
  # verify_targets_state：目标文件存在性校验的最后状态。
  local verify_targets_state
  # md5_state：MD5 校验的最后状态。
  local md5_state
  # summary_state_source：summary 读取校验状态时使用的状态表。
  local summary_state_source

  manifest_count="$(count_lines "${ACCESSION_FILE}")"
  shard_count="$(count_lines "${SHARD_LIST_FILE}")"
  zip_count="$(count_current_zip_files)"
  unpack_count="$(count_current_unpacked_fetch_files)"
  fetch_count="$(count_lines "${MERGED_FETCH_FILE}")"
  target_count="$(count_lines "${FETCH_TARGETS_FILE}")"
  missing_target_count="$(count_lines "${MISSING_TARGETS_FILE}")"
  missing_fetch_accession_count="$(count_lines "${MISSING_FETCH_ACCESSIONS_FILE}")"
  extra_fetch_accession_count="$(count_lines "${EXTRA_FETCH_ACCESSIONS_FILE}")"
  invalid_target_count="$(count_lines "${INVALID_FETCH_TARGETS_FILE}")"
  invalid_fetch_row_count="$(count_lines "${INVALID_FETCH_ROWS_FILE}")"
  missing_fetch_class_count="$(count_lines "${MISSING_FETCH_CLASSES_FILE}")"
  md5_status_count="$(count_lines "${MD5_STATUS_FILE}")"
  verify_targets_state="$(last_state_status "verify_targets")"
  md5_state="$(last_state_status "verify_md5")"
  if [[ "${REQUESTED_ACTION}" == "summary" ]]; then
    summary_state_source="$(find_latest_previous_state_file)"
    [[ -n "${summary_state_source}" ]] || summary_state_source="not_found"
  else
    summary_state_source="${STATE_FILE}"
  fi
  if [[ "${md5_status_count}" -gt 0 ]]; then
    md5_status_count=$((md5_status_count - 1))
  fi
  if [[ "${REQUESTED_ACTION}" != "summary" && "${RUN_MERGE_FETCH}" == "0" && "${RUN_REHYDRATE}" == "0" && "${RUN_VERIFY}" == "0" ]]; then
    fetch_count="not_run"
    missing_fetch_accession_count="not_run"
    extra_fetch_accession_count="not_run"
    target_count="not_run"
    invalid_target_count="not_run"
    invalid_fetch_row_count="not_run"
    missing_fetch_class_count="not_run"
    missing_target_count="not_run"
    md5_status_count="not_run"
    verify_targets_state="not_run"
    md5_state="not_run"
  elif [[ "${REQUESTED_ACTION}" != "summary" && "${RUN_VERIFY}" == "0" ]]; then
    missing_target_count="not_run"
    md5_status_count="not_run"
  fi

  cat > "${SUMMARY_REPORT}.partial.${RUN_ID}" <<EOF
# RefSeq genomes datasets download summary

- Run ID: ${RUN_ID}
- Data root: ${DATA_ROOT}
- Data root candidates: ${DATA_ROOT_CANDIDATES[*]}
- Merged package: ${MERGED_PACKAGE_DIR}
- Rehydrate package name: ${REHYDRATE_PACKAGE_NAME}
- Rehydrate gzip: ${REHYDRATE_GZIP}
- Rehydrate min free GB: ${STORAGE_MIN_FREE_GB}
- Gzip status: ${GZIP_STATUS_FILE}
- Assembly summary: ${RESOLVED_ASSEMBLY_SUMMARY_FILE:-${ASSEMBLY_SUMMARY_FILE}}
- Assembly summary source URL: ${ASSEMBLY_SUMMARY_SOURCE_URL}
- Assembly summary content token: ${ASSEMBLY_SUMMARY_CONTEXT_TOKEN}
- Include: ${INCLUDE_FILES}
- Assembly source: ${ASSEMBLY_SOURCE}
- Strict integrity: ${STRICT_INTEGRITY}
- Verify fetch targets: ${VERIFY_FETCH_TARGETS_AFTER_REHYDRATE}
- Verify fetch MD5: ${VERIFY_FETCH_MD5}
- Verify targets state: ${verify_targets_state}
- Verify MD5 state: ${md5_state}
- State source: ${summary_state_source}
- Download link retries: ${DOWNLOAD_LINK_MAX_RETRIES}
- Rehydrate retries: ${REHYDRATE_MAX_RETRIES}
- Retry sleep seconds: ${RETRY_SLEEP_SECONDS}
- Rehydrate progress interval seconds: ${REHYDRATE_PROGRESS_INTERVAL_SECONDS}

## Counts

| item | count |
|---|---:|
| manifest accessions | ${manifest_count} |
| shards | ${shard_count} |
| dehydrated zip packages | ${zip_count} |
| unpacked fetch sources | ${unpack_count} |
| merged fetch rows | ${fetch_count} |
| missing fetch accessions | ${missing_fetch_accession_count} |
| extra fetch accessions | ${extra_fetch_accession_count} |
| fetch target rows | ${target_count} |
| invalid fetch targets | ${invalid_target_count} |
| invalid fetch rows | ${invalid_fetch_row_count} |
| missing fetch target classes | ${missing_fetch_class_count} |
| missing targets | ${missing_target_count} |
| md5 status rows | ${md5_status_count} |

## Key files

- Manifest: ${MANIFEST_FILE}
- Manifest summary: ${MANIFEST_SUMMARY_FILE}
- Shard list: ${SHARD_LIST_FILE}
- Package status: ${PACKAGE_STATUS_FILE}
- Unpack status: ${UNPACK_STATUS_FILE}
- Merged fetch: ${MERGED_FETCH_FILE}
- Missing fetch accessions: ${MISSING_FETCH_ACCESSIONS_FILE}
- Extra fetch accessions: ${EXTRA_FETCH_ACCESSIONS_FILE}
- Invalid fetch targets: ${INVALID_FETCH_TARGETS_FILE}
- Invalid fetch rows: ${INVALID_FETCH_ROWS_FILE}
- Fetch target profile: ${FETCH_PROFILE_FILE}
- Missing fetch target classes: ${MISSING_FETCH_CLASSES_FILE}
- Missing targets: ${MISSING_TARGETS_FILE}
- MD5 status: ${MD5_STATUS_FILE}
- State: ${STATE_FILE}
- Log: ${DL_LOG}
- Error log: ${ERR_LOG}
EOF
  mv -- "${SUMMARY_REPORT}.partial.${RUN_ID}" "${SUMMARY_REPORT}"
  log "summary report 已生成：${SUMMARY_REPORT}"
}

# ==================== 主流程 ====================
# main：脚本入口，按 action 调度 manifest、download-links、unpack-links、merge-fetch、rehydrate、verify、summary。
# 参数：
#   $1 / action：可选；all、manifest、download-links、unpack-links、merge-fetch、rehydrate、verify、summary。
# 全局副作用：
#   1. 根据 action 改写 RUN_* 阶段开关。
#   2. 检查依赖命令。
#   3. 初始化 STATE_FILE。
#   4. 调用各阶段函数并生成 SUMMARY_REPORT。
# 失败行为：
#   任一关键阶段 die 或返回非 0 时脚本停止，错误细节写入 ERR_LOG。
main() {
  # action：用户指定的执行阶段组合；未指定时为 all。
  local action="${1:-all}"
  # need_manifest_input：是否必须读取原始 assembly_summary 文件；已有 manifest 时可跳过。
  local need_manifest_input=0

  init_run_state

  configure_action "${action}"
  validate_config
  normalize_force_flags
  require_action_commands

  if [[ -n "${NCBI_API_KEY}" ]]; then
    export NCBI_API_KEY
  fi

  if [[ "${ASSEMBLY_SUMMARY_CONTEXT_TOKEN}" == "unresolved" && "${REQUIRE_RESOLVED_CONTEXT_TOKEN}" == "1" && -z "${PIPELINE_CONTEXT_OVERRIDE}" ]]; then
    write_state "context" "FAILED_UNRESOLVED_SOURCE_TOKEN" "${ASSEMBLY_SUMMARY_FILE}"
    die "无法读取 assembly_summary_refseq.txt 内容指纹，已停止当前 action。请检查 ASSEMBLY_SUMMARY_FILE；若必须复用旧 context，请显式设置 PIPELINE_CONTEXT_OVERRIDE。"
  fi

  if [[ "${RUN_BUILD_MANIFEST}" == "0" && ! -s "${MANIFEST_CONFIG_FILE}" ]]; then
    write_state "context" "FAILED_MISSING_MANIFEST_CONFIG" "${MANIFEST_CONFIG_FILE}"
    die "当前 context 缺少 manifest 配置快照：${MANIFEST_CONFIG_FILE}。请先运行 manifest，或设置 PIPELINE_CONTEXT_OVERRIDE 指向已有 context。"
  fi

  if [[ "${RUN_BUILD_MANIFEST}" == "1" ]]; then
    if [[ ! -s "${MANIFEST_FILE}" || ! -s "${ACCESSION_FILE}" || ! -s "${ACCESSION_SORTED_FILE}" || ! -s "${MANIFEST_CONFIG_FILE}" || "${FORCE_REBUILD_MANIFEST}" == "1" ]]; then
      # need_manifest_input=1 表示必须访问原始 assembly_summary 文件来重建 manifest。
      need_manifest_input=1
    fi
  fi

  if [[ "${need_manifest_input}" == "1" ]]; then
    if [[ "${ASSEMBLY_SUMMARY_CONTEXT_TOKEN}" == "unresolved" ]]; then
      write_state "manifest" "FAILED_UNRESOLVED_SOURCE_TOKEN" "${ASSEMBLY_SUMMARY_FILE}"
      die "无法读取 assembly_summary_refseq.txt 内容指纹，已停止重建 manifest；请检查 ASSEMBLY_SUMMARY_FILE 是否为当前运行环境可读路径：${ASSEMBLY_SUMMARY_FILE}"
    fi
    # RESOLVED_ASSEMBLY_SUMMARY_FILE：重建 manifest 时使用真实可读路径。
    RESOLVED_ASSEMBLY_SUMMARY_FILE="$(resolve_assembly_summary_path "${ASSEMBLY_SUMMARY_FILE}")"
  elif [[ -f "${MANIFEST_CONFIG_FILE}" ]]; then
    # RESOLVED_ASSEMBLY_SUMMARY_FILE：不重建 manifest 时从上次配置快照恢复来源表路径。
    RESOLVED_ASSEMBLY_SUMMARY_FILE="$(awk -F '=' '$1 == "ASSEMBLY_SUMMARY_FILE" {print substr($0, index($0, "=") + 1); exit}' "${MANIFEST_CONFIG_FILE}")"
  else
    # RESOLVED_ASSEMBLY_SUMMARY_FILE：没有 manifest 配置快照时保留原始配置值，仅用于日志展示。
    RESOLVED_ASSEMBLY_SUMMARY_FILE="${ASSEMBLY_SUMMARY_FILE}"
  fi

  log "========== RefSeq genomes datasets 下载流程开始 =========="
  log "action=${action}"
  log "assembly summary=${RESOLVED_ASSEMBLY_SUMMARY_FILE}"
  log "assembly summary source url=${ASSEMBLY_SUMMARY_SOURCE_URL}"
  log "assembly summary content token=${ASSEMBLY_SUMMARY_CONTEXT_TOKEN}"
  log "data root=${DATA_ROOT}"
  log "data root candidates=${DATA_ROOT_CANDIDATES[*]}"
  log "run root=${RUN_ROOT}"
  log "pipeline context=${PIPELINE_CONTEXT_NAME}"
  log "pipeline context computed=${PIPELINE_CONTEXT_COMPUTED_NAME}; override=$([[ -n "${PIPELINE_CONTEXT_OVERRIDE}" ]] && printf '%s' "${PIPELINE_CONTEXT_OVERRIDE}" || printf no)"
  log "include=${INCLUDE_FILES}; assembly_source=${ASSEMBLY_SOURCE}"
  log "filters: latest_only=${FILTER_LATEST_ONLY}, genome_rep=${FILTER_GENOME_REP}, excluded=${FILTER_EXCLUDED_FROM_REFSEQ}, assembly_levels=${FILTER_ASSEMBLY_LEVELS}, groups=${FILTER_GROUPS}, min_genome_size=${MIN_GENOME_SIZE}, max_accessions=${MAX_ACCESSIONS}"
  log "shard: size=${SHARD_SIZE}, force_single_package=${FORCE_SINGLE_PACKAGE}"
  log "steps: manifest=${RUN_BUILD_MANIFEST}, download_links=${RUN_DOWNLOAD_LINKS}, unpack_links=${RUN_UNPACK_LINKS}, merge_fetch=${RUN_MERGE_FETCH}, rehydrate=${RUN_REHYDRATE}, verify=${RUN_VERIFY}"
  log "retry: download_links=${DOWNLOAD_LINK_MAX_RETRIES}, rehydrate=${REHYDRATE_MAX_RETRIES}, sleep_seconds=${RETRY_SLEEP_SECONDS}"
  log "integrity: strict=${STRICT_INTEGRITY}, verify_targets=${VERIFY_FETCH_TARGETS_AFTER_REHYDRATE}, verify_md5=${VERIFY_FETCH_MD5}, checksum_format=${VERIFY_FETCH_CHECKSUM_FORMAT}, file_profile=${VERIFY_FETCH_FILE_PROFILE}"
  log "rehydrate max workers=${REHYDRATE_MAX_WORKERS}; progress_interval_seconds=${REHYDRATE_PROGRESS_INTERVAL_SECONDS}; gzip=${REHYDRATE_GZIP}; storage_min_free_gb=${STORAGE_MIN_FREE_GB}"
  log "api key mode: env_exported=$([[ -n "${NCBI_API_KEY}" ]] && printf yes || printf no); argv_api_key=disabled"

  if [[ "${RUN_BUILD_MANIFEST}" == "1" ]]; then
    build_manifest "${RESOLVED_ASSEMBLY_SUMMARY_FILE}"
    build_shards
  fi

  if [[ "${RUN_DOWNLOAD_LINKS}" == "1" ]]; then
    download_dehydrated_packages
  fi

  if [[ "${RUN_UNPACK_LINKS}" == "1" ]]; then
    unpack_dehydrated_packages
  fi

  if [[ "${RUN_MERGE_FETCH}" == "1" ]]; then
    merge_fetch_files
  fi

  if [[ "${RUN_REHYDRATE}" == "1" ]]; then
    if ! rehydrate_merged_package; then
      die "rehydrate 阶段失败。请查看 rehydrate_list/rehydrate 状态行和对应日志；修复后可重跑 rehydrate。"
    fi
  fi

  if [[ "${RUN_VERIFY}" == "1" ]]; then
    verify_fetch_accession_coverage
    verify_fetch_targets
    verify_gzip_integrity
    verify_fetch_md5
  fi

  write_summary_report
  log "========== RefSeq genomes datasets 下载流程结束 =========="
  log "summary report：${SUMMARY_REPORT}"
}

main "$@"
