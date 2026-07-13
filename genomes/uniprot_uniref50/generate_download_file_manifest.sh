#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="${RELEASE:-2026_02}"
UNIPROT_BASE="${UNIPROT_BASE:-https://ftp.uniprot.org/pub/databases/uniprot/current_release}"
GOA_BASE="${GOA_BASE:-https://ftp.ebi.ac.uk/pub/databases/GO/goa/UNIPROT}"
OUTPUT="${OUTPUT:-${SCRIPT_DIR}/download_file_manifest_${RELEASE}.tsv}"
PAN_WORKERS="${PAN_WORKERS:-24}"
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

extract_hrefs() {
  sed -n 's/.*href="\([^"]*\)".*/\1/p'
}

emit_top_listing_files() {
  local scope="$1"
  local tier="$2"
  local dataset="$3"
  local base_url="$4"
  local relative_prefix="$5"
  local include_regex="${6:-.*}"
  local exclude_regex="${7:-^$}"
  local index_file href

  index_file="$(fetch_cached "${base_url%/}/" index)"
  while IFS= read -r href; do
    href="${href%%\?*}"
    href="${href%%#*}"
    case "${href}" in
      ""|"../"|/*|*/) continue ;;
    esac
    [[ "${href}" =~ ${include_regex} ]] || continue
    [[ ! "${href}" =~ ${exclude_regex} ]] || continue
    emit "${scope}" "${tier}" "${dataset}" "${base_url%/}/${href}" \
      "${relative_prefix}/${href}" "" "" "directory_listing" ""
  done < <(extract_hrefs < "${index_file}")
}

crawl_metalink_tree() {
  local scope="$1"
  local tier="$2"
  local dataset="$3"
  local base_url="$4"
  local relative_prefix="$5"
  local depth="${6:-0}"
  local index_file href child

  (( depth <= 6 )) || die "directory recursion too deep: ${base_url}"
  index_file="$(fetch_cached "${base_url%/}/" index)"
  if grep -q 'href="RELEASE.metalink"' "${index_file}"; then
    emit_metalink_selection "${scope}" "${tier}" "${dataset}" \
      "${base_url}" "${relative_prefix}" '.*'
  else
    emit_top_listing_files "${scope}" "${tier}" "${dataset}" \
      "${base_url}" "${relative_prefix}"
  fi

  while IFS= read -r href; do
    href="${href%%\?*}"
    href="${href%%#*}"
    case "${href}" in
      ""|"../"|/*) continue ;;
    esac
    if [[ "${href}" == */ ]]; then
      child="${href%/}"
      crawl_metalink_tree "${scope}" "${tier}" "${dataset}" \
        "${base_url%/}/${child}" "${relative_prefix}/${child}" "$((depth + 1))"
    fi
  done < <(extract_hrefs < "${index_file}")
}

emit_goa() {
  local readme_url="${GOA_BASE}/README"
  local readme_file readme_bytes
  local format data_url md5_url md5_file md5 bytes headers

  readme_file="$(fetch_cached "${readme_url}" goa_readme)"
  readme_bytes="$(wc -c < "${readme_file}")"
  emit required P2 goa_uniprot_all "${readme_url}" "goa/UNIPROT/README" \
    "${readme_bytes}" "" static_file independent_GOA_snapshot

  for format in gaf gpa gpi; do
    data_url="${GOA_BASE}/goa_uniprot_all.${format}.gz"
    md5_url="${data_url}.md5"
    md5_file="$(fetch_cached "${md5_url}" md5)"
    md5="$(awk 'NF {print $1; exit}' "${md5_file}")"
    [[ "${md5}" =~ ^[0-9a-fA-F]{32}$ ]] || die "invalid GOA MD5: ${md5_url}"
    headers="$(curl_official --head "${data_url}")"
    bytes="$(awk 'BEGIN {IGNORECASE=1} /^content-length:/ {gsub(/\r/, ""); value=$2} END {print value}' <<< "${headers}")"
    [[ "${bytes}" =~ ^[0-9]+$ ]] || die "missing GOA Content-Length: ${data_url}"

    emit required P2 goa_uniprot_all "${data_url}" \
      "goa/UNIPROT/goa_uniprot_all.${format}.gz" "${bytes}" "${md5}" \
      static_file md5_sidecar
    emit required P2 goa_uniprot_all "${md5_url}" \
      "goa/UNIPROT/goa_uniprot_all.${format}.gz.md5" \
      "$(wc -c < "${md5_file}")" "" checksum_file independent_GOA_snapshot
  done
}

