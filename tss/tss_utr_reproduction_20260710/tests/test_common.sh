#!/usr/bin/env bash

set -euo pipefail

SOURCE_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON_SH="${SOURCE_PROJECT_ROOT}/scripts/lib/common.sh"
TEST_ID="common_$(date -u '+%Y%m%dT%H%M%S')_$$"
TEST_ROOT="${SOURCE_PROJECT_ROOT}/work/tests/${TEST_ID}"
PROJECT_ROOT="${TEST_ROOT}/project"
CONFIG_COPY="${PROJECT_ROOT}/config/pipeline.env"

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

expect_failure() {
    local description="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        fail "expected failure: ${description}"
    fi
}

mkdir -p "${PROJECT_ROOT}/config"
{
    printf 'PROJECT_ROOT=%s\n' "${PROJECT_ROOT}"
    tail -n +2 "${SOURCE_PROJECT_ROOT}/config/pipeline.env"
} > "${CONFIG_COPY}"

CONFIG_FILE="${CONFIG_COPY}"
source "${COMMON_SH}"

RUN_ID="${TEST_ID}"
RESUME=0

if (unset RUN_ID; init_run_layout) > "${TEST_ROOT}/missing-run-id.stderr" 2>&1; then
    fail "missing RUN_ID must be rejected"
fi
rg -q 'RUN_ID 未设置' "${TEST_ROOT}/missing-run-id.stderr" || \
    fail "missing RUN_ID must report an explicit error"

expect_failure "relative conda prefix" run_conda "relative/prefix" true
expect_failure "resource output" assert_safe_output_path "${RESOURCE_ROOT}/forbidden.out"
expect_failure "tool output" assert_safe_output_path "${TOOL_ROOT}/forbidden.out"

for output_path in \
    "${PROJECT_ROOT}/work/${RUN_ID}/candidate.out" \
    "${PROJECT_ROOT}/logs/${RUN_ID}/stage.log" \
    "${PROJECT_ROOT}/results/${RUN_ID}/result.gff3" \
    "${PROJECT_ROOT}/reports/${RUN_ID}/report.tsv" \
    "${PROJECT_ROOT}/trash/${RUN_ID}/failed.out"; do
    assert_safe_output_path "${output_path}"
done

init_run_layout

for run_dir in reference fastp star stringtie pasa_align pasa_update agat validation state; do
    [[ -d "${PROJECT_ROOT}/work/${RUN_ID}/${run_dir}" ]] || fail "missing run directory: ${run_dir}"
done

rename_probe_source="${PROJECT_ROOT}/work/${RUN_ID}/renameat2-probe.source"
rename_probe_destination="${PROJECT_ROOT}/work/${RUN_ID}/renameat2-probe.destination"
printf 'renameat2 probe content\n' > "${rename_probe_source}"
rename_noreplace "${rename_probe_source}" "${rename_probe_destination}" || \
    fail "configured PASA Perl must support renameat2(RENAME_NOREPLACE)"
[[ ! -e "${rename_probe_source}" ]] || fail "renameat2 probe source still exists"
[[ "$(<"${rename_probe_destination}")" == "renameat2 probe content" ]] || \
    fail "renameat2 probe destination content changed"

eexist_source="${PROJECT_ROOT}/work/${RUN_ID}/renameat2-eexist.source"
eexist_destination="${PROJECT_ROOT}/work/${RUN_ID}/renameat2-eexist.destination"
printf 'source must survive EEXIST\n' > "${eexist_source}"
printf 'destination must survive EEXIST\n' > "${eexist_destination}"
set +e
rename_noreplace "${eexist_source}" "${eexist_destination}"
eexist_status=$?
set -e
[[ "${eexist_status}" -eq 17 ]] || \
    fail "renameat2 EEXIST must return status 17, got ${eexist_status}"
[[ "$(<"${eexist_source}")" == "source must survive EEXIST" ]] || \
    fail "renameat2 EEXIST changed the source"
[[ "$(<"${eexist_destination}")" == "destination must survive EEXIST" ]] || \
    fail "renameat2 EEXIST changed the destination"

expect_failure "report path used as a process output" \
    assert_process_output_path "${PROJECT_ROOT}/reports/${RUN_ID}/report.tsv"
