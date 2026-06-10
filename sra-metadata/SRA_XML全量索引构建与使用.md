# SRA XML 全量索引构建与使用

本文档说明 H100 上最终使用的 SRA XML full streaming v1 方案。当前主线不再使用旧的 4090 C++ 100k stress 版本。

## 1. 数据来源

H100 原始 XML 快照：

```text
/data3/shared/sra/NCBI_SRA_Metadata_Full_20260516
```

整理后的原始数据入口：

```text
/data3/m252202014/NCBI_data/SRA/XML_Metadata/raw/NCBI_SRA_Metadata_Full_20260516
```

快照编号固定：

```text
source_snapshot_id=20260516
```

`source_snapshot_id` 表示真实 NCBI 快照日期，不因 smoke、pilot、stress、full 改名。

## 2. 代码位置

H100 运行代码包：

```text
/home/m252202014/SRA/full_index_runs/20260516_full_streaming_v1
```

本仓库保存的代码副本：

```text
sra-metadata/sra_xml_index_full_streaming_v1
```

关键脚本：

```text
scripts/build_targeted_fixture_v1.py      # 第一阶段：manifest + chunk parser + chunk_status
scripts/finalize_stress_build.py          # 第二阶段：compact + entity/relation rebuild + QC
scripts/validate_schema.py                # schema 校验
scripts/validate_against_xml.py           # 回源 XML 抽样校验
schema/v1/schema.json                     # 输出 schema contract
```

## 3. 输出索引位置

H100 full 输出根目录：

```text
/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1
```

整理后的入口：

```text
/data3/m252202014/NCBI_data/SRA/XML_Metadata/index/20260516_full_streaming_v1
```

## 4. 输出目录结构

```text
20260516_full_streaming_v1/
├── build_manifest.parquet
├── directory_index.parquet
├── file_index.parquet
├── entity_record_index.parquet
├── entity_index.parquet
├── external_accession_index.parquet
├── relation_index.parquet
├── chunk_status_summary.parquet
├── failed_chunks.tsv
├── manifest/
│   ├── directory_manifest.parquet
│   └── chunk_manifest.parquet
├── core/
│   ├── run_core_raw.parquet
│   ├── experiment_core_raw.parquet
│   ├── sample_core_raw.parquet
│   ├── study_core_raw.parquet
│   ├── run_core.parquet
│   ├── experiment_core.parquet
│   ├── sample_core.parquet
│   ├── study_core.parquet
│   └── sample_attribute_core.parquet
├── inventory/
│   └── xml_path_inventory.parquet
├── qc/
│   ├── parse_qc_summary.parquet
│   ├── entity_qc_summary.parquet
│   ├── relation_closure_qc.parquet
│   ├── core_missingness_qc.parquet
│   ├── core_conflict_qc.parquet
│   ├── directory_file_consistency_qc.parquet
│   └── xml_backcheck_*.json
└── chunks/
    └── chunk_*.done/
```

## 5. 构建流程

全量构建拆成两个阶段。

第一阶段只负责 chunk 产物：

```text
manifest -> chunk_manifest -> chunk parser -> chunk_status.json -> failed_chunks.tsv -> chunks/*.done
```

第二阶段统一 finalizer：

```text
compact chunk tables -> rebuild entity_index -> rebuild relation_index
-> rebuild relation_closure_qc -> validate_schema.py -> validate_against_xml.py
-> update build_manifest
```

这样设计的原因是：如果全量解析中断，只需要根据 `failed_chunks.tsv` 和 `chunks/*.done` 重跑失败或缺失 chunk；final 阶段也可以从已经完成的 chunk 重新 compact，不需要重跑 parser。

## 6. full 构建结果

已完成 full run 的关键规模：

```text
directory_index              7,609,455
file_index                  20,541,383
entity_record_index        131,929,436
entity_index               131,929,435
external_accession_index   106,851,200
relation_index             228,660,216
sample_attribute_core      623,710,941
```

全量验证采用目录级抽样和 abnormal/error 文件反向校验。强验证结果文件：

```text
/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1/qc/xml_backcheck_full_5000dirs_plus5000abnormal_fixed_20260608_231005.json
```

## 7. 基础查询

推荐 DuckDB：

```python
import duckdb

root = "/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1"
con = duckdb.connect()
con.execute("PRAGMA threads=16")

run = con.execute("""
SELECT *
FROM read_parquet(?)
WHERE run_accession = ?
""", [f"{root}/core/run_core.parquet", "SRR000001"]).fetchdf()
```

按 BioSample 查 SAMPLE：

```sql
SELECT sample_accession, biosample_accession, taxon_id, scientific_name
FROM read_parquet('/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1/core/sample_core.parquet')
WHERE biosample_accession = 'SAMN00000000';
```

查 RUN 到 SAMPLE/STUDY 关系：

```sql
SELECT src_entity_type, src_entity_accession, relation_type, dst_entity_type, dst_entity_accession
FROM read_parquet('/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1/relation_index.parquet')
WHERE src_entity_accession = 'SRR000001';
```

查 sample attributes：

```sql
SELECT sample_accession, attribute_name, attribute_value
FROM read_parquet('/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1/core/sample_attribute_core.parquet')
WHERE sample_accession = 'SRS000001';
```

## 8. 与 SRA_Accessions 的互补关系

- 用 `SRA_Accessions` 快速筛选 `live/public/nonzero` RUN。
- 用 XML 索引补充文库策略、平台、sample attributes、BioSample/BioProject/Taxon 和实体关系。
- 两者可通过 `RUN accession`、`Experiment`、`Sample`、`Study`、`BioSample`、`BioProject` 互相校验。

正式分析中，不要只依赖一个索引。需要下载数据时，通常先用 `SRA_Accessions` 做可下载性过滤，再用 XML 索引补充生物学和实验设计字段。
