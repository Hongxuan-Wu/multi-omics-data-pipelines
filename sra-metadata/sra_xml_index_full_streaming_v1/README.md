# SRA XML 快照轻量索引

本项目在 H100 上把 NCBI SRA XML 快照构建成可恢复、可校验、可回源审计的轻量 Parquet 索引。当前主规范是 `source_snapshot_id=20260516`，代码放在用户目录，数据和构建结果放在 `/data3`。

## 固定路径

- 代码仓库：`/home/m252202014/SRA`
- 项目目录：`/home/m252202014/SRA/projects/sra_xml_snapshot_index`
- 输入 XML 快照：`/data3/shared/sra/NCBI_SRA_Metadata_Full_20260516`
- 当前可写 build 根目录：`/data3/m252202014/SRA/outputs/sra_xml_index/builds/20260516`
- 共享正式 snapshot 目标：`/data3/shared/sra_xml_index/snapshot=20260516`
- 共享 current 软链目标：`/data3/shared/sra_xml_index/current`

代码不得放到 `/data3/shared`。`/data3/shared` 只用于共享输入、正式索引和 current 软链。

## 整体数据流

```text
XML snapshot directories
  -> directory_manifest.parquet
  -> chunk_manifest.parquet
  -> chunks/<chunk_id>.done/*.parquet + chunk_status.json
  -> finalizer compact/rebuild
  -> final Parquet tables
  -> schema validation
  -> XML back-check
  -> build_manifest status
  -> optional formal snapshot publish
```

构建分两步执行。

1. `build_targeted_fixture_v1.py` 只负责稳定 manifest、chunk parser、chunk 状态和 failed chunk 列表。
2. `finalize_stress_build.py` 统一负责 final compact、全局 `entity_index`、全局 `relation_index`、关系闭合 QC 和 `build_manifest` 终态。

不要在 chunk builder 里重新实现 final 合并逻辑。后续 targeted、1k smoke、100k pilot、1M stress、full 都应复用同一个 finalizer。

## 主要脚本职责

| 文件 | 任务 | 输入 | 输出 |
| --- | --- | --- | --- |
| `scripts/build_targeted_fixture_v1.py` | 生成 manifest、分 chunk 解析 XML、写 chunk 状态 | XML 根目录、fixture 或采样参数、schema contract | `manifest/*.parquet`、`chunks/*.done/`、`chunk_status_summary.parquet`、`failed_chunks.tsv`、`build_manifest.parquet` |
| `scripts/finalize_stress_build.py` | 从已完成 chunk 统一 compact 并重建 final 全局表 | build `output_root` 下的 `chunks/*.done`、schema contract | final Parquet 表、`qc/relation_closure_qc.parquet`、`build_timing.json`、更新后的 `build_manifest.parquet` |
| `scripts/validate_schema.py` | 校验 final 输出是否符合 `schema/v1/schema.json` | schema contract、build `output_root` | 命令退出码；失败时打印缺表、字段、类型、枚举错误 |
| `scripts/validate_against_xml.py` | 抽样回源 XML 校验索引准确率 | final Parquet build、原 XML 路径来自 `file_index` | `qc/xml_backcheck_*.json`、`qc/xml_backcheck_*.md` |
| `schema/v1/schema.json` | 冻结字段、类型、nullable、枚举和输出路径 | 手工维护 | schema validation 和 writer 的统一契约 |
| `fixtures/targeted_dirs.tsv` | targeted fixture 清单 | 手工维护 | targeted 构建的目录输入 |
| `docs/QUERY_USAGE.md` | 查询示例 | final Parquet 索引 | DuckDB 查询方式 |

## 输入与中间产物

### 原始输入

- XML 目录树：`--xml-root /data3/shared/sra/NCBI_SRA_Metadata_Full_20260516`
- Schema contract：`--schema schema/v1/schema.json`
- targeted fixture：`fixtures/targeted_dirs.tsv`
- build 参数：`source_snapshot_id`、`build_scope`、`build_label`、`manifest_subset_type`、`sample_size`、`chunk_size`、`threads`

`source_snapshot_id` 必须保持真实快照日期，例如 `20260516`。不要写成 `20260516_smoke_1k`。

### Manifest 产物

- `manifest/directory_manifest.parquet`
- `manifest/chunk_manifest.parquet`