emit_pan_proteomes() {
  local pan_base="${UNIPROT_BASE}/knowledgebase/pan_proteomes"
  local pan_prefix="knowledgebase/pan_proteomes"
  local root_index pan_cache
  local expected_count=3195
  local id metalink_file metalink_bytes name size md5 child_count
  local -a pan_dirs

  emit_metalink_selection required P2 pan_proteomes \
    "${pan_base}" "${pan_prefix}" '.*'
  root_index="$(fetch_cached "${pan_base}/" index)"
  mapfile -t pan_dirs < <(extract_hrefs < "${root_index}" | sed -n 's#^\(pp[0-9][0-9]*\)/$#\1#p' | LC_ALL=C sort -V)
  [[ "${#pan_dirs[@]}" -eq "${expected_count}" ]] || \
    die "unexpected Pan Proteome directory count: ${#pan_dirs[@]} (expected ${expected_count})"

  pan_cache="${CACHE_ROOT}/pan_metalinks"
  mkdir -p "${pan_cache}"
  log "fetching ${#pan_dirs[@]} Pan Proteome metalinks with ${PAN_WORKERS} workers"
  printf '%s\n' "${pan_dirs[@]}" | xargs -r -P "${PAN_WORKERS}" -I '{}' \
    bash -c '
      set -Eeuo pipefail
      id="$1"
      base="$2"
      out="$3/${id}.metalink"
      if [[ ! -s "${out}" ]]; then
        env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
          -u ALL_PROXY -u all_proxy \
          curl --fail --silent --show-error --location --retry 4 --retry-delay 1 \
            --connect-timeout 30 "${base}/${id}/RELEASE.metalink" -o "${out}"
      fi
      [[ -s "${out}" ]]
    ' _ '{}' "${pan_base}" "${pan_cache}"

  for id in "${pan_dirs[@]}"; do
    metalink_file="${pan_cache}/${id}.metalink"
    assert_metalink_version "${metalink_file}" "${pan_base}/${id}/RELEASE.metalink"
    metalink_bytes="$(wc -c < "${metalink_file}")"
    emit required P2 pan_proteomes "${pan_base}/${id}/RELEASE.metalink" \
      "${pan_prefix}/${id}/RELEASE.metalink" "${metalink_bytes}" "" \
      release_manifest "expected_version=${RELEASE}"
    child_count=0
    while IFS=$'\t' read -r name size md5; do
      [[ -n "${name}" ]] || continue
      child_count=$((child_count + 1))
      emit required P2 pan_proteomes "${pan_base}/${id}/${name}" \
        "${pan_prefix}/${id}/${name}" "${size}" "${md5}" static_file official_metalink
    done < <(parse_metalink_files "${metalink_file}")
    [[ "${child_count}" -eq 3 ]] || \
      die "unexpected file count in ${pan_base}/${id}: ${child_count} (expected 3)"
  done
}

write_final_manifest() {
  local duplicate_urls invalid_rows invalid_fields final_tmp dataset actual expected
  local -A expected_counts

  duplicate_urls="$(awk -F '\t' '{count[$5]++} END {for (url in count) if (count[url] > 1) print url}' "${RAW_MANIFEST}")"
  [[ -z "${duplicate_urls}" ]] || die "duplicate URLs found: ${duplicate_urls}"
  invalid_rows="$(awk -F '\t' 'NF != 10 || $5 == "" || $6 == "" {print NR}' "${RAW_MANIFEST}")"
  [[ -z "${invalid_rows}" ]] || die "invalid TSV rows: ${invalid_rows}"
  invalid_fields="$(awk -F '\t' '
    $5 !~ /^https:\/\// ||
    $6 ~ /^\// || $6 ~ /(^|\/)\.\.($|\/)/ ||
    ($7 != "" && $7 !~ /^[0-9]+$/) ||
    ($8 != "" && (length($8) != 32 || $8 !~ /^[0-9a-fA-F]+$/)) {print NR}
  ' "${RAW_MANIFEST}")"
  [[ -z "${invalid_fields}" ]] || die "invalid manifest fields: ${invalid_fields}"

  if [[ "${RELEASE}" == "2026_02" ]]; then
    expected_counts=(
      [genome_annotation_tracks]=73
      [goa_uniprot_all]=7
      [idmapping]=3
      [pan_proteomes]=12789
      [proteomes_rest]=1
      [proteomics_mapping]=50
      [reference_proteomes]=4
      [semantic_rdf]=20
      [uniparc_active]=201
      [uniparc_metadata]=3
      [uniparc_xml_all]=201
      [uniprotkb_complete]=10
      [uniprotkb_docs]=104
      [uniref100]=6
      [uniref50]=7
      [uniref90]=7
      [variants]=38
    )
    for dataset in "${!expected_counts[@]}"; do
      expected="${expected_counts[${dataset}]}"
      actual="$(awk -F '\t' -v dataset="${dataset}" '$3 == dataset {count++} END {print count+0}' "${RAW_MANIFEST}")"
      [[ "${actual}" -eq "${expected}" ]] || \
        die "unexpected ${dataset} count: ${actual} (expected ${expected})"
    done
  fi

  final_tmp="${CACHE_ROOT}/download_file_manifest_${RELEASE}.tsv"
  {
    printf '# generated_at_utc\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '# expected_uniprot_release\t%s\n' "${RELEASE}"
    printf '# scope\trequired=download; conditional=download only for offline UniParc source/history audit\n'
    printf 'scope\ttier\tdataset\trelease\tremote_url\trelative_path\tbytes\tmd5\tsource_kind\tnotes\n'
    awk -F '\t' 'BEGIN {OFS="\t"} {rank=($1=="required" ? 1 : 2); print rank,$0}' "${RAW_MANIFEST}" \
      | LC_ALL=C sort -t $'\t' -k1,1n -k3,3 -k4,4 -k7,7 \
      | cut -f2-
  } > "${final_tmp}"
  install -m 0644 "${final_tmp}" "${OUTPUT}"

  log "manifest written: ${OUTPUT}"
  log "cache retained: ${CACHE_ROOT}"
  awk -F '\t' '!/^#/ && $1 != "scope" {count[$1 FS $3]++} END {for (k in count) print k, count[k]}' \
    "${OUTPUT}" | LC_ALL=C sort >&2
}

