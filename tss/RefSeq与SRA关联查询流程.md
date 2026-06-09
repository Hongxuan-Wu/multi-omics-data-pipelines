# RefSeq 与 SRA 关联查询流程

本文档说明如何把 RefSeq 与 SRA 关联起来，用于筛选目标测序数据并下载。

## 1. 总体目标

目标是从 RefSeq 中确定目标物种、菌株、基因组集合，再通过 BioSample/BioProject/TaxID 找到对应的 SRA 测序数据，最后筛选出可下载、适合 TSS 或转录组分析的数据。

## 2. 输入索引

SRA_Accessions 索引：

```text
/data/shared/sra_parquet
/data3/m252202014/NCBI_data/SRA/SRA_Accessions/index/sra_parquet
```

SRA XML full 索引：

```text
/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1
```

RefSeq 原始输入：

```text
/data3/m252202014/NCBI_data/RefSeq/raw/assembly_summary_refseq.txt
```

RefSeq 目标表，待正式生成：

```text
refseq_assembly_core.parquet
```

## 3. SRA 侧筛选逻辑

先用 `SRA_Accessions` 做可下载性过滤：

```sql
SELECT Accession AS run_accession, Experiment, Sample, Study, BioSample, BioProject, Spots, Bases
FROM read_parquet('/data/shared/sra_parquet/sra_accessions_by_type/Type=RUN/*.parquet')
WHERE Status = 'live'
  AND Visibility = 'public'
  AND TRY_CAST(Spots AS BIGINT) > 0
  AND TRY_CAST(Bases AS BIGINT) > 0;
```

再用 XML 索引补充实验字段：

```sql
SELECT run_accession, experiment_accession, instrument_platform, instrument_model
FROM read_parquet('/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1/core/run_core.parquet');
```

样本字段来自：

```text
core/sample_core.parquet
core/sample_attribute_core.parquet
```

## 4. RefSeq 侧筛选逻辑

当前还没有生成 `refseq_assembly_core.parquet`。下一步应从 `assembly_summary_refseq.txt` 抽取并标准化字段：

```text
assembly_accession, bioproject, biosample, taxid, species_taxid,
organism_name, infraspecific_name, isolate, version_status,
assembly_level, genome_rep, ftp_path
```

RefSeq 侧生成核心表后，先筛选可用 assembly：

```sql
SELECT *
FROM read_parquet('refseq_assembly_core.parquet')
WHERE version_status = 'latest'
  AND assembly_level IN ('Complete Genome', 'Chromosome');
```

如果目标是某类物种或菌株，可继续按 `organism_name`、`taxid`、`species_taxid`、`strain_or_isolate` 过滤。

## 5. 关联顺序

第一层，按 BioSample 精确关联：

```sql
SELECT
  r.assembly_accession,
  r.organism_name,
  r.biosample,
  s.sample_accession,
  s.biosample_accession,
  s.tax_id,
  s.scientific_name
FROM read_parquet('refseq_assembly_core.parquet') r
JOIN read_parquet('/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1/core/sample_core.parquet') s
  ON r.biosample = s.biosample_accession;
```

第二层，用 SRA_Accessions 找 RUN：

```sql
SELECT
  a.Accession AS run_accession,
  a.Experiment,
  a.Sample,
  a.Study,
  a.BioSample,
  a.BioProject
FROM read_parquet('/data/shared/sra_parquet/sra_accessions_by_type/Type=RUN/*.parquet') a
WHERE a.BioSample IN (
  SELECT biosample
  FROM read_parquet('refseq_assembly_core.parquet')
)
  AND a.Status = 'live'
  AND a.Visibility = 'public'
  AND TRY_CAST(a.Spots AS BIGINT) > 0
  AND TRY_CAST(a.Bases AS BIGINT) > 0;
```

第三层，用 XML 的 sample attributes 和 experiment core 做实验类型过滤。

## 6. 目标数据筛选

TSS 或转录组相关数据应优先保留：

- RNA-Seq / transcriptomic library。
- library strategy 与转录组相关，如 `RNA-Seq`。
- 有明确 platform、layout、sample organism、taxon。
- RUN 可下载，即 `live/public/Spots>0/Bases>0`。

应排除：

- 纯 WGS、Amplicon、Metagenomic 等与目标不符的数据。
- controlled_access 或非 public 数据。
- Spots/Bases 为 0 或缺失且无法确认的数据。
- 仅 BioProject 层面匹配但 BioSample 不匹配的数据，除非作为候选集人工复核。

## 7. 下载入口

最终输出应生成待下载 RUN 列表：

```text
selected_sra_runs.tsv
```

建议字段：

```text
run_accession
experiment_accession
sample_accession
study_accession
biosample
bioproject
assembly_accession
taxid
organism_name
library_strategy
library_source
library_selection
instrument_platform
spots
bases
download_reason
qc_flags
```

后续下载可用 SRA Toolkit、prefetch、fasterq-dump 或 NCBI/ENA 下载链接完成。下载前必须保留筛选 SQL、索引版本和快照日期。