`directory_manifest.parquet` 按 `relative_directory_path` 稳定排序，并保存 `manifest_row_id`。`chunk_manifest.parquet` 是稳定分块计划，只包含：

```text
chunk_id, start_row, row_count, manifest_row_id_start, manifest_row_id_end, expected_directory_count
```

rerun 必须复用旧 manifest，不应修改稳定 chunk 计划。

### Chunk 产物

每个成功 chunk 写入：

```text
chunks/<chunk_id>.done/
  chunk_status.json
  directory_index.parquet
  file_index.parquet
  entity_record_index.parquet
  external_accession_index.parquet
  relation_index.parquet
  core/*.parquet
  inventory/xml_path_inventory.parquet
  qc/*.parquet
```

`chunk_status.json` 记录 `chunk_id`、行范围、起止时间、退出码、parser/schema 版本、输入 manifest hash、输出表、逐表行数、warning/error 数量。

`failed_chunks.tsv` 永远生成。无失败时只有 header。

## Final 输出

finalizer 成功后，每个 build 根目录必须包含：

```text
build_manifest.parquet
manifest/directory_manifest.parquet
manifest/chunk_manifest.parquet
chunk_status_summary.parquet
failed_chunks.tsv
directory_index.parquet
file_index.parquet
entity_record_index.parquet
entity_index.parquet
external_accession_index.parquet
relation_index.parquet
core/run_core_raw.parquet
core/experiment_core_raw.parquet
core/sample_core_raw.parquet
core/study_core_raw.parquet
core/run_core.parquet
core/experiment_core.parquet
core/sample_core.parquet
core/study_core.parquet
core/sample_attribute_core.parquet
inventory/xml_path_inventory.parquet
qc/parse_qc_summary.parquet
qc/entity_qc_summary.parquet
qc/relation_closure_qc.parquet
qc/core_missingness_qc.parquet
qc/core_conflict_qc.parquet
qc/directory_file_consistency_qc.parquet
```

第一版暂缓 `submission_core_raw`、`analysis_core_raw`、`submission_core`、`analysis_core`、`xml_field_long_selected`、`xml_field_long_full`。

## 常用运行命令

先进入项目目录：

```bash
cd /home/m252202014/SRA/projects/sra_xml_snapshot_index
```

### targeted fixture

```bash
python3 scripts/build_targeted_fixture_v1.py \
  --xml-root /data3/shared/sra/NCBI_SRA_Metadata_Full_20260516 \
  --output-root /data3/m252202014/SRA/outputs/sra_xml_index/builds/20260516/targeted_fixture_v1 \
  --build-scope fixture \
  --build-label targeted_fixture_v1 \
  --manifest-subset-type targeted \
  --chunk-size 1000 \
  --threads 64 \
  --stage chunks \
  --overwrite

python3 scripts/finalize_stress_build.py \
  --output-root /data3/m252202014/SRA/outputs/sra_xml_index/builds/20260516/targeted_fixture_v1 \
  --schema schema/v1/schema.json \
  --source-snapshot-id 20260516
```

### 1k deterministic smoke

```bash
python3 scripts/build_targeted_fixture_v1.py \
  --xml-root /data3/shared/sra/NCBI_SRA_Metadata_Full_20260516 \
  --output-root /data3/m252202014/SRA/outputs/sra_xml_index/builds/20260516/smoke_1k \
  --build-scope smoke \
  --build-label smoke_1k \
  --manifest-subset-type deterministic_random \
  --sample-size 1000 \
  --seed 20260608 \
  --chunk-size 1000 \
  --threads 64 \
  --stage chunks \
  --overwrite

python3 scripts/finalize_stress_build.py \
  --output-root /data3/m252202014/SRA/outputs/sra_xml_index/builds/20260516/smoke_1k \
  --schema schema/v1/schema.json \
  --source-snapshot-id 20260516
```

### 100k prefix-stratified pilot

```bash
python3 scripts/build_targeted_fixture_v1.py \
  --xml-root /data3/shared/sra/NCBI_SRA_Metadata_Full_20260516 \
  --output-root /data3/m252202014/SRA/outputs/sra_xml_index/builds/20260516/pilot_100k \
  --build-scope pilot \
  --build-label pilot_100k \
  --manifest-subset-type prefix_stratified \
  --sample-size 100000 \
  --seed 20260608 \
  --chunk-size 5000 \
  --threads 64 \
  --stage chunks \
  --overwrite

python3 scripts/finalize_stress_build.py \
  --output-root /data3/m252202014/SRA/outputs/sra_xml_index/builds/20260516/pilot_100k \
  --schema schema/v1/schema.json \
  --source-snapshot-id 20260516
```

