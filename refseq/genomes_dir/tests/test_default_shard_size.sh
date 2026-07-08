#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source_script="${repo_root}/refseq/genomes_dir/download_refseq_genomes_api.sh"

actual="$(
  awk -F '=' '
    $1 == "SHARD_SIZE" {
      gsub(/[[:space:]]+/, "", $2)
      print $2
      exit
    }
  ' "${source_script}"
)"

if [[ "${actual}" != "5000" ]]; then
  printf 'expected default SHARD_SIZE=5000, got %s\n' "${actual}" >&2
  exit 1
fi
