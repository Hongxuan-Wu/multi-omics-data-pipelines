#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/download_file_manifest_2026_02.tsv"
MANIFEST_DOC="${SCRIPT_DIR}/download_file_manifest_2026_02.md"
GENERATOR="${SCRIPT_DIR}/generate_download_file_manifest.sh"
DOWNLOADER="${SCRIPT_DIR}/download_uniprot.sh"
OPERATIONAL_TEST="${SCRIPT_DIR}/test_operational_contract.sh"
FAKE_ARIA2="${SCRIPT_DIR}/tests/fixtures/fake_aria2c.sh"

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "${actual}" == "${expected}" ]] || \
    fail "${label}: expected=${expected} actual=${actual}"
}

assert_dataset_count() {
  local dataset="$1"
  local expected="$2"
  local actual
  actual="$(awk -F '\t' -v dataset="${dataset}" '!/^#/ && $1 != "scope" && $3 == dataset {count++} END {print count+0}' "${MANIFEST}")"
  assert_eq "${expected}" "${actual}" "dataset ${dataset} count"
}

for script in "${GENERATOR}" "${DOWNLOADER}" "${OPERATIONAL_TEST}" "${FAKE_ARIA2}" "${BASH_SOURCE[0]}"; do
  bash -n "${script}" || fail "bash syntax: ${script}"
done

for document in download_contract.md decisions.md runbook.md implementation_plan.md; do
  [[ -s "${SCRIPT_DIR}/${document}" ]] || fail "missing UniProt operational document: ${document}"
done

row_count="$(awk -F '\t' '!/^#/ && $1 != "scope" {count++} END {print count+0}' "${MANIFEST}")"
assert_eq 25 "${row_count}" "manifest row count"
byte_sum="$(awk -F '\t' '!/^#/ && $1 != "scope" {bytes += $7} END {printf "%.0f", bytes+0}' "${MANIFEST}")"
assert_eq 618535806550 "${byte_sum}" "manifest byte sum"

invalid_rows="$(awk -F '\t' '!/^#/ && $1 != "scope" && (NF != 10 || $1 != "required" || $4 != "2026_02" || $5 !~ /^https:\/\/ftp\.uniprot\.org\// || $6 ~ /^\// || $7 !~ /^[0-9]+$/ || ($9 == "static_file" && $8 !~ /^[0-9a-f]{32}$/)) {print NR}' "${MANIFEST}")"
[[ -z "${invalid_rows}" ]] || fail "invalid manifest rows: ${invalid_rows}"

duplicate_paths="$(awk -F '\t' '!/^#/ && $1 != "scope" {count[$6]++} END {for (path in count) if (count[path] > 1) print path}' "${MANIFEST}")"
[[ -z "${duplicate_paths}" ]] || fail "duplicate manifest paths: ${duplicate_paths}"

