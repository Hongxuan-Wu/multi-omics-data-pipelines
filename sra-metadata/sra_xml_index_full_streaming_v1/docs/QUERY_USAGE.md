# SRA XML Parquet 索引使用说明

本目录是 `NCBI_SRA_Metadata_Full_20260516` 的 100,000 目录 stress pilot 索引结果，不是全量 7,609,455 目录结果。它用于验证结构、检索方式、字段抽取和性能。

数据目录：

```text
/data/shared/sra_xml_index_20260516_cpp_stress_100000_fixed_study
```

## 1. 表结构

每张表都是一个目录，实际文件为 `data.parquet`。

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

核心原则：

- `directory_index` 保存顶层 accession 目录和目录路径。
- `file_index` 保存 XML 文件路径和解析状态。
- 其他大表只保存 `file_id`，需要回源 XML 时再 join `file_index`。
- `relation_index` 保存实体之间的边，例如 `RUN -> EXPERIMENT`、`EXPERIMENT -> SAMPLE`、`EXPERIMENT -> STUDY`。
- `xml_path_inventory` 是字段路径 inventory，不保存全量字段值。
- `xml_field_long_selected` 只保存白名单字段值，不是全 XML 暴力长表。

## 2. 推荐使用 DuckDB

服务器上可用：

```bash
source /usr/local/anaconda3/etc/profile.d/conda.sh
conda activate tss
python
```

Python 示例：

```python
import duckdb

root = "/data/shared/sra_xml_index_20260516_cpp_stress_100000_fixed_study"
con = duckdb.connect()

run_core = f"{root}/core/run_core/data.parquet"
rows = con.execute(f"""
    SELECT *
    FROM read_parquet('{run_core}')
    LIMIT 5
""").fetchdf()

print(rows)
```

也可以直接用 DuckDB SQL：

```python
con.execute(f"""
    SELECT COUNT(*) AS n
    FROM read_parquet('{root}/core/sample_core/data.parquet')
""").fetchall()
```

## 3. 常用检索

### 3.1 按 accession 查实体

```python
acc = "ERR000001"

entity = con.execute(f"""
    SELECT *
    FROM read_parquet('{root}/entity_index/data.parquet')
    WHERE entity_accession = ?
""", [acc]).fetchdf()

print(entity)
```

### 3.2 查 RUN 的核心字段

```python
run_acc = "ERR000001"

run = con.execute(f"""
    SELECT *
    FROM read_parquet('{root}/core/run_core/data.parquet')
    WHERE run_accession = ?
""", [run_acc]).fetchdf()

print(run)
```

### 3.3 RUN -> EXPERIMENT -> SAMPLE -> STUDY

```python
run_acc = "ERR000001"

rows = con.execute(f"""
    WITH run AS (
      SELECT *
      FROM read_parquet('{root}/core/run_core/data.parquet')
      WHERE run_accession = ?
    )
    SELECT
      r.run_accession,
      r.experiment_accession,
      e.sample_accession,
      e.study_accession,
      s.bio_sample_id,
      s.taxon_id,
      s.scientific_name,
      st.bioproject_id,
      st.study_title
    FROM run r
    LEFT JOIN read_parquet('{root}/core/experiment_core/data.parquet') e
      ON r.experiment_accession = e.experiment_accession
    LEFT JOIN read_parquet('{root}/core/sample_core/data.parquet') s
      ON e.sample_accession = s.sample_accession
    LEFT JOIN read_parquet('{root}/core/study_core/data.parquet') st
      ON e.study_accession = st.study_accession
""", [run_acc]).fetchdf()

print(rows)
```

### 3.4 按 BioSample 查 SAMPLE

```python
biosample = "SAMEA000001"

rows = con.execute(f"""
    SELECT *
    FROM read_parquet('{root}/core/sample_core/data.parquet')
    WHERE bio_sample_id = ?
""", [biosample]).fetchdf()

print(rows)
```

### 3.5 查 SAMPLE_ATTRIBUTE

例如查样本属性 tag 或 value：

```python
rows = con.execute(f"""
    SELECT sample_accession, bio_sample_id, tag, value
    FROM read_parquet('{root}/core/sample_attribute_core/data.parquet')
    WHERE lower(tag) LIKE '%tissue%'
       OR lower(value) LIKE '%liver%'
    LIMIT 100
""").fetchdf()

print(rows)
```

### 3.6 按实验平台/文库策略筛选

```python
rows = con.execute(f"""
    SELECT
      experiment_accession,
      study_accession,
      sample_accession,
      library_strategy,
      library_source,
      library_selection,
      platform,
      instrument_model
    FROM read_parquet('{root}/core/experiment_core/data.parquet')
    WHERE platform = 'ILLUMINA'
      AND library_strategy = 'RNA-Seq'
    LIMIT 100
""").fetchdf()

print(rows)
```

