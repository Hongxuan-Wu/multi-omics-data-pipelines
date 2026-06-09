# sra-metadata——SRA 元数据索引构建与使用

本目录只负责 SRA 侧数据，不负责 RefSeq 侧处理。SRA 侧目前有两条稳定链路：

1. `SRA_Accessions`：NCBI 提供的全库 accession 索引 TSV，适合快速判断 accession 类型、状态、可见性、BioSample/BioProject 关系和 RUN 是否可下载。
2. `SRA XML Metadata`：NCBI SRA XML 快照，保存更完整的 RUN、EXPERIMENT、SAMPLE、STUDY、relation、sample attributes 和 XML path inventory。

两者互补：`SRA_Accessions` 快、轻、适合粗筛；`SRA XML Metadata` 信息更全，适合回查样本属性、文库策略、平台、关系闭合和 XML 字段路径。

## 服务器上的当前索引位置

H100 上的 SRA_Accessions 索引入口：

```text
/data3/m252202014/NCBI_data/SRA/SRA_Accessions/index/sra_parquet
```

H100 上的 SRA XML full streaming v1 索引真实路径：

```text
/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1
```

H100 上整理后的 SRA XML 索引统一入口：

```text
/data3/m252202014/NCBI_data/SRA/XML_Metadata/index/20260516_full_streaming_v1
```

## 阅读顺序

```text
sra-metadata数据包预处理.md              # 总览：SRA_Accessions 与 XML 两条预处理链路
sra-metadata数据下载.md                  # 原始数据下载地址、服务器路径、下载校验
sra-metadata数据分析.md                  # SRA_Accessions 和 XML metadata 分别能筛什么
sra_accession 详细统计数据.md            # SRA_Accessions 原始统计键值结果
sra_accession 详细统计数据可视化版.md    # SRA_Accessions 统计速览版
SRA_Accessions索引构建与使用.md          # SRA_Accessions TSV -> Parquet 索引 -> 查询
SRA_XML全量索引构建与使用.md             # SRA XML full snapshot -> full streaming v1 索引 -> 查询
sra-metadata数据调用方式.md              # DuckDB/Python 调用两个索引
```

## 目录结构

```text
.
├── readme.md
├── sra-metadata数据包预处理.md           # 预处理入口说明
├── sra-metadata数据下载.md               # SRA metadata 下载说明
├── sra-metadata数据分析.md               # SRA metadata 字段和实际筛选逻辑说明
├── sra-metadata数据调用方式.md           # 索引调用方式说明
├── sra_accession 详细统计数据.md         # SRA_Accessions 关系统计旧版
├── sra_accession 详细统计数据可视化版.md # SRA_Accessions 详细统计新版
├── SRA_Accessions索引构建与使用.md       # 当前 SRA_Accessions 索引主说明
├── SRA_XML全量索引构建与使用.md          # 当前 SRA XML full streaming v1 索引主说明
├── TSS数据处理.md                       # 旧版 SRA/RefSeq/TSS 综合草案，保留作历史参考
├── sra_accessions_audit_full_20260601/
│   ├── code/                           # SRA_Accessions 审计、Parquet 转换和关系统计代码
│   ├── logs/                           # 早期并行审计 chunk 日志
│   └── outputs/                        # 审计报告和 chunk 统计
├── sra_xml_annotations/                # RNA-seq 与非 RNA-seq XML 示例及人工注释
└── sra_xml_index_full_streaming_v1/
    ├── README.md                       # H100 full streaming v1 代码包说明
    ├── docs/                           # 查询说明
    ├── fixtures/                       # targeted fixture 清单
    ├── run_bundle/                     # full 运行包记录
    ├── schema/                         # schema contract
    └── scripts/                        # 仅保留 full 实际使用的 builder/finalizer/validation 脚本
```
