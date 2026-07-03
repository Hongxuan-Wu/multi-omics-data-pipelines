#!/usr/bin/env bash
# =============================================================================
# NCBI RefSeq 目标集完整性验证脚本
#
# 用法：
#   bash verify_refseq_truly_full.sh
#   bash verify_refseq_truly_full.sh /data3/p252701008/refseq_release /data3/p252701008/refseq_release_runlogs
#   bash verify_refseq_truly_full.sh /data3/p252701008/refseq_release /data3/p252701008/refseq_release_runlogs 20260702T132418Z.1820503
#
# 前提：先运行 download_refseq.sh，生成 RUN_ROOT/manifests/target_files_<RUN_ID>.tsv。
#
# 输出报告：
#   1. manifest 信息（release、base_url、local_root、run_id）
#   2. MD5 逐文件校验（不中止，全部跑完）
#   3. 无官方 MD5 文件 gzip/非空弱校验
#   4. 文件数量统计矩阵（按目录 × 类型）
#   5. 序列数采样
#   6. 磁盘使用汇总
#   7. 最终验证总结报告
# =============================================================================
set -euo pipefail

# LOCAL_ROOT：本地 RefSeq 镜像根目录；结构应严格对应 NCBI refseq/release。
LOCAL_ROOT="${1:-/data3/p252701008/refseq_release}"
# RUN_ROOT：download_refseq.sh 保存运行日志、manifest、计划文件的位置。
RUN_ROOT="${2:-/data3/p252701008/refseq_release_runlogs}"
# RUN_ID：可选；为空时自动选择最新 target_files_<RUN_ID>.tsv。
RUN_ID="${3:-${RUN_ID:-}}"

# MANIFEST_DIR：download_refseq.sh 输出 target/unverified manifest 的目录。
MANIFEST_DIR="${RUN_ROOT}/manifests"
# LOG_DIR：验证报告输出目录，与下载脚本日志目录保持一致，不污染 LOCAL_ROOT。
LOG_DIR="${RUN_ROOT}/logs"
# TARGET_MANIFEST：可用环境变量覆盖；默认由 RUN_ID 或最新文件自动解析。
TARGET_MANIFEST="${TARGET_MANIFEST:-}"
# UNVERIFIED_MANIFEST：可用环境变量覆盖；默认与 TARGET_MANIFEST 使用同一 RUN_ID。
UNVERIFIED_MANIFEST="${UNVERIFIED_MANIFEST:-}"
# VERIFY_LOG：解析 RUN_ID 后设置为 verify_<RUN_ID>.log。
VERIFY_LOG=""
# REPORT_FILE：解析 RUN_ID 后设置为 verify_report_<RUN_ID>.txt。
REPORT_FILE=""
mkdir -p "${LOG_DIR}"

