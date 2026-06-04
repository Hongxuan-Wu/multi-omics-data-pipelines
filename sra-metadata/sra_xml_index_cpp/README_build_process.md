# SRA XML Index 建立流程

本文档记录 `NCBI_SRA_Metadata_Full_20260516` 的 SRA XML 实体关系索引建立流程。

输入目录：

```text
/data/p252701008/datasets/SRA/NCBI_SRA_Metadata_Full_20260516
```

代码目录：

```text
/home/m252202014/SRA/code/sra_xml_index_cpp
```

大表输出目录：

```text
/data/shared
```

报告与 QC 目录：

```text
/home/m252202014/SRA/results/sra_xml_index_20260516
```

## 1. 当前已验证产物

当前已完成并验证的是 100,000 目录 stress pilot，不是全量 7,609,455 目录索引。

最终 Parquet 目录：

```text
/data/shared/sra_xml_index_20260516_cpp_stress_100000_fixed_study
```

目录 manifest：

```text
/data/shared/sra_xml_index_20260516_directory_manifest
```

100k QC：

```text
/home/m252202014/SRA/results/sra_xml_index_20260516/cpp_stress_100000_fixed_study_qc.md
/home/m252202014/SRA/results/sra_xml_index_20260516/cpp_stress_100000_fixed_study_qc.json
```

原 XML 回查验证：

```text
/home/m252202014/SRA/results/sra_xml_index_20260516/validate_against_xml_100k_sample1000.md
/home/m252202014/SRA/results/sra_xml_index_20260516/validate_against_xml_100k_sample1000.json
```

## 2. 模块说明

核心代码：

```text
sra_xml_indexer.cpp
```

作用：

- 读取目录 manifest 或原始根目录。
- 扫描每个 accession 目录下 XML 文件。
- 生成 TSV 中间结果。
- 抽取 entity、relation、core tables、sample attributes、path inventory、selected field-long。

目录 manifest：

```text
generate_directory_manifest.py
```

作用：

- 只扫描顶层 accession 目录。
- 生成稳定目录路径清单。
- 后续 C++ 解析只读 manifest，不再重复遍历 760 万目录。

并行运行：

```text
run_cpp_chunked_parallel.sh
```

作用：

- 按 manifest 行号切 chunk。
- 多 worker 并行运行 `sra_xml_indexer`。
- 每个 chunk 独立输出 TSV。
- 用 status 文件记录 chunk 成功或失败。

TSV 转 Parquet：

```text
convert_tsv_chunks_to_parquet.py
```

作用：

- 将多个 chunk 的 TSV 合并转换为 Parquet。
- 使用 DuckDB strict CSV reader。
- 默认不静默吞错。
- 每张表做 TSV 数据行数 vs Parquet 行数校验。
- `xml_path_inventory` 做跨 chunk 聚合。

索引 QC：

```text
evaluate_parquet_index.py
```

作用：

- 统计目录数、XML 文件数、实体数、关系数。
- 统计 sample attribute 和 selected field-long 行数。
- 统计 parse failure rate。
- 统计关系闭合率。
- 统计核心字段缺失率。
- 估算全量体积和耗时。

原 XML 回查验证：

```text
validate_against_xml.py
```

作用：

- 从 Parquet 随机抽样 XML。
- 回读 `file_index.file_path` 指向的原始 XML。
- 用 Python XML parser 独立抽取字段。
- 对比索引结果和原 XML。
- 分组输出准确率：
  - core fields
  - relation fields
  - BioSample/BioProject
  - sample attributes

检索使用说明：

```text
README_query_usage.md
```

作用：

- 说明如何用 DuckDB/Python 查询 Parquet。
- 给出 accession 查询、关系 join、sample attributes、path inventory、回源 XML 示例。

## 3. 输出表

每张表最终是一个 Parquet 目录，实际文件是 `data.parquet`。

```text
directory_index/data.parquet
file_index/data.parquet
entity_index/data.parquet
relation_index/data.parquet
core/run_core/data.parquet
core/experiment_core/data.parquet
core/sample_core/data.parquet
core/sample_attribute_core/data.parquet
core/study_core/data.parquet
core/submission_core/data.parquet
core/analysis_core/data.parquet
inventory/xml_path_inventory/data.parquet
fields/xml_field_long_selected/data.parquet
```