### 3.7 查字段路径 inventory

先看某类 XML/实体有哪些字段路径：

```python
rows = con.execute(f"""
    SELECT
      xml_kind,
      entity_type,
      field_path,
      attribute_name,
      value_kind,
      occurrence_count,
      non_empty_count,
      example_value
    FROM read_parquet('{root}/inventory/xml_path_inventory/data.parquet')
    WHERE entity_type = 'SAMPLE'
    ORDER BY occurrence_count DESC
    LIMIT 100
""").fetchdf()

print(rows)
```

### 3.8 查白名单字段长表

适合找标题、摘要、平台、Taxon、BioSample、BioProject、样本属性等白名单字段。

```python
rows = con.execute(f"""
    SELECT
      entity_accession,
      entity_type,
      field_name,
      field_path,
      value
    FROM read_parquet('{root}/fields/xml_field_long_selected/data.parquet')
    WHERE field_name = 'SCIENTIFIC_NAME'
      AND lower(value) LIKE '%homo sapiens%'
    LIMIT 100
""").fetchdf()

print(rows)
```

## 4. 回源 XML

任何核心表只有 `file_id`，完整 XML 路径在 `file_index`。

```python
run_acc = "ERR000001"

rows = con.execute(f"""
    SELECT
      r.run_accession,
      r.file_id,
      f.file_path,
      f.xml_kind,
      f.parse_status
    FROM read_parquet('{root}/core/run_core/data.parquet') r
    LEFT JOIN read_parquet('{root}/file_index/data.parquet') f
      ON r.file_id = f.file_id
    WHERE r.run_accession = ?
""", [run_acc]).fetchdf()

print(rows)
```

拿到 `file_path` 后可以直接查看原始 XML：

```bash
less /data/p252701008/datasets/SRA/NCBI_SRA_Metadata_Full_20260516/...
```

## 5. 关系表用法

查某个实体的所有出边：

```python
acc = "ERR000001"

rows = con.execute(f"""
    SELECT *
    FROM read_parquet('{root}/relation_index/data.parquet')
    WHERE src_accession = ?
""", [acc]).fetchdf()

print(rows)
```

查所有 `RUN -> EXPERIMENT` 关系：

```python
rows = con.execute(f"""
    SELECT src_accession AS run_accession, dst_accession AS experiment_accession
    FROM read_parquet('{root}/relation_index/data.parquet')
    WHERE relation_type = 'RUN_TO_EXPERIMENT'
    LIMIT 100
""").fetchdf()

print(rows)
```

## 6. 质量状态

转换摘要：

```text
/data/shared/sra_xml_index_20260516_cpp_stress_100000_fixed_study/conversion_summary.json
```

QC 报告：

```text
/home/m252202014/SRA/results/sra_xml_index_20260516/cpp_stress_100000_fixed_study_qc.md
/home/m252202014/SRA/results/sra_xml_index_20260516/cpp_stress_100000_fixed_study_qc.json
```

当前 100k pilot 的重要状态：

- `parse_failure_rate = 0`
- TSV 数据行数与 Parquet 行数全部一致
- `study_core.study_type` 已修复，缺失率为 0
- 已用 `validate_against_xml.py` 随机抽样 1000 个 XML 回查原始 XML，核心字段、关系字段、BioSample/BioProject、sample attributes 准确率均为 100%
- 这是 100k stress pilot，不是全量索引

自动回查脚本：

```text
/home/m252202014/SRA/code/sra_xml_index_cpp/validate_against_xml.py
```

示例命令：

```bash
source /usr/local/anaconda3/etc/profile.d/conda.sh
conda activate tss

python /home/m252202014/SRA/code/sra_xml_index_cpp/validate_against_xml.py \
  --parquet-root /data/shared/sra_xml_index_20260516_cpp_stress_100000_fixed_study \
  --sample-size 1000 \
  --seed 20260604 \
  --out-json /home/m252202014/SRA/results/sra_xml_index_20260516/validate_against_xml_100k_sample1000.json \
  --out-md /home/m252202014/SRA/results/sra_xml_index_20260516/validate_against_xml_100k_sample1000.md
```

验证报告：

```text
/home/m252202014/SRA/results/sra_xml_index_20260516/validate_against_xml_100k_sample1000.md
/home/m252202014/SRA/results/sra_xml_index_20260516/validate_against_xml_100k_sample1000.json
```

## 7. 注意事项

- 不要把这个 100k pilot 当作全量数据库。
- 跨 accession 的闭合率在 100k 子集里会偏低，因为目标 EXPERIMENT/SAMPLE/STUDY 可能不在这 100k 目录中。
- 如果要做全量检索，下一步需要跑全量 manifest 和全量核心解析。
- 如果只想试查询语法和字段结构，这个目录已经够用。
