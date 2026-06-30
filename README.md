# multi-omics-data-pipelines——转录组学数据处理与校验文档

本仓库用于说明和校验转录组相关数据处理流程。仓库重点记录四件事：

1. 数据来源：SRA、SRA XML、RefSeq 数据从哪里来，原始文件放在哪里。
2. 索引构建：SRA_Accessions 索引和 SRA XML 全量索引如何从原始数据构建出来。
3. 使用方式：如何用 DuckDB/Python 查询已经构建好的索引。
4. 关联逻辑：RefSeq 与 SRA 如何通过 BioSample、BioProject、TaxID 等字段关联，并用于筛选、下载目标数据。

## 当前服务器数据入口

H100 服务器：

```text
/data3/m252202014/NCBI_data
/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1
/data3/shared/sra/NCBI_SRA_Metadata_Full_20260516
/data3/m252202014/NCBI_data/RefSeq/raw/assembly_summary_refseq.txt
```

## 目录结构

```text
.
├── sra-metadata/        # SRA_Accessions 与 SRA XML metadata 的下载、索引构建、查询和校验
├── refseq/              # RefSeq 数据来源、预处理目标和与 SRA 关联所需字段
├── tss/                 # TSS 目标数据筛选、RefSeq-SRA 关联查询和后续下载流程
├── type3_promoter/      # III 型启动子数据挖掘流程，目前为占位文档
└── README.md            # 仓库总说明
```