main() {
  local complete_regex
  local rdf_regex

  complete_regex='^(README|LICENSE|reldate\.txt|uniprot\.xsd|uniprot_sprot\.fasta\.gz|uniprot_trembl\.fasta\.gz|uniprot_sprot_varsplic\.fasta\.gz|uniprot_sprot\.dat\.gz|uniprot_trembl\.dat\.gz)$'
  rdf_regex='^(README|core\.owl|databases\.rdf\.xz|diseases\.rdf\.xz|enzyme\.rdf\.xz|enzyme-hierarchy\.rdf\.xz|go\.owl\.xz|go-hierarchy\.owl\.xz|keywords\.rdf\.xz|keywords-hierarchy\.rdf\.xz|locations\.rdf\.xz|locations-hierarchy\.rdf\.xz|pathways\.rdf\.xz|pathways-hierarchy\.rdf\.xz|proteomes\.rdf\.xz|taxonomy\.rdf\.xz|taxonomy-hierarchy\.rdf\.xz|tissues\.rdf\.xz|void\.rdf)$'

  log "enumerating UniProtKB complete"
  emit_metalink_selection required P0 uniprotkb_complete \
    "${UNIPROT_BASE}/knowledgebase/complete" "knowledgebase/complete" "${complete_regex}"
  emit_metalink_selection required P0 uniprotkb_docs \
    "${UNIPROT_BASE}/knowledgebase/complete/docs" "knowledgebase/complete/docs" '.*'

  log "enumerating UniRef50/90/100"
  emit_metalink_selection required P0 uniref50 \
    "${UNIPROT_BASE}/uniref/uniref50" "uniref/uniref50" '.*'
  emit_metalink_selection required P0 uniref90 \
    "${UNIPROT_BASE}/uniref/uniref90" "uniref/uniref90" '.*'
  emit_metalink_selection required P0 uniref100 \
    "${UNIPROT_BASE}/uniref/uniref100" "uniref/uniref100" '.*'

  log "enumerating identifier and reference-proteome mappings"
  emit_metalink_selection required P1 idmapping \
    "${UNIPROT_BASE}/knowledgebase/idmapping" "knowledgebase/idmapping" \
    '^(README|idmapping\.dat\.gz)$'
  emit_metalink_selection required P1 reference_proteomes \
    "${UNIPROT_BASE}/knowledgebase/reference_proteomes" \
    "knowledgebase/reference_proteomes" '.*'
  emit required P1 proteomes_rest \
    'https://rest.uniprot.org/proteomes/search?query=%2A&format=json&size=500' \
    "knowledgebase/proteomes/proteomes_${RELEASE}.json" "" "" api_paginated \
    'follow_Link_headers_and_merge_all_pages;record_query_and_timestamp'

  log "enumerating Pan Proteomes"
  emit_pan_proteomes

  log "enumerating genome, peptide and variant mappings"
  crawl_metalink_tree required P2 genome_annotation_tracks \
    "${UNIPROT_BASE}/knowledgebase/genome_annotation_tracks" \
    "knowledgebase/genome_annotation_tracks"
  emit_metalink_selection required P2 proteomics_mapping \
    "${UNIPROT_BASE}/knowledgebase/proteomics_mapping" \
    "knowledgebase/proteomics_mapping" '.*'
  emit_metalink_selection required P2 variants \
    "${UNIPROT_BASE}/knowledgebase/variants" "knowledgebase/variants" '.*'

  log "enumerating GOA and semantic mapping files"
  emit_goa
  emit_metalink_selection required P2 semantic_rdf \
    "${UNIPROT_BASE}/rdf" "rdf" "${rdf_regex}"

  log "enumerating UniParc active and conditional XML"
  emit_metalink_selection required P3 uniparc_metadata \
    "${UNIPROT_BASE}/uniparc" "uniparc" '.*'
  emit_metalink_selection required P3 uniparc_active \
    "${UNIPROT_BASE}/uniparc/fasta/active" "uniparc/fasta/active" '.*'
  emit_metalink_selection conditional P4 uniparc_xml_all \
    "${UNIPROT_BASE}/uniparc/xml/all" "uniparc/xml/all" '.*' \
    'offline_UniParc_source_and_history_audit_only'

  write_final_manifest
}

main "$@"
