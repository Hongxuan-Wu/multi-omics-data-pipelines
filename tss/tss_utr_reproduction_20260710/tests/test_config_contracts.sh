#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${PROJECT_ROOT}/../.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${PROJECT_ROOT}/config/pipeline.env}"
SAMPLES_FILE="${SAMPLES_FILE:-${PROJECT_ROOT}/config/samples.tsv}"

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

[[ -f "${CONFIG_FILE}" ]] || fail "missing configuration: ${CONFIG_FILE}"
[[ -f "${SAMPLES_FILE}" ]] || fail "missing sample manifest: ${SAMPLES_FILE}"

expected_config="$(cat <<'EOF'
PROJECT_ROOT=/data/p252701008/projects/multi-omics-data-pipelines/tss/tss_utr_reproduction_20260710
TSS_ROOT=/data/p252701008/projects/multi-omics-data-pipelines/tss
RESOURCE_ROOT=/data/p252701008/projects/multi-omics-data-pipelines/tss/resources
RAW_ROOT=/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001
TOOL_ROOT=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools
CONDA_EXE=/opt/miniconda3/bin/conda
REFERENCE_FASTA=/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/S1.genome.fasta
REFERENCE_GFF=/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/S1.genome.gff
COMPANY_GFF=/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/S1.genome_new.gff3
FLOW_IMAGE=/data/p252701008/projects/multi-omics-data-pipelines/tss/tss注释流程.png
FASTP_PREFIX=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/fastp/env
STAR_PREFIX=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/STAR/env
STRINGTIE_PREFIX=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/stringtie/env
PASA_PREFIX=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/pasa/env
AGAT_PREFIX=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/agat/env
PASA_HOME=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/pasa/env/opt/pasa-2.5.2
FASTP_POLICY_STATUS=blocked
FASTP_MAX_N=0
FASTP_QUAL=20
FASTP_MIN_PASS_FRACTION=0.50
SMOKE_READ_PAIRS=50000
STAR_GENOME_SA_INDEX_NBASES=11
PASA_MAX_INTRON_LENGTH=500000
PASA_TOP_ALIGNMENTS=1
DEFAULT_THREADS=32
SAMPLE_PARALLELISM=1
MIN_FREE_GB=300
EOF
)"

if ! diff -u <(printf '%s\n' "${expected_config}") "${CONFIG_FILE}"; then
    fail "pipeline.env must exactly match the approved configuration contract"
fi

expected_samples="$(
    printf 'sample_id\tr1\tr2\tr1_md5\tr2_md5\n'
    for sample_number in {1..9}; do
        sample_name="WH25005593-BY20250509-3-S${sample_number}-BY2105"
        sample_dir="/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_${sample_name}"
        printf 'S%s\t%s/%s_combined_R1.fastq.gz\t%s/%s_combined_R2.fastq.gz\t%s/%s_combined_R1.fastq.gz.md5\t%s/%s_combined_R2.fastq.gz.md5\n' \
            "${sample_number}" \
            "${sample_dir}" "${sample_name}" \
            "${sample_dir}" "${sample_name}" \
            "${sample_dir}" "${sample_name}" \
            "${sample_dir}" "${sample_name}"
    done
)"

if ! diff -u <(printf '%s\n' "${expected_samples}") "${SAMPLES_FILE}"; then
    fail "samples.tsv must exactly match the approved S1-S9 R1/R2/MD5 mapping"
fi

expected_header=$'sample_id\tr1\tr2\tr1_md5\tr2_md5'
IFS= read -r actual_header < "${SAMPLES_FILE}"
[[ "${actual_header}" == "${expected_header}" ]] || fail "unexpected sample manifest header"

sample_count="$(awk 'NR > 1 { count++ } END { print count + 0 }' "${SAMPLES_FILE}")"
[[ "${sample_count}" == "9" ]] || fail "expected 9 samples, found ${sample_count}"

mapfile -t sample_ids < <(awk -F '\t' 'NR > 1 { print $1 }' "${SAMPLES_FILE}")
[[ "${#sample_ids[@]}" == "9" ]] || fail "expected 9 sample IDs"

for index in "${!sample_ids[@]}"; do
    expected_id="S$((index + 1))"
    [[ "${sample_ids[${index}]}" == "${expected_id}" ]] || fail "expected ${expected_id} at row $((index + 2))"
done

unique_id_count="$(printf '%s\n' "${sample_ids[@]}" | sort -u | wc -l | tr -d ' ')"
[[ "${unique_id_count}" == "9" ]] || fail "sample IDs must be unique"

while IFS=$'\t' read -r sample_id r1 r2 r1_md5 r2_md5 extra; do
    [[ -z "${extra}" ]] || fail "${sample_id} has more than five columns"
    [[ -n "${r1_md5}" && -n "${r2_md5}" ]] || fail "${sample_id} has fewer than five columns"

    for input_path in "${r1}" "${r2}" "${r1_md5}" "${r2_md5}"; do
        [[ -f "${input_path}" ]] || fail "${sample_id} input is missing: ${input_path}"
    done
done < <(tail -n +2 "${SAMPLES_FILE}")

for ignored_dir in work logs results trash; do
    git -C "${REPO_ROOT}" check-ignore -q \
        "tss/tss_utr_reproduction_20260710/${ignored_dir}/" || \
        fail "${ignored_dir}/ must be Git ignored"
done

for tracked_file in \
    tss/resources/S1.genome.fasta \
    tss/resources/S1.genome.gff \
    tss/resources/S1.genome_new.gff3 \
    'tss/tss注释流程.png'; do
    git -C "${REPO_ROOT}" ls-files --error-unmatch -- "${tracked_file}" >/dev/null || \
        fail "required reference is not Git tracked: ${tracked_file}"
done

printf '[PASS] config contracts\n'
