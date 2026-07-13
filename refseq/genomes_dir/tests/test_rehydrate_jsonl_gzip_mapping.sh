#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source_script="${repo_root}/refseq/genomes_dir/download_refseq_genomes_api.sh"

test_root="/tmp/refseq_genomes_api_jsonl_gzip_mapping_test.$(date +%s%N).$$"
work_root="${test_root}/work"
data_root="${test_root}/data1"
run_base_root="${test_root}/datasets"
run_root="${run_base_root}/refseq_genomes_runlogs"
bin_dir="${test_root}/bin"
script_under_test="${work_root}/download_refseq_genomes_api.sh"
context_name="test_context"
owner_dir="p252701008"

mkdir -p "${work_root}" "${data_root}" "${run_base_root}" "${bin_dir}"
cp -- "${source_script}" "${script_under_test}"

assembly_summary="${work_root}/assembly_summary_refseq.txt"
printf '# assembly summary fixture\n' > "${assembly_summary}"

sed -i \
  -e "s|^ASSEMBLY_SUMMARY_FILE=.*|ASSEMBLY_SUMMARY_FILE=\"${assembly_summary}\"|" \
  -e "s|^STORAGE_DISK_CANDIDATES=.*|STORAGE_DISK_CANDIDATES=(\"${data_root}\")|" \
  -e "s|^STORAGE_OWNER_DIR=.*|STORAGE_OWNER_DIR=\"${owner_dir}\"|" \
  -e "s|^RUN_BASE_ROOT=.*|RUN_BASE_ROOT=\"${run_base_root}\"|" \
  -e "s|^PIPELINE_CONTEXT_OVERRIDE=.*|PIPELINE_CONTEXT_OVERRIDE=\"${context_name}\"|" \
  -e "s|^DATASETS_BIN=.*|DATASETS_BIN=\"${bin_dir}/datasets\"|" \
  -e "s|^REHYDRATE_MAX_RETRIES=.*|REHYDRATE_MAX_RETRIES=1|" \
  -e "s|^RETRY_SLEEP_SECONDS=.*|RETRY_SLEEP_SECONDS=0|" \
  -e "s|^REHYDRATE_PROGRESS_INTERVAL_SECONDS=.*|REHYDRATE_PROGRESS_INTERVAL_SECONDS=0|" \
  -e "s|^REHYDRATE_GZIP=.*|REHYDRATE_GZIP=1|" \
  -e "s|^STORAGE_MIN_FREE_GB=.*|STORAGE_MIN_FREE_GB=0|" \
  -e "s|^MIN_DISK_GB=.*|MIN_DISK_GB=0|" \
  "${script_under_test}"

cat > "${bin_dir}/datasets" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

directory=""
is_list=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --directory)
      directory="$2"
      shift 2
      ;;
    --list)
      is_list=1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "${is_list}" == "1" ]]; then
  awk -F '\t' 'NF >= 3 {print $3}' "${directory}/ncbi_dataset/fetch.txt"
  exit 0
fi

printf 'unexpected rehydrate invocation\n' > "${REHYDRATE_MARKER}"
jsonl_target="${directory}/ncbi_dataset/data/GCF_000001.1/sequence_report.jsonl"
if [[ -e "${jsonl_target}" ]]; then
  printf 'empty JSONL placeholder was not quarantined before rehydrate\n' >&2
  exit 98
fi
mkdir -p "$(dirname "${jsonl_target}")"
printf '{}\n' > "${jsonl_target}"
EOF
chmod +x "${bin_dir}/datasets"

context_root="${data_root}/${owner_dir}/refseq_genomes/contexts/${context_name}"
merged_ncbi_dir="${context_root}/merged_refseq_dataset/ncbi_dataset"
rehydrate_data_dir="${context_root}/rehydrate_refseq_dataset/ncbi_dataset/data/GCF_000001.1"
manifest_dir="${run_root}/manifests/${context_name}"
mkdir -p "${merged_ncbi_dir}" "${rehydrate_data_dir}" "${manifest_dir}"

printf 'ASSEMBLY_SUMMARY_FILE=%s\n' "${assembly_summary}" > "${manifest_dir}/manifest_config.txt"
printf 'GCF_000001.1\n' > "${manifest_dir}/accessions.sorted.txt"
printf 'https://example.org/genome\t0\tdata/GCF_000001.1/GCF_000001.1_genomic.fna\n' > "${merged_ncbi_dir}/fetch.txt"
printf 'https://example.org/report\t0\tdata/GCF_000001.1/sequence_report.jsonl\n' >> "${merged_ncbi_dir}/fetch.txt"

printf 'gzip-placeholder\n' | gzip -c > "${rehydrate_data_dir}/GCF_000001.1_genomic.fna.gz"
printf '{}\n' > "${rehydrate_data_dir}/sequence_report.jsonl"

export REHYDRATE_MARKER="${test_root}/unexpected_rehydrate.marker"
run_log="${test_root}/rehydrate.log"
if ! NCBI_API_KEY='test-secret-key' bash "${script_under_test}" rehydrate > "${run_log}" 2>&1; then
  printf 'expected existing uncompressed sequence_report.jsonl to satisfy gzip-mode target mapping\n' >&2
  tail -n 60 "${run_log}" >&2
  exit 1
fi

if [[ -e "${REHYDRATE_MARKER}" ]]; then
  printf 'expected no datasets rehydrate invocation when all targets already exist\n' >&2
  exit 1
fi

grep -q '所有 rehydrate 目标文件已在候选盘中存在' "${run_log}" || {
  printf 'expected all-targets-present message\n' >&2
  tail -n 60 "${run_log}" >&2
  exit 1
}

: > "${rehydrate_data_dir}/sequence_report.jsonl"
empty_run_log="${test_root}/rehydrate_empty_jsonl.log"
if ! NCBI_API_KEY='test-secret-key' bash "${script_under_test}" rehydrate > "${empty_run_log}" 2>&1; then
  printf 'expected empty sequence_report.jsonl to be quarantined and downloaded again\n' >&2
  tail -n 60 "${empty_run_log}" >&2
  exit 1
fi

if [[ ! -s "${REHYDRATE_MARKER}" ]]; then
  printf 'expected datasets rehydrate invocation for empty sequence_report.jsonl\n' >&2
  tail -n 60 "${empty_run_log}" >&2
  exit 1
fi

[[ -s "${rehydrate_data_dir}/sequence_report.jsonl" ]] || {
  printf 'expected rehydrate to replace empty sequence_report.jsonl with non-empty data\n' >&2
  exit 1
}

find "${run_root}/trash" -type f -path '*/GCF_000001.1/sequence_report.jsonl' -size 0c | grep -q . || {
  printf 'expected original empty sequence_report.jsonl in trash quarantine\n' >&2
  exit 1
}
