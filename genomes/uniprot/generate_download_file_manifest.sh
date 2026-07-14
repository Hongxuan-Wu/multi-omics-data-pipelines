#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="${RELEASE:-2026_02}"
UNIPROT_BASE="${UNIPROT_BASE:-https://ftp.uniprot.org/pub/databases/uniprot/current_release}"
OUTPUT="${OUTPUT:-${SCRIPT_DIR}/download_file_manifest_${RELEASE}.tsv}"
CACHE_ROOT="${CACHE_ROOT:-/tmp/uniprot_manifest_${RELEASE}_$(date -u '+%Y%m%dT%H%M%SZ').$$}"
RAW_MANIFEST="${CACHE_ROOT}/manifest.raw.tsv"

mkdir -p "${CACHE_ROOT}"
: > "${RAW_MANIFEST}"

log() {
  printf '[manifest] %s\n' "$*" >&2
}

die() {
  printf '[manifest] ERROR: %s\n' "$*" >&2
  exit 1
}

curl_official() {
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    -u ALL_PROXY -u all_proxy \
    curl --fail --silent --show-error --location \
      --retry 4 --retry-delay 1 --connect-timeout 30 "$@"
}

cache_name_for_url() {
  local url="$1"
  printf '%s' "${url}" | sha256sum | awk '{print $1}'
}

fetch_cached() {
  local url="$1"
  local suffix="${2:-source}"
  local path="${CACHE_ROOT}/$(cache_name_for_url "${url}").${suffix}"
  if [[ ! -s "${path}" ]]; then
    curl_official "${url}" -o "${path}"
  fi
  [[ -s "${path}" ]] || die "empty response: ${url}"
  printf '%s' "${path}"
}

emit() {
  local scope="$1"
  local tier="$2"
  local dataset="$3"
  local remote_url="$4"
  local relative_path="$5"
  local bytes="${6:-}"
  local md5="${7:-}"
  local source_kind="${8:-static_file}"
  local notes="${9:-}"

  [[ -n "${remote_url}" && -n "${relative_path}" ]] || die "empty manifest path"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${scope}" "${tier}" "${dataset}" "${RELEASE}" "${remote_url}" \
    "${relative_path}" "${bytes}" "${md5}" "${source_kind}" "${notes}" \
    >> "${RAW_MANIFEST}"
}

assert_metalink_version() {
  local metalink_file="$1"
  local metalink_url="$2"
  grep -q "<version>${RELEASE}</version>" "${metalink_file}" || \
    die "release mismatch in ${metalink_url}; expected ${RELEASE}"
}

