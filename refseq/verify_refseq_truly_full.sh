#!/usr/bin/env bash
# =============================================================================
# NCBI RefSeq 目标集完整性验证脚本
#
# 用法：bash verify_refseq_truly_full.sh /data/refseq_release
# 前提：先运行 download_refseq_truly_full.sh，生成 logs/target_files.tsv
#
# 输出报告：
#   1. manifest 信息（release 版本、下载时间）
#   2. MD5 逐文件校验（不中止，全部跑完）
#   3. 文件数量统计矩阵（按目录 × 类型）
#   4. 序列数采样
#   5. 磁盘使用汇总
#   6. 最终验证总结报告
# =============================================================================
set -euo pipefail

LOCAL_ROOT="${1:-/data/refseq_release}"
LOG_DIR="${LOCAL_ROOT}/logs"
VERIFY_LOG="${LOG_DIR}/verify.log"
TARGET_MANIFEST="${LOG_DIR}/target_files.tsv"
UNVERIFIED_MANIFEST="${LOG_DIR}/unverified_files.tsv"
REPORT_FILE="${LOG_DIR}/verify_report.txt"
mkdir -p "${LOG_DIR}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${VERIFY_LOG}"; }

manifest_data_count() {
  grep -vc '^#' "${TARGET_MANIFEST}" 2>/dev/null || true
}

unverified_data_count() {
  if [[ ! -s "${UNVERIFIED_MANIFEST}" ]]; then
    echo 0
    return 0
  fi
  grep -Evc '^(#|[[:space:]]*$)' "${UNVERIFIED_MANIFEST}" 2>/dev/null || true
}

ensure_manifests() {
  # 至少需要 target_files.tsv 存在（证明下载脚本运行过）
  if [[ ! -f "${TARGET_MANIFEST}" ]]; then
    log "[ERROR] 目标 manifest 不存在：${TARGET_MANIFEST}"
    log "        请先运行 download_refseq_truly_full.sh，或确认下载目录是否正确。"
    exit 1
  fi

  local target_count unverified_count
  target_count=$(manifest_data_count)
  unverified_count=$(unverified_data_count)

  # 两个 manifest 都为空 = 下载脚本未正常工作
  if [[ "${target_count}" -eq 0 && "${unverified_count}" -eq 0 ]]; then
    log "[ERROR] target_files.tsv 和 unverified_files.tsv 均无数据行。"
    log "        下载脚本可能未正常完成，请检查 download.log。"
    exit 1
  fi

  # target_files.tsv 为空但 unverified 有数据 → 跳过 MD5，只做 gzip CRC
  if [[ "${target_count}" -eq 0 ]]; then
    log "[WARN] target_files.tsv 无数据行（所有文件均无 MD5 catalog 条目）。"
    log "       跳过 Step 1 MD5 校验，仅执行 gzip CRC 校验（Step 1b）。"
  fi
}

show_manifest_info() {
  log "===== Manifest 信息 ====="
  local release_line started_line finished_line url_line
  release_line=$(grep '^# release' "${TARGET_MANIFEST}" || true)
  started_line=$(grep '^# download_started' "${TARGET_MANIFEST}" || true)
  finished_line=$(grep '^# download_finished' "${TARGET_MANIFEST}" || true)
  url_line=$(grep '^# base_url' "${TARGET_MANIFEST}" || true)

  [[ -n "${release_line}" ]] && log "  ${release_line#\# }"
  [[ -n "${started_line}" ]] && log "  ${started_line#\# }"
  [[ -n "${finished_line}" ]] && log "  ${finished_line#\# }"
  [[ -n "${url_line}" ]] && log "  ${url_line#\# }"

  log "  目标文件数：$(manifest_data_count)"
  log "  未 MD5 校验文件数：$(unverified_data_count)"
}