当前不默认生成：

```text
fields/xml_field_long_full_optional/
```

原因：

- 全量 XML 字段值长表体积和 IO 成本不可控。
- 当前默认产物是可回溯、可 join、可筛选的实体关系索引。

## 4. 100k stress pilot 建立过程

### 4.1 编译 C++

```bash
g++ -O3 -std=c++17 \
  /home/m252202014/SRA/code/sra_xml_index_cpp/sra_xml_indexer.cpp \
  -o /home/m252202014/SRA/code/sra_xml_index_cpp/sra_xml_indexer
```

### 4.2 生成 manifest

```bash
python3 /home/m252202014/SRA/code/sra_xml_index_cpp/generate_directory_manifest.py \
  --root /data/p252701008/datasets/SRA/NCBI_SRA_Metadata_Full_20260516 \
  --out /data/shared/sra_xml_index_20260516_directory_manifest/dirs_first_100000.txt \
  --limit 100000
```

100k manifest 实测：

```text
directory_count = 100000
elapsed_seconds = 37.4
prefix_counts = DRA 369; ERA 71787; SRA 27844
```

### 4.3 并行 C++ 解析

```bash
BASE_OUT=/data/shared/sra_xml_index_20260516_cpp_stress_100000_fixed_study_tsv_chunks \
LIMIT_TOTAL=100000 \
CHUNK_SIZE=500 \
CHUNK_TIMEOUT=900 \
WORKERS=16 \
MANIFEST=/data/shared/sra_xml_index_20260516_directory_manifest/dirs_first_100000.txt \
/home/m252202014/SRA/code/sra_xml_index_cpp/run_cpp_chunked_parallel.sh
```

100k 修正版实测：

```text
all chunks completed
failed_chunks.tsv 只有表头
sum_chunk_elapsed_seconds = 51333.37
```

说明：

- `CHUNK_SIZE=500` 是为了降低单 chunk 长尾失败成本。
- `WORKERS=16` 是当前验证过的稳妥并发。
- `CHUNK_TIMEOUT=900` 是为了容忍共享盘 IO 抖动。
- 如果全量跑，建议先做 1M stress pilot 再调整到 24 或 32 workers。

### 4.4 TSV 转 Parquet

服务器使用 `tss` conda 环境：

```bash
source /usr/local/anaconda3/etc/profile.d/conda.sh
conda activate tss
```

转换命令：

```bash
python /home/m252202014/SRA/code/sra_xml_index_cpp/convert_tsv_chunks_to_parquet.py \
  --chunks-root /data/shared/sra_xml_index_20260516_cpp_stress_100000_fixed_study_tsv_chunks \
  --parquet-root /data/shared/sra_xml_index_20260516_cpp_stress_100000_fixed_study \
  --overwrite \
  --threads 16
```

100k 转换结果：

```text
directory_index: 100000 rows
file_index: 270488 rows
entity_index: 1642770 rows
relation_index: 2853521 rows
run_core: 520233 rows
experiment_core: 494015 rows
sample_core: 517500 rows
sample_attribute_core: 7595144 rows
study_core: 9691 rows
submission_core: 99740 rows
analysis_core: 1591 rows
xml_field_long_selected: 19021798 rows
xml_path_inventory: 248 rows after aggregation
```

所有普通表均通过：

```text
TSV data rows == Parquet rows
```

转换耗时：

```text
elapsed_seconds = 984.1
```

### 4.5 Parquet QC

```bash
python /home/m252202014/SRA/code/sra_xml_index_cpp/evaluate_parquet_index.py \
  --parquet-root /data/shared/sra_xml_index_20260516_cpp_stress_100000_fixed_study \
  --chunks-root /data/shared/sra_xml_index_20260516_cpp_stress_100000_fixed_study_tsv_chunks \
  --out-json /home/m252202014/SRA/results/sra_xml_index_20260516/cpp_stress_100000_fixed_study_qc.json \
  --out-md /home/m252202014/SRA/results/sra_xml_index_20260516/cpp_stress_100000_fixed_study_qc.md
```

QC 摘要：

```text
Directories: 100000
XML files: 270488
Entities: 1642770
Relations: 2853521
Sample attribute rows: 7595144
Selected field-long rows: 19021798
Path inventory rows: 248
Parse failure rate: 0
Parquet bytes: 146328298
Estimated full Parquet bytes: 11134785988
```

