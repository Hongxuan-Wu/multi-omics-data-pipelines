#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source_script="${repo_root}/refseq/genomes_dir/download_refseq_genomes_api.sh"

test_root="/tmp/refseq_genomes_api_repair_shards_test.$(date +%s%N).$$"
work_root="${test_root}/work"
data_root="${test_root}/data1"
run_base_root="${test_root}/datasets"
run_root="${run_base_root}/refseq_genomes_runlogs"
bin_dir="${test_root}/bin"
script_under_test="${work_root}/download_refseq_genomes_api.sh"
context_name="test_context"
owner_dir="p252701008"
shard_id="refseq_000000"

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
  -e "s|^UNZIP_BIN=.*|UNZIP_BIN=\"${bin_dir}/unzip\"|" \
  -e "s|^REPAIR_SHARDS=.*|REPAIR_SHARDS=\"${shard_id}\"|" \
  -e "s|^DOWNLOAD_LINK_MAX_RETRIES=.*|DOWNLOAD_LINK_MAX_RETRIES=1|" \
  -e "s|^RETRY_SLEEP_SECONDS=.*|RETRY_SLEEP_SECONDS=0|" \
  -e "s|^VERIFY_FETCH_FILE_PROFILE=.*|VERIFY_FETCH_FILE_PROFILE=0|" \
  -e "s|^MIN_DISK_GB=.*|MIN_DISK_GB=0|" \
  "${script_under_test}"

cat > "${bin_dir}/datasets" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

out_file=""
input_file=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --filename)
      out_file="$2"
      shift 2
      ;;
    --inputfile)
      input_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

[[ -n "${out_file}" ]] || {
  printf 'missing --filename\n' >&2
  exit 2
}
[[ -s "${input_file}" ]] || {
  printf 'missing --inputfile\n' >&2
  exit 3
}
printf 'fake dehydrated zip for %s\n' "${input_file}" > "${out_file}"
EOF
chmod +x "${bin_dir}/datasets"

cat > "${bin_dir}/unzip" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == "-t" ]]; then
  [[ -s "${2:-}" ]] || exit 4
  exit 0
fi

out_dir=""
zip_file=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -d)
      out_dir="$2"
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      zip_file="$1"
      shift
      ;;
  esac
done

[[ -n "${out_dir}" ]] || {
  printf 'missing -d\n' >&2
  exit 5
}

shard_id="$(basename "${zip_file}" .zip)"
input_file="${SHARD_FIXTURE_DIR}/${shard_id}.txt"
mkdir -p "${out_dir}/ncbi_dataset"
: > "${out_dir}/ncbi_dataset/fetch.txt"
: > "${out_dir}/ncbi_dataset/assembly_data_report.jsonl"
while IFS= read -r accession; do
  [[ -n "${accession}" ]] || continue
  printf 'https://example.org/%s/genome\t0\tdata/%s/%s_genomic.fna\n' "${accession}" "${accession}" "${accession}" >> "${out_dir}/ncbi_dataset/fetch.txt"
  printf 'https://example.org/%s/report\t0\tdata/%s/sequence_report.jsonl\n' "${accession}" "${accession}" >> "${out_dir}/ncbi_dataset/fetch.txt"
  printf '{"accession":"%s"}\n' "${accession}" >> "${out_dir}/ncbi_dataset/assembly_data_report.jsonl"
done < "${input_file}"
EOF
chmod +x "${bin_dir}/unzip"

manifest_dir="${run_root}/manifests/${context_name}"
shard_dir="${run_root}/shards/${context_name}/refseq_shards_size_5000"
status_dir="${run_root}/status/${context_name}"
link_root="${data_root}/${owner_dir}/refseq_genomes/contexts/${context_name}/dehydrated_links"
zip_dir="${link_root}/zips"
unpack_dir="${link_root}/unzipped"
merged_ncbi_dir="${data_root}/${owner_dir}/refseq_genomes/contexts/${context_name}/merged_refseq_dataset/ncbi_dataset"
mkdir -p "${manifest_dir}" "${shard_dir}" "${status_dir}" "${zip_dir}" "${unpack_dir}/${shard_id}/ncbi_dataset" "${merged_ncbi_dir}"

printf 'ASSEMBLY_SUMMARY_FILE=%s\n' "${assembly_summary}" > "${manifest_dir}/manifest_config.txt"
printf 'GCF_000001.1\nGCF_000002.1\n' > "${manifest_dir}/accessions.sorted.txt"
printf 'GCF_000001.1\nGCF_000002.1\n' > "${shard_dir}/${shard_id}.txt"
printf '%s\n' "${shard_dir}/${shard_id}.txt" > "${shard_dir}/shard_list.txt"
printf 'old zip\n' > "${zip_dir}/${shard_id}.zip"
printf 'https://old.example.org\t0\tdata/GCF_000001.1/old.fna\n' > "${unpack_dir}/${shard_id}/ncbi_dataset/fetch.txt"

export SHARD_FIXTURE_DIR="${shard_dir}"
run_log="${test_root}/repair.log"
if ! NCBI_API_KEY='test-secret-key' bash "${script_under_test}" repair-shards > "${run_log}" 2>&1; then
  printf 'expected repair-shards to repair one shard and rebuild merged fetch\n' >&2
  tail -n 80 "${run_log}" >&2
  exit 1
fi

grep -q 'GCF_000002.1' "${merged_ncbi_dir}/fetch.txt" || {
  printf 'expected merged fetch to include repaired second accession\n' >&2
  tail -n 80 "${run_log}" >&2
  exit 1
}

find "${run_root}/trash" -type f -name "*repair_old_zip*${shard_id}*" | grep -q . || {
  printf 'expected old shard zip to be moved to trash\n' >&2
  exit 1
}

grep -q "${shard_id}" "${status_dir}/repair_shard_status.tsv" || {
  printf 'expected repair status to record repaired shard\n' >&2
  exit 1
}
