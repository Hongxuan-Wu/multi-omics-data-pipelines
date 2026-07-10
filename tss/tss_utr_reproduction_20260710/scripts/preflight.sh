#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SAMPLES_FILE="${SAMPLES_FILE:-${COMMON_PROJECT_ROOT}/config/samples.tsv}"
RUN_ID=""
MODE=""
RESUME=0

usage() {
    printf 'usage: %s --run-id ID --mode full|smoke\n' "$0" >&2
}

while (( $# > 0 )); do
    case "$1" in
        --run-id)
            (( $# >= 2 )) || { usage; exit 2; }
            RUN_ID="$2"
            shift 2
            ;;
        --mode)
            (( $# >= 2 )) || { usage; exit 2; }
            MODE="$2"
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

require_run_id
case "${MODE}" in
    full|smoke) ;;
    *) usage; exit 2 ;;
esac
assert_absolute "${SAMPLES_FILE}"

# This gate intentionally precedes every tool invocation, checksum, and FASTQ read.
if [[ "${FASTP_POLICY_STATUS}" != "approved" ]]; then
    printf 'ERROR: fastp policy is blocked (status=%s)\n' "${FASTP_POLICY_STATUS}" >&2
    exit 42
fi

init_run_layout

TOOL_LOG_ROOT="${RUN_LOG_ROOT}/tool_versions"
TOOL_REPORT="${RUN_REPORT_ROOT}/tool_versions.tsv"
TOOL_REPORT_TMP="${RUN_LOG_ROOT}/tool_versions.tmp.tsv"
mkdir -p "${TOOL_LOG_ROOT}"
assert_report_output_path "${TOOL_REPORT}"
assert_process_output_path "${TOOL_REPORT_TMP}"
printf 'kind\ttool\texpected_version\tobserved_version\tentrypoint\tpackage\tpackage_version\tsha256\n' \
    > "${TOOL_REPORT_TMP}"

check_main_tool() {
    local tool="$1"
    local expected="$2"
    local prefix="$3"
    local entrypoint="$4"
    shift 4
    local stdout_file="${TOOL_LOG_ROOT}/${tool}.stdout.log"
    local stderr_file="${TOOL_LOG_ROOT}/${tool}.stderr.log"
    local combined observed checksum

    assert_absolute "${entrypoint}" || return 1
    [[ -x "${entrypoint}" ]] || die "工具入口缺失或不可执行：${entrypoint}"
    if ! run_conda "${prefix}" "$@" > "${stdout_file}" 2> "${stderr_file}"; then
        die "工具版本命令失败：${tool}"
        return 1
    fi
    combined="$(cat "${stdout_file}" "${stderr_file}")"
    case "${tool}" in
        fastp) observed="$(printf '%s\n' "${combined}" | sed -n 's/^fastp \([^[:space:]]*\)$/\1/p' | head -n 1)" ;;
        STAR) observed="$(printf '%s\n' "${combined}" | sed -n '/^[0-9][0-9A-Za-z.]*$/p' | head -n 1)" ;;
        stringtie) observed="$(printf '%s\n' "${combined}" | sed -n '/^[0-9][0-9.]*$/p' | head -n 1)" ;;
        PASA) observed="$(printf '%s\n' "${combined}" | sed -n 's/^PASA version: \([^[:space:]]*\)$/\1/p' | head -n 1)" ;;
        AGAT) observed="$(printf '%s\n' "${combined}" | sed -n 's/.*Version: v\([^ |]*\).*/\1/p' | head -n 1)" ;;
        *) die "未知主工具：${tool}"; return 1 ;;
    esac
    [[ -n "${observed}" ]] || die "无法解析工具版本：${tool}"
    [[ "${observed}" == "${expected}" ]] || \
        die "工具版本不匹配：${tool} expected=${expected} observed=${observed}"
    checksum="$(sha256sum -- "${entrypoint}" | awk '{print $1}')"
    printf 'main\t%s\t%s\t%s\t%s\t\t\t%s\n' \
        "${tool}" "${expected}" "${observed}" "${entrypoint}" "${checksum}" \
        >> "${TOOL_REPORT_TMP}"
}

