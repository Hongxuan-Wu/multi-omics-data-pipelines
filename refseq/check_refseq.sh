#!/usr/bin/env bash
# RefSeq 代码与文档统一自检入口；不访问网络，不启动下载，不修改数据库。
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
refseq_root="${repo_root}/refseq"

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

if [[ -n "${REFSEQ_PYTHON:-}" ]]; then
  python_bin="${REFSEQ_PYTHON}"
else
  if [[ -z "${CONDA_PREFIX:-}" || "${CONDA_DEFAULT_ENV:-}" == "base" ]]; then
    die "请先激活非 base Conda Python 环境，或通过 REFSEQ_PYTHON 指定该环境中的 Python。"
  fi
  python_bin="python"
fi

command -v "${python_bin}" >/dev/null 2>&1 || die "找不到 Python：${python_bin}"
export REFSEQ_PYTHON="${python_bin}"

shell_scripts=(
  "${refseq_root}/check_refseq.sh"
  "${refseq_root}/genomes_dir/download_refseq_genomes_api.sh"
  "${refseq_root}/genomes_dir/download_refseq_genomes_ftp.sh"
  "${refseq_root}/refseq_release_dir/download_refseq.sh"
  "${refseq_root}/refseq_release_dir/verify_refseq_truly_full.sh"
)

python_files=(
  "${refseq_root}/refseq_release_dir/verify_md5_parallel.py"
  "${refseq_root}/resources/getProkaryotesGenomes.py"
  "${refseq_root}/resources/preProkaryotesGeneExpression_prokaryotes.py"
)

test_scripts=(
  "${refseq_root}"/genomes_dir/tests/test_*.sh
  "${refseq_root}"/tests/test_*.sh
)
test_output=""

printf '[1/4] Bash syntax: %s files\n' "${#shell_scripts[@]}"
for script in "${shell_scripts[@]}"; do
  bash -n "${script}"
done

printf '[2/4] Python syntax: %s files\n' "${#python_files[@]}"
"${python_bin}" -c '
import ast
import pathlib
import sys

for raw_path in sys.argv[1:]:
    path = pathlib.Path(raw_path)
    ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
' "${python_files[@]}"

printf '[3/4] RefSeq tests: %s files\n' "${#test_scripts[@]}"
for test_script in "${test_scripts[@]}"; do
  printf '  RUN %s ... ' "${test_script#"${repo_root}/"}"
  if test_output="$(bash "${test_script}" 2>&1)"; then
    printf 'PASS\n'
  else
    printf 'FAIL\n%s\n' "${test_output}" >&2
    exit 1
  fi
done

printf '[4/4] Git whitespace check\n'
git -C "${repo_root}" diff --check -- refseq
git -C "${repo_root}" diff --cached --check -- refseq

printf 'RefSeq checks passed: bash=%s, python=%s, tests=%s.\n' \
  "${#shell_scripts[@]}" "${#python_files[@]}" "${#test_scripts[@]}"
