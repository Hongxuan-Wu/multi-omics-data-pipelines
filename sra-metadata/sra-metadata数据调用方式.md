# SRA metadata 数据调用方式

当前推荐统一使用 DuckDB 读取 Parquet 索引。

## 1. 调用 SRA_Accessions 索引

4090 路径：

```text
/data/shared/sra_parquet
```

H100 整理路径：

```text
/data3/m252202014/NCBI_data/SRA/SRA_Accessions/index/sra_parquet
```

示例：

```python
import duckdb

root = "/data/shared/sra_parquet"
con = duckdb.connect()
con.execute("PRAGMA threads=16")

df = con.execute("""
SELECT Accession AS run_accession, Experiment, Sample, Study, BioSample, BioProject
FROM read_parquet(?)
WHERE Status = 'live'
  AND Visibility = 'public'
  AND TRY_CAST(Spots AS BIGINT) > 0
  AND TRY_CAST(Bases AS BIGINT) > 0
LIMIT 20
""", [f"{root}/sra_accessions_by_type/Type=RUN/*.parquet"]).fetchdf()
```

## 2. 调用 SRA XML full 索引

H100 路径：

```text
/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1
```

示例：

```python
import duckdb

root = "/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1"
con = duckdb.connect()
con.execute("PRAGMA threads=16")

sample = con.execute("""
SELECT sample_accession, biosample_accession, taxon_id, scientific_name
FROM read_parquet(?)
WHERE biosample_accession = ?
""", [f"{root}/core/sample_core.parquet", "SAMN00000000"]).fetchdf()
```

## 3. 调用原则

- 可下载性过滤优先用 `SRA_Accessions`。
- sample attributes、library strategy、platform 和 XML path inventory 优先用 XML full 索引。
- RefSeq-SRA 关联优先使用 BioSample。
- BioProject 只能作为项目级辅助字段。