check_main_tool fastp 0.23.1 "${FASTP_PREFIX}" "${FASTP_PREFIX}/bin/fastp" fastp --version
check_main_tool STAR 2.7.9a "${STAR_PREFIX}" "${STAR_PREFIX}/bin/STAR" STAR --version
check_main_tool stringtie 2.2.0 "${STRINGTIE_PREFIX}" "${STRINGTIE_PREFIX}/bin/stringtie" stringtie --version
check_main_tool PASA 2.5.2 "${PASA_PREFIX}" "${PASA_HOME}/Launch_PASA_pipeline.pl" \
    "${PASA_HOME}/Launch_PASA_pipeline.pl" --version
check_main_tool AGAT 0.8.0 "${AGAT_PREFIX}" "${AGAT_PREFIX}/bin/agat_sp_keep_longest_isoform.pl" \
    agat_sp_keep_longest_isoform.pl --help

CONDA_PACKAGES_JSON="${TOOL_LOG_ROOT}/pasa_conda_packages.json"
CONDA_PACKAGES_TSV="${TOOL_LOG_ROOT}/pasa_conda_packages.tsv"
"${CONDA_EXE}" list -p "${PASA_PREFIX}" --json > "${CONDA_PACKAGES_JSON}" || \
    die "无法读取 PASA conda 包清单"
run_conda "${PASA_PREFIX}" perl -MJSON::PP -0777 -e '
    my $packages = decode_json(<>);
    for my $package (@{$packages}) {
        next if !defined $package->{name} || !defined $package->{version};
        print "$package->{name}\t$package->{version}\n";
    }
' < "${CONDA_PACKAGES_JSON}" > "${CONDA_PACKAGES_TSV}" || die "无法解析 PASA conda 包清单"

for tool_package in gmap:gmap blat:ucsc-blat samtools:samtools sqlite3:sqlite; do
    tool="${tool_package%%:*}"
    package="${tool_package#*:}"
    entrypoint="${PASA_PREFIX}/bin/${tool}"
    assert_absolute "${entrypoint}"
    [[ -x "${entrypoint}" ]] || die "PASA 依赖入口缺失或不可执行：${entrypoint}"
    package_version="$(awk -F '\t' -v package="${package}" '$1 == package {print $2}' "${CONDA_PACKAGES_TSV}")"
    [[ -n "${package_version}" ]] || die "PASA 依赖包版本缺失：${package}"
    checksum="$(sha256sum -- "${entrypoint}" | awk '{print $1}')"
    printf 'dependency\t%s\t\t%s\t%s\t%s\t%s\t%s\n' \
        "${tool}" "${package_version}" "${entrypoint}" "${package}" "${package_version}" "${checksum}" \
        >> "${TOOL_REPORT_TMP}"
done
mv -- "${TOOL_REPORT_TMP}" "${TOOL_REPORT}"
assert_report_output_path "${TOOL_REPORT}"

available_kb="$(df -Pk -- "${PROJECT_ROOT}" | awk 'NR == 2 {print $4}')"
[[ "${available_kb}" =~ ^[0-9]+$ ]] || die "无法解析可用磁盘空间：${PROJECT_ROOT}"
required_kb=$((MIN_FREE_GB * 1024 * 1024))
(( available_kb >= required_kb )) || \
    die "可用磁盘空间低于门禁：available_kb=${available_kb} required_kb=${required_kb}"

CONFIG_FILE="${CONFIG_FILE}" SAMPLES_FILE="${SAMPLES_FILE}" \
    bash "${SCRIPT_DIR}/snapshot_inputs.sh" --run-id "${RUN_ID}" --phase before >/dev/null

FASTQ_INVENTORY="${RUN_REPORT_ROOT}/fastq_inventory.tsv"
FASTQ_INVENTORY_TMP="${RUN_LOG_ROOT}/fastq_inventory.tmp.tsv"
assert_report_output_path "${FASTQ_INVENTORY}"
assert_process_output_path "${FASTQ_INVENTORY_TMP}"
printf 'sample_id\tpairs\tr1_min_length\tr1_max_length\tr2_min_length\tr2_max_length\n' \
    > "${FASTQ_INVENTORY_TMP}"