expected_paths="$(LC_ALL=C sort <<'EOF'
knowledgebase/complete/README
knowledgebase/complete/RELEASE.metalink
knowledgebase/complete/docs/RELEASE.metalink
knowledgebase/complete/docs/sec_ac.txt
knowledgebase/complete/uniprot_sprot.dat.gz
knowledgebase/complete/uniprot_sprot.fasta.gz
knowledgebase/complete/uniprot_sprot_varsplic.fasta.gz
knowledgebase/complete/uniprot_trembl.dat.gz
knowledgebase/complete/uniprot_trembl.fasta.gz
knowledgebase/idmapping/README
knowledgebase/idmapping/RELEASE.metalink
knowledgebase/idmapping/idmapping.dat.gz
knowledgebase/reference_proteomes/README
knowledgebase/reference_proteomes/RELEASE.metalink
knowledgebase/reference_proteomes/Reference_Proteomes_2026_02.tar.gz
knowledgebase/reference_proteomes/STATS
uniref/uniref100/README
uniref/uniref100/RELEASE.metalink
uniref/uniref100/uniref100.fasta.gz
uniref/uniref50/README
uniref/uniref50/RELEASE.metalink
uniref/uniref50/uniref50.fasta.gz
uniref/uniref90/README
uniref/uniref90/RELEASE.metalink
uniref/uniref90/uniref90.fasta.gz
EOF
)"
actual_paths="$(awk -F '\t' '!/^#/ && $1 != "scope" {print $6}' "${MANIFEST}" | LC_ALL=C sort)"
[[ "${actual_paths}" == "${expected_paths}" ]] || fail "manifest path set differs from the approved 25-file contract"
documented_paths="$(awk '
  /^[0-9]+\. `[^`]+\/[^`]+`$/ {
    line=$0
    sub(/^[0-9]+\. `/, "", line)
    sub(/`$/, "", line)
    print line
  }
' "${MANIFEST_DOC}" | LC_ALL=C sort)"
[[ "${documented_paths}" == "${expected_paths}" ]] || fail "Markdown checklist differs from the TSV path contract"

assert_dataset_count uniprotkb_complete 7
assert_dataset_count uniprotkb_accessions 2
assert_dataset_count uniref50 3
assert_dataset_count uniref90 3
assert_dataset_count uniref100 3
assert_dataset_count idmapping 3
assert_dataset_count reference_proteomes 4

reference_md5="$(awk -F '\t' '$6 == "knowledgebase/reference_proteomes/Reference_Proteomes_2026_02.tar.gz" {print $8}' "${MANIFEST}")"
assert_eq dac5c26eaf65eb2c5e9615f8faf2c9d7 "${reference_md5}" "Reference Proteomes MD5"

secondary_md5="$(awk -F '\t' '$6 == "knowledgebase/complete/docs/sec_ac.txt" {print $8}' "${MANIFEST}")"
assert_eq 36985d8756a672823f60f1b81acece9a "${secondary_md5}" "sec_ac.txt MD5"

if rg -n -i 'GOA_BASE|emit_goa|uniparc|pan_proteomes|proteomes_rest|semantic_rdf|genome_annotation_tracks|proteomics_mapping|variants' "${GENERATOR}" >/dev/null; then
  fail "manifest generator still references excluded datasets"
fi

grep -Fq 'DOWNLOAD_DATASETS="${DOWNLOAD_DATASETS:-uniref50}"' "${DOWNLOADER}" || \
  fail "downloader default is not UniRef50"
grep -Fq -- '--dataset' "${DOWNLOADER}" || fail "downloader lacks --dataset"
grep -Fq -- '--all' "${DOWNLOADER}" || fail "downloader lacks --all"
grep -Fq -- '--plan-only' "${DOWNLOADER}" || fail "downloader lacks --plan-only"
grep -Fq 'download_file_manifest_${RELEASE}.tsv' "${DOWNLOADER}" || \
  fail "downloader does not consume the versioned static manifest"
for function_name in \
  validate_safe_roots init_runtime_state write_state write_progress_snapshot \
  write_summary_report acquire_run_lock classify_transfer_failure run_aria2_attempt \
  build_repair_plan verify_selected_files run_download_with_recovery; do
  grep -Eq "^${function_name}\\(\\)" "${DOWNLOADER}" || fail "downloader lacks ${function_name}"
done
for option in verify-only status summary download-attempts retry-wait progress-interval lock-wait; do
  grep -Fq -- "--${option}" "${DOWNLOADER}" || fail "downloader lacks --${option}"
done
if grep -Eq '(^|[[:space:]])rm([[:space:]]|$)' "${DOWNLOADER}" "${OPERATIONAL_TEST}" "${FAKE_ARIA2}"; then
  fail "UniProt operational scripts contain a destructive rm command"
fi

test_root="$(mktemp -d /tmp/uniprot_manifest_contract.XXXXXX)"
"${DOWNLOADER}" --dataset uniprotkb --plan-only \
  --local-root "${test_root}/data" --run-root "${test_root}/run" \
  > "${test_root}/plan.stdout" 2> "${test_root}/plan.stderr"
shopt -s nullglob
plan_files=("${test_root}/run/plans"/download_plan_*.tsv)
shopt -u nullglob
assert_eq 1 "${#plan_files[@]}" "plan file count"

plan_rows="$(awk -F '\t' '!/^#/ && $1 != "dataset" {count++} END {print count+0}' "${plan_files[0]}")"
assert_eq 9 "${plan_rows}" "uniprotkb preset plan row count"
invalid_plan_rows="$(awk -F '\t' '
  !/^#/ && $1 != "dataset" {
    invalid = NF != 8 || $7 !~ /^(static_file|release_manifest)$/ ||
      ($7 == "static_file" && $6 !~ /^[0-9a-f]{32}$/) ||
      ($7 == "release_manifest" && $6 != "")
    if (invalid) print NR
  }
' "${plan_files[0]}")"
[[ -z "${invalid_plan_rows}" ]] || fail "plan field alignment is invalid: ${invalid_plan_rows}"

