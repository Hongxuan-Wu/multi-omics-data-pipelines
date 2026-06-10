# SRA_Accessions 索引构建与使用

本文档说明如何从 NCBI `SRA_Accessions` 原始 TSV 构建 Parquet 索引，以及如何查询该索引。

## 1. 数据来源

4090 原始 SRA 数据目录：

```text
/data/shared/SRA
```

原始 `SRA_Accessions` 文件来自 NCBI SRA metadata full snapshot：

```text
/data/shared/SRA/NCBI_SRA_Metadata_Full_20260516/SRA_Accessions
```

早期文档中也出现过如下路径：

```text
/data/p252701008/datasets/SRA/NCBI_SRA_Metadata_Full_20260516/SRA_Accessions
```

当前整理后的 H100 入口为：

```text
/data3/m252202014/NCBI_data/SRA/SRA_Accessions/raw/SRA_Accessions
```

## 2. 索引输出位置

4090 已构建索引：

```text
/data/shared/sra_parquet
```

H100 整理目录中的目标位置：

```text
/data3/m252202014/NCBI_data/SRA/SRA_Accessions/index/sra_parquet
```

当前同步说明：H100 目录由 4090 的 `/data/shared/sra_parquet` 复制得到，已完成文件数和总大小校验。4090 源目录与 H100 整理目录均为 `21` 个文件、`8.2G`。

## 3. 输出目录结构

```text
sra_parquet/
├── README.md
├── convert_full.log
├── sra_accessions_by_type/
│   ├── Type=RUN/data_0.parquet
│   ├── Type=EXPERIMENT/data_0.parquet
│   ├── Type=SAMPLE/data_0.parquet
│   ├── Type=STUDY/data_0.parquet
│   ├── Type=SUBMISSION/data_0.parquet
│   └── Type=ANALYSIS/data_0.parquet
├── derived/
│   ├── sra_run_live_public_nonzero.parquet
│   └── sra_run_live_public_nonzero_typed.parquet
├── pilot/
└── qc/
```

主索引按 `Type` 做 Hive 分区。派生表 `sra_run_live_public_nonzero*` 是常用 RUN 筛选结果，保留 `Status=live`、`Visibility=public`、`Spots > 0`、`Bases > 0` 的 RUN。

## 4. 构建代码

代码目录：

```text
sra-metadata/sra_accessions_audit_full_20260601/code
```

关键脚本：

```text
convert_sra_accessions_to_parquet.py          # SRA_Accessions TSV -> Parquet index
sra_parquet_relation_stats_with_source_check.py
run_sra_accessions_parallel.sh
sra_accessions_chunk_audit.cpp
merge_sra_accessions_chunks.py
```

`convert_sra_accessions_to_parquet.py` 的输入是原始 `SRA_Accessions` TSV，输出是 Parquet dataset、derived 表和 QC 表。

典型命令：

```bash
python /home/m252202014/SRA/code/convert_sra_accessions_to_parquet.py \
  --source /data/shared/SRA/NCBI_SRA_Metadata_Full_20260516/SRA_Accessions \
  --output-root /data/shared/sra_parquet \
  --threads 16
```

本仓库中的对应代码路径：

```text
sra-metadata/sra_accessions_audit_full_20260601/code/convert_sra_accessions_to_parquet.py
```

## 5. 主要字段

`SRA_Accessions` 共 20 列：

```text
Accession, Submission, Status, Updated, Published, Received, Type, Center,
Visibility, Alias, Experiment, Sample, Study, Loaded, Spots, Bases,
Md5sum, BioSample, BioProject, ReplacedBy
```

重要字段解释：

- `Accession`：实体 accession，前缀可粗略区分 SRR/SRX/SRS/SRP/SRA 等层级。
- `Type`：实体类型，包括 `RUN`、`EXPERIMENT`、`SAMPLE`、`STUDY`、`SUBMISSION`、`ANALYSIS`。
- `Status`：状态，常用有效条件是 `live`。
- `Visibility`：可见性，常用有效条件是 `public`。
- `Experiment`、`Sample`、`Study`：SRA 内部层级关系。
- `BioSample`、`BioProject`：跨 NCBI 数据库关联字段，后续连接 RefSeq 时优先使用 BioSample。
- `Spots`、`Bases`：RUN 规模字段，筛选可用测序数据时应大于 0。

## 6. 基础查询

推荐 DuckDB：

```python
import duckdb

root = "/data/shared/sra_parquet"
con = duckdb.connect()
con.execute("PRAGMA threads=16")

rows = con.execute("""
SELECT Accession, Experiment, Sample, Study, BioSample, BioProject, Spots, Bases
FROM read_parquet(?)
WHERE Status = 'live'
  AND Visibility = 'public'
  AND TRY_CAST(Spots AS BIGINT) > 0
  AND TRY_CAST(Bases AS BIGINT) > 0
LIMIT 20
""", [f"{root}/sra_accessions_by_type/Type=RUN/*.parquet"]).fetchall()
```

按 BioSample 查可下载 RUN：

```sql
SELECT Accession AS run_accession, Experiment, Sample, Study, BioSample, BioProject
FROM read_parquet('/data/shared/sra_parquet/sra_accessions_by_type/Type=RUN/*.parquet')
WHERE BioSample = 'SAMN00000000'
  AND Status = 'live'
  AND Visibility = 'public'
  AND TRY_CAST(Spots AS BIGINT) > 0
  AND TRY_CAST(Bases AS BIGINT) > 0;
```

## 7. QC 重点

构建完成后至少校验：

- 总行数是否为 `148,211,048`。
- 六类 `Type` 的行数是否与 QC 表一致。
- `RUN live public nonzero` 派生表是否可读。
- `Spots`、`Bases` 是否用 `TRY_CAST` 做数值判断。
- 不要只按 accession 前缀推断实体类型，正式查询应使用 `Type` 字段。
