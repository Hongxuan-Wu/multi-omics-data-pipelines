#!/usr/bin/env bash

set -euo pipefail

SOURCE_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT_SH="${SOURCE_PROJECT_ROOT}/scripts/preflight.sh"
SNAPSHOT_SH="${SOURCE_PROJECT_ROOT}/scripts/snapshot_inputs.sh"
PAIR_CHECKER="${SOURCE_PROJECT_ROOT}/scripts/check_fastq_pairs.pl"
REAL_PASA_PERL="/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/pasa/env/bin/perl"
TEST_ID="${TEST_ID:-preflight_$(date -u '+%Y%m%dT%H%M%S')_$$}"
TEST_ROOT="${SOURCE_PROJECT_ROOT}/work/tests/${TEST_ID}"
PROJECT_ROOT="${TEST_ROOT}/project"
EVIDENCE_ROOT="${PROJECT_ROOT}/work/test-evidence"
FIXTURE_ROOT="${PROJECT_ROOT}/resources"
RAW_ROOT="${FIXTURE_ROOT}/raw"
TOOLS_ROOT="${PROJECT_ROOT}/tools"
SAMPLES_FILE="${PROJECT_ROOT}/config/samples.tsv"

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

assert_file() {
    [[ -f "$1" ]] || fail "missing file: $1"
}

assert_no_marker() {
    local run_id="$1"
    [[ ! -e "${PROJECT_ROOT}/work/${run_id}/state/preflight.done" ]] || \
        fail "failed preflight created preflight.done: ${run_id}"
}

write_fastq_pair() {
    local sample="$1"
    local r1="$2"
    local r2="$3"

    printf '@%s.read1/1 comment\nACGT\n+\n!!!!\n@%s.read2 1:N:0:1\nACGTAC\n+\n!!!!!!\n' \
        "${sample}" "${sample}" | gzip -c > "${r1}"
    printf '@%s.read1/2 comment\nTGCA\n+\n####\n@%s.read2 2:N:0:1\nTGCATG\n+\n######\n' \
        "${sample}" "${sample}" | gzip -c > "${r2}"
}

write_md5_file() {
    local data_file="$1"
    local md5_file="$2"

    (
        cd "$(dirname "${data_file}")"
        md5sum -- "$(basename "${data_file}")" > "${md5_file}"
    )
}

write_config() {
    local destination="$1"
    local policy="$2"
    local min_free_gb="${3:-1}"

    {
        printf 'PROJECT_ROOT=%s\n' "${PROJECT_ROOT}"
        printf 'TSS_ROOT=%s\n' "${PROJECT_ROOT}"
        printf 'RESOURCE_ROOT=%s\n' "${FIXTURE_ROOT}"
        printf 'RAW_ROOT=%s\n' "${RAW_ROOT}"
        printf 'TOOL_ROOT=%s\n' "${TOOLS_ROOT}"
        printf 'CONDA_EXE=%s\n' "${TOOLS_ROOT}/conda"
        printf 'REFERENCE_FASTA=%s\n' "${FIXTURE_ROOT}/reference.fa"
        printf 'REFERENCE_GFF=%s\n' "${FIXTURE_ROOT}/reference.gff3"
        printf 'COMPANY_GFF=%s\n' "${FIXTURE_ROOT}/company.gff3"
        printf 'FLOW_IMAGE=%s\n' "${FIXTURE_ROOT}/flow.png"
        printf 'FASTP_PREFIX=%s\n' "${TOOLS_ROOT}/fastp"
        printf 'STAR_PREFIX=%s\n' "${TOOLS_ROOT}/star"
        printf 'STRINGTIE_PREFIX=%s\n' "${TOOLS_ROOT}/stringtie"
        printf 'PASA_PREFIX=%s\n' "${TOOLS_ROOT}/pasa"
        printf 'AGAT_PREFIX=%s\n' "${TOOLS_ROOT}/agat"
        printf 'PASA_HOME=%s\n' "${TOOLS_ROOT}/pasa/opt/pasa-2.5.2"
        printf 'FASTP_POLICY_STATUS=%s\n' "${policy}"
        printf 'FASTP_MAX_N=0\n'
        printf 'FASTP_QUAL=20\n'
        printf 'FASTP_MIN_PASS_FRACTION=0.50\n'
        printf 'SMOKE_READ_PAIRS=50000\n'
        printf 'STAR_GENOME_SA_INDEX_NBASES=11\n'
        printf 'PASA_MAX_INTRON_LENGTH=500000\n'
        printf 'PASA_TOP_ALIGNMENTS=1\n'
        printf 'DEFAULT_THREADS=32\n'
        printf 'SAMPLE_PARALLELISM=1\n'
        printf 'MIN_FREE_GB=%s\n' "${min_free_gb}"
    } > "${destination}"
}

