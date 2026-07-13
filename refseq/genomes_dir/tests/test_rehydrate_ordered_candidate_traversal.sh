#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source_script="${repo_root}/refseq/genomes_dir/download_refseq_genomes_api.sh"

test_root="/tmp/refseq_genomes_api_ordered_candidates_test.$(date +%s%N).$$"
work_root="${test_root}/work"
fake_data1="${test_root}/data1"
fake_data2="${test_root}/data2"
fake_data4="${test_root}/data4"
fake_data5="${test_root}/data5"
fake_data3="${test_root}/data3"
bin_dir="${test_root}/bin"
script_under_test="${work_root}/download_refseq_genomes_api.sh"
context_name="test_context"
owner_dir="p252701008"
run_base_root="${test_root}/datasets"
run_root="${run_base_root}/refseq_genomes_runlogs"

mkdir -p "${work_root}" "${bin_dir}" "${fake_data1}" "${fake_data2}" "${fake_data4}" "${fake_data5}" "${fake_data3}" "${run_base_root}"
cp -- "${source_script}" "${script_under_test}"

assembly_summary="${work_root}/assembly_summary_refseq.txt"
printf '# assembly summary fixture\n' > "${assembly_summary}"

sed -i \
  -e "s|^ASSEMBLY_SUMMARY_FILE=.*|ASSEMBLY_SUMMARY_FILE=\"${assembly_summary}\"|" \
  -e "s|^STORAGE_DISK_CANDIDATES=.*|STORAGE_DISK_CANDIDATES=(\"${fake_data1}\" \"${fake_data2}\" \"${fake_data4}\" \"${fake_data5}\" \"${fake_data3}\")|" \
  -e "s|^STORAGE_OWNER_DIR=.*|STORAGE_OWNER_DIR=\"${owner_dir}\"|" \
  -e "s|^RUN_BASE_ROOT=.*|RUN_BASE_ROOT=\"${run_base_root}\"|" \
  -e "s|^PIPELINE_CONTEXT_OVERRIDE=.*|PIPELINE_CONTEXT_OVERRIDE=\"${context_name}\"|" \
  -e "s|^DATASETS_BIN=.*|DATASETS_BIN=\"${bin_dir}/datasets\"|" \
  -e "s|^REHYDRATE_MAX_RETRIES=.*|REHYDRATE_MAX_RETRIES=3|" \
  -e "s|^RETRY_SLEEP_SECONDS=.*|RETRY_SLEEP_SECONDS=0|" \
  -e "s|^REHYDRATE_PROGRESS_INTERVAL_SECONDS=.*|REHYDRATE_PROGRESS_INTERVAL_SECONDS=0|" \
  -e "s|^REHYDRATE_GZIP=.*|REHYDRATE_GZIP=1|" \
  -e "s|^STORAGE_MIN_FREE_GB=.*|STORAGE_MIN_FREE_GB=200|" \
  -e "s|^MIN_DISK_GB=.*|MIN_DISK_GB=0|" \
  -e "s|^STRICT_INTEGRITY=.*|STRICT_INTEGRITY=0|" \
  -e "s|^VERIFY_FETCH_MD5=.*|VERIFY_FETCH_MD5=0|" \
  "${script_under_test}"

cat > "${bin_dir}/df" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
target="\${@: -1}"
disk="other"
case "\${target}" in
  ${fake_data1}*) disk="data1" ;;
  ${fake_data2}*) disk="data2" ;;
  ${fake_data4}*) disk="data4" ;;
  ${fake_data5}*) disk="data5" ;;
  ${fake_data3}*) disk="data3" ;;
esac
printf 'Filesystem 1G-blocks Used Available Use%% Mounted on\\n'
if [[ -f "${test_root}/\${disk}.low" ]]; then
  printf 'fake_%s 1000G 900G 100G 90%% /\\n' "\${disk}"
else
  printf 'fake_%s 1000G 100G 900G 10%% /\\n' "\${disk}"
fi
EOF
chmod +x "${bin_dir}/df"

