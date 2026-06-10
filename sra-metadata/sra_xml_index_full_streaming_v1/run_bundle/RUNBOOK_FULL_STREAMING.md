# SRA XML 全量索引运行包

This directory is a clean run bundle for the full `source_snapshot_id=20260516` SRA XML light index using the stable two-stage streaming finalizer.

## Directory Layout

```text
/home/m252202014/SRA/full_index_runs/20260516_full_streaming_v1/
  code/sra_xml_snapshot_index/       # copied code snapshot
  configs/full_streaming.env         # fixed run parameters
  logs/                              # command logs for this full run
  output_root -> /data3/.../full_runs/20260516_full_streaming_v1
```

The real Parquet output root is:

```text
/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1
```

## Current Status

This bundle is prepared only. The builder now accepts:

```text
--build-scope full
--manifest-subset-type full
```

Do not start the full run until the operator explicitly decides to launch Stage 1. The full mode means Stage 1 reads all first-level accession directories under `XML_ROOT`, sorts them deterministically, writes `directory_manifest.parquet` and `chunk_manifest.parquet`, then runs the existing chunk parser.

## Stage 1: Chunk Build

Stage 1 should generate the stable manifests, chunk outputs, chunk status, and failed chunk list.

Expected inputs:

```text
XML_ROOT=/data3/shared/sra/NCBI_SRA_Metadata_Full_20260516
SCHEMA=code/sra_xml_snapshot_index/schema/v1/schema.json
SOURCE_SNAPSHOT_ID=20260516
MANIFEST_SUBSET_TYPE=full
```

Expected intermediate outputs:

```text
output_root/manifest/directory_manifest.parquet
output_root/manifest/chunk_manifest.parquet
output_root/chunks/<chunk_id>.done/
output_root/chunks/<chunk_id>.done/chunk_status.json
output_root/chunk_status_summary.parquet
output_root/failed_chunks.tsv
```

Command template:

```bash
cd /home/m252202014/SRA/full_index_runs/20260516_full_streaming_v1
source configs/full_streaming.env

/usr/bin/time -v python3 "$CODE_ROOT/scripts/build_targeted_fixture_v1.py" \
  --xml-root "$XML_ROOT" \
  --output-root "$OUTPUT_ROOT" \
  --schema "$SCHEMA" \
  --source-snapshot-id "$SOURCE_SNAPSHOT_ID" \
  --build-scope "$BUILD_SCOPE" \
  --build-label "$BUILD_LABEL" \
  --manifest-subset-type "$MANIFEST_SUBSET_TYPE" \
  --chunk-size "$CHUNK_SIZE" \
  --threads "$THREADS" \
  --stage chunks \
  2>&1 | tee "$RUN_ROOT/logs/stage1_chunks_$(date +%Y%m%d_%H%M%S).log"
```

Use `--overwrite` only before the first real full run or after explicitly deciding to discard the current full output root.

## Monitoring During Stage 1

Start these monitors in separate terminals before launching Stage 1:

```bash
cd /home/m252202014/SRA/full_index_runs/20260516_full_streaming_v1
source configs/full_streaming.env

mkdir -p "$RUN_ROOT/logs"
iostat -xz 30 > "$RUN_ROOT/logs/iostat_stage1_$(date +%Y%m%d_%H%M%S).log"
```

```bash
cd /home/m252202014/SRA/full_index_runs/20260516_full_streaming_v1
source configs/full_streaming.env

vmstat 30 > "$RUN_ROOT/logs/vmstat_stage1_$(date +%Y%m%d_%H%M%S).log"
```

Monitor these during the run:

```bash
df -h /data3 "$OUTPUT_ROOT"
tail -n +1 "$OUTPUT_ROOT/failed_chunks.tsv" 2>/dev/null | head -20
find "$OUTPUT_ROOT/chunks" -maxdepth 1 -name '*.done' 2>/dev/null | wc -l
cat "$OUTPUT_ROOT/finalize_progress.json" 2>/dev/null || true
```

Required monitoring fields:

```text
I/O wait: vmstat wa column, iostat await/%util
Peak memory: /usr/bin/time -v Maximum resident set size
Disk remaining: df -h /data3 and df -h "$OUTPUT_ROOT"
Failed chunks: "$OUTPUT_ROOT/failed_chunks.tsv"
```

## Stage 2: Streaming Finalizer

Stage 2 must reuse `.done` chunks and must not rerun parser chunks.

Expected inputs:

```text
output_root/chunks/*.done/
output_root/manifest/directory_manifest.parquet
output_root/manifest/chunk_manifest.parquet
schema/v1/schema.json
```

Expected final outputs:

```text
output_root/build_manifest.parquet
output_root/directory_index.parquet
output_root/file_index.parquet
output_root/entity_record_index.parquet
output_root/entity_index.parquet
output_root/external_accession_index.parquet
output_root/relation_index.parquet
output_root/core/*.parquet
output_root/inventory/xml_path_inventory.parquet
output_root/qc/*.parquet
output_root/build_timing.json
```

Command:

```bash
cd /home/m252202014/SRA/full_index_runs/20260516_full_streaming_v1
source configs/full_streaming.env

/usr/bin/time -v python3 "$CODE_ROOT/scripts/finalize_stress_build.py" \
  --output-root "$OUTPUT_ROOT" \
  --schema "$SCHEMA" \
  --source-snapshot-id "$SOURCE_SNAPSHOT_ID" \
  --duckdb-memory-limit "$DUCKDB_MEMORY_LIMIT" \
  --duckdb-threads "$DUCKDB_THREADS" \
  --relation-batch-size "$RELATION_BATCH_SIZE" \
  2>&1 | tee "$RUN_ROOT/logs/stage2_finalize_$(date +%Y%m%d_%H%M%S).log"
```

## Stage 3: Schema Validation

```bash
cd /home/m252202014/SRA/full_index_runs/20260516_full_streaming_v1
source configs/full_streaming.env

python3 "$CODE_ROOT/scripts/validate_schema.py" \
  --schema "$SCHEMA" \
  --output-root "$OUTPUT_ROOT" \
  --check-values \
  2>&1 | tee "$RUN_ROOT/logs/stage3_schema_$(date +%Y%m%d_%H%M%S).log"
```

## Stage 4: XML Back-Check

```bash
cd /home/m252202014/SRA/full_index_runs/20260516_full_streaming_v1
source configs/full_streaming.env

python3 "$CODE_ROOT/scripts/validate_against_xml.py" \
  --parquet-root "$OUTPUT_ROOT" \
  --sample-size "$BACKCHECK_SAMPLE_SIZE" \
  --seed "$BACKCHECK_SEED" \
  --include-abnormal-cases \
  --out-json "$OUTPUT_ROOT/qc/xml_backcheck_full_${BACKCHECK_SAMPLE_SIZE}.json" \
  --out-md "$OUTPUT_ROOT/qc/xml_backcheck_full_${BACKCHECK_SAMPLE_SIZE}.md" \
  2>&1 | tee "$RUN_ROOT/logs/stage4_xml_backcheck_$(date +%Y%m%d_%H%M%S).log"
```

## Do Not Publish Yet

This run bundle writes to a user-owned full run output root. It does not update:

```text
/data3/shared/sra_xml_index/snapshot=20260516
/data3/shared/sra_xml_index/current
```

Publishing requires a separate, explicit step after full QC passes and `_FULL_QC_PASSED` is written.