run_preflight_case() {
    local run_id="$1"
    local config_file="$2"
    local samples_file="$3"
    local expected_status="$4"
    shift 4
    local stdout_file="${EVIDENCE_ROOT}/${run_id}.stdout"
    local stderr_file="${EVIDENCE_ROOT}/${run_id}.stderr"
    local status

    set +e
    env \
        CONFIG_FILE="${config_file}" \
        SAMPLES_FILE="${samples_file}" \
        PATH="${TOOLS_ROOT}/test-bin:${PATH}" \
        "$@" \
        bash "${PREFLIGHT_SH}" --run-id "${run_id}" --mode full \
        > "${stdout_file}" 2> "${stderr_file}"
    status=$?
    set -e

    [[ "${status}" -eq "${expected_status}" ]] || \
        fail "${run_id}: expected status ${expected_status}, got ${status}; see ${stderr_file}"
}

expect_pair_failure() {
    local description="$1"
    local sample="$2"
    local r1="$3"
    local r2="$4"
    local expected_pattern="$5"
    local stderr_file="${EVIDENCE_ROOT}/pair-${description}.stderr"

    if "${REAL_PASA_PERL}" "${PAIR_CHECKER}" \
        --sample "${sample}" --r1 "${r1}" --r2 "${r2}" \
        > "${EVIDENCE_ROOT}/pair-${description}.stdout" 2> "${stderr_file}"; then
        fail "pair checker accepted ${description} fixture"
    fi
    rg -q "${expected_pattern}" "${stderr_file}" || \
        fail "pair checker ${description} error lacks '${expected_pattern}'"
}

mkdir -p \
    "${PROJECT_ROOT}/config" \
    "${EVIDENCE_ROOT}" \
    "${RAW_ROOT}" \
    "${TOOLS_ROOT}/test-bin" \
    "${TOOLS_ROOT}/fastp/bin" \
    "${TOOLS_ROOT}/star/bin" \
    "${TOOLS_ROOT}/stringtie/bin" \
    "${TOOLS_ROOT}/pasa/bin" \
    "${TOOLS_ROOT}/pasa/opt/pasa-2.5.2" \
    "${TOOLS_ROOT}/agat/bin"

printf '>ctg1\nACGTACGTACGT\n' > "${FIXTURE_ROOT}/reference.fa"
printf '##gff-version 3\nctg1\ttest\tgene\t1\t12\t.\t+\t.\tID=gene1\nctg1\ttest\tmRNA\t1\t12\t.\t+\t.\tID=tx1;Parent=gene1\nctg1\ttest\texon\t1\t12\t.\t+\t.\tID=exon1;Parent=tx1\n' \
    > "${FIXTURE_ROOT}/reference.gff3"
printf '##gff-version 3\n' > "${FIXTURE_ROOT}/company.gff3"
printf 'fixture image bytes\n' > "${FIXTURE_ROOT}/flow.png"

printf 'sample_id\tr1\tr2\tr1_md5\tr2_md5\n' > "${SAMPLES_FILE}"
for sample_number in {1..9}; do
    sample="S${sample_number}"
    sample_dir="${RAW_ROOT}/${sample}"
    r1="${sample_dir}/${sample}_R1.fastq.gz"
    r2="${sample_dir}/${sample}_R2.fastq.gz"
    mkdir -p "${sample_dir}"
    write_fastq_pair "${sample}" "${r1}" "${r2}"
    write_md5_file "${r1}" "${r1}.md5"
    write_md5_file "${r2}" "${r2}.md5"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "${sample}" "${r1}" "${r2}" "${r1}.md5" "${r2}.md5" >> "${SAMPLES_FILE}"
done

cat > "${TOOLS_ROOT}/conda" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$1" == "run" ]]; then
    shift
    [[ "\$1" == "--no-capture-output" ]]
    shift
    [[ "\$1" == "-p" ]]
    prefix="\$2"
    shift 2
    export PATH="\${prefix}/bin:/usr/bin:/bin"
    if [[ "\$1" == "perl" ]]; then
        shift
        exec "${REAL_PASA_PERL}" "\$@"
    fi
    exec "\$@"