sample_count=0
while IFS=$'\t' read -r sample_id r1 r2 r1_md5 r2_md5 extra; do
    [[ -n "${sample_id}" && -n "${r1}" && -n "${r2}" && -z "${extra:-}" ]] || \
        die "样本表数据行非法：${sample_id:-<empty>}"
    run_conda "${PASA_PREFIX}" perl "${SCRIPT_DIR}/check_fastq_pairs.pl" \
        --sample "${sample_id}" --r1 "${r1}" --r2 "${r2}" >> "${FASTQ_INVENTORY_TMP}"
    sample_count=$((sample_count + 1))
done < <(tail -n +2 "${SAMPLES_FILE}")
[[ "${sample_count}" -eq 9 ]] || die "FASTQ 配对检查必须覆盖 9 个样本，实际 ${sample_count}"
mv -- "${FASTQ_INVENTORY_TMP}" "${FASTQ_INVENTORY}"
assert_report_output_path "${FASTQ_INVENTORY}"

reference_fasta_copy="${RUN_ROOT}/reference/$(basename -- "${REFERENCE_FASTA}")"
reference_gff_copy="${RUN_ROOT}/reference/$(basename -- "${REFERENCE_GFF}")"
for source_destination in \
    "${REFERENCE_FASTA}:${reference_fasta_copy}" \
    "${REFERENCE_GFF}:${reference_gff_copy}"; do
    source_path="${source_destination%%:*}"
    destination_path="${source_destination#*:}"
    assert_process_output_path "${destination_path}"
    [[ ! -e "${destination_path}" ]] || die "参考副本已存在：${destination_path}"
    cp --reflink=auto --preserve=timestamps -- "${source_path}" "${destination_path}"
    cmp -s -- "${source_path}" "${destination_path}" || \
        die "参考副本内容不一致：${destination_path}"
    source_hash="$(sha256sum -- "${source_path}" | awk '{print $1}')"
    destination_hash="$(sha256sum -- "${destination_path}" | awk '{print $1}')"
    [[ "${source_hash}" == "${destination_hash}" ]] || \
        die "参考副本 SHA-256 不一致：${destination_path}"
done

ANNOTATION_REPORT_ROOT="${RUN_REPORT_ROOT}/input_annotation"
ANNOTATION_LOG_ROOT="${RUN_LOG_ROOT}/input_annotation"
mkdir -p "${ANNOTATION_REPORT_ROOT}" "${ANNOTATION_LOG_ROOT}"
STRUCTURE_REPORT="${ANNOTATION_REPORT_ROOT}/structure_check.tsv"
STRUCTURE_STDERR="${ANNOTATION_LOG_ROOT}/structure_check.stderr.log"
assert_report_output_path "${STRUCTURE_REPORT}"
run_conda "${PASA_PREFIX}" perl - "${reference_fasta_copy}" "${reference_gff_copy}" \
    > "${STRUCTURE_REPORT}" 2> "${STRUCTURE_STDERR}" <<'PERL'
use strict;
use warnings;

my ($fasta_path, $gff_path) = @ARGV;
my (%contig_length, %all_ids, %gene_transcript_ids, @parents);
my ($current_id, $current_length, $feature_count, $gene_count, $mrna_count) = (q{}, 0, 0, 0, 0);

open my $fasta, '<', $fasta_path or die "cannot open FASTA $fasta_path: $!\n";
while (my $line = <$fasta>) {
    chomp $line;
    $line =~ s/\r\z//;
    if ($line =~ /^>(\S+)/) {
        if ($current_id ne q{}) {
            die "empty FASTA sequence: $current_id\n" if $current_length == 0;
            $contig_length{$current_id} = $current_length;
        }
        $current_id = $1;
        die "duplicate FASTA ID: $current_id\n" if exists $contig_length{$current_id};
        $current_length = 0;
    } else {
        die "FASTA sequence before first header\n" if $current_id eq q{};
        $line =~ s/\s+//g;
        die "invalid FASTA sequence characters for $current_id\n" if $line !~ /^[A-Za-z*.-]+$/;
        $current_length += length $line;
    }
}
close $fasta or die "cannot close FASTA $fasta_path: $!\n";
die "FASTA contains no sequences\n" if $current_id eq q{};
die "empty FASTA sequence: $current_id\n" if $current_length == 0;
$contig_length{$current_id} = $current_length;

