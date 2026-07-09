#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  grep -Eq "${pattern}" "${file}" || fail "${file} missing pattern: ${pattern}"
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  if grep -Eq "${pattern}" "${file}"; then
    fail "${file} contains forbidden pattern: ${pattern}"
  fi
}

assert_executable() {
  local file="$1"
  [[ -x "${file}" ]] || fail "${file} is not executable"
}

common="${ROOT_DIR}/common/common.sh"
roadmap="${ROOT_DIR}/roadmap/download_roadmap.sh"
bvbrc="${ROOT_DIR}/bv_brc/download_bv_brc.sh"
encode="${ROOT_DIR}/encode/download_encode.sh"
gtdb="${ROOT_DIR}/gtdb/download_gtdb.sh"
genbank="${ROOT_DIR}/genbank/download_genbank.sh"
gencode="${ROOT_DIR}/gencode/download_gencode.sh"
rnacentral="${ROOT_DIR}/rnacentral/download_rnacentral.sh"
ucsc="${ROOT_DIR}/ucsc/download_ucsc.sh"
uniprot="${ROOT_DIR}/uniprot_uniref50/download_uniprot_uniref50.sh"
phytozome="${ROOT_DIR}/phytozome/download_phytozome.sh"
mycocosm="${ROOT_DIR}/mycocosm/download_mycocosm.sh"
veupathdb="${ROOT_DIR}/veupathdb/download_veupathdb.sh"

assert_contains "${common}" '^set -Eeuo pipefail$'
assert_contains "${common}" '^export LC_ALL=C$'
assert_contains "${common}" '^warnlog\(\)'

assert_contains "${roadmap}" 'byFileType/metadata/EID_metadata\.tab'
assert_not_contains "${roadmap}" 'data/metadata/'
assert_not_contains "${roadmap}" 'model_15_coreMarks_dense\.gz'

assert_contains "${bvbrc}" 'eq\(genome_status,Complete\)'
assert_not_contains "${bvbrc}" 'BV_BRC_API_URL.*\?limit\(10\)&select'
assert_contains "${bvbrc}" 'DOWNLOAD_MODE="api"'
assert_contains "${bvbrc}" 'BV_BRC_API_BASE='
assert_contains "${bvbrc}" 'download_one_api'
assert_contains "${bvbrc}" 'genome_id,pathway_id,pathway_name,pathway_class,annotation'
assert_contains "${bvbrc}" 'genome_id,subsystem_id,subsystem_name,superclass,class,subclass,role_name,active,product'
assert_not_contains "${bvbrc}" 'require_command lftp'
assert_not_contains "${bvbrc}" 'ftps://ftp\.bvbrc\.org'
assert_not_contains "${bvbrc}" 'awk .*\| while'

assert_contains "${encode}" 'ALLOW_LIVE_API='
assert_contains "${encode}" 'FROZEN_MANIFEST='
assert_contains "${encode}" 'load_frozen_manifest_if_present'
[[ -f "${ROOT_DIR}/encode/frozen_file_manifest.example.tsv" ]] || fail "encode frozen manifest example is missing"

assert_contains "${gtdb}" 'DOWNLOAD_GTDB_REP_GENOMES="\$\{DOWNLOAD_GTDB_REP_GENOMES:-0\}"'
assert_contains "${gtdb}" 'FULL_SEQUENCE_MIN_DISK_GB='
assert_contains "${gtdb}" 'should_include_target_record'

assert_contains "${genbank}" 'DOWNLOAD_GENBANK_ASSEMBLY_FILES="\$\{DOWNLOAD_GENBANK_ASSEMBLY_FILES:-0\}"'
assert_contains "${genbank}" 'FULL_SEQUENCE_MIN_DISK_GB='
assert_contains "${genbank}" 'metadata-only'

assert_contains "${gencode}" 'DOWNLOAD_GENCODE_TRANSCRIPTS="\$\{DOWNLOAD_GENCODE_TRANSCRIPTS:-0\}"'
assert_contains "${gencode}" 'DOWNLOAD_GENCODE_TRANSLATIONS="\$\{DOWNLOAD_GENCODE_TRANSLATIONS:-0\}"'
assert_contains "${gencode}" 'should_include_target_record'

assert_contains "${rnacentral}" 'DOWNLOAD_RNACENTRAL_SEQUENCES="\$\{DOWNLOAD_RNACENTRAL_SEQUENCES:-0\}"'
assert_contains "${rnacentral}" 'FULL_SEQUENCE_MIN_DISK_GB='
assert_contains "${rnacentral}" 'should_include_target_record'

assert_contains "${ucsc}" 'DOWNLOAD_UCSC_2BIT="\$\{DOWNLOAD_UCSC_2BIT:-0\}"'
assert_contains "${ucsc}" 'should_include_target_record'

assert_contains "${uniprot}" 'DOWNLOAD_UNIREF50_SEQUENCE_ARCHIVE="\$\{DOWNLOAD_UNIREF50_SEQUENCE_ARCHIVE:-1\}"'
assert_contains "${uniprot}" 'FULL_SEQUENCE_MIN_DISK_GB='
assert_contains "${uniprot}" 'should_include_target_record'

assert_contains "${phytozome}" 'DOWNLOAD_PROTEIN_CDS_SEQUENCES="\$\{DOWNLOAD_PROTEIN_CDS_SEQUENCES:-0\}"'
assert_contains "${phytozome}" 'should_include_jgi_file'
assert_contains "${mycocosm}" 'DOWNLOAD_PROTEIN_CDS_SEQUENCES="\$\{DOWNLOAD_PROTEIN_CDS_SEQUENCES:-0\}"'
assert_contains "${mycocosm}" 'should_include_jgi_file'

assert_contains "${veupathdb}" 'DOWNLOAD_FASTA="\$\{DOWNLOAD_FASTA:-0\}"'
assert_contains "${veupathdb}" 'should_include_veupathdb_file'

for script in "${ROOT_DIR}"/*/download_*.sh "${common}"; do
  assert_executable "${script}"
  bash -n "${script}"
done

for script in "${ROOT_DIR}"/*/download_*.sh; do
  assert_contains "${script}" '^LOCAL_ROOT="\$\{LOCAL_ROOT:-'
  assert_contains "${script}" '^RUN_ROOT="\$\{RUN_ROOT:-'
  assert_contains "${script}" '^MIN_DISK_GB="\$\{MIN_DISK_GB:-'
done

if grep -R -n -E '待目标环境确认|Linux 服务器 `bash -n` 仍需补做|本机 Bash/WSL 语法校验受限|jq.*本机未安装' "${ROOT_DIR}"/*/validation_report.md; then
  fail 'validation reports still contain stale local-environment validation status'
fi

printf '[PASS] genomes static contracts\n'
