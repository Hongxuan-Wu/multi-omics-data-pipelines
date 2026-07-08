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
├── SRA_Run_Members头表构建与RNA-seq筛选流程.md  # 当前 SRA 侧 Run 头表构建、Step 1/2/3c 和 471,792 结果解释
├── sra_run_members_head_table_pipeline/        # 上述流程对应的脚本、测试和运行记录，用于代码/流程审核
├── RefSeq与SRA关联查询流程.md       # RefSeq-SRA 关联、筛选和下载列表生成
├── TSS数据挖掘.md                   # 早期综合草案，保留作历史参考
└── readme.md
```

## 当前主线

1. SRA 侧先用 `SRA_Run_Members` 生成 member-level 头表，保留 Run -> Experiment -> Sample/BioSample 关系。
2. Step 1 在 `SRA_Run_Members` 内部做 live、Spots/Bases 非零、Experiment/Sample/BioSample 非空硬筛选。
3. Step 2 join `SRA_Accessions Type=RUN`，只补 `Visibility=public` 可见性 gate。
4. Step 3c 使用 SRA XML full index 筛选 ordinary transcriptomic RNA-seq 和 A/B 级 wildtype 证据，输出 `471,792` 个 no-exclusion Run。
5. RefSeq 侧再从 `assembly_summary_refseq.txt` 生成 `refseq_assembly_core.parquet`，后续优先用 BioSample 与 SRA 头表关联。

SRA 侧头表生产见 `SRA_Run_Members头表构建与RNA-seq筛选流程.md`。
RefSeq-SRA 关联 SQL 和字段见 `RefSeq与SRA关联查询流程.md`。