"${DOWNLOADER}" --plan-only \
  --local-root "${test_root}/default-data" --run-root "${test_root}/default-run" \
  > "${test_root}/default.stdout" 2> "${test_root}/default.stderr"
default_plans=("${test_root}/default-run/plans"/download_plan_*.tsv)
assert_eq 1 "${#default_plans[@]}" "default plan file count"
default_rows="$(awk -F '\t' '!/^#/ && $1 != "dataset" {count++} END {print count+0}' "${default_plans[0]}")"
default_datasets="$(awk -F '\t' '!/^#/ && $1 != "dataset" {print $1}' "${default_plans[0]}" | LC_ALL=C sort -u)"
assert_eq 3 "${default_rows}" "default plan row count"
assert_eq uniref50 "${default_datasets}" "default plan dataset"

"${DOWNLOADER}" --all --plan-only \
  --local-root "${test_root}/all-data" --run-root "${test_root}/all-run" \
  > "${test_root}/all.stdout" 2> "${test_root}/all.stderr"
all_plans=("${test_root}/all-run/plans"/download_plan_*.tsv)
assert_eq 1 "${#all_plans[@]}" "all plan file count"
all_rows="$(awk -F '\t' '!/^#/ && $1 != "dataset" {count++} END {print count+0}' "${all_plans[0]}")"
all_bytes="$(awk -F '\t' '!/^#/ && $1 != "dataset" {bytes += $5} END {printf "%.0f", bytes+0}' "${all_plans[0]}")"
assert_eq 25 "${all_rows}" "all plan row count"
assert_eq 618535806550 "${all_bytes}" "all plan byte sum"

"${DOWNLOADER}" --dataset swissprot --plan-only \
  --local-root "${test_root}/swissprot-data" --run-root "${test_root}/swissprot-run" \
  > "${test_root}/swissprot.stdout" 2> "${test_root}/swissprot.stderr"
swissprot_plans=("${test_root}/swissprot-run/plans"/download_plan_*.tsv)
assert_eq 1 "${#swissprot_plans[@]}" "Swiss-Prot plan file count"
swissprot_rows="$(awk -F '\t' '!/^#/ && $1 != "dataset" {count++} END {print count+0}' "${swissprot_plans[0]}")"
swissprot_trembl_rows="$(awk -F '\t' '$2 ~ /uniprot_trembl/ {count++} END {print count+0}' "${swissprot_plans[0]}")"
assert_eq 5 "${swissprot_rows}" "Swiss-Prot plan row count"
assert_eq 0 "${swissprot_trembl_rows}" "Swiss-Prot plan TrEMBL leakage"

"${DOWNLOADER}" --dataset trembl --plan-only \
  --local-root "${test_root}/trembl-data" --run-root "${test_root}/trembl-run" \
  > "${test_root}/trembl.stdout" 2> "${test_root}/trembl.stderr"
trembl_plans=("${test_root}/trembl-run/plans"/download_plan_*.tsv)
assert_eq 1 "${#trembl_plans[@]}" "TrEMBL plan file count"
trembl_rows="$(awk -F '\t' '!/^#/ && $1 != "dataset" {count++} END {print count+0}' "${trembl_plans[0]}")"
trembl_swissprot_rows="$(awk -F '\t' '$2 ~ /uniprot_sprot/ {count++} END {print count+0}' "${trembl_plans[0]}")"
assert_eq 4 "${trembl_rows}" "TrEMBL plan row count"
assert_eq 0 "${trembl_swissprot_rows}" "TrEMBL plan Swiss-Prot leakage"

"${DOWNLOADER}" --dataset multiomics --plan-only \
  --local-root "${test_root}/multiomics-data" --run-root "${test_root}/multiomics-run" \
  > "${test_root}/multiomics.stdout" 2> "${test_root}/multiomics.stderr"
multiomics_plans=("${test_root}/multiomics-run/plans"/download_plan_*.tsv)
assert_eq 1 "${#multiomics_plans[@]}" "multiomics plan file count"
multiomics_rows="$(awk -F '\t' '!/^#/ && $1 != "dataset" {count++} END {print count+0}' "${multiomics_plans[0]}")"
multiomics_sec_ac="$(awk -F '\t' '$2 == "knowledgebase/complete/docs/sec_ac.txt" {count++} END {print count+0}' "${multiomics_plans[0]}")"
assert_eq 9 "${multiomics_rows}" "multiomics plan row count"
assert_eq 1 "${multiomics_sec_ac}" "multiomics sec_ac inclusion"

