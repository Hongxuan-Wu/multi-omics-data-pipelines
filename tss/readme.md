# tss——目标转录组数据筛选与下载流程

本目录说明 TSS 或转录组目标数据如何从 RefSeq 与 SRA 的关联结果中筛选出来。这里不直接保存全量数据，只保存流程文档、查询逻辑和最终筛选原则。

## 数据来源

4090 上可检查的 SRA 数据入口：

```text
/data/shared/SRA
/data/shared/sra_parquet
```

H100 上可检查的 SRA XML full 索引入口：

```text
/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1
```

RefSeq 原始数据已下载到：

```text
/data3/m252202014/NCBI_data/RefSeq/raw/assembly_summary_refseq.txt
```

## 目录结构

```text
.
├── RefSeq与SRA关联查询流程.md       # RefSeq-SRA 关联、筛选和下载列表生成
├── TSS数据挖掘.md                   # 早期综合草案，保留作历史参考
└── readme.md
```

## 当前主线

1. RefSeq 侧先从 `assembly_summary_refseq.txt` 生成 `refseq_assembly_core.parquet`。
2. SRA 侧使用 `SRA_Accessions` Parquet 过滤可下载 RUN。
3. SRA XML full 索引用于补充 sample attributes、library strategy、platform、BioSample/BioProject/Taxon。
4. 优先用 BioSample 关联 RefSeq 和 SRA。
5. 生成 `selected_sra_runs.tsv` 作为后续下载输入。

具体 SQL 和字段见 `RefSeq与SRA关联查询流程.md`。
