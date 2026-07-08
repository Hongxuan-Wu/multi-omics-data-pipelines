#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source_script="${repo_root}/refseq/genomes_dir/download_refseq_genomes_api.sh"

test_root="/tmp/refseq_genomes_api_rehydrate_list_test.$(date +%s%N).$$"
work_root="${test_root}/work"
data_root="${test_root}/data"
run_root="${test_root}/run"
bin_dir="${test_root}/bin"
script_under_test="${work_root}/download_refseq_genomes_api.sh"
context_name="test_context"

mkdir -p "${work_root}" "${data_root}" "${run_root}" "${bin_dir}"
cp -- "${source_script}" "${script_under_test}"

assembly_summary="${work_root}/assembly_summary_refseq.txt"
printf '# assembly summary fixture\n' > "${assembly_summary}"

sed -i \
  -e "s|^ASSEMBLY_SUMMARY_FILE=.*|ASSEMBLY_SUMMARY_FILE=\"${assembly_summary}\"|" \
  -e "s|^STORAGE_DISK_CANDIDATES=.*|STORAGE_DISK_CANDIDATES=(\"${data_root}\")|" \
  -e "s|^STORAGE_OWNER_DIR=.*|STORAGE_OWNER_DIR=\"owner\"|" \
  -e "s|^RUN_ROOT=.*|RUN_ROOT=\"${run_root}\"|" \
  -e "s|^PIPELINE_CONTEXT_OVERRIDE=.*|PIPELINE_CONTEXT_OVERRIDE=\"${context_name}\"|" \
  -e "s|^DATASETS_BIN=.*|DATASETS_BIN=\"${bin_dir}/datasets\"|" \
  -e "s|^REHYDRATE_MAX_RETRIES=.*|REHYDRATE_MAX_RETRIES=1|" \
  -e "s|^RETRY_SLEEP_SECONDS=.*|RETRY_SLEEP_SECONDS=0|" \
  -e "s|^REHYDRATE_PROGRESS_INTERVAL_SECONDS=.*|REHYDRATE_PROGRESS_INTERVAL_SECONDS=0|" \
  -e "s|^REHYDRATE_GZIP=.*|REHYDRATE_GZIP=0|" \
  -e "s|^STORAGE_MIN_FREE_GB=.*|STORAGE_MIN_FREE_GB=0|" \
  -e "s|^STRICT_INTEGRITY=.*|STRICT_INTEGRITY=0|" \
  -e "s|^VERIFY_FETCH_MD5=.*|VERIFY_FETCH_MD5=0|" \
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
  for i in $(seq 1 1000); do
    printf 'data/GCF_000001.1/list_entry_%04d.txt\n' "${i}"
  done
  exit 0
fi

mkdir -p "${directory}/data/GCF_000001.1" "${directory}/ncbi_dataset/data/GCF_000001.1"
printf '>seq\nACGT\n' > "${directory}/data/GCF_000001.1/GCF_000001.1_genomic.fna"
printf '{}\n' > "${directory}/data/GCF_000001.1/sequence_report.jsonl"
cp -- "${directory}/data/GCF_000001.1/GCF_000001.1_genomic.fna" "${directory}/ncbi_dataset/data/GCF_000001.1/GCF_000001.1_genomic.fna"
cp -- "${directory}/data/GCF_000001.1/sequence_report.jsonl" "${directory}/ncbi_dataset/data/GCF_000001.1/sequence_report.jsonl"
EOF
chmod +x "${bin_dir}/datasets"

manifest_dir="${run_root}/manifests/${context_name}"
package_dir="${data_root}/owner/refseq_genomes/contexts/${context_name}/merged_refseq_dataset/ncbi_dataset"
mkdir -p "${manifest_dir}" "${package_dir}"
printf 'ASSEMBLY_SUMMARY_FILE=%s\n' "${assembly_summary}" > "${manifest_dir}/manifest_config.txt"
printf 'GCF_000001.1\n' > "${manifest_dir}/accessions.sorted.txt"
printf 'https://example.org/genome\t0\tdata/GCF_000001.1/GCF_000001.1_genomic.fna\n' > "${package_dir}/fetch.txt"
printf 'https://example.org/report\t0\tdata/GCF_000001.1/sequence_report.jsonl\n' >> "${package_dir}/fetch.txt"

NCBI_API_KEY='test-secret-key' bash "${script_under_test}" rehydrate

list_log="$(find "${run_root}/logs/${context_name}" -maxdepth 1 -type f -name 'datasets_rehydrate_list_*.log' ! -name '*.stderr' | head -n 1)"
[[ -n "${list_log}" ]] || {
  printf 'expected rehydrate list summary log\n' >&2
  exit 1
}

line_count="$(wc -l < "${list_log}" | awk '{print $1}')"
if [[ "${line_count}" -ge 1000 ]]; then
  printf 'expected summary log, got full --list output with %s lines: %s\n' "${line_count}" "${list_log}" >&2
  exit 1
fi

grep -q 'stdout_lines=1000' "${list_log}" || {
  printf 'expected stdout_lines=1000 in summary log: %s\n' "${list_log}" >&2
  exit 1
}

if find "${run_root}/logs/${context_name}" -maxdepth 1 -type f -name '*.redacted.*' | grep -q .; then
  printf 'expected no redacted full-list temp files\n' >&2
  exit 1
fi