fi
if [[ "\$1" == "list" ]]; then
    cat <<'JSON'
[{"name":"gmap","version":"2025.07.31"},{"name":"ucsc-blat","version":"482"},{"name":"samtools","version":"1.23.1"},{"name":"sqlite","version":"3.53.3"}]
JSON
    exit 0
fi
exit 97
EOF
chmod +x "${TOOLS_ROOT}/conda"

cat > "${TOOLS_ROOT}/fastp/bin/fastp" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_FASTP_VERSION_MISMATCH:-0}" == "1" ]]; then
    printf 'fastp 9.9.9\n'
else
    printf 'fastp 0.23.1\n'
fi
EOF
cat > "${TOOLS_ROOT}/star/bin/STAR" <<'EOF'
#!/usr/bin/env bash
printf '2.7.9a\n'
EOF
cat > "${TOOLS_ROOT}/stringtie/bin/stringtie" <<'EOF'
#!/usr/bin/env bash
printf '2.2.0\n'
EOF
cat > "${TOOLS_ROOT}/pasa/opt/pasa-2.5.2/Launch_PASA_pipeline.pl" <<EOF
#!${REAL_PASA_PERL}
print "PASA version: 2.5.2\\n";
EOF
cat > "${TOOLS_ROOT}/agat/bin/agat_sp_keep_longest_isoform.pl" <<'EOF'
#!/usr/bin/env bash
printf 'Another GFF Analysis Toolkit (AGAT) - Version: v0.8.0\n'
EOF
cat > "${TOOLS_ROOT}/agat/bin/agat_sp_statistics.pl" <<'EOF'
#!/usr/bin/env bash
printf 'Number of genes 10370\n'
printf 'fixture AGAT diagnostic\n' >&2
EOF
for tool in gmap blat samtools sqlite3; do
    cat > "${TOOLS_ROOT}/pasa/bin/${tool}" <<EOF
#!/usr/bin/env bash
printf '${tool} fixture\\n'
EOF
done
chmod +x \
    "${TOOLS_ROOT}/fastp/bin/fastp" \
    "${TOOLS_ROOT}/star/bin/STAR" \
    "${TOOLS_ROOT}/stringtie/bin/stringtie" \
    "${TOOLS_ROOT}/pasa/opt/pasa-2.5.2/Launch_PASA_pipeline.pl" \
    "${TOOLS_ROOT}/agat/bin/agat_sp_keep_longest_isoform.pl" \
    "${TOOLS_ROOT}/agat/bin/agat_sp_statistics.pl" \
    "${TOOLS_ROOT}/pasa/bin/gmap" \
    "${TOOLS_ROOT}/pasa/bin/blat" \
    "${TOOLS_ROOT}/pasa/bin/samtools" \
    "${TOOLS_ROOT}/pasa/bin/sqlite3"

cat > "${TOOLS_ROOT}/test-bin/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
if [[ "${FAKE_LOW_DISK:-0}" == "1" ]]; then
    printf 'fixture 1000000 999999 1 100%% /fixture\n'
else
    printf 'fixture 2147483648 1 2147483647 1%% /fixture\n'
fi
EOF
cat > "${TOOLS_ROOT}/test-bin/cp" <<'EOF'
#!/usr/bin/env bash
/bin/cp "$@"
destination="${!#}"
if [[ "${FAKE_COPY_CORRUPTION:-0}" == "1" && "${destination}" == *.fa ]]; then
    printf 'corruption\n' >> "${destination}"
fi
EOF
chmod +x "${TOOLS_ROOT}/test-bin/df" "${TOOLS_ROOT}/test-bin/cp"

write_config "${PROJECT_ROOT}/config/approved.env" approved
write_config "${PROJECT_ROOT}/config/blocked.env" blocked

# The standalone checker must consume every gzip record and report exact inventory.
valid_row="$(${REAL_PASA_PERL} "${PAIR_CHECKER}" \
    --sample S1 \
    --r1 "${RAW_ROOT}/S1/S1_R1.fastq.gz" \
    --r2 "${RAW_ROOT}/S1/S1_R2.fastq.gz")"
[[ "${valid_row}" == $'S1\t2\t4\t6\t4\t6' ]] || \
    fail "unexpected pair inventory: ${valid_row}"

