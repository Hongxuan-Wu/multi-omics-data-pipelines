#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python_bin="${REFSEQ_PYTHON:?请通过 refseq/check_refseq.sh 在非 base Conda 环境中运行本测试}"
expected='历史研究脚本没有受支持的命令行入口；当前 RefSeq 下载请使用 genomes_dir/download_refseq_genomes_api.sh。'

for legacy_script in \
  "${repo_root}/refseq/resources/getProkaryotesGenomes.py" \
  "${repo_root}/refseq/resources/preProkaryotesGeneExpression_prokaryotes.py"; do
  set +e
  output="$("${python_bin}" "${legacy_script}" 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -ne 1 || "${output}" != "${expected}" ]]; then
    printf 'legacy Python entrypoint guard failed: %s\nstatus=%s\noutput=%s\n' \
      "${legacy_script}" "${status}" "${output}" >&2
    exit 1
  fi
done

printf 'Legacy Python entrypoints are guarded.\n'
