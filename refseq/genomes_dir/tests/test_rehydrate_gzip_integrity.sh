#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source_script="${repo_root}/refseq/genomes_dir/download_refseq_genomes_api.sh"

test_root="/tmp/refseq_genomes_api_gzip_integrity_test.$(date +%s%N).$$"
work_root="${test_root}/work"
data_root="${test_root}/data1"
run_base_root="${test_root}/datasets"
run_root="${run_base_root}/refseq_genomes_runlogs"
script_under_test="${work_root}/download_refseq_genomes_api.sh"
context_name="test_context"
owner_dir="p252701008"

mkdir -p "${work_root}" "${data_root}" "${run_base_root}"
cp -- "${source_script}" "${script_under_test}"

assembly_summary="${work_root}/assembly_summary_refseq.txt"
printf '# assembly summary fixture\n' > "${assembly_summary}"

sed -i \
  -e "s|^ASSEMBLY_SUMMARY_FILE=.*|ASSEMBLY_SUMMARY_FILE=\"${assembly_summary}\"|" \
  -e "s|^STORAGE_DISK_CANDIDATES=.*|STORAGE_DISK_CANDIDATES=(\"${data_root}\")|" \
  -e "s|^STORAGE_OWNER_DIR=.*|STORAGE_OWNER_DIR=\"${owner_dir}\"|" \
  -e "s|^RUN_BASE_ROOT=.*|RUN_BASE_ROOT=\"${run_base_root}\"|" \
  -e "s|^PIPELINE_CONTEXT_OVERRIDE=.*|PIPELINE_CONTEXT_OVERRIDE=\"${context_name}\"|" \
  -e "s|^REHYDRATE_GZIP=.*|REHYDRATE_GZIP=1|" \
  -e "s|^STRICT_INTEGRITY=.*|STRICT_INTEGRITY=0|" \
  -e "s|^VERIFY_FETCH_MD5=.*|VERIFY_FETCH_MD5=0|" \
  -e "s|^MIN_DISK_GB=.*|MIN_DISK_GB=0|" \
  "${script_under_test}"

merged_ncbi_dir="${data_root}/${owner_dir}/refseq_genomes/contexts/${context_name}/merged_refseq_dataset/ncbi_dataset"
rehydrate_data_dir="${data_root}/${owner_dir}/refseq_genomes/contexts/${context_name}/rehydrate_refseq_dataset/ncbi_dataset/data/GCF_000001.1"
manifest_dir="${run_root}/manifests/${context_name}"
mkdir -p "${merged_ncbi_dir}" "${rehydrate_data_dir}" "${manifest_dir}"

printf 'ASSEMBLY_SUMMARY_FILE=%s\n' "${assembly_summary}" > "${manifest_dir}/manifest_config.txt"
printf 'GCF_000001.1\n' > "${manifest_dir}/accessions.sorted.txt"
printf 'https://example.org/genome\t0\tdata/GCF_000001.1/GCF_000001.1_genomic.fna\n' > "${merged_ncbi_dir}/fetch.txt"
printf 'https://example.org/report\t0\tdata/GCF_000001.1/sequence_report.jsonl\n' >> "${merged_ncbi_dir}/fetch.txt"

printf 'this is not gzip data\n' > "${rehydrate_data_dir}/GCF_000001.1_genomic.fna.gz"
printf '{}\n' | gzip -c > "${rehydrate_data_dir}/sequence_report.jsonl.gz"

if NCBI_API_KEY='test-secret-key' bash "${script_under_test}" verify > "${test_root}/verify.log" 2>&1; then
  printf 'expected verify to fail on corrupt gzip file\n' >&2
  exit 1
fi

grep -Eq 'gzip|GZIP|压缩' "${test_root}/verify.log" || {
  printf 'expected gzip integrity failure in verify log\n' >&2
  tail -n 40 "${test_root}/verify.log" >&2
  exit 1
}