### 1M stress mixed

```bash
python3 scripts/build_targeted_fixture_v1.py \
  --xml-root /data3/shared/sra/NCBI_SRA_Metadata_Full_20260516 \
  --output-root /data3/m252202014/SRA/outputs/sra_xml_index/builds/20260516/stress_1m \
  --build-scope stress \
  --build-label stress_1m \
  --manifest-subset-type stress_mixed \
  --sample-size 1000000 \
  --seed 20260608 \
  --chunk-size 5000 \
  --threads 64 \
  --stage chunks \
  --overwrite

python3 scripts/finalize_stress_build.py \
  --output-root /data3/m252202014/SRA/outputs/sra_xml_index/builds/20260516/stress_1m \
  --schema schema/v1/schema.json \
  --source-snapshot-id 20260516 \
  --duckdb-memory-limit 1500GB \
  --duckdb-threads 32 \
  --relation-batch-size 100000
```

full 默认也从 `threads=64` 开始，但必须根据 1M stress 的 I/O wait、失败率和吞吐决定是否降到 32 或 16。

## 校验命令

### Schema validation

```bash
python3 scripts/validate_schema.py \
  --schema schema/v1/schema.json \
  --output-root /data3/m252202014/SRA/outputs/sra_xml_index/builds/20260516/stress_1m \
  --check-values
```

### XML back-check

targeted fixture 应全量或高比例回查。1M stress 和 full 使用分层随机加异常用例：

```bash
python3 scripts/validate_against_xml.py \
  --parquet-root /data3/m252202014/SRA/outputs/sra_xml_index/builds/20260516/stress_1m \
  --sample-size 3000 \
  --seed 20260608 \
  --include-abnormal-cases \
  --out-json /data3/m252202014/SRA/outputs/sra_xml_index/builds/20260516/stress_1m/qc/xml_backcheck_3000.json \
  --out-md /data3/m252202014/SRA/outputs/sra_xml_index/builds/20260516/stress_1m/qc/xml_backcheck_3000.md
```

准确率定义固定为：

```text
accuracy = exact_match_pass_count / checked_item_count
```

失败原因枚举固定为：

```text
parser_wrong, index_join_wrong, normalization_difference, ambiguous_source, missing_in_xml_because_path_absent
```

## Resume 与失败处理

- chunk builder 输出的 `manifest/directory_manifest.parquet` 和 `manifest/chunk_manifest.parquet` 是稳定计划。
- `chunks/<chunk_id>.done` 代表该 chunk 完成，运行状态以 `chunk_status.json` 为准。
- `failed_chunks.tsv` 总是存在，监控和 rerun 脚本不需要处理文件缺失分支。
- finalizer 只读取 `.done` chunk，并校验 compact 后 final 表行数等于所有成功 chunk 对应表行数之和。
- finalizer 失败时不得更新 `build_manifest` 为 `succeeded`，不得发布 current。
- `tmp/`、`chunks/`、`final/` 必须在同一个 `output_root` 下，避免 atomic rename 跨文件系统退化成 copy。

## 发布规则

试运行 build 放在：

```text
/data3/m252202014/SRA/outputs/sra_xml_index/builds/20260516/<build_label>/
```

正式 full 通过 schema validation、QC 和 XML back-check 后，才允许写入：

```text
/data3/shared/sra_xml_index/snapshot=20260516/
```

只有正式 full 目录写入 `_FULL_QC_PASSED` 后，才允许更新 current：

```bash
cd /data3/shared/sra_xml_index
ln -sfn snapshot=20260516 current_tmp
mv -T current_tmp current
```

## 已知边界

- 当前 Python v1 链路已经覆盖 targeted、1k smoke、100k pilot、1M stress。
- `selected_field_long`、submission core、analysis core 暂缓。
- 当前 `scripts/` 只保留 full 实际运行用到的 4 个脚本：chunk builder、streaming finalizer、schema validation、XML back-check。
- full 还未发布到 `/data3/shared/sra_xml_index/snapshot=20260516/`，current 不应更新。