open my $gff, '<', $gff_path or die "cannot open GFF $gff_path: $!\n";
my $line_number = 0;
while (my $line = <$gff>) {
    $line_number++;
    next if $line =~ /^#/ || $line =~ /^\s*$/;
    chomp $line;
    $line =~ s/\r\z//;
    my @field = split /\t/, $line, -1;
    die "GFF line $line_number does not have nine columns\n" if @field != 9;
    my ($seqid, undef, $type, $start, $end, undef, undef, undef, $attributes) = @field;
    die "GFF line $line_number uses unknown seqid $seqid\n" if !exists $contig_length{$seqid};
    die "GFF line $line_number has invalid coordinates\n"
        if $start !~ /^\d+$/ || $end !~ /^\d+$/ || $start < 1 || $end < $start;
    die "GFF line $line_number exceeds contig $seqid\n" if $end > $contig_length{$seqid};

    my %attribute;
    for my $item (split /;/, $attributes) {
        my ($key, $value) = split /=/, $item, 2;
        next if !defined $key || !defined $value || $key eq q{};
        $attribute{$key} = $value;
    }
    if (defined $attribute{ID} && $attribute{ID} ne q{}) {
        $all_ids{$attribute{ID}} = 1;
    }
    if ($type eq 'gene' || $type eq 'mRNA') {
        die "GFF line $line_number $type lacks ID\n" if !defined $attribute{ID} || $attribute{ID} eq q{};
        die "duplicate gene/mRNA ID: $attribute{ID}\n" if $gene_transcript_ids{$attribute{ID}}++;
        $gene_count++ if $type eq 'gene';
        $mrna_count++ if $type eq 'mRNA';
    }
    if (defined $attribute{Parent} && $attribute{Parent} ne q{}) {
        push @parents, map { [$_, $line_number] } split /,/, $attribute{Parent};
    }
    $feature_count++;
}
close $gff or die "cannot close GFF $gff_path: $!\n";
for my $parent (@parents) {
    die "unresolved Parent $parent->[0] at GFF line $parent->[1]\n" if !exists $all_ids{$parent->[0]};
}
die "GFF contains no genes\n" if $gene_count == 0;
die "GFF contains no mRNA features\n" if $mrna_count == 0;

print "metric\tvalue\n";
print "contigs\t", scalar(keys %contig_length), "\n";
print "features\t$feature_count\n";
print "genes\t$gene_count\n";
print "mRNAs\t$mrna_count\n";
print "parents_checked\t", scalar(@parents), "\n";
PERL
assert_report_output_path "${STRUCTURE_REPORT}"

AGAT_REPORT="${ANNOTATION_REPORT_ROOT}/agat_sp_statistics.tsv"
AGAT_STDERR="${ANNOTATION_LOG_ROOT}/agat_sp_statistics.stderr.log"
assert_report_output_path "${AGAT_REPORT}"
run_conda "${AGAT_PREFIX}" agat_sp_statistics.pl \
    --gff "${reference_gff_copy}" --gs "${reference_fasta_copy}" \
    > "${AGAT_REPORT}" 2> "${AGAT_STDERR}" || die "AGAT 原始注释统计失败"
assert_report_output_path "${AGAT_REPORT}"
agat_gene_count="$(sed -n 's/.*Number of genes[^0-9]*\([0-9][0-9,]*\).*/\1/p' "${AGAT_REPORT}" | head -n 1 | tr -d ',')"
[[ "${agat_gene_count}" == "10370" ]] || \
    die "AGAT 原始注释 gene 数不匹配：expected=10370 observed=${agat_gene_count:-unparsed}"

mark_stage_done preflight "${reference_fasta_copy}" "${reference_gff_copy}"
log "preflight passed: run_id=${RUN_ID} mode=${MODE}"
