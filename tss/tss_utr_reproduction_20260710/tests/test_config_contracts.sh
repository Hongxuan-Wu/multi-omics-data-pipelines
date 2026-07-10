#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${PROJECT_ROOT}/../.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/pipeline.env"
SAMPLES_FILE="${PROJECT_ROOT}/config/samples.tsv"

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

[[ -f "${CONFIG_FILE}" ]] || fail "missing configuration: ${CONFIG_FILE}"
[[ -f "${SAMPLES_FILE}" ]] || fail "missing sample manifest: ${SAMPLES_FILE}"

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

grep -qx 'FASTP_POLICY_STATUS=blocked' "${CONFIG_FILE}" || fail "FASTP policy must remain blocked"
grep -qx 'FASTP_MAX_N=0' "${CONFIG_FILE}" || fail "FASTP_MAX_N must remain 0"

for ignored_dir in work logs results trash; do
    git -C "${REPO_ROOT}" check-ignore -q \
        "tss/tss_utr_reproduction_20260710/${ignored_dir}/" || \
        fail "${ignored_dir}/ must be Git ignored"
done

for tracked_file in \
    tss/resources/S1.genome.fasta \
    tss/resources/S1.genome.gff \
    tss/resources/S1.genome_new.gff3 \
    'tss/resources/tss注释流程.png'; do
    git -C "${REPO_ROOT}" ls-files --error-unmatch -- "${tracked_file}" >/dev/null || \
        fail "required reference is not Git tracked: ${tracked_file}"
done

printf '[PASS] config contracts\n'