PAIR_FIXTURES="${FIXTURE_ROOT}/pair-fixtures"
mkdir -p "${PAIR_FIXTURES}"
printf '@ok/1\nACGT\n+\n!!!!\n@left/1\nACGT\n+\n!!!!\n' | gzip -c > "${PAIR_FIXTURES}/name-r1.gz"
printf '@ok/2\nTGCA\n+\n####\n@right/2\nTGCA\n+\n####\n' | gzip -c > "${PAIR_FIXTURES}/name-r2.gz"
expect_pair_failure name-mismatch fixture \
    "${PAIR_FIXTURES}/name-r1.gz" "${PAIR_FIXTURES}/name-r2.gz" 'record 2'

printf '@bad/1\nACGT\n+\n!!!\n' | gzip -c > "${PAIR_FIXTURES}/length-r1.gz"
printf '@bad/2\nTGCA\n+\n####\n' | gzip -c > "${PAIR_FIXTURES}/length-r2.gz"
expect_pair_failure length-mismatch fixture \
    "${PAIR_FIXTURES}/length-r1.gz" "${PAIR_FIXTURES}/length-r2.gz" 'record 1'

printf '@truncated/1\nACGT\n+\n' | gzip -c > "${PAIR_FIXTURES}/truncated-r1.gz"
printf '@truncated/2\nTGCA\n+\n####\n' | gzip -c > "${PAIR_FIXTURES}/truncated-r2.gz"
expect_pair_failure truncated fixture \
    "${PAIR_FIXTURES}/truncated-r1.gz" "${PAIR_FIXTURES}/truncated-r2.gz" 'record 1'

printf '@one/1\nACGT\n+\n!!!!\n' | gzip -c > "${PAIR_FIXTURES}/count-r1.gz"
printf '@one/2\nTGCA\n+\n####\n@two/2\nTGCA\n+\n####\n' | gzip -c > "${PAIR_FIXTURES}/count-r2.gz"
expect_pair_failure unequal-count fixture \
    "${PAIR_FIXTURES}/count-r1.gz" "${PAIR_FIXTURES}/count-r2.gz" 'record 2'

# blocked must win over nonexistent FASTQ/MD5 paths and tool invocation.
MISSING_SAMPLES="${PROJECT_ROOT}/config/missing-all-samples.tsv"
printf 'sample_id\tr1\tr2\tr1_md5\tr2_md5\nS1\t/no/53gb-r1.gz\t/no/53gb-r2.gz\t/no/r1.md5\t/no/r2.md5\n' \
    > "${MISSING_SAMPLES}"
run_preflight_case blocked-policy "${PROJECT_ROOT}/config/blocked.env" \
    "${MISSING_SAMPLES}" 42
rg -q 'fastp policy is blocked' "${EVIDENCE_ROOT}/blocked-policy.stderr" || \
    fail "blocked policy error is not explicit"
for run_root in \
    "${PROJECT_ROOT}/work/blocked-policy" \
    "${PROJECT_ROOT}/logs/blocked-policy" \
    "${PROJECT_ROOT}/results/blocked-policy" \
    "${PROJECT_ROOT}/reports/blocked-policy" \
    "${PROJECT_ROOT}/trash/blocked-policy"; do
    [[ ! -e "${run_root}" ]] || \
        fail "blocked policy performed pre-gate initialization: ${run_root}"
done
assert_no_marker blocked-policy

# Remaining failures run with approved policy and must fail closed.
MISSING_FASTQ_SAMPLES="${PROJECT_ROOT}/config/missing-fastq-samples.tsv"
awk -F '\t' -v OFS='\t' 'NR == 2 {$2 = "/missing/S1_R1.fastq.gz"} {print}' \
    "${SAMPLES_FILE}" > "${MISSING_FASTQ_SAMPLES}"
run_preflight_case missing-fastq "${PROJECT_ROOT}/config/approved.env" \
    "${MISSING_FASTQ_SAMPLES}" 1
assert_no_marker missing-fastq

BAD_MD5_SAMPLES="${PROJECT_ROOT}/config/bad-md5-samples.tsv"
BAD_MD5="${RAW_ROOT}/S1/S1_R1.bad.md5"
printf '00000000000000000000000000000000  S1_R1.fastq.gz\n' > "${BAD_MD5}"
awk -F '\t' -v OFS='\t' -v bad="${BAD_MD5}" 'NR == 2 {$4 = bad} {print}' \
    "${SAMPLES_FILE}" > "${BAD_MD5_SAMPLES}"