核心字段缺失率重点：

```text
experiment_core.library_strategy/source/selection/platform/instrument_model = 0
sample_core.bio_sample_id = 0
sample_core.taxon_id = 0
study_core.study_type = 0
study_core.existing_study_type = 0
```

注意：

- 100k 子集里关系闭合率偏低是预期现象，因为目标 accession 可能不在 first-100k 目录中。
- 关系闭合率要等全量 manifest 和全量索引后才有完整解释力。

### 4.6 原 XML 回查验证

```bash
python /home/m252202014/SRA/code/sra_xml_index_cpp/validate_against_xml.py \
  --parquet-root /data/shared/sra_xml_index_20260516_cpp_stress_100000_fixed_study \
  --sample-size 1000 \
  --seed 20260604 \
  --out-json /home/m252202014/SRA/results/sra_xml_index_20260516/validate_against_xml_100k_sample1000.json \
  --out-md /home/m252202014/SRA/results/sra_xml_index_20260516/validate_against_xml_100k_sample1000.md
```

1000 XML 随机抽样回查结果：

```text
XML parse errors = 0
core_fields accuracy = 1.0
relation_fields accuracy = 1.0
biosample_bioproject accuracy = 1.0
sample_attributes accuracy = 1.0
```

验证阈值：

```text
core_fields >= 99.9%
relation_fields >= 99.9%
BioSample/BioProject >= 99.5%
sample attributes 记录差异，不作为默认硬失败项
```

当前 1000 抽样全部超过阈值。

## 5. 全量建立建议流程

不要直接从 100k 跳全量。建议执行：

### 5.1 1M stress pilot

目的：

- 暴露更长尾的 XML/IO 问题。
- 比较 16/24/32 worker 的吞吐。
- 更稳地估算全量时间和中间 TSV 体积。

示例：

```bash
python3 /home/m252202014/SRA/code/sra_xml_index_cpp/generate_directory_manifest.py \
  --root /data/p252701008/datasets/SRA/NCBI_SRA_Metadata_Full_20260516 \
  --out /data/shared/sra_xml_index_20260516_directory_manifest/dirs_first_1000000.txt \
  --limit 1000000

BASE_OUT=/data/shared/sra_xml_index_20260516_cpp_stress_1000000_tsv_chunks \
LIMIT_TOTAL=1000000 \
CHUNK_SIZE=500 \
CHUNK_TIMEOUT=900 \
WORKERS=16 \
MANIFEST=/data/shared/sra_xml_index_20260516_directory_manifest/dirs_first_1000000.txt \
/home/m252202014/SRA/code/sra_xml_index_cpp/run_cpp_chunked_parallel.sh
```

### 5.2 全量 manifest

全量 manifest 应该保留，后续所有解析只读这个 manifest。

```bash
python3 /home/m252202014/SRA/code/sra_xml_index_cpp/generate_directory_manifest.py \
  --root /data/p252701008/datasets/SRA/NCBI_SRA_Metadata_Full_20260516 \
  --out /data/shared/sra_xml_index_20260516_directory_manifest/dirs_full.txt \
  --limit 0
```

全量目录数应校验为：

```text
7609455
```

### 5.3 全量 C++ 解析

建议初始参数：

```bash
BASE_OUT=/data/shared/sra_xml_index_20260516_full_tsv_chunks \
LIMIT_TOTAL=7609455 \
CHUNK_SIZE=500 \
CHUNK_TIMEOUT=900 \
WORKERS=16 \
MANIFEST=/data/shared/sra_xml_index_20260516_directory_manifest/dirs_full.txt \
/home/m252202014/SRA/code/sra_xml_index_cpp/run_cpp_chunked_parallel.sh
```

如果 1M stress 证明 IO 稳定，可以尝试：

```text
WORKERS=24 或 WORKERS=32
```

但不建议未验证就直接 64 worker。大量小 XML 文件的瓶颈主要是共享盘 IO，不是 CPU。

### 5.4 全量 Parquet 转换

```bash
python /home/m252202014/SRA/code/sra_xml_index_cpp/convert_tsv_chunks_to_parquet.py \
  --chunks-root /data/shared/sra_xml_index_20260516_full_tsv_chunks \
  --parquet-root /data/shared/sra_xml_index_20260516_full \
  --overwrite \
  --threads 16
```

