# Step 3c no-exclusion 随机 50 条官网人工校验表

## 目的

从 Step 3c no-exclusion 最终 `471,792` 条 Run 中抽取 50 条，用于到官方网页人工核验：

```text
1. 是否为 RNA-seq / TRANSCRIPTOMIC
2. 是否有 wildtype 相关证据
```

## 抽样口径

```text
population_table = /home/m252202014/TSS/02_stage2_run_members_head_table/step3c_xml_semantic_no_exclusion_filtering/production_runs/wildtype_ab_no_exclusion_transcriptomic_rnaseq_generic_index_20260707/merged/tables/wildtype_ab_no_exclusion_transcriptomic_rnaseq_member_level.parquet
population_rows = 471792
sample_size = 50
seed = 20260708
method = ORDER BY hash(Run || seed) LIMIT sample_size
```

## 文件

```text
sample_records.tsv
sample_records.csv
manifest.json
README.md
```

## 官网链接使用

`primary_official_url` 根据 Run 前缀选择：

```text
SRR -> NCBI SRA Run Browser
ERR -> ENA Browser
DRR -> DDBJ Search
```

同时保留 `ncbi_sra_url`、`ncbi_run_browser_url`、`ena_browser_url`、`ddbj_search_url`，方便交叉检索。

## 人工记录列

```text
manual_official_rnaseq_confirmed
manual_official_wildtype_confirmed
manual_notes
```

这三个列留空，供人工检索后填写。