parse_metalink_files() {
  local metalink_file="$1"
  awk '
    /<file name="/ {
      name=$0
      sub(/^.*<file name="/, "", name)
      sub(/".*$/, "", name)
      size=""
      md5=""
      in_file=1
    }
    in_file && /<size>/ {
      size=$0
      sub(/^.*<size>/, "", size)
      sub(/<\/size>.*$/, "", size)
    }
    in_file && /<hash type="md5">/ {
      md5=$0
      sub(/^.*<hash type="md5">/, "", md5)
      sub(/<\/hash>.*$/, "", md5)
    }
    in_file && /<\/file>/ {
      print name "\t" size "\t" md5
      name=""
      size=""
      md5=""
      in_file=0
    }
  ' "${metalink_file}"
}

emit_metalink_selection() {
  local scope="$1"
  local tier="$2"
  local dataset="$3"
  local base_url="$4"
  local relative_prefix="$5"
  local include_regex="$6"
  local notes="${7:-official_metalink}"
  local metalink_url="${base_url%/}/RELEASE.metalink"
  local metalink_file
  local metalink_bytes
  local name size md5

  metalink_file="$(fetch_cached "${metalink_url}" metalink)"
  assert_metalink_version "${metalink_file}" "${metalink_url}"
  metalink_bytes="$(wc -c < "${metalink_file}")"
  emit "${scope}" "${tier}" "${dataset}" "${metalink_url}" \
    "${relative_prefix}/RELEASE.metalink" "${metalink_bytes}" "" \
    "release_manifest" "expected_version=${RELEASE}"

  while IFS=$'\t' read -r name size md5; do
    [[ -n "${name}" ]] || continue
    if [[ -n "${include_regex}" && ! "${name}" =~ ${include_regex} ]]; then
      continue
    fi
    emit "${scope}" "${tier}" "${dataset}" "${base_url%/}/${name}" \
      "${relative_prefix}/${name}" "${size}" "${md5}" "static_file" "${notes}"
  done < <(parse_metalink_files "${metalink_file}")
}

write_final_manifest() {
  local duplicate_urls invalid_rows invalid_fields final_tmp dataset actual expected
  local total_count total_bytes known_count
  local -A expected_counts

  duplicate_urls="$(awk -F '\t' '{count[$5]++} END {for (url in count) if (count[url] > 1) print url}' "${RAW_MANIFEST}")"
  [[ -z "${duplicate_urls}" ]] || die "duplicate URLs found: ${duplicate_urls}"
  invalid_rows="$(awk -F '\t' 'NF != 10 || $5 == "" || $6 == "" {print NR}' "${RAW_MANIFEST}")"
  [[ -z "${invalid_rows}" ]] || die "invalid TSV rows: ${invalid_rows}"
  invalid_fields="$(awk -F '\t' '
    $1 != "required" ||
    $4 != "2026_02" ||
    $5 !~ /^https:\/\/ftp\.uniprot\.org\/pub\/databases\/uniprot\/current_release\// ||
    $6 ~ /^\// || $6 ~ /(^|\/)\.\.($|\/)/ ||
    $7 !~ /^[1-9][0-9]*$/ ||
    ($9 == "static_file" && (length($8) != 32 || $8 !~ /^[0-9a-fA-F]+$/)) ||
    ($9 == "release_manifest" && $8 != "") ||
    ($9 != "static_file" && $9 != "release_manifest") {print NR}
  ' "${RAW_MANIFEST}")"
  [[ -z "${invalid_fields}" ]] || die "invalid manifest fields: ${invalid_fields}"

  [[ "${RELEASE}" == "2026_02" ]] || die "unsupported release: ${RELEASE}"
  expected_counts=(
    [idmapping]=3
    [reference_proteomes]=4
    [uniprotkb_accessions]=2
    [uniprotkb_complete]=7
    [uniref100]=3
    [uniref50]=3
    [uniref90]=3
  )
  known_count=0
  for dataset in "${!expected_counts[@]}"; do
    expected="${expected_counts[${dataset}]}"
    actual="$(awk -F '\t' -v dataset="${dataset}" '$3 == dataset {count++} END {print count+0}' "${RAW_MANIFEST}")"
    [[ "${actual}" -eq "${expected}" ]] || \
      die "unexpected ${dataset} count: ${actual} (expected ${expected})"
    known_count=$((known_count + actual))
  done
  total_count="$(awk 'END {print NR+0}' "${RAW_MANIFEST}")"
  [[ "${total_count}" -eq 25 && "${known_count}" -eq 25 ]] || \
    die "unexpected manifest total: ${total_count}; expected 25"
  total_bytes="$(awk -F '\t' '{bytes += $7} END {printf "%.0f", bytes+0}' "${RAW_MANIFEST}")"
  [[ "${total_bytes}" == "618535806550" ]] || \
    die "unexpected compressed bytes: ${total_bytes}; expected 618535806550"

  final_tmp="${CACHE_ROOT}/download_file_manifest_${RELEASE}.tsv"
  {
    printf '# generated_at_utc\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '# expected_uniprot_release\t%s\n' "${RELEASE}"
    printf '# approved_target_count\t25\n'
    printf '# approved_compressed_bytes\t618535806550\n'
    printf 'scope\ttier\tdataset\trelease\tremote_url\trelative_path\tbytes\tmd5\tsource_kind\tnotes\n'
    LC_ALL=C sort -t $'\t' -k2,2 -k3,3 -k6,6 "${RAW_MANIFEST}"
  } > "${final_tmp}"
  install -m 0644 "${final_tmp}" "${OUTPUT}"

  log "manifest written: ${OUTPUT}"
  log "cache retained: ${CACHE_ROOT}"
  awk -F '\t' '!/^#/ && $1 != "scope" {count[$1 FS $3]++} END {for (k in count) print k, count[k]}' \
    "${OUTPUT}" | LC_ALL=C sort >&2
}

main() {
  local complete_regex

  complete_regex='^(README|uniprot_sprot\.fasta\.gz|uniprot_trembl\.fasta\.gz|uniprot_sprot_varsplic\.fasta\.gz|uniprot_sprot\.dat\.gz|uniprot_trembl\.dat\.gz)$'

  log "enumerating UniProtKB complete"
  emit_metalink_selection required P0 uniprotkb_complete \
    "${UNIPROT_BASE}/knowledgebase/complete" "knowledgebase/complete" "${complete_regex}"
  emit_metalink_selection required P1 uniprotkb_accessions \
    "${UNIPROT_BASE}/knowledgebase/complete/docs" \
    "knowledgebase/complete/docs" '^sec_ac\.txt$'

  log "enumerating UniRef50/90/100"
  emit_metalink_selection required P0 uniref50 \
    "${UNIPROT_BASE}/uniref/uniref50" "uniref/uniref50" \
    '^(README|uniref50\.fasta\.gz)$'
  emit_metalink_selection required P0 uniref90 \
    "${UNIPROT_BASE}/uniref/uniref90" "uniref/uniref90" \
    '^(README|uniref90\.fasta\.gz)$'
  emit_metalink_selection required P0 uniref100 \
    "${UNIPROT_BASE}/uniref/uniref100" "uniref/uniref100" \
    '^(README|uniref100\.fasta\.gz)$'

  log "enumerating identifier mappings"
  emit_metalink_selection required P1 idmapping \
    "${UNIPROT_BASE}/knowledgebase/idmapping" "knowledgebase/idmapping" \
    '^(README|idmapping\.dat\.gz)$'

  log "enumerating Reference Proteomes archive"
  emit_metalink_selection required P1 reference_proteomes \
    "${UNIPROT_BASE}/knowledgebase/reference_proteomes" \
    "knowledgebase/reference_proteomes" \
    '^(README|STATS|Reference_Proteomes_2026_02\.tar\.gz)$'

  write_final_manifest
}

main "$@"