# 验证日志同时打印到屏幕和 verify_<RUN_ID>.log；RUN_ID 解析前只打印到屏幕。
log() {
  if [[ -n "${VERIFY_LOG}" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${VERIFY_LOG}"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  fi
}

# 输出错误并终止脚本。
die() {
  log "[ERROR] $*"
  exit 1
}

# 判断 manifest 中的相对路径是否安全，避免访问 LOCAL_ROOT 外的文件。
is_safe_relpath() {
  local relpath="$1"
  [[ "${relpath}" != /* && "${relpath}" != "../"* && "${relpath}" != *"/../"* && "${relpath}" != *"/.." ]]
}

# 从 target_files_<RUN_ID>.tsv 文件名解析 RUN_ID。
run_id_from_target_manifest() {
  local path="$1"
  local name="${path##*/}"
  name="${name#target_files_}"
  name="${name%.tsv}"
  printf '%s\n' "${name}"
}

# 自动发现最新 target_files_<RUN_ID>.tsv。
find_latest_target_manifest() {
  local latest
  latest=$({ find "${MANIFEST_DIR}" -maxdepth 1 -type f -name 'target_files_*.tsv' -printf '%T@\t%p\n' 2>/dev/null || true; } \
    | sort -nr \
    | awk -F '\t' 'NR==1 {print $2}')
  [[ -n "${latest}" ]] || return 1
  printf '%s\n' "${latest}"
}

# 根据 RUN_ID、环境变量或最新文件解析本次要验证的 manifest。
resolve_manifest_paths() {
  if [[ -n "${TARGET_MANIFEST}" ]]; then
    [[ -f "${TARGET_MANIFEST}" ]] || die "指定的 TARGET_MANIFEST 不存在：${TARGET_MANIFEST}"
    if [[ -z "${RUN_ID}" ]]; then
      RUN_ID="$(run_id_from_target_manifest "${TARGET_MANIFEST}")"
    fi
  elif [[ -n "${RUN_ID}" ]]; then
    TARGET_MANIFEST="${MANIFEST_DIR}/target_files_${RUN_ID}.tsv"
    [[ -f "${TARGET_MANIFEST}" ]] || die "指定 RUN_ID 的 target manifest 不存在：${TARGET_MANIFEST}"
  else
    TARGET_MANIFEST="$(find_latest_target_manifest)" || die "未找到 target_files_*.tsv：${MANIFEST_DIR}。请先运行 download_refseq.sh。"
    RUN_ID="$(run_id_from_target_manifest "${TARGET_MANIFEST}")"
  fi

  if [[ -z "${UNVERIFIED_MANIFEST}" ]]; then
    UNVERIFIED_MANIFEST="${MANIFEST_DIR}/unverified_files_${RUN_ID}.tsv"
  fi
  [[ -f "${UNVERIFIED_MANIFEST}" ]] || die "unverified manifest 不存在：${UNVERIFIED_MANIFEST}"

  VERIFY_LOG="${LOG_DIR}/verify_${RUN_ID}.log"
  REPORT_FILE="${LOG_DIR}/verify_report_${RUN_ID}.txt"
  : > "${VERIFY_LOG}"
}

# 统计 target manifest 的数据行数；注释行和空行不算目标文件。
manifest_data_count() {
  grep -Evc '^(#|[[:space:]]*$)' "${TARGET_MANIFEST}" 2>/dev/null || true
}

# 统计没有官方 MD5 的文件数；空行和注释行都排除。
unverified_data_count() {
  if [[ ! -s "${UNVERIFIED_MANIFEST}" ]]; then
    echo 0
    return 0
  fi
  grep -Evc '^(#|[[:space:]]*$)' "${UNVERIFIED_MANIFEST}" 2>/dev/null || true
}

# 验证下载脚本是否至少生成了可用 manifest。
ensure_manifests() {
  # 至少需要 target manifest 存在（证明下载脚本运行过）。
  if [[ ! -f "${TARGET_MANIFEST}" ]]; then
    log "[ERROR] 目标 manifest 不存在：${TARGET_MANIFEST}"
    log "        请先运行 download_refseq.sh，或确认 RUN_ROOT/RUN_ID 是否正确。"
    exit 1
  fi
  if [[ ! -f "${UNVERIFIED_MANIFEST}" ]]; then
    log "[ERROR] 无官方 MD5 manifest 不存在：${UNVERIFIED_MANIFEST}"
    log "        请先运行 download_refseq.sh，或确认 RUN_ROOT/RUN_ID 是否正确。"
    exit 1
  fi

  local target_count unverified_count
  target_count=$(manifest_data_count)
  unverified_count=$(unverified_data_count)

  # 两个 manifest 都为空 = 下载脚本未正常生成目标集。
  if [[ "${target_count}" -eq 0 && "${unverified_count}" -eq 0 ]]; then
    log "[ERROR] target manifest 和 unverified manifest 均无数据行。"
    log "        下载脚本可能未正常生成计划，请检查 ${RUN_ROOT}/logs/download_${RUN_ID}.log。"
    exit 1
  fi

  # target manifest 为空但 unverified 有数据 -> 跳过 MD5，只做弱校验。
  if [[ "${target_count}" -eq 0 ]]; then
    log "[WARN] target manifest 无数据行（所有文件均无官方 MD5 条目）。"
    log "       跳过 Step 1 MD5 校验，仅执行 Step 1b 弱校验。"
  fi
}

# 打印 manifest 头部元信息：release、base_url、local_root、run_id。
show_manifest_info() {
  log "===== Manifest 信息 ====="
  local release_line url_line local_root_line run_id_line columns_line
  release_line=$(grep '^# release' "${TARGET_MANIFEST}" || true)
  url_line=$(grep '^# base_url' "${TARGET_MANIFEST}" || true)
  local_root_line=$(grep '^# local_root' "${TARGET_MANIFEST}" || true)
  run_id_line=$(grep '^# run_id' "${TARGET_MANIFEST}" || true)
  columns_line=$(grep '^# columns' "${TARGET_MANIFEST}" || true)

  log "  target_manifest：${TARGET_MANIFEST}"
  log "  unverified_manifest：${UNVERIFIED_MANIFEST}"
  log "  run_root：${RUN_ROOT}"
  [[ -n "${release_line}" ]] && log "  ${release_line#\# }"
  [[ -n "${url_line}" ]] && log "  ${url_line#\# }"
  [[ -n "${local_root_line}" ]] && log "  ${local_root_line#\# }"
  [[ -n "${run_id_line}" ]] && log "  ${run_id_line#\# }"
  [[ -n "${columns_line}" ]] && log "  ${columns_line#\# }"

  log "  目标文件数：$(manifest_data_count)"
  log "  无官方 MD5 文件数：$(unverified_data_count)"
}

# 对有官方 MD5 的目标文件做逐文件精确校验。
verify_md5() {
  log "===== Step 1: MD5 校验（仅校验本次目标集）====="

  local target_count
  target_count=$(manifest_data_count)
  if [[ "${target_count}" -eq 0 ]]; then
    log "  target manifest 无数据行，跳过 MD5 校验。"
    return 0
  fi

  local total=0 ok=0 failed=0 missing=0 unsafe=0
  local failed_list="${LOG_DIR}/md5_failed_${RUN_ID}.txt"
  local missing_list="${LOG_DIR}/md5_missing_${RUN_ID}.txt"
  local md5_report="${LOG_DIR}/md5_detail_report_${RUN_ID}.txt"
  # 每次验证都重写这 3 个报告，避免和上一次结果混在一起。
  : > "${failed_list}"
  : > "${missing_list}"
  : > "${md5_report}"

  echo "========== MD5 校验详细报告 ==========" > "${md5_report}"
  echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')" >> "${md5_report}"
  echo "" >> "${md5_report}"

  while IFS=$'\t' read -r md5 filepath; do
    # target_files_<RUN_ID>.tsv 格式是 md5<TAB>relative_path；跳过头部注释和空行。
    [[ -z "${md5:-}" ]] && continue
    [[ "${md5}" == \#* ]] && continue
    [[ -z "${filepath:-}" ]] && continue
    total=$((total + 1))

    if ! is_safe_relpath "${filepath}"; then
      unsafe=$((unsafe + 1))
      echo "[UNSAFE] ${filepath}" >> "${md5_report}"
      echo "  原因：manifest 中出现不安全相对路径" >> "${md5_report}"
      echo "" >> "${md5_report}"
      continue
    fi

    local local_path="${LOCAL_ROOT}/${filepath}"

    if [[ ! -f "${local_path}" ]]; then
      # manifest 中有记录但本地没有文件，说明下载中断或目标目录不一致。
      echo "${filepath}" >> "${missing_list}"
      echo "[MISSING] ${filepath}" >> "${md5_report}"
      echo "  期望 MD5：${md5}" >> "${md5_report}"
      echo "  本地路径：${local_path}" >> "${md5_report}"
      echo "  原因：文件不存在（可能未下载或下载中断）" >> "${md5_report}"
      echo "" >> "${md5_report}"
      missing=$((missing + 1))
      continue
    fi

    local actual_md5
    # md5sum 输出格式是 "<md5>  <filename>"，这里只取第一列。
    actual_md5=$(md5sum "${local_path}" | awk '{print $1}')
    if [[ "${actual_md5}" == "${md5}" ]]; then
      ok=$((ok + 1))
    else
      echo "${filepath}  expected=${md5}  actual=${actual_md5}" >> "${failed_list}"
      echo "[FAILED] ${filepath}" >> "${md5_report}"
      echo "  期望 MD5：${md5}" >> "${md5_report}"
      echo "  实际 MD5：${actual_md5}" >> "${md5_report}"
      echo "  本地路径：${local_path}" >> "${md5_report}"
      echo "  原因：MD5 不匹配（文件可能损坏或不完整）" >> "${md5_report}"
      echo "  建议：重跑 download_refseq.sh；下载脚本会处理断点续传和异常文件隔离" >> "${md5_report}"
      echo "" >> "${md5_report}"
      failed=$((failed + 1))
    fi

    # 每 200 个文件打一条进度，避免日志过密。
    if [[ $((total % 200)) -eq 0 ]]; then
      log "  已校验 ${total} 文件（OK=${ok}, 失败=${failed}, 缺失=${missing}, 不安全=${unsafe}）"
    fi
  done < "${TARGET_MANIFEST}"

  local pass_rate="0.0"
  if [[ ${total} -gt 0 ]]; then
    # 用 awk 计算百分比，避免 Bash 整数除法丢失小数。
    pass_rate=$(awk -v ok="${ok}" -v total="${total}" 'BEGIN{printf "%.1f", ok*100/total}')
  fi

  # 把摘要追加到 md5_detail_report_<RUN_ID>.txt 尾部，方便只看一个文件就能判断结果。
  {
    echo "========== MD5 校验摘要 =========="
    echo "目标总计：${total}"
    echo "通过：${ok}"
    echo "失败：${failed}"
    echo "缺失：${missing}"
    echo "不安全路径：${unsafe}"
    echo "通过率：${pass_rate}%"
    echo ""
    if [[ ${failed} -gt 0 ]]; then
      echo "⚠ 失败文件（${failed} 个）—— MD5 不匹配，文件可能损坏："
      echo "  详见：${md5_report}"
      echo "  简表：${failed_list}"
      echo "  处理建议：重跑 download_refseq.sh；下载脚本会利用 aria2 断点续传"
    fi
    if [[ ${missing} -gt 0 ]]; then
      echo "⚠ 缺失文件（${missing} 个）—— 未下载或下载中断："
      echo "  详见：${md5_report}"
      echo "  简表：${missing_list}"
      echo "  处理建议：重跑下载脚本补齐"
    fi
    if [[ ${unsafe} -gt 0 ]]; then
      echo "⚠ 不安全路径（${unsafe} 个）—— manifest 中存在绝对路径或 ../："
      echo "  详见：${md5_report}"
      echo "  处理建议：检查 manifest 来源，不要校验来源不明的清单"
    fi
    if [[ ${failed} -eq 0 && ${missing} -eq 0 && ${unsafe} -eq 0 && ${total} -gt 0 ]]; then
      echo "全部目标文件 MD5 校验通过。"
    fi
  } >> "${md5_report}"

  log "MD5 校验结果："
  log "  目标总计：${total}"
  log "  通过：${ok}"
  log "  失败：${failed}（详见 ${md5_report}）"
  log "  缺失：${missing}（详见 ${md5_report}）"
  log "  不安全路径：${unsafe}（详见 ${md5_report}）"
  log "  通过率：${pass_rate}%"

  # 只要有失败、缺失或不安全路径，返回非 0；主流程继续做其他检查并在最终报告中汇总。
  if [[ ${total} -eq 0 || ${failed} -gt 0 || ${missing} -gt 0 || ${unsafe} -gt 0 ]]; then
    return 1
  fi
  return 0
}

# 对没有官方 MD5 的文件做弱校验；gzip 文件查 CRC，非 gzip 文件查非空。
verify_unverified_files() {
  log "===== Step 1b: 无官方 MD5 文件弱校验 ====="

  if [[ ! -s "${UNVERIFIED_MANIFEST}" ]]; then
    log "  未发现 unverified manifest，跳过。"
    return 0
  fi

  local total=0 ok=0 failed=0 missing=0 unsafe=0
  local report="${LOG_DIR}/unverified_detail_report_${RUN_ID}.txt"
  # 重写 gzip CRC 报告，避免历史结果干扰本轮判断。
  : > "${report}"

  echo "========== 无官方 MD5 文件弱校验报告 ==========" > "${report}"
  echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')" >> "${report}"
  echo "" >> "${report}"

  while IFS=$'\t' read -r filepath reason; do
    # unverified_files_<RUN_ID>.tsv 格式是 relative_path<TAB>reason。
    [[ -z "${filepath:-}" ]] && continue
    [[ "${filepath}" == \#* ]] && continue
    [[ -z "${reason:-}" ]] && reason="NO_MD5_IN_CATALOG"

    total=$((total + 1))
    # 防止 manifest 中出现绝对路径或 ../，避免验证脚本读到 LOCAL_ROOT 外部文件。
    if ! is_safe_relpath "${filepath}"; then
      unsafe=$((unsafe + 1))
      echo "[UNSAFE] ${filepath}" >> "${report}"
      echo "  原因：不安全相对路径" >> "${report}"
      echo "" >> "${report}"
      continue
    fi

    local local_path="${LOCAL_ROOT}/${filepath}"
    if [[ ! -f "${local_path}" ]]; then
      # 没有 MD5 的文件也必须存在；不存在就说明下载不完整。
      missing=$((missing + 1))
      echo "[MISSING] ${filepath}" >> "${report}"
      echo "  原因：${reason}" >> "${report}"
      echo "  本地路径：${local_path}" >> "${report}"
      echo "" >> "${report}"
      continue
    fi

    if [[ "${filepath}" == *.gz ]]; then
      # gzip -t 只检查压缩流完整性和 CRC，不解压落盘。
      if gzip -t "${local_path}" 2>> "${report}"; then
        ok=$((ok + 1))
        echo "[OK] ${filepath}" >> "${report}"
      else
        failed=$((failed + 1))
        echo "[FAILED] ${filepath}" >> "${report}"
      fi
    elif [[ -s "${local_path}" ]]; then
      ok=$((ok + 1))
      echo "[OK] ${filepath}" >> "${report}"
    else
      failed=$((failed + 1))
      echo "[FAILED] ${filepath}" >> "${report}"
      echo "  原因：非 gzip 文件为空" >> "${report}"
    fi
  done < "${UNVERIFIED_MANIFEST}"

  log "无官方 MD5 文件弱校验结果："
  log "  目标总计：${total}"
  log "  通过：${ok}"
  log "  失败：${failed}（详见 ${report}）"
  log "  缺失：${missing}（详见 ${report}）"
  log "  不安全路径：${unsafe}（详见 ${report}）"

  # 无 MD5 文件中只要有损坏、缺失或不安全路径，就让该步骤失败。
  if [[ ${failed} -gt 0 || ${missing} -gt 0 || ${unsafe} -gt 0 ]]; then
    return 1
  fi
  return 0
}

# 输出各目录、各文件类型的数量矩阵，用于快速发现某类文件是否明显缺失。
verify_file_count() {
  log "===== Step 2: 文件数量统计（按目录 × 类型）====="

  # 和下载脚本的目标目录保持一致；complete 单独附加。
  local dirs=(
    bacteria archaea fungi plant invertebrate protozoa
    vertebrate_mammalian vertebrate_other viral
    mitochondrion plasmid plastid other complete
  )

  # 统计这些后缀的文件数；bna.gz 主要用于 complete 目录。
  local types=(
    "genomic.fna.gz"
    "genomic.gbff.gz"
    "protein.faa.gz"
    "protein.gpff.gz"
    "rna.fna.gz"
    "rna.gbff.gz"
    "bna.gz"
  )

  {
    echo "========== 文件数量统计 =========="
    echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    printf "%-25s" "目录"
    for t in "${types[@]}"; do
      printf "%14s" "${t%.gz}"
    done
    printf "%12s\n" "合计"

    for d in "${dirs[@]}"; do
      local dir_path="${LOCAL_ROOT}/${d}"
      # 如果某目录不存在，说明下载脚本没有创建或没有跑到该阶段，统计时跳过。
      [[ ! -d "${dir_path}" ]] && continue

      local row_total=0
      printf "%-25s" "${d}"
      for t in "${types[@]}"; do
        local count
        # find 只在当前目录内按文件名后缀计数，不解析文件内容。
        count=$(find "${dir_path}" -name "*.${t}" 2>/dev/null | wc -l)
        printf "%14s" "${count}"
        row_total=$((row_total + count))
      done
      printf "%12s\n" "${row_total}"
    done
  } | tee -a "${VERIFY_LOG}"
}

# 每个目录抽样前 3 个 genomic.fna.gz，粗略检查 FASTA 是否可读、序列数是否正常。
count_sequences_sample() {
  log "===== Step 3: 序列数采样（每目录前 3 个 genomic.fna.gz）====="

  # complete 不参与 genomic.fna.gz 采样，因为这里只想看分类目录的基因组 FASTA。
  local dirs=(
    bacteria archaea fungi plant invertebrate protozoa
    vertebrate_mammalian vertebrate_other viral
    mitochondrion plasmid plastid other
  )

  for d in "${dirs[@]}"; do
    local dir_path="${LOCAL_ROOT}/${d}"
    [[ ! -d "${dir_path}" ]] && continue

    local files
    # sort -V 按版本号自然排序，head -3 只取少量样本，避免全量 zcat 太慢。
    files=$(find "${dir_path}" -name "*.genomic.fna.gz" | sort -V | head -3)
    [[ -z "${files}" ]] && continue

    log "  ${d}："
    while IFS= read -r f; do
      local seq_count fsize
      # 先做 gzip 完整性检查，损坏文件不参与序列计数
      if ! gzip -t "${f}" 2>/dev/null; then
        fsize=$(du -h "${f}" | awk '{print $1}')
        log "    $(basename "${f}"): [WARN] gzip 损坏（CRC 校验失败），${fsize}"
        continue
      fi
      # FASTA 中每条序列头以 > 开头，因此 grep -c "^>" 可估算序列条数。
      seq_count=$(zcat "${f}" 2>/dev/null | grep -c "^>" || true)
      fsize=$(du -h "${f}" | awk '{print $1}')
      log "    $(basename "${f}"): ${seq_count} 序列, ${fsize}"
    done <<< "${files}"
  done
}

# 汇总 LOCAL_ROOT 总占用和每个分类目录占用，用于判断下载规模。
disk_usage_summary() {
  log "===== Step 4: 磁盘使用汇总 ====="
  local total_size
  total_size=$(du -sh "${LOCAL_ROOT}" 2>/dev/null | awk '{print $1}')
  log "  总占用：${total_size}"

  for d in bacteria archaea fungi plant invertebrate protozoa \
           vertebrate_mammalian vertebrate_other viral \
           mitochondrion plasmid plastid other complete \
           release-catalog release-statistics; do
    local dir_path="${LOCAL_ROOT}/${d}"
    [[ ! -d "${dir_path}" ]] && continue
    local size
    size=$(du -sh "${dir_path}" 2>/dev/null | awk '{print $1}')
    log "    ${d}: ${size}"
  done
}

# 生成最终报告文件，把前面各步骤结果合并成一个可读摘要。
generate_final_report() {
  local md5_result="$1"
  local unverified_result="${2:-PASS}"
  {
    echo "=============================================="
    echo "  RefSeq 目标集验证最终报告"
    echo "  生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
    echo "  根目录：${LOCAL_ROOT}"
    echo "  运行目录：${RUN_ROOT}"
    echo "  RUN_ID：${RUN_ID}"
    echo "  target manifest：${TARGET_MANIFEST}"
    echo "  unverified manifest：${UNVERIFIED_MANIFEST}"
    echo "=============================================="
    echo ""
    echo "验证项目及结果："
    echo ""
    echo "  [Manifest 信息]     已读取"
    echo ""
    if [[ "${md5_result}" == "SKIP" ]]; then
      echo "  [MD5 校验]         跳过（target manifest 无数据行，所有文件无官方 MD5 条目）"
    elif [[ "${md5_result}" == "PASS" ]]; then
      echo "  [MD5 校验]         全部通过"
    else
      echo "  [MD5 校验]         存在问题（见 ${LOG_DIR}/md5_detail_report_${RUN_ID}.txt）"
    fi
    if [[ "${unverified_result}" == "PASS" ]]; then
      echo "  [无官方 MD5 文件]  gzip CRC/非空弱校验通过或无此类文件"
    else
      echo "  [无官方 MD5 文件]  弱校验存在问题（见 ${LOG_DIR}/unverified_detail_report_${RUN_ID}.txt）"
    fi
    echo ""
    echo "  [文件数量统计]      已输出（见上方 Step 2）"
    echo "  [序列数采样]        已输出（见上方 Step 3）"
    echo "  [磁盘使用汇总]      已输出（见上方 Step 4）"
    echo ""
    echo "日志文件："
    echo "  验证日志：      ${VERIFY_LOG}"
    echo "  MD5 详情：      ${LOG_DIR}/md5_detail_report_${RUN_ID}.txt"
    echo "  MD5 失败：      ${LOG_DIR}/md5_failed_${RUN_ID}.txt"
    echo "  MD5 缺失：      ${LOG_DIR}/md5_missing_${RUN_ID}.txt"
    echo "  无官方 MD5 详情：${LOG_DIR}/unverified_detail_report_${RUN_ID}.txt"
    echo ""
    if [[ "${md5_result}" == "FAIL" || "${unverified_result}" != "PASS" ]]; then
      echo "处理建议："
      echo "  1. 检查 ${LOG_DIR}/md5_detail_report_${RUN_ID}.txt 和 ${LOG_DIR}/unverified_detail_report_${RUN_ID}.txt"
      echo "  2. MD5 不匹配或缺失的文件：重跑 download_refseq.sh，依赖 aria2 续传和脚本内完整性跳过"
      echo "  3. 无官方 MD5 文件弱校验失败时，优先重跑 download_refseq.sh 补齐"
    fi
    echo ""
    echo "=============================================="
  } > "${REPORT_FILE}"

  # 最终报告既保存到文件，也追加到 verify.log。
  log ""
  log "========== 验证总结 =========="
  cat "${REPORT_FILE}" | tee -a "${VERIFY_LOG}"
  log ""
  log "完整报告已保存：${REPORT_FILE}"
}

# 主流程入口：manifest 检查 -> MD5/gzip 校验 -> 数量/采样/空间统计 -> 最终报告。
main() {
  resolve_manifest_paths

  log "========== RefSeq 目标集完整性验证 =========="
  log "根目录：${LOCAL_ROOT}"
  log "运行目录：${RUN_ROOT}"
  log "RUN_ID：${RUN_ID}"
  log "说明：RefSeq release FTP 不提供 genomic.gff3.gz；本脚本不校验 GFF3。"
  log ""

  ensure_manifests
  show_manifest_info

  local md5_status="PASS"
  local target_data_count
  target_data_count=$(manifest_data_count)
  if [[ "${target_data_count}" -eq 0 ]]; then
    # 没有 MD5 目标行时不算失败，因为可能所有目标都落入 unverified 清单。
    md5_status="SKIP"
    log "  跳过 MD5 校验（target manifest 无数据行）"
  else
    # verify_md5 失败后不立刻退出；继续跑后续检查，最后统一给报告。
    verify_md5 || md5_status="FAIL"
  fi

  local unverified_status="PASS"
  # 无 MD5 文件也不在这里中断，先记录状态，最终统一 exit。
  verify_unverified_files || unverified_status="FAIL"

  verify_file_count
  count_sequences_sample
  disk_usage_summary
  generate_final_report "${md5_status}" "${unverified_status}"

  log "========== 验证完成 =========="
  # SKIP（MD5 无目标行）不算失败；只有 FAIL 才 exit 1
  if [[ "${md5_status}" == "FAIL" || "${unverified_status}" == "FAIL" ]]; then
    exit 1
  fi
}

main "$@"