verify_md5() {
  log "===== Step 1: MD5 校验（仅校验本次目标集）====="

  local target_count
  target_count=$(manifest_data_count)
  if [[ "${target_count}" -eq 0 ]]; then
    log "  target_files.tsv 无数据行，跳过 MD5 校验。"
    return 0
  fi

  local total=0 ok=0 failed=0 missing=0
  local failed_list="${LOG_DIR}/md5_failed.txt"
  local missing_list="${LOG_DIR}/md5_missing.txt"
  local md5_report="${LOG_DIR}/md5_detail_report.txt"
  : > "${failed_list}"
  : > "${missing_list}"
  : > "${md5_report}"

  echo "========== MD5 校验详细报告 ==========" > "${md5_report}"
  echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')" >> "${md5_report}"
  echo "" >> "${md5_report}"

  while IFS=$'\t' read -r md5 filepath; do
    [[ -z "${md5:-}" ]] && continue
    [[ "${md5}" == \#* ]] && continue
    [[ -z "${filepath:-}" ]] && continue
    total=$((total + 1))
    local local_path="${LOCAL_ROOT}/${filepath}"

    if [[ ! -f "${local_path}" ]]; then
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
      echo "  建议：将该文件移入垃圾箱/隔离目录后重跑 download_refseq_truly_full.sh 续传" >> "${md5_report}"
      echo "" >> "${md5_report}"
      failed=$((failed + 1))
    fi

    if [[ $((total % 200)) -eq 0 ]]; then
      log "  已校验 ${total} 文件（OK=${ok}, 失败=${failed}, 缺失=${missing}）"
    fi
  done < "${TARGET_MANIFEST}"

  local pass_rate="0.0"
  if [[ ${total} -gt 0 ]]; then
    pass_rate=$(awk -v ok="${ok}" -v total="${total}" 'BEGIN{printf "%.1f", ok*100/total}')
  fi

  {
    echo "========== MD5 校验摘要 =========="
    echo "目标总计：${total}"
    echo "通过：${ok}"
    echo "失败：${failed}"
    echo "缺失：${missing}"
    echo "通过率：${pass_rate}%"
    echo ""
    if [[ ${failed} -gt 0 ]]; then
      echo "⚠ 失败文件（${failed} 个）—— MD5 不匹配，文件可能损坏："
      echo "  详见：${md5_report}"
      echo "  简表：${failed_list}"
      echo "  处理建议：将异常文件移入垃圾箱/隔离目录后重跑下载脚本续传"
    fi
    if [[ ${missing} -gt 0 ]]; then
      echo "⚠ 缺失文件（${missing} 个）—— 未下载或下载中断："
      echo "  详见：${md5_report}"
      echo "  简表：${missing_list}"
      echo "  处理建议：重跑下载脚本补齐"
    fi
    if [[ ${failed} -eq 0 && ${missing} -eq 0 && ${total} -gt 0 ]]; then
      echo "全部目标文件 MD5 校验通过。"
    fi
  } >> "${md5_report}"

  log "MD5 校验结果："
  log "  目标总计：${total}"
  log "  通过：${ok}"
  log "  失败：${failed}（详见 ${md5_report}）"
  log "  缺失：${missing}（详见 ${md5_report}）"
  log "  通过率：${pass_rate}%"

  if [[ ${total} -eq 0 || ${failed} -gt 0 || ${missing} -gt 0 ]]; then
    return 1
  fi
  return 0
}

verify_unverified_files() {
  log "===== Step 1b: 无 MD5 文件 gzip CRC 校验 ====="

  if [[ ! -s "${UNVERIFIED_MANIFEST}" ]]; then
    log "  未发现 unverified_files.tsv，跳过。"
    return 0
  fi

  local total=0 ok=0 failed=0 missing=0 unsafe=0
  local report="${LOG_DIR}/unverified_detail_report.txt"
  : > "${report}"

  echo "========== 无 MD5 文件 gzip CRC 校验报告 ==========" > "${report}"
  echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')" >> "${report}"
  echo "" >> "${report}"

  while IFS=$'\t' read -r filepath reason; do
    [[ -z "${filepath:-}" ]] && continue
    [[ "${filepath}" == \#* ]] && continue
    [[ -z "${reason:-}" ]] && reason="NO_MD5_IN_CATALOG"

    total=$((total + 1))
    if [[ "${filepath}" == /* || "${filepath}" == "../"* || "${filepath}" == *"/../"* || "${filepath}" == *"/.." ]]; then
      unsafe=$((unsafe + 1))
      echo "[UNSAFE] ${filepath}" >> "${report}"
      echo "  原因：不安全相对路径" >> "${report}"
      echo "" >> "${report}"
      continue
    fi

    local local_path="${LOCAL_ROOT}/${filepath}"
    if [[ ! -f "${local_path}" ]]; then
      missing=$((missing + 1))
      echo "[MISSING] ${filepath}" >> "${report}"
      echo "  原因：${reason}" >> "${report}"
      echo "  本地路径：${local_path}" >> "${report}"
      echo "" >> "${report}"
      continue
    fi

    if gzip -t "${local_path}" 2>> "${report}"; then
      ok=$((ok + 1))
      echo "[OK] ${filepath}" >> "${report}"
    else
      failed=$((failed + 1))
      echo "[FAILED] ${filepath}" >> "${report}"
    fi
  done < "${UNVERIFIED_MANIFEST}"

  log "无 MD5 文件 gzip CRC 结果："
  log "  目标总计：${total}"
  log "  通过：${ok}"
  log "  失败：${failed}（详见 ${report}）"
  log "  缺失：${missing}（详见 ${report}）"
  log "  不安全路径：${unsafe}（详见 ${report}）"

  if [[ ${failed} -gt 0 || ${missing} -gt 0 || ${unsafe} -gt 0 ]]; then
    return 1
  fi
  return 0
}

verify_file_count() {
  log "===== Step 2: 文件数量统计（按目录 × 类型）====="

  local dirs=(
    bacteria archaea fungi plant invertebrate protozoa
    vertebrate_mammalian vertebrate_other viral
    mitochondrion plasmid plastid other complete
  )

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
      [[ ! -d "${dir_path}" ]] && continue

      local row_total=0
      printf "%-25s" "${d}"
      for t in "${types[@]}"; do
        local count
        count=$(find "${dir_path}" -name "*.${t}" 2>/dev/null | wc -l)
        printf "%14s" "${count}"
        row_total=$((row_total + count))
      done
      printf "%12s\n" "${row_total}"
    done
  } | tee -a "${VERIFY_LOG}"
}

count_sequences_sample() {
  log "===== Step 3: 序列数采样（每目录前 3 个 genomic.fna.gz）====="

  local dirs=(
    bacteria archaea fungi plant invertebrate protozoa
    vertebrate_mammalian vertebrate_other viral
    mitochondrion plasmid plastid other
  )

  for d in "${dirs[@]}"; do
    local dir_path="${LOCAL_ROOT}/${d}"
    [[ ! -d "${dir_path}" ]] && continue

    local files
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
      seq_count=$(zcat "${f}" 2>/dev/null | grep -c "^>" || true)
      fsize=$(du -h "${f}" | awk '{print $1}')
      log "    $(basename "${f}"): ${seq_count} 序列, ${fsize}"
    done <<< "${files}"
  done
}

disk_usage_summary() {
  log "===== Step 4: 磁盘使用汇总 ====="
  local total_size
  total_size=$(du -sh "${LOCAL_ROOT}" 2>/dev/null | awk '{print $1}')
  log "  总占用：${total_size}"

  for d in bacteria archaea fungi plant invertebrate protozoa \
           vertebrate_mammalian vertebrate_other viral \
           mitochondrion plasmid plastid other complete; do
    local dir_path="${LOCAL_ROOT}/${d}"
    [[ ! -d "${dir_path}" ]] && continue
    local size
    size=$(du -sh "${dir_path}" 2>/dev/null | awk '{print $1}')
    log "    ${d}: ${size}"
  done
}

generate_final_report() {
  local md5_result="$1"
  local unverified_result="${2:-PASS}"
  {
    echo "=============================================="
    echo "  RefSeq 目标集验证最终报告"
    echo "  生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
    echo "  根目录：${LOCAL_ROOT}"
    echo "=============================================="
    echo ""
    echo "验证项目及结果："
    echo ""
    echo "  [Manifest 信息]     已读取"
    echo ""
    if [[ "${md5_result}" == "SKIP" ]]; then
      echo "  [MD5 校验]         跳过（target_files.tsv 无数据行，所有文件无 MD5 catalog 条目）"
    elif [[ "${md5_result}" == "PASS" ]]; then
      echo "  [MD5 校验]         全部通过"
    else
      echo "  [MD5 校验]         存在问题（见 ${LOG_DIR}/md5_detail_report.txt）"
    fi
    if [[ "${unverified_result}" == "PASS" ]]; then
      echo "  [无 MD5 文件]      gzip CRC 通过或无此类文件"
    else
      echo "  [无 MD5 文件]      gzip CRC 存在问题（见 ${LOG_DIR}/unverified_detail_report.txt）"
    fi
    echo ""
    echo "  [文件数量统计]      已输出（见上方 Step 2）"
    echo "  [序列数采样]        已输出（见上方 Step 3）"
    echo "  [磁盘使用汇总]      已输出（见上方 Step 4）"
    echo ""
    echo "日志文件："
    echo "  验证日志：      ${VERIFY_LOG}"
    echo "  MD5 详情：      ${LOG_DIR}/md5_detail_report.txt"
    echo "  MD5 失败：      ${LOG_DIR}/md5_failed.txt"
    echo "  MD5 缺失：      ${LOG_DIR}/md5_missing.txt"
    echo "  无 MD5 详情：   ${LOG_DIR}/unverified_detail_report.txt"
    echo ""
    if [[ "${md5_result}" != "PASS" || "${unverified_result}" != "PASS" ]]; then
      echo "处理建议："
      echo "  1. 检查 ${LOG_DIR}/md5_detail_report.txt 和 ${LOG_DIR}/unverified_detail_report.txt"
      echo "  2. MD5 不匹配的文件：移入垃圾箱/隔离目录后重跑 download_refseq_truly_full.sh"
      echo "  3. 缺失的文件：直接重跑 download_refseq_truly_full.sh 补齐"
      echo "  4. 无 MD5 文件 gzip CRC 失败时，优先重跑下载脚本或单独续传对应文件"
    fi
    echo ""
    echo "=============================================="
  } > "${REPORT_FILE}"

  log ""
  log "========== 验证总结 =========="
  cat "${REPORT_FILE}" | tee -a "${VERIFY_LOG}"
  log ""
  log "完整报告已保存：${REPORT_FILE}"
}

main() {
  log "========== RefSeq 目标集完整性验证 =========="
  log "根目录：${LOCAL_ROOT}"
  log "说明：RefSeq release FTP 不提供 genomic.gff3.gz；本脚本不校验 GFF3。"
  log ""

  ensure_manifests
  show_manifest_info

  local md5_status="PASS"
  local target_data_count
  target_data_count=$(manifest_data_count)
  if [[ "${target_data_count}" -eq 0 ]]; then
    md5_status="SKIP"
    log "  跳过 MD5 校验（target_files.tsv 无数据行）"
  else
    verify_md5 || md5_status="FAIL"
  fi

  local unverified_status="PASS"
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