### 5.5 全量 QC

```bash
python /home/m252202014/SRA/code/sra_xml_index_cpp/evaluate_parquet_index.py \
  --parquet-root /data/shared/sra_xml_index_20260516_full \
  --chunks-root /data/shared/sra_xml_index_20260516_full_tsv_chunks \
  --out-json /home/m252202014/SRA/results/sra_xml_index_20260516/full_qc.json \
  --out-md /home/m252202014/SRA/results/sra_xml_index_20260516/full_qc.md
```

### 5.6 全量原 XML 回查验证

建议至少抽样 1000 XML：

```bash
python /home/m252202014/SRA/code/sra_xml_index_cpp/validate_against_xml.py \
  --parquet-root /data/shared/sra_xml_index_20260516_full \
  --sample-size 1000 \
  --seed 20260604 \
  --out-json /home/m252202014/SRA/results/sra_xml_index_20260516/full_validate_against_xml_sample1000.json \
  --out-md /home/m252202014/SRA/results/sra_xml_index_20260516/full_validate_against_xml_sample1000.md
```

如果要更严格：

```text
sample-size = 5000
```

## 6. 全量耗时和空间预估

基于 100k stress pilot 外推：

```text
manifest scan: about 0.8 h
C++ parsing with 16 workers: about 69 h
TSV to Parquet: about 21 h
QC and validation: about 1 h
total: about 4 days
```

保守预算：

```text
4-5 days
```

空间：

```text
final Parquet: about 11-12 GB
intermediate TSV chunks: about 300-320 GB
recommended free space: >= 350 GB
```

## 7. 中间文件清理原则

确认以下条件满足后，才清理 TSV chunks：

- Parquet 转换完成。
- `conversion_summary.json` 中所有普通表 `row_match = true`。
- `evaluate_parquet_index.py` QC 通过。
- `validate_against_xml.py` 抽样回查通过。

清理时不要直接永久删除。建议移动到：

```text
/data/shared/codex_delete/
```

例如：

```bash
trash=/data/shared/codex_delete/sra_xml_index_full_tsv_chunks_$(date +%Y%m%d_%H%M%S)
mkdir -p "$trash"
mv /data/shared/sra_xml_index_20260516_full_tsv_chunks "$trash/"
```

## 8. 已修复的问题

### 8.1 chunk 边界和输入稳定性

最初按根目录 iterator + start offset 做 chunk，会导致每个 chunk 重复扫描前面的目录，且受目录枚举长尾影响。现在改为 manifest 驱动：

- manifest 阶段一次性生成目录列表。
- C++ 解析阶段按 manifest 行号切片。
- `file_id` 由目录 accession 和文件名稳定生成。

### 8.2 `xml_path_inventory`

最初是占位结构，后来改为真实统计：

- `xml_kind`
- `entity_type`
- `field_path`
- `attribute_name`
- `value_kind`
- `occurrence_count`
- `non_empty_count`
- `example_value`
- `value_truncated`

### 8.3 TSV 转 Parquet 静默吞错

转换脚本使用 DuckDB strict reader，并对普通表强制校验：

```text
TSV data rows == Parquet rows
```

不一致则写 summary 并报错。

### 8.4 PLATFORM 泛化

不再只识别 `ILLUMINA`，而是读取 `EXPERIMENT/PLATFORM` 下第一个子标签作为 `platform`。

### 8.5 XML escape 和 whitespace

parser 解码常见 XML escape：

```text
&amp; &lt; &gt; &quot; &apos;
```

文本字段会压缩连续 whitespace。验证脚本也按同样规则归一化。

### 8.6 `study_type`

发现 `STUDY_TYPE` 多数是 attribute-only 节点。修复后：

- `existing_study_type` 显式保存 attribute。
- `study_type` 文本为空时回退到 `existing_study_type`。

100k 修正版中：

```text
study_core.study_type missing rate = 0
study_core.existing_study_type missing rate = 0
```

## 9. 全量前硬性检查

全量前建议确认：

- `/data/shared` 可用空间至少 350 GB。
- `conda run -n tss python -c "import duckdb"` 可用。
- 1M stress pilot 完成且无系统性 parser 错误。
- `validate_against_xml.py` 在 1M pilot 上通过。
- 不要在共享盘高峰期启动 64 worker。