assert_process_output_path "${PROJECT_ROOT}/work/${RUN_ID}/fastp/output.fastq.gz"
assert_process_output_path "${PROJECT_ROOT}/logs/${RUN_ID}/fastp.log"
assert_process_output_path "${PROJECT_ROOT}/results/${RUN_ID}/result.gff3"
assert_process_output_path "${PROJECT_ROOT}/trash/${RUN_ID}/failed.out"
assert_report_output_path "${PROJECT_ROOT}/reports/${RUN_ID}/report.tsv"
oversize_report="${PROJECT_ROOT}/reports/${RUN_ID}/too-large.tsv"
truncate -s $((10 * 1024 * 1024 + 1)) "${oversize_report}"
expect_failure "existing report larger than 10 MiB" \
    assert_report_output_path "${oversize_report}"
expect_failure "another run's process output" \
    assert_process_output_path "${PROJECT_ROOT}/work/another-run/output"
expect_failure "existing run without resume" init_run_layout

RESUME=1
init_run_layout

stage_output="${PROJECT_ROOT}/results/${RUN_ID}/stage-output.txt"
printf 'original output\n' > "${stage_output}"
mark_stage_done "stage_hashes" "${stage_output}"
stage_is_valid "stage_hashes" || fail "fresh stage marker must be valid"

printf 'tampered output\n' > "${stage_output}"
if stage_is_valid "stage_hashes"; then
    fail "tampered stage output must invalidate marker"
fi

config_stage_output="${PROJECT_ROOT}/results/${RUN_ID}/config-stage-output.txt"
printf 'stable output\n' > "${config_stage_output}"
mark_stage_done "config_hash" "${config_stage_output}"
stage_is_valid "config_hash" || fail "fresh config marker must be valid"
printf 'TEST_CONFIG_REVISION=%s\n' "${TEST_ID}" >> "${CONFIG_COPY}"
if stage_is_valid "config_hash"; then
    fail "changed configuration hash must invalidate marker"
fi
expect_failure "changed configuration hash during resume" init_run_layout

failed_output="${PROJECT_ROOT}/work/${RUN_ID}/failed.out"
printf 'failed attempt\n' > "${failed_output}"
trash_path="$(move_to_trash "${failed_output}" "validation")"
[[ ! -e "${failed_output}" ]] || fail "failed output was not moved"
[[ -f "${trash_path}" ]] || fail "failed output is missing from trash"
case "${trash_path}" in
    "${PROJECT_ROOT}/trash/${RUN_ID}/validation."*) ;;
    *) fail "trash path is outside the run-local trash directory: ${trash_path}" ;;
esac

race_timestamp="20260710T000000000000000"
race_source="${PROJECT_ROOT}/work/${RUN_ID}/race-source.out"
race_destination="${PROJECT_ROOT}/trash/${RUN_ID}/collision.${race_timestamp}.race-source.out"
race_suffixed_destination="${PROJECT_ROOT}/trash/${RUN_ID}/collision.${race_timestamp}.1.race-source.out"
printf 'source content\n' > "${race_source}"
printf 'existing destination content\n' > "${race_destination}"
date() {
    if [[ "$#" -eq 2 && "$1" == "-u" && "$2" == "+%Y%m%dT%H%M%S%N" ]]; then
        printf '%s\n' "${race_timestamp}"
    else
        command date "$@"
    fi
}
race_trash_path="$(move_to_trash "${race_source}" "collision")"
[[ "${race_trash_path}" == "${race_suffixed_destination}" ]] || \
    fail "trash collision did not use the suffixed destination"
[[ ! -e "${race_source}" ]] || fail "collision source was not moved"
[[ "$(<"${race_destination}")" == "existing destination content" ]] || \
    fail "existing trash destination was overwritten"
[[ "$(<"${race_suffixed_destination}")" == "source content" ]] || \
    fail "source content was not preserved at the suffixed destination"

partial_run_id="${TEST_ID}_partial"
mkdir -p "${PROJECT_ROOT}/work/${partial_run_id}/state"
sha256sum -- "${CONFIG_COPY}" | awk '{print $1}' > \
    "${PROJECT_ROOT}/work/${partial_run_id}/state/config.sha256"
RUN_ID="${partial_run_id}"
RESUME=1
expect_failure "incomplete run layout during resume" init_run_layout

printf '[PASS] common isolation and state contracts\n'