run_preflight_case bad-md5 "${PROJECT_ROOT}/config/approved.env" "${BAD_MD5_SAMPLES}" 1
assert_no_marker bad-md5

run_preflight_case version-mismatch "${PROJECT_ROOT}/config/approved.env" \
    "${SAMPLES_FILE}" 1 FAKE_FASTP_VERSION_MISMATCH=1
assert_no_marker version-mismatch

run_preflight_case low-disk "${PROJECT_ROOT}/config/approved.env" \
    "${SAMPLES_FILE}" 1 FAKE_LOW_DISK=1
assert_no_marker low-disk

run_preflight_case copied-reference-mismatch "${PROJECT_ROOT}/config/approved.env" \
    "${SAMPLES_FILE}" 1 FAKE_COPY_CORRUPTION=1
assert_no_marker copied-reference-mismatch

run_preflight_case success "${PROJECT_ROOT}/config/approved.env" "${SAMPLES_FILE}" 0
assert_file "${PROJECT_ROOT}/work/success/state/preflight.done"
assert_file "${PROJECT_ROOT}/reports/success/input_manifest.before.tsv"
assert_file "${PROJECT_ROOT}/reports/success/tool_versions.tsv"
assert_file "${PROJECT_ROOT}/reports/success/fastq_inventory.tsv"
[[ "$(awk 'END {print NR}' "${PROJECT_ROOT}/reports/success/fastq_inventory.tsv")" -eq 10 ]] || \
    fail "successful preflight did not inventory all nine samples"
rg -q $'^S9\t2\t4\t6\t4\t6$' "${PROJECT_ROOT}/reports/success/fastq_inventory.tsv" || \
    fail "successful preflight lacks complete S9 inventory"
assert_file "${PROJECT_ROOT}/logs/success/input_annotation/agat_sp_statistics.stderr.log"
[[ ! -e "${PROJECT_ROOT}/reports/success/input_annotation/agat_sp_statistics.stderr.log" ]] || \
    fail "detailed AGAT stderr leaked into reports"

CONFIG_FILE="${PROJECT_ROOT}/config/approved.env" SAMPLES_FILE="${SAMPLES_FILE}" \
    bash "${SNAPSHOT_SH}" --run-id success --phase after \
    > "${EVIDENCE_ROOT}/snapshot-after.stdout" 2> "${EVIDENCE_ROOT}/snapshot-after.stderr"
cmp -s \
    "${PROJECT_ROOT}/reports/success/input_manifest.before.tsv" \
    "${PROJECT_ROOT}/reports/success/input_manifest.after.tsv" || \
    fail "unchanged before/after manifests differ"

expected_header=$'kind\tpath\tsize_bytes\tmtime_epoch\tchecksum_type\tchecksum'
[[ "$(head -n 1 "${PROJECT_ROOT}/reports/success/input_manifest.before.tsv")" == "${expected_header}" ]] || \
    fail "input manifest header differs from the fixed contract"
[[ "$(awk 'END {print NR}' "${PROJECT_ROOT}/reports/success/input_manifest.before.tsv")" -eq 41 ]] || \
    fail "input manifest must contain header plus 4 resources, 18 FASTQ, and 18 MD5 files"

run_preflight_case snapshot-mutation "${PROJECT_ROOT}/config/approved.env" "${SAMPLES_FILE}" 0
printf 'post-preflight mutation\n' >> "${FIXTURE_ROOT}/flow.png"
set +e
CONFIG_FILE="${PROJECT_ROOT}/config/approved.env" SAMPLES_FILE="${SAMPLES_FILE}" \
    bash "${SNAPSHOT_SH}" --run-id snapshot-mutation --phase after \
    > "${EVIDENCE_ROOT}/snapshot-mutation.stdout" 2> "${EVIDENCE_ROOT}/snapshot-mutation.stderr"
snapshot_mutation_status=$?
set -e
[[ "${snapshot_mutation_status}" -eq 1 ]] || \
    fail "changed controlled input must fail after snapshot, got ${snapshot_mutation_status}"
rg -q 'before/after 输入快照不一致' "${EVIDENCE_ROOT}/snapshot-mutation.stderr" || \
    fail "changed after snapshot did not report manifest mismatch"

printf '[PASS] preflight tool, input, disk, pairing, and reference gates\n'
printf '[INFO] preserved test evidence: %s\n' "${PROJECT_ROOT}"