tampered_manifest="${test_root}/tampered_manifest.tsv"
awk -F '\t' '
  BEGIN {OFS=FS}
  FNR == NR {
    if ($6 == "knowledgebase/complete/README") {
      readme_url=$5
      readme_bytes=$7
      readme_md5=$8
    } else if ($6 == "knowledgebase/complete/docs/sec_ac.txt") {
      sec_ac_url=$5
      sec_ac_bytes=$7
      sec_ac_md5=$8
    }
    next
  }
  {
    if ($6 == "knowledgebase/complete/README") {
      $5=sec_ac_url
      $7=sec_ac_bytes
      $8=sec_ac_md5
    } else if ($6 == "knowledgebase/complete/docs/sec_ac.txt") {
      $5=readme_url
      $7=readme_bytes
      $8=readme_md5
    }
    print
  }
' "${MANIFEST}" "${MANIFEST}" > "${tampered_manifest}"

set +e
"${DOWNLOADER}" --manifest "${tampered_manifest}" --plan-only \
  --local-root "${test_root}/tampered-data" --run-root "${test_root}/tampered-run" \
  > "${test_root}/tampered.stdout" 2> "${test_root}/tampered.stderr"
tampered_status=$?
set -e
assert_eq 30 "${tampered_status}" "tampered manifest blocked exit status"

set +e
CHECK_REMOTE_RELEASE=0 "${DOWNLOADER}" --plan-only \
  --local-root "${test_root}/disabled-release-data" --run-root "${test_root}/disabled-release-run" \
  > "${test_root}/disabled-release.stdout" 2> "${test_root}/disabled-release.stderr"
disabled_release_status=$?
VERIFY_AFTER_DOWNLOAD=0 "${DOWNLOADER}" --plan-only \
  --local-root "${test_root}/disabled-verify-data" --run-root "${test_root}/disabled-verify-run" \
  > "${test_root}/disabled-verify.stdout" 2> "${test_root}/disabled-verify.stderr"
disabled_verify_status=$?
set -e
assert_eq 30 "${disabled_release_status}" "disabled remote release check blocked exit status"
assert_eq 30 "${disabled_verify_status}" "disabled post-download verification blocked exit status"

set +e
"${DOWNLOADER}" --all --dataset uniref50 --plan-only \
  > "${test_root}/invalid.stdout" 2> "${test_root}/invalid.stderr"
invalid_status=$?
set -e
assert_eq 2 "${invalid_status}" "conflicting selector exit status"

failure_root="${test_root}/aria-failure"
failure_file="${failure_root}/data/bad.metalink"
failure_plan="${failure_root}/failed-plan.tsv"
mkdir -p "$(dirname "${failure_file}")"
printf 'bad' > "${failure_file}"
{
  printf 'dataset\trelative_path\turl\tlocal_file\tbytes\tmd5\tsource_kind\tnotes\n'
  printf 'uniref50\ttest/bad.metalink\thttps://ftp.uniprot.org/pub/databases/uniprot/current_release/test/bad.metalink\t%s\t10\t\trelease_manifest\texpected_version=2026_02\n' "${failure_file}"
} > "${failure_plan}"

set +e
(
  export PLAN_ONLY=1
  export LOCAL_ROOT="${failure_root}/data"
  export RUN_ROOT="${failure_root}/run"
  source "${DOWNLOADER}"
  RUN_ID="unit"
  LOG_DIR="${RUN_ROOT}/logs"
  PLAN_DIR="${RUN_ROOT}/plans"
  MANIFEST_DIR="${RUN_ROOT}/manifests"
  TMP_DIR="${RUN_ROOT}/tmp/unit"
  TRASH_DIR="${RUN_ROOT}/trash"
  DL_LOG="${LOG_DIR}/unit.log"
  ERR_LOG="${LOG_DIR}/unit.err.log"
  PLAN_FILE="${failure_plan}"
  common_init_dirs
  quarantine_invalid_completed_files
) > "${failure_root}/unit.stdout" 2> "${failure_root}/unit.stderr"
quarantine_status=$?
set -e
assert_eq 0 "${quarantine_status}" "aria failure quarantine helper status"
[[ ! -e "${failure_file}" ]] || fail "invalid completed file was not moved to trash"
shopt -s nullglob
trash_files=("${failure_root}/run/trash"/*)
shopt -u nullglob
assert_eq 1 "${#trash_files[@]}" "aria failure trash file count"

printf '[PASS] UniProt 2026_02 manifest and downloader contract\n'