cat > "${bin_dir}/datasets" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

directory=""
is_list=0
gzip_mode=0
printf '%s\n' "$*" >> "${DATASETS_ARGS_LOG}"
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
    --gzip)
      gzip_mode=1
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

if [[ "${gzip_mode}" != "1" ]]; then
  printf 'expected --gzip\n' >&2
  exit 9
fi

case "${directory}" in
  *"/data1/"*) touch "${CANDIDATE_STATE_DIR}/data1.low"; exit 42 ;;
  *"/data2/"*) touch "${CANDIDATE_STATE_DIR}/data2.low"; exit 42 ;;
  *"/data4/"*) touch "${CANDIDATE_STATE_DIR}/data4.low"; exit 42 ;;
esac

while IFS=$'\t' read -r _url _checksum target _rest; do
  [[ -n "${target}" ]] || continue
  if [[ "${target}" == *.jsonl ]]; then
    out="${directory}/ncbi_dataset/${target}"
  else
    out="${directory}/ncbi_dataset/${target}.gz"
  fi
  mkdir -p "$(dirname "${out}")"
  if [[ "${out}" == *.gz ]]; then
    printf 'gzip-placeholder\n' | gzip -c > "${out}"
  else
    printf '{}\n' > "${out}"
  fi
done < "${directory}/ncbi_dataset/fetch.txt"
EOF
chmod +x "${bin_dir}/datasets"

primary_package="${fake_data1}/${owner_dir}/refseq_genomes/contexts/${context_name}/merged_refseq_dataset/ncbi_dataset"
manifest_dir="${run_root}/manifests/${context_name}"
mkdir -p "${primary_package}" "${manifest_dir}"
printf 'ASSEMBLY_SUMMARY_FILE=%s\n' "${assembly_summary}" > "${manifest_dir}/manifest_config.txt"
printf 'GCF_000001.1\n' > "${manifest_dir}/accessions.sorted.txt"
printf 'https://example.org/genome\t0\tdata/GCF_000001.1/GCF_000001.1_genomic.fna\n' > "${primary_package}/fetch.txt"
printf 'https://example.org/report\t0\tdata/GCF_000001.1/sequence_report.jsonl\n' >> "${primary_package}/fetch.txt"

export PATH="${bin_dir}:${PATH}"
export DATASETS_ARGS_LOG="${test_root}/datasets_args.log"
export CANDIDATE_STATE_DIR="${test_root}"
run_log="${test_root}/rehydrate.log"
if ! NCBI_API_KEY='test-secret-key' bash "${script_under_test}" rehydrate > "${run_log}" 2>&1; then
  printf 'expected rehydrate to continue through ordered candidates to data5\n' >&2
  tail -n 60 "${run_log}" >&2
  exit 1
fi

expected_data_dir="${fake_data5}/${owner_dir}/refseq_genomes/contexts/${context_name}/rehydrate_refseq_dataset/ncbi_dataset/data/GCF_000001.1"
[[ -s "${expected_data_dir}/GCF_000001.1_genomic.fna.gz" ]] || {
  printf 'expected successful download on fourth ordered candidate data5: %s\n' "${expected_data_dir}" >&2
  tail -n 60 "${run_log}" >&2
  exit 1
}

grep -q "${fake_data1}.*/rehydrate_refseq_dataset" "${DATASETS_ARGS_LOG}" || {
  printf 'expected data1 to be attempted first\n' >&2
  exit 1
}
grep -q "${fake_data2}.*/rehydrate_refseq_dataset" "${DATASETS_ARGS_LOG}" || {
  printf 'expected data2 to be attempted second\n' >&2
  exit 1
}
grep -q "${fake_data4}.*/rehydrate_refseq_dataset" "${DATASETS_ARGS_LOG}" || {
  printf 'expected data4 to be attempted third\n' >&2
  exit 1
}
grep -q "${fake_data5}.*/rehydrate_refseq_dataset" "${DATASETS_ARGS_LOG}" || {
  printf 'expected data5 to be attempted fourth\n' >&2
  exit 1
}
