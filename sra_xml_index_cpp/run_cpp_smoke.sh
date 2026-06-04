#!/usr/bin/env bash
set -euo pipefail

ROOT=${ROOT:-/data/p252701008/datasets/SRA/NCBI_SRA_Metadata_Full_20260516}
CODE_ROOT=${CODE_ROOT:-/home/m252202014/SRA/code/sra_xml_index_cpp}
OUT=${OUT:-/home/m252202014/SRA/results/sra_xml_index_20260516/cpp_smoke_1000}
LIMIT_DIRS=${LIMIT_DIRS:-1000}

mkdir -p "$CODE_ROOT" "$OUT"
g++ -O3 -std=c++17 "$CODE_ROOT/sra_xml_indexer.cpp" -o "$CODE_ROOT/sra_xml_indexer"
"/usr/bin/time" -f 'wall_elapsed=%E' "$CODE_ROOT/sra_xml_indexer" "$ROOT" "$OUT" "$LIMIT_DIRS"